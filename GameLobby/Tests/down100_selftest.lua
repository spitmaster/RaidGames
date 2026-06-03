-- GameLobby/Tests/down100_selftest.lua
-- 独立无头自测（elimination 版）：注册 down100 → 单人 Start → 进 PLAYING →
--   驱动帧+按键（移动）→ 触发死亡检测（坠底/出顶）→ 断言立即出局结算 → 围观者早退。
-- 运行（仓库根）：lua GameLobby/Tests/down100_selftest.lua  ·  exit 0 = 通过。

local env = dofile("GameLobby/Tests/headless_env.lua")

local errs = {}
local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then print(string.format("  [PASS] %s", name))
    else
        print(string.format("  [FAIL] %s", name))
        print("         " .. (tostring(err):match("[^\n]*") or tostring(err)))
        table.insert(errs, { name = name, err = err })
    end
end

-- ===== 库桩（同 run_all）=====
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
    "Core/UI/Widgets/Primitives.lua", "Core/UI/Widgets/SectionLabel.lua", "Core/UI/Widgets/Button.lua",
    "Core/UI/Widgets/SmashButton.lua", "Core/UI/Widgets/PlayerCard.lua", "Core/UI/Widgets/LootCard.lua",
    "Core/UI/Widgets/GameTile.lua", "Core/UI/Widgets/Castbar.lua", "Core/UI/Widgets/RankRow.lua",
    "Core/UI/Widgets/StatCard.lua", "Core/UI/Widgets/LogStrip.lua", "Core/UI/Widgets/ScrollList.lua",
    "Core/UI/Lobby.lua", "Core/UI/Playing.lua", "Core/UI/Results.lua", "Core/UI/History.lua",
    "Core/UI/About.lua", "Core/UI/ImportPanel.lua", "Core/UI/ExportPanel.lua", "Core/UI/Popups.lua",
    "Core/GameImport.lua", "Core/Push.lua",
    "Games/SpeedClick.lua",
    "Games/Down100.lua",   -- 被测游戏
    "Core/Init.lua",
}
print("== 1) 加载插件 + Down100 ==")
for _, rel in ipairs(loadOrder) do
    step("load " .. rel, function() assert(loadfile("GameLobby/" .. rel))() end)
end

local GL = _G.GameLobby
assert(GL, "致命：_G.GameLobby 未建立")

print("== 2) 引导 flush ==")
step("PLAYER_LOGIN flush", function() env.FireEvent("PLAYER_LOGIN", true, false) end)
step("PLAYER_ENTERING_WORLD", function() env.FireEvent("PLAYER_ENTERING_WORLD", true, false) end)

print("== 3) down100 注册（elimination 真实版）==")
step("down100 已注册、tier=canvas、endMode=elimination、有 code", function()
    local def = GL.Games:Get("down100")
    assert(def, "down100 未注册")
    assert(def.locked ~= true, "应已非占位")
    assert(def.tier == "canvas", "tier 应为 canvas")
    assert(def.endMode == "elimination", "endMode 应为 elimination，实际: " .. tostring(def.endMode))
    assert(def.code and def.code:sub(1, 6) == "return", "def.code 应为自包含 SOURCE")
end)
step("down100 可导出（!GL: 串）", function()
    local s, r = GL.Import:ExportGame("down100")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)

-- ===== 单人模式 =====
print("== 4) 单人跑一局（含死亡立即结束）==")
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
GL.UI:Show()

local ctxRef
step("Start down100 → COUNTDOWN", function()
    GL.Match:Start("down100", { prize = { mode = "friendly" } })
    local p = GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "实际: " .. tostring(p))
end)

step("advance 过倒计时 → PLAYING + setup/start 被调", function()
    env.advance(5)
    ctxRef = GL.Match:GetContext()
    assert(ctxRef.phase == "PLAYING", "应 PLAYING，实际: " .. tostring(ctxRef.phase))
    local G = ctxRef._d100
    assert(G and G.hero, "setup 未建角色")
    assert(G.plats and #G.plats > 0, "平台池未建")
    assert(G.running == true, "start 未挂 OnUpdate")
    -- 每行必有安全块（可解性保证），刺为可选；不做种子敏感断言（带刺秒杀由专门场景 + 真机验证）。
    assert(type(G.plats[1].safeX) == "number" and G.plats[1].safeW > 0, "每行应有安全块")
    assert(type(G.plats[1].hasSpike) == "boolean", "平台应有 hasSpike 标记字段")
    assert(type(G.nextSpike) == "function", "应有 nextSpike 生成器")
end)

step("按键 → 角色左右移动", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._d100
    local x0 = G.heroX
    env.fireScript(cv, "OnKeyDown", "RIGHT")
    for _ = 1, 4 do env.fireScript(cv, "OnUpdate", 0.04) end
    env.fireScript(cv, "OnKeyUp", "RIGHT")
    assert(G.heroX > x0, "按右键角色应右移")
end)

step("落到新平台 → depth+1（确定性计分）", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._d100
    G.dead = false; G.rest = nil
    G.heroY = G.H * 0.5                       -- 安全高度（远离上下死亡边界）
    local before = G.depth
    local p = G.plats[1]
    p._landed = false
    p.hasSpike = false
    p.safeX = 0; p.safeW = G.W                -- 整宽安全平台，必落上
    p.y = G.heroY + G.CHAR_SZ + 15            -- 平台顶在脚下一点（留够余量，抵消本帧平台上滚）
    G.heroX = 50
    G.vy = 300
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.depth == before + 1, "落到新平台应 depth+1，before=" .. before .. " after=" .. G.depth)
    assert(GL.Match._api:GetScore() == G.depth, "SetScore 未推到 ctx.scores")
end)

