-- GameLobby/Tests/duckhunt_selftest.lua
-- 打鸭子（duckhunt）独立无头自测：加载全插件 + DuckHunt，单人跑一局，
-- 模拟点中目标使分数累加，断言生命周期 setup/start/stop/teardown 被调、能到 RESULTS。
-- 运行：lua GameLobby/Tests/duckhunt_selftest.lua （cwd = 仓库根）。退出码 0 = 全过。
-- 注意：本文件仅自测用，不接主线程 run_all.lua（按任务边界：不改 run_all.lua / .toc）。

local env = dofile("GameLobby/Tests/headless_env.lua")

local errs = {}
local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        print(string.format("  [PASS] %s", name))
    else
        print(string.format("  [FAIL] %s", name))
        print("         " .. (tostring(err):match("[^\n]*") or tostring(err)))
        table.insert(errs, { name = name, err = err })
    end
end

-- ===== 库桩 + 按 .toc 顺序加载全插件（照 run_all.lua）=====
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
    "Core/Push.lua", "Games/SpeedClick.lua", "Games/DuckHunt.lua", "Core/Init.lua",
}
for _, rel in ipairs(loadOrder) do
    step("load " .. rel, function() assert(loadfile("GameLobby/" .. rel))() end)
end

local GL = _G.GameLobby
assert(GL, "致命：_G.GameLobby 未建立")

-- ===== 引导 flush =====
step("PLAYER_LOGIN flush", function() env.FireEvent("PLAYER_LOGIN", true, false) end)
step("PLAYER_ENTERING_WORLD", function() env.FireEvent("PLAYER_ENTERING_WORLD", true, false) end)

-- ===== duckhunt 已注册 =====
step("duckhunt 已注册到 Games", function()
    local d = GL.Games and GL.Games:Get("duckhunt")
    assert(d, "duckhunt 未注册")
    assert(d.tier == "canvas", "tier 应为 canvas")
    assert(d.endMode == "timed", "endMode 应为 timed")
    assert(d.scoreOrder == "desc", "scoreOrder 应为 desc")
    assert(d.needsKeyboard == false, "needsKeyboard 应为 false")
    assert(d.seeded == true, "seeded 应为 true")
    assert(type(d.scoreCap) == "function" and d.scoreCap(10) == 200, "scoreCap(10) 应为 200")
    assert(type(d.code) == "string" and d.code:find("duckhunt", 1, true), "def.code 应含自包含 SOURCE")
end)
step("duckhunt 出现在游戏格列表", function()
    local found = false
    for _, d in ipairs(GL.Games:List()) do if d.id == "duckhunt" then found = true end end
    assert(found, "duckhunt 应在 List() 中")
end)

-- ===== 单人模式：建 roster + 打开 UI（让 PlayingScreen/canvas 就绪）=====
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
step("UI:Show（建主框架 + PlayingScreen）", function() GL.UI:Show() end)

-- 用「探针」包住 duckhunt 的生命周期，确认各阶段被调（不改游戏本体）。
local trace = { setup = 0, start = 0, stop = 0, teardown = 0 }
do
    local d = GL.Games:Get("duckhunt")
    for _, ph in ipairs({ "setup", "start", "stop", "teardown" }) do
        local orig = d[ph]
        d[ph] = function(ctx, api)
            trace[ph] = trace[ph] + 1
            return orig(ctx, api)
        end
    end
end

-- ===== 单人跑一局 =====
step("Match:Start(duckhunt) 单人 → 进入倒计时", function()
    GL.Match:Start("duckhunt", { prize = { mode = "friendly" } })
    local p = GL.Match:GetContext() and GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "solo Start 后应进入倒计时/比赛，实际: " .. tostring(p))
end)

step("过倒计时进入 PLAYING + setup/start 被调", function()
    env.advance(5)   -- 跨过 3-2-1-GO 进入 PLAYING
    assert(GL.Match:GetContext().phase == "PLAYING", "应处于 PLAYING")
    assert(trace.setup >= 1, "setup 未被调用")
    assert(trace.start >= 1, "start 未被调用")
end)

