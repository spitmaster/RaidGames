-- GameLobby/Tests/run_match.lua
-- 驱动「通讯线路」：模拟收发 addon message（CHAT_MSG_ADDON），验证
--   ① 参与端收 Start→邀请→Join→Begin→倒计时→上报→收 Final 落战绩
--   ② host 端收两份并列最高分 Result → 触发 Tie 加赛
-- 这是多人核心逻辑（除真实网络外）的端到端验证。
-- 运行：lua GameLobby/Tests/run_match.lua

local env = dofile("GameLobby/Tests/headless_env.lua")

local errs = 0
local function check(name, cond, extra)
    if cond then print("  [PASS] " .. name)
    else print("  [FAIL] " .. name .. (extra and ("  ← " .. tostring(extra)) or "")); errs = errs + 1 end
end
local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then print("  [ERR ] " .. name); print(tostring(err):match("[^\n]*\n[^\n]*")); errs = errs + 1 end
end

-- ---- 加载库桩 + 全插件 ----
dofile("GameLobby/Libs/LibStub/LibStub.lua"); dofile("GameLobby/Libs/LibBase64/LibBase64.lua")
do
    LibStub:NewLibrary("LibSerialize", 99); local LS = LibStub("LibSerialize")
    local store, seq = {}, 0
    LS.Serialize = function(_, t) seq = seq + 1; local k = "\1S" .. seq .. "\1"; store[k] = t; return k end
    LS.Deserialize = function(_, s) if store[s] then return true, store[s] end return false, "x" end
    LibStub:NewLibrary("LibDeflate", 99); local LD = LibStub("LibDeflate")
    LD.CompressDeflate = function(_, s) return s end; LD.DecompressDeflate = function(_, s) return s end
    LD.EncodeForPrint = function(_, s) return s end; LD.DecodeForPrint = function(_, s) return s end
end
for _, rel in ipairs({
    "Core/Bootstrap.lua","Core/Comm.lua","Core/Roster.lua","Core/GameRegistry.lua","Core/Stats.lua",
    "Core/Match.lua","Core/UI/Theme.lua","Core/UI/Frame.lua","Core/UI/Widgets.lua","Core/UI/Lobby.lua",
    "Core/UI/Playing.lua","Core/UI/Results.lua","Core/UI/History.lua","Core/UI/About.lua",
    "Core/UI/ImportPanel.lua","Core/UI/ExportPanel.lua","Core/UI/Popups.lua","Core/GameImport.lua",
    "Games/SpeedClick.lua","Core/Init.lua",
}) do assert(loadfile("GameLobby/" .. rel))() end
local GL = _G.GameLobby
env.FireEvent("PLAYER_LOGIN", true, false)

local PREFIX = GL.Comm.PREFIX
-- 模拟「别的玩家」发来一条 addon message
local function recv(body, sender)
    env.FireEvent("CHAT_MSG_ADDON", PREFIX, body, "RAID", sender or "Maginus-测试服")
end
-- 找最近一条发出的指定 cmd 广播
local function lastSent(cmd)
    for i = #env.sent, 1, -1 do
        local m = env.sent[i]
        if m.msg and m.msg:match("^" .. cmd .. "[,$]") or (m.msg and m.msg == cmd) or (m.msg and m.msg:match("^" .. cmd .. ",")) then return m end
    end
end

print("======== 场景①：本端是参与者 ========")
env.state.isLeader = false; env.state.isAssist = false; env.state.inGroup = true; env.state.inRaid = true
env.state.members = {
    { name = "Tester", classFile = "WARRIOR", online = true },
    { name = "Maginus", classFile = "MAGE", isLeader = true, online = true },
}
env.FireEvent("GROUP_ROSTER_UPDATE")
local me = GL.Roster:Me()
local host = GL.Roster:Norm("Maginus")
local mid = "1716800000-Maginus"

step("收 Start（host=Maginus 发起 speedclick）", function()
    recv(("Start,%s,speedclick,1.0.0,%s,10,10,"):format(mid, host), host)
end)
check("收 Start 后建立 ctx", (function()
    local ctx = GL.Match:GetContext(); return ctx and ctx.matchId == mid and ctx.gameId == "speedclick"
end)(), "ctx.matchId=" .. tostring(GL.Match:GetContext() and GL.Match:GetContext().matchId))

step("本端 Join（点准备/参与）", function()
    if GL.Match.Join then GL.Match:Join() end
    if GL.Match.SetReady then GL.Match:SetReady(true) end
end)
check("本端广播了 Join", (function()
    for _, m in ipairs(env.sent) do if m.msg and m.msg:match("^Join,") then return true end end
end)())

step("收 Begin → 倒计时", function() recv(("Begin,%s,0"):format(mid), host); env.advance(5) end)
check("进入 PLAYING", (function() local c = GL.Match:GetContext(); return c and c.phase == "PLAYING" end)(),
      "phase=" .. tostring(GL.Match:GetContext() and GL.Match:GetContext().phase))

step("本端计分并到点上报", function()
    if GL.Match.ReportScore then GL.Match:ReportScore(95) end
    env.advance(12)
end)
check("本端广播了 Result", (function()
    for _, m in ipairs(env.sent) do if m.msg and m.msg:match("^Result,") then return true end end
end)())

step("收 host 的 Final（含排名）", function()
    recv(("Final,%s,%s,%s:187,%s:95"):format(mid, host, host, me), host)
end)
check("收 Final 后落战绩（参与即记）", (GL.Stats:GetSummary().total or 0) >= 1,
      "total=" .. tostring(GL.Stats:GetSummary().total))
step("Results 屏渲染", function() GL.UI:ShowScreen("results") end)
step("收尾 Close", function() if GL.Match.Close then GL.Match:Close() end end)

print("======== 场景②：本端是 host，冠军并列 → 加赛 ========")
env.sent = {}   -- 清空发包记录
env.state.isLeader = true
env.state.members = {
    { name = "Tester", classFile = "WARRIOR", isLeader = true, online = true },
    { name = "Healer", classFile = "PRIEST", online = true },
    { name = "Maginus", classFile = "MAGE", online = true },
}
env.FireEvent("GROUP_ROSTER_UPDATE")

step("host 发起", function() GL.Match:Start("speedclick", { prize = { mode = "friendly" } }) end)
local mid2 = GL.Match:GetContext() and GL.Match:GetContext().matchId
check("生成 matchId", mid2 ~= nil)
step("host 开局 + 进入比赛", function() if GL.Match.Begin then GL.Match:Begin() end; env.advance(5) end)

local H = GL.Roster:Norm("Healer")
local Mg = GL.Roster:Norm("Maginus")
step("收两份并列最高分 + 本端低分", function()
    recv(("Result,%s,%s,200,0"):format(mid2, H), H)
    recv(("Result,%s,%s,200,0"):format(mid2, Mg), Mg)
    if GL.Match.ReportScore then GL.Match:ReportScore(120) end
    env.advance(15)   -- 跨过计时 + 3 秒收集窗
end)
check("host 广播了 Tie（冠军并列触发加赛）", (function()
    for _, m in ipairs(env.sent) do if m.msg and m.msg:match("^Tie,") then return true end end
end)(), "sent cmds: " .. (function() local t={} for _,m in ipairs(env.sent) do if m.msg then t[#t+1]=m.msg:match("^(%a+)") end end return table.concat(t,",") end)())

print("")
print(string.format("======== 结果：%d 处失败 ========", errs))
os.exit(errs == 0 and 0 or 1)
