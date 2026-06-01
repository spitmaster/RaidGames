-- GameLobby/Tests/run_all.lua
-- 无头加载整个插件 + 驱动 UI/状态机/战绩/导入导出，批量抓运行时错。
-- 运行：lua GameLobby/Tests/run_all.lua  （cwd = 仓库根）
-- 退出码 0 = 全过；非 0 = 有错（详见输出）。

local env = dofile("GameLobby/Tests/headless_env.lua")

local errs = {}
local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        print(string.format("  [PASS] %s", name))
    else
        print(string.format("  [FAIL] %s", name))
        local first = tostring(err):match("[^\n]*") or tostring(err)
        print("         " .. first)
        table.insert(errs, { name = name, err = err })
    end
end

-- ============ 1) 库桩 + 按 .toc 顺序加载全插件 ============
print("== 1) 加载插件文件 ==")

-- 先建 LibStub（真），注册 LibDeflate/LibSerialize 桩（逻辑测试不需要真压缩）
dofile("GameLobby/Libs/LibStub/LibStub.lua")
dofile("GameLobby/Libs/LibBase64/LibBase64.lua")   -- 真，挂 _G.GameLobby_Lib.Base64
do
    local store, seq = {}, 0
    LibStub:NewLibrary("LibSerialize", 99)
    local LS = LibStub("LibSerialize")
    LS.Serialize = function(_, t) seq = seq + 1; local k = "\1SER" .. seq .. "\1"; store[k] = t; return k end
    LS.Deserialize = function(_, s) local t = store[s]; if t then return true, t end; return false, "stub-bad" end
    LibStub:NewLibrary("LibDeflate", 99)
    local LD = LibStub("LibDeflate")
    LD.CompressDeflate = function(_, s) return s end
    LD.DecompressDeflate = function(_, s) return s end
    LD.EncodeForPrint = function(_, s) return s end
    LD.DecodeForPrint = function(_, s) return s end
end

local loadOrder = {
    "Core/Bootstrap.lua",
    "Core/Comm.lua",
    "Core/Roster.lua",
    "Core/GameRegistry.lua",
    "Core/Stats.lua",
    "Core/Match.lua",
    "Core/UI/Theme.lua",
    "Core/UI/Frame.lua",
    -- Widgets 子系统：Primitives 必须先（其他组件依赖它），其余无内部依赖。
    "Core/UI/Widgets/Primitives.lua",
    "Core/UI/Widgets/SectionLabel.lua",
    "Core/UI/Widgets/Button.lua",
    "Core/UI/Widgets/SmashButton.lua",
    "Core/UI/Widgets/PlayerCard.lua",
    "Core/UI/Widgets/LootCard.lua",
    "Core/UI/Widgets/GameTile.lua",
    "Core/UI/Widgets/Castbar.lua",
    "Core/UI/Widgets/RankRow.lua",
    "Core/UI/Widgets/StatCard.lua",
    "Core/UI/Widgets/LogStrip.lua",
    "Core/UI/Widgets/ScrollList.lua",
    "Core/UI/Lobby.lua",
    "Core/UI/Playing.lua",
    "Core/UI/Results.lua",
    "Core/UI/History.lua",
    "Core/UI/About.lua",
    "Core/UI/ImportPanel.lua",
    "Core/UI/ExportPanel.lua",
    "Core/UI/Popups.lua",
    "Core/GameImport.lua",
    "Core/Push.lua",
    "Games/SpeedClick.lua",
    "Core/Init.lua",
}
for _, rel in ipairs(loadOrder) do
    step("load " .. rel, function()
        local chunk = assert(loadfile("GameLobby/" .. rel))
        chunk()
    end)
end

local GL = _G.GameLobby
assert(GL, "致命：_G.GameLobby 未建立，后续无法继续")

-- ============ 2) 引导 flush（注册 slash、Comm、各模块 Init）============
print("== 2) 引导 flush ==")
step("PLAYER_LOGIN flush", function() env.FireEvent("PLAYER_LOGIN", true, false) end)
step("PLAYER_ENTERING_WORLD", function() env.FireEvent("PLAYER_ENTERING_WORLD", true, false) end)
step("slash /gl 已注册", function()
    assert(SlashCmdList and SlashCmdList["GAMELOBBY"], "slash 未注册")
end)
step("极速按键已注册到 Games", function()
    assert(GL.Games and GL.Games:Get("speedclick"), "speedclick 未注册")
end)

-- ============ 3) 设置一个 5 人团队 roster ============
print("== 3) roster + 打开 UI ==")
env.state.inGroup = true; env.state.inRaid = true; env.state.isLeader = true
env.state.members = {
    { name = "Tester", classFile = "WARRIOR", isLeader = true, online = true },
    { name = "Healer", classFile = "PRIEST", online = true },
    { name = "Maginus", classFile = "MAGE", online = true },
    { name = "Backstab", classFile = "ROGUE", online = true },
    { name = "Shockwave", classFile = "SHAMAN", online = true },
}
step("GROUP_ROSTER_UPDATE", function() env.FireEvent("GROUP_ROSTER_UPDATE") end)
step("UI:Show（建主框架）", function() GL.UI:Show() end)

