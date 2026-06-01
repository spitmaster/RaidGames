-- GameLobby/Tests/up100_selftest.lua
-- 「是男人就上 100 层」(up100) 独立无头自测。照 run_all.lua 7c) canvas 档地基范例。
-- 运行（仓库根）：lua GameLobby/Tests/up100_selftest.lua  → exit 0 全过。

local env = dofile("GameLobby/Tests/headless_env.lua")

local errs = {}
local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then print("  [PASS] " .. name)
    else
        print("  [FAIL] " .. name)
        print("         " .. (tostring(err):match("[^\n]*") or tostring(err)))
        table.insert(errs, { name = name, err = err })
    end
end

-- ===== 1) 库桩 + 按 .toc 顺序加载核心 + 本游戏 =====
dofile("GameLobby/Libs/LibStub/LibStub.lua")
dofile("GameLobby/Libs/LibBase64/LibBase64.lua")
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
    "Core/Bootstrap.lua", "Core/Comm.lua", "Core/Roster.lua", "Core/GameRegistry.lua",
    "Core/Stats.lua", "Core/Match.lua", "Core/UI/Theme.lua", "Core/UI/Frame.lua",
    "Core/UI/Widgets/Primitives.lua", "Core/UI/Widgets/SectionLabel.lua",
    "Core/UI/Widgets/Button.lua", "Core/UI/Widgets/SmashButton.lua",
    "Core/UI/Widgets/PlayerCard.lua", "Core/UI/Widgets/LootCard.lua",
    "Core/UI/Widgets/GameTile.lua", "Core/UI/Widgets/Castbar.lua",
    "Core/UI/Widgets/RankRow.lua", "Core/UI/Widgets/StatCard.lua",
    "Core/UI/Widgets/LogStrip.lua", "Core/UI/Widgets/ScrollList.lua",
    "Core/UI/Lobby.lua", "Core/UI/Playing.lua", "Core/UI/Results.lua",
    "Core/UI/History.lua", "Core/UI/About.lua", "Core/UI/ImportPanel.lua",
    "Core/UI/ExportPanel.lua", "Core/UI/Popups.lua", "Core/GameImport.lua",
    "Core/Push.lua", "Games/SpeedClick.lua", "Games/Up100.lua", "Core/Init.lua",
}
for _, rel in ipairs(loadOrder) do
    step("load " .. rel, function() assert(loadfile("GameLobby/" .. rel))() end)
end

local GL = _G.GameLobby
assert(GL, "致命：_G.GameLobby 未建立")

-- ===== 2) 引导 flush =====
step("PLAYER_LOGIN flush", function() env.FireEvent("PLAYER_LOGIN", true, false) end)
step("PLAYER_ENTERING_WORLD", function() env.FireEvent("PLAYER_ENTERING_WORLD", true, false) end)

-- ===== 3) up100 注册成功（1.0.0 替换 0.0.0 占位、非 locked、可导出）=====
step("up100 已注册且非 locked", function()
    local g = GL.Games:Get("up100")
    assert(g, "up100 未注册")
    assert(g.version == "1.0.0", "版本未替换占位，实际: " .. tostring(g.version))
    assert(not g.locked, "up100 不应仍是 locked 占位")
    assert(g.tier == "canvas" and g.endMode == "timed" and g.scoreOrder == "desc", "元数据不符")
end)
step("up100 可导出 !GL: 串（自包含 code 已挂）", function()
    local s, r = GL.Import:ExportGame("up100")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)

-- ===== 4) 单人跑一整局：setup/start → 驱动循环 → SetScore → 到 RESULTS → stop/teardown =====
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
if GL.Match.Close then GL.Match:Close() end

step("UI:Show 建主框架（PlayingScreen 含 canvas）", function() GL.UI:Show() end)

step("Match:Start up100 单人 → 进入倒计时/比赛", function()
    GL.Match:Start("up100", { prize = { mode = "friendly" } })
    -- 钉死 matchId → GetSeed 确定 → 平台布局稳定 → 下面的按键序列可复现地爬层。
    -- （setup 在过倒计时时才跑读 seed，所以此处改 matchId 早于 setup 生效。）
    GL.Match:GetContext().matchId = "selftest-fixed-seed"
    local p = GL.Match:GetContext() and GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "Start 后 phase 异常: " .. tostring(p))
end)