step("OnUpdate 驱动目标移动（位置变化）", function()
    local cv = GL.UI:Canvas()
    assert(cv, "canvas 不存在")
    local state = cv._gl_duckhunt
    assert(state and state.targets and #state.targets >= 1, "目标池未建立")
    local t1 = state.targets[1]
    local x0, y0 = t1.x, t1.y
    env.fireScript(cv, "OnUpdate", 0.05)
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(t1.x ~= x0 or t1.y ~= y0, "OnUpdate 后目标位置应变化（dt 驱动）")
end)

step("点中目标使分数累加（AddScore via OnMouseDown）", function()
    local cv = GL.UI:Canvas()
    local state = cv._gl_duckhunt
    local before = GL.Match:GetContext().scores[GL.Roster:Me()] or 0
    -- 模拟点中前 3 个目标各一次。
    for i = 1, 3 do
        env.fireScript(state.targets[i].frame, "OnMouseDown", "LeftButton")
    end
    local after = GL.Match:GetContext().scores[GL.Roster:Me()] or 0
    assert(after == before + 3, string.format("分数应 +3：before=%d after=%d", before, after))
end)

step("命中后目标重生（位置可能变）+ 继续移动不抛错", function()
    local cv = GL.UI:Canvas()
    for _ = 1, 5 do env.fireScript(cv, "OnUpdate", 0.05) end
    -- 再点几次确认稳定累加。
    local state = cv._gl_duckhunt
    local before = GL.Match:GetContext().scores[GL.Roster:Me()] or 0
    env.fireScript(state.targets[2].frame, "OnMouseDown", "LeftButton")
    assert((GL.Match:GetContext().scores[GL.Roster:Me()] or 0) == before + 1, "再次命中应 +1")
end)

step("时间到 → stop 被调 + 收尾到 RESULTS/IDLE", function()
    env.advance(12)   -- 跑完 10s 窗口 + 收集窗
    assert(trace.stop >= 1, "stop 未在时间到时调用")
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "收尾 phase 异常: " .. tostring(p))
end)

step("stop 后命中不再计分（冻结）", function()
    local cv = GL.UI:Canvas()
    local state = cv._gl_duckhunt
    local before = GL.Match:GetContext().scores[GL.Roster:Me()] or 0
    env.fireScript(state.targets[1].frame, "OnMouseDown", "LeftButton")
    assert((GL.Match:GetContext().scores[GL.Roster:Me()] or 0) == before, "stop 后点击不应再计分")
end)

step("OnUpdate 已停（stop 后 SetScript(nil)）", function()
    local cv = GL.UI:Canvas()
    assert(cv:GetScript("OnUpdate") == nil, "stop 后 OnUpdate 应被清空")
end)

step("Close → teardown 被调（目标隐藏/解绑）", function()
    if GL.Match.Close then GL.Match:Close() end
    assert(trace.teardown >= 1, "teardown 未在 Close 时调用")
end)

step("ExportGame(duckhunt) 成功（自包含可分享）", function()
    local s, r = GL.Import:ExportGame("duckhunt")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)

step("围观者点击不计分", function()
    -- 重开一局，把自己标 spectator，确认命中回调里 IsSpectator 分支生效。
    GL.Match:Start("duckhunt", { prize = { mode = "friendly" } })
    local ctx = GL.Match:GetContext()
    local me = GL.Roster:Me()
    ctx.players[me] = ctx.players[me] or {}
    ctx.players[me].spectator = true
    env.advance(5)   -- 进 PLAYING
    local cv = GL.UI:Canvas()
    local state = cv._gl_duckhunt
    local before = ctx.scores[me] or 0
    env.fireScript(state.targets[1].frame, "OnMouseDown", "LeftButton")
    assert((ctx.scores[me] or 0) == before, "围观者点击不应计分")
    env.advance(12)
    if GL.Match.Close then GL.Match:Close() end
end)

-- ===== 汇总 =====
print("")
print(string.format("==== 结果：%d 个步骤失败 ====", #errs))
for _, e in ipairs(errs) do
    print("---- " .. e.name .. " ----")
    print(e.err)
end
os.exit(#errs == 0 and 0 or 1)