step("坠出底部 → 死亡 → 冻结 ~2s 后才结算（不立刻切结果）", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._d100
    G.dead = false; G.rest = nil
    G.heroY = G.H + 50                        -- 放到画布底部以下 → 应判「坠落出局」
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.dead == true, "坠出底部应触发死亡")
    -- 死亡当帧还不结算：先冻结显示死因（仍 PLAYING、未 Finish）。
    local pMid = GL.Match:GetContext().phase
    assert(pMid == "PLAYING", "死亡瞬间应仍冻结在 PLAYING（2s 后才结算），实际: " .. tostring(pMid))
    assert(G.finished ~= true, "死亡瞬间不应已 Finish")
    -- 推进：先过 2s 死亡冻结触发延时 Finish，再过 elimination 收集窗 → 结算。
    env.advance(12)
    assert(G.finished == true, "冻结结束后应已 Finish")
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "冻结结束后应结算，phase=" .. tostring(p))
end)

step("Close 不抛错", function() GL.Match:Close(); assert(true) end)

-- ===== 出顶死亡（骑乘到顶）=====
print("== 5) 出顶死亡 ==")
step("被顶到画布顶部 → 死亡", function()
    GL.Match:Start("down100", { prize = { mode = "friendly" } })
    env.advance(5)
    local ctx = GL.Match:GetContext()
    local G = ctx._d100
    local cv = GL.Match._api:Canvas()
    G.dead = false
    -- 模拟骑乘平台被托到顶：rest 安全块 y≈0、角色与其水平重叠 → 骑乘分支把 heroY 设为负 → 夹顶死。
    local p = G.plats[1]
    p.y = 0; p.safeX = 0; p.safeW = G.W   -- 整宽安全块 → over=true → 角色随平台上移被托到顶
    G.rest = p
    G.heroX = 10
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.dead == true, "夹顶应触发死亡")
    env.advance(2)
    GL.Match:Close()
end)

step("落到带刺平台 → 死亡（带刺秒杀逻辑）", function()
    GL.Match:Start("down100", { prize = { mode = "friendly" } })
    env.advance(5)
    local ctx = GL.Match:GetContext()
    local G = ctx._d100
    local cv = GL.Match._api:Canvas()
    G.dead = false; G.rest = nil
    G.heroY = G.H * 0.4
    local p = G.plats[1]
    -- 安全块缩到 0 宽（角色落不上），刺块整宽 → 角色必落到刺上 → 扎死
    p.hasSpike = true; p.safeX = 0; p.safeW = 0; p.spikeX = 0; p.spikeW = G.W
    p.y = G.heroY + G.CHAR_SZ + 15           -- 留够余量，抵消本帧平台上滚
    G.heroX = 50; G.vy = 300
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.dead == true, "落到带刺平台应死亡")
    env.advance(2); GL.Match:Close()
end)

-- ===== 围观者分支 =====
print("== 6) 围观者不绑输入 ==")
step("围观者 start 直接 return（不挂 OnUpdate）", function()
    local def = GL.Games:Get("down100")
    local fakeCanvas = GL.UI:Canvas()
    fakeCanvas:SetScript("OnUpdate", nil)
    local fakeApi = {
        IsSpectator = function() return true end,
        Canvas = function() return fakeCanvas end,
        CaptureKeyboard = function() error("围观者不应申请键盘") end,
        SetScore = function() error("围观者不应计分") end,
        GetSeed = function() return 1 end,
        Random = function(_, a, b) return a or 0 end,
    }
    def.start({ _d100 = { plats = {}, held = {} } }, fakeApi)
    assert(fakeCanvas:GetScript("OnUpdate") == nil, "围观者不应挂 OnUpdate")
end)

print("")
print(string.format("==== 结果：%d 个步骤失败 ====", #errs))
for _, e in ipairs(errs) do
    print("---- " .. e.name .. " ----"); print(e.err)
end
os.exit(#errs == 0 and 0 or 1)