-- ============ 4) 逐屏渲染 ============
print("== 4) 逐屏渲染 ==")
for _, scr in ipairs({ "lobby", "history", "about", "playing", "results" }) do
    step("ShowScreen " .. scr, function() GL.UI:ShowScreen(scr) end)
end
step("RefreshBadge", function() GL.UI:RefreshBadge() end)
step("倒计时遮罩 Countdown(3..GO)", function()
    for _, n in ipairs({ 3, 2, 1, 0 }) do GL.UI:Countdown(n) end
end)
step("日志条 Log", function() GL.UI:Log("sys", "测试日志"); GL.UI:Log("warn", "警告") end)
step("导入面板 ShowImport/Hide", function() GL.UI:ShowImport(); GL.UI:HideImport() end)
step("导出面板 ShowExport/Hide", function() GL.UI:ShowExport("测试", "!GL:1!abcdef"); if GL.UI.HideExport then GL.UI:HideExport() end end)
-- 注：整包分享（GetShareBundle/ShowShare）已于 2026-06-01 移除（D20，只分享单游戏）。单游戏导出走 ShowExport（上一步已覆盖）。

-- ============ 4b) PlayerCard 右键推送菜单 ============
print("== 4b) PlayerCard 右键推送菜单 ==")
local W = GL.UI and GL.UI.Widgets
step("BuildPlayerPushMenu(他人) 含「推送：极速按键」", function()
    assert(W and W.BuildPlayerPushMenu, "BuildPlayerPushMenu 未暴露")
    local menu = W.BuildPlayerPushMenu("Healer", "Healer-测试服", false)
    assert(type(menu) == "table" and #menu >= 2, "菜单结构异常")
    assert(menu[1].isTitle, "首项应为标题")
    local hasPush = false
    for _, item in ipairs(menu) do
        if type(item.text) == "string" and item.text:match("^推送：") then hasPush = true end
    end
    assert(hasPush, "他人卡应至少有一条「推送：」项（speedclick 已注册且可导出）")
end)
step("BuildPlayerPushMenu(自己) 不含推送项", function()
    local menu = W.BuildPlayerPushMenu("Tester", "Tester-测试服", true)
    for _, item in ipairs(menu) do
        assert(not (type(item.text) == "string" and item.text:match("^推送：")),
            "自己的卡不应出现推送项")
    end
end)
step("PlayerCard 实例 SetData + ShowContextMenu 不抛错", function()
    local card = W.PlayerCard(GL.UI._frame or UIParent)
    card:SetData({ name = "Healer", classFile = "PRIEST", pushTarget = "Healer-测试服", isSelf = false })
    card:ShowContextMenu()
end)

-- ============ 5) Stats 战绩（直接喂 MATCH_FINAL）============
print("== 5) Stats ==")
step("Stats:GetSummary 初值", function() local s = GL.Stats:GetSummary(); assert(type(s) == "table") end)
step("Emit MATCH_FINAL 记一局", function()
    local me = GL.Roster:Me()                 -- 用真实归一化名，确保 Stats 能认出"我参与了"
    local healer = GL.Roster:Norm("Healer")
    GL:Emit("MATCH_FINAL", {
        matchId = "m1", gameId = "speedclick", duration = 10,
        winner = me,
        prize = { mode = "friendly" },
        ranking = {
            { name = me, score = 187, cps = 18.7, classFile = "WARRIOR" },
            { name = healer, score = 150, cps = 15.0, classFile = "PRIEST" },
        },
        players = { [me] = { name = "Tester", classFile = "WARRIOR", isSelf = true } },
    })
end)
step("Stats:GetSummary 累计", function()
    local s = GL.Stats:GetSummary(); assert((s.total or 0) >= 1, "总场次未累计")
end)
step("Stats:GetHistory", function() local h = GL.Stats:GetHistory(); assert(type(h) == "table") end)
step("History 屏渲染（有数据）", function() GL.UI:ShowScreen("history") end)
step("Stats:Clear", function() GL.Stats:Clear() end)

-- ============ 6) Match 全流程（host 端）============
print("== 6) Match 全流程（host）==")
step("Match:Start 发起", function()
    GL.Match:Start("speedclick", { prize = { mode = "custom", text = "5000 金币" } })
    local ctx = GL.Match:GetContext()
    assert(ctx and ctx.matchId, "未生成 matchId")
end)
step("Match:Begin + 倒计时推进", function()
    if GL.Match.Begin then GL.Match:Begin() end
    env.advance(5)   -- 跨过倒计时进入 PLAYING
end)
step("PLAYING 屏 + 模拟点击", function()
    GL.UI:ShowScreen("playing")
    local ctx = GL.Match:GetContext()
    -- 模拟自己点击：直接走 api（若 Match 暴露）或 ReportScore
    if GL.Match.ReportScore then GL.Match:ReportScore(120) end
end)
step("推进到结束 + 收集窗", function() env.advance(15) end)
step("结束后有 ctx（RESULTS/COLLECTING）", function()
    local ctx = GL.Match:GetContext()
    assert(ctx and ctx.phase, "比赛结束后无 phase: " .. tostring(ctx and ctx.phase))
end)
step("Results 屏渲染", function() GL.UI:ShowScreen("results") end)
step("Match:Close", function() if GL.Match.Close then GL.Match:Close() end end)