step("过倒计时进入 PLAYING（setup/start 已被调）", function()
    GL.UI:ShowScreen("playing")
    env.advance(5)   -- 跨过 3-2-1-GO 倒计时
    local p = GL.Match:GetContext().phase
    assert(p == "PLAYING", "应进入 PLAYING，实际: " .. tostring(p))
end)

-- 拿到 canvas 并驱动循环：按右移 + 多帧 OnUpdate 让角色弹跳爬层。
local canvas = GL.UI:Canvas()
step("拿到 canvas 且角色/平台已建（setup 跑过）", function()
    assert(canvas, "Canvas() 返回 nil")
end)

step("驱动按键 + OnUpdate 循环（模拟「完美玩家」朝下一层落脚点转向，确定性爬层）", function()
    -- 用真实游戏状态（Match._api.G，本游戏 setup 挂的局内表）做「完美转向」：
    -- 每帧朝「比当前最高层更高一层」的平台 px 方向按键，对准后落脚 → 弹起 → 层数+1。
    -- 这模拟真人操作（朝下个落脚点走），且不依赖随机种子 → 确定性。只读 G，不写游戏内部。
    local G = GL.Match._api and GL.Match._api.G
    assert(G and G.platforms, "拿不到游戏局内状态 G（setup 未挂 api.G？）")
    local cur = nil   -- 当前按住的方向
    local function press(dir)
        if cur == dir then return end
        if cur then env.fireScript(canvas, "OnKeyUp", cur) end
        cur = dir
        if dir then env.fireScript(canvas, "OnKeyDown", dir) end
    end
    for _ = 1, 300 do
        -- 目标：下一层平台（maxTier 之上那层）的水平中心。
        local target = G.platforms[(G.maxTier or 1) + 1]
        if target then
            local charCenter = G.charX + G.charSize / 2
            local tgtCenter = target.px + G.pltW / 2
            if charCenter < tgtCenter - 4 then press("RIGHT")
            elseif charCenter > tgtCenter + 4 then press("LEFT")
            else press(nil) end
        end
        env.fireScript(canvas, "OnUpdate", 0.05)
    end
    press(nil)
end)

step("SetScore 已生效（完美玩家应爬若干层，分数落到 ctx.scores）", function()
    local me = GL.Roster:Me()
    local sc = GL.Match:GetContext().scores[me]
    assert(sc ~= nil, "未上报任何分（SetScore 未生效）")
    assert(sc >= 1, "完美转向应至少爬 1 层，实际: " .. tostring(sc))
    print("         （爬到层数 = " .. tostring(sc) .. "）")
end)

step("推进到时间到 → 收尾（RESULTS/IDLE），stop 被框架调用", function()
    env.advance(40)   -- 跑完 30s + 收集窗口
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "收尾 phase 异常: " .. tostring(p))
    -- stop 应已停掉 OnUpdate（再 fire 一次不抛错即可视作冻结）
    assert(canvas._scripts.OnUpdate == nil, "stop 未清除 OnUpdate（循环未停）")
end)

step("Results 屏渲染不抛错", function() GL.UI:ShowScreen("results") end)

step("Close → teardown（幂等清理）不抛错", function()
    if GL.Match.Close then GL.Match:Close() end
end)

-- ===== 5) 围观者分支：不绑输入不计分（IsSpectator 早退）=====
-- 复跑一局，把自己设为围观者，确认 start 不绑 OnUpdate、不上报分。
step("围观者：start 早退（不绑 OnUpdate）", function()
    if GL.Match.Close then GL.Match:Close() end
    GL.Match:Start("up100", { prize = { mode = "friendly" } })
    local ctx = GL.Match:GetContext()
    local me = GL.Roster:Me()
    -- 标记自己围观
    ctx.players[me] = ctx.players[me] or {}
    ctx.players[me].spectator = true
    GL.UI:ShowScreen("playing")
    env.advance(5)
    local cv = GL.UI:Canvas()
    assert(cv._scripts.OnUpdate == nil, "围观者不应绑 OnUpdate")
    env.advance(40)
    if GL.Match.Close then GL.Match:Close() end
end)

-- ===== 汇总 =====
print(string.format("==== 结果：%d 个步骤失败 ====", #errs))
for _, e in ipairs(errs) do print("---- " .. e.name .. " ----\n" .. e.err) end
os.exit(#errs == 0 and 0 or 1)