-- ============ 7) 收 Start 弹邀请（参与端模拟）============
print("== 7) 参与端：收 Start 弹邀请 ==")
step("Emit MATCH_INVITED → UI:Invite", function()
    local ctx = { matchId = "m2", gameId = "speedclick", host = "Healer-测试服",
                  duration = 10, prize = { mode = "friendly" }, players = {} }
    if GL.UI.Invite then GL.UI:Invite(ctx) end
end)

-- ============ 7b) 单人模式：CanInitiate + Match:Start 自动 Begin → 跑通一局 ============
print("== 7b) 单人模式 ==")
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
if GL.Match.Close then GL.Match:Close() end
step("CanInitiate 单人允许", function() assert(GL.Roster:CanInitiate(), "单人应允许发起") end)
step("Match:Start 单人 → 自动进入 COUNTDOWN", function()
    GL.Match:Start("speedclick", { prize = { mode = "friendly" } })
    -- Start 内部应自动 Begin → setPhase(COUNTDOWN)
    local p = GL.Match:GetContext() and GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "solo Start 后应进入倒计时/比赛，实际: " .. tostring(p))
end)
step("单人推进比赛 + ReportScore + 收尾", function()
    env.advance(5); if GL.Match.ReportScore then GL.Match:ReportScore(80) end
    env.advance(15)
    local p = GL.Match:GetContext() and GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "单人比赛收尾 phase 异常: " .. tostring(p))
end)
step("单人 Results 屏渲染", function() GL.UI:ShowScreen("results") end)
if GL.Match.Close then GL.Match:Close() end

-- ============ 7c) canvas 档地基冒烟：自绘游戏生命周期 + 新 api（D21 通用容器）============
print("== 7c) canvas 档地基 ==")
local cTrace = {}
local cSeed
GL:RegisterGame({
    id = "smoketest_canvas", name = "冒烟画布", version = "1.0.0",
    tier = "canvas", endMode = "timed", scoreOrder = "desc", scoreUnit = "层",
    duration = 10, needsKeyboard = true, seeded = true,
    scoreCap = function() return 100 end,
    setup = function(ctx, api)
        cTrace.setup = true
        local cv = api:Canvas(); assert(cv, "canvas 档应能拿到 api:Canvas()")
        cSeed = api:GetSeed(); assert(type(cSeed) == "number", "GetSeed 应返回数字")
        local t = cv:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(1, 0, 0, 1); t:SetSize(10, 10)
    end,
    start = function(ctx, api)
        cTrace.start = true
        api:CaptureKeyboard(function() end)   -- 申请键盘（框架托管 propagate/ESC/归还）
        api:SetScore(42)                      -- 直接设分（上/下100层式）
    end,
    stop = function() cTrace.stop = true end,
    teardown = function() cTrace.teardown = true end,
})
step("注册 canvas 冒烟游戏", function()
    assert(GL.Games:Get("smoketest_canvas"), "应已注册")
end)
step("canvas 档跑通一局（单人）+ setup/start 被调", function()
    GL.Match:Start("smoketest_canvas", { prize = { mode = "friendly" } })
    env.advance(5)   -- 过倒计时进入 PLAYING
    assert(cTrace.setup, "setup 未被调用")
    assert(cTrace.start, "start 未被调用")
    assert(GL.Match:GetContext().scores[GL.Roster:Me()] == 42, "SetScore(42) 未生效")
end)
step("时间到 → stop 被调 + 收尾", function()
    env.advance(12)  -- 跑完 10s + 收集窗口
    assert(cTrace.stop, "stop 未在时间到时调用")
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "canvas 局收尾 phase 异常: " .. tostring(p))
end)
step("Close → teardown 被调（键盘归还）", function()
    GL.Match:Close()
    assert(cTrace.teardown, "teardown 未在 Close 时调用")
end)

-- ============ 8) 导出（reason 路径 + 占位游戏）============
print("== 8) 导出 ==")
step("ExportGame(speedclick) 成功", function()
    local s, r = GL.Import:ExportGame("speedclick")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)
step("ExportGame(down100) 应拒绝", function()
    local s = GL.Import:ExportGame("down100")
    assert(s == nil, "占位游戏不应可导出")
end)

-- ============ 汇总 ============
print("")
print(string.format("==== 结果：%d 个步骤失败 ====", #errs))
for _, e in ipairs(errs) do
    print("---- " .. e.name .. " ----")
    print(e.err)
end
os.exit(#errs == 0 and 0 or 1)
