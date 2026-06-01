-- GameLobby/Tests/up100_selftest.lua
-- 「是男人就上 100 层」(up100) 独立无头自测（elimination 版）。
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
    "Games/Up100.lua",
    "Core/Init.lua",
}
print("== 1) 加载插件 + Up100 ==")
for _, rel in ipairs(loadOrder) do
    step("load " .. rel, function() assert(loadfile("GameLobby/" .. rel))() end)
end

local GL = _G.GameLobby
assert(GL, "致命：_G.GameLobby 未建立")

print("== 2) 引导 flush ==")
step("PLAYER_LOGIN flush", function() env.FireEvent("PLAYER_LOGIN", true, false) end)
step("PLAYER_ENTERING_WORLD", function() env.FireEvent("PLAYER_ENTERING_WORLD", true, false) end)

print("== 3) up100 注册（elimination 真实版）==")
step("up100 已注册、tier=canvas、endMode=elimination、有 code", function()
    local def = GL.Games:Get("up100")
    assert(def, "up100 未注册")
    assert(def.locked ~= true, "应已非占位")
    assert(def.tier == "canvas", "tier 应为 canvas")
    assert(def.endMode == "elimination", "endMode 应为 elimination，实际: " .. tostring(def.endMode))
    assert(def.code and def.code:sub(1, 6) == "return", "def.code 应为自包含 SOURCE")
end)
step("up100 可导出（!GL: 串）", function()
    local s, r = GL.Import:ExportGame("up100")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)

print("== 4) 单人跑一局（含坠落立即结束）==")
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
GL.UI:Show()

step("Start up100 → COUNTDOWN", function()
    GL.Match:Start("up100", { prize = { mode = "friendly" } })
    local p = GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "实际: " .. tostring(p))
end)

step("advance 过倒计时 → PLAYING + setup/start 被调", function()
    env.advance(5)
    local ctx = GL.Match:GetContext()
    assert(ctx.phase == "PLAYING", "应 PLAYING，实际: " .. tostring(ctx.phase))
    local G = GL.Match._api.G
    assert(G and G.charTex, "setup 未建角色")
    assert(G.platforms and #G.platforms > 0, "平台序列未建")
    assert(GL.Match._api:Canvas():GetScript("OnUpdate"), "start 未挂 OnUpdate")
    local hasSpike = false
    for _, p in ipairs(G.platforms) do if p.spiked then hasSpike = true end end
    assert(hasSpike, "关卡应含带刺平台")
end)

step("按键 → 角色左右移动", function()
    local cv = GL.Match._api:Canvas()
    local G = GL.Match._api.G
    local x0 = G.charX
    env.fireScript(cv, "OnKeyDown", "RIGHT")
    for _ = 1, 4 do env.fireScript(cv, "OnUpdate", 0.04) end
    env.fireScript(cv, "OnKeyUp", "RIGHT")
    assert(G.charX > x0, "按右键角色应右移")
end)

step("正常跑帧 → 弹跳/计分不抛错，maxTier≥1", function()
    local cv = GL.Match._api:Canvas()
    local G = GL.Match._api.G
    for _ = 1, 30 do env.fireScript(cv, "OnUpdate", 0.03) end   -- 可能中途自然死亡，不抛错即可
    assert(type(G.maxTier) == "number" and G.maxTier >= 1, "maxTier 非法: " .. tostring(G.maxTier))
    assert(GL.Match._api:GetScore() == G.maxTier - 1, "分应等于 maxTier-1")
    GL.Match:Close()
end)

step("坠出画布底部 → 死亡检测 → 立即出局结算（全新一局）", function()
    GL.Match:Start("up100", { prize = { mode = "friendly" } })
    env.advance(5)   -- 进 PLAYING（OnUpdate 活着）
    local cv = GL.Match._api:Canvas()
    local G = GL.Match._api.G
    G.dead = false
    G.charWorldY = -1000             -- 远低于所有平台 → 无落脚、投影到画布底以下 → 坠落死
    G.vy = -50
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.dead == true, "坠出底部应触发死亡")
    env.advance(2)
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "死亡后应立即结算，phase=" .. tostring(p))
    GL.Match:Close()
end)

print("== 5) 围观者不绑输入 ==")
step("围观者 start 直接 return（不挂 OnUpdate）", function()
    local def = GL.Games:Get("up100")
    local fakeCanvas = GL.UI:Canvas()
    fakeCanvas:SetScript("OnUpdate", nil)
    local fakeApi = {
        G = nil,
        IsSpectator = function() return true end,
        Canvas = function() return fakeCanvas end,
        CaptureKeyboard = function() error("围观者不应申请键盘") end,
        SetScore = function() error("围观者不应计分") end,
        GetSeed = function() return 1 end,
        Random = function(_, a, b) return a or 0 end,
    }
    def.start({}, fakeApi)
    assert(fakeCanvas:GetScript("OnUpdate") == nil, "围观者不应挂 OnUpdate")
end)

print("")
print(string.format("==== 结果：%d 个步骤失败 ====", #errs))
for _, e in ipairs(errs) do
    print("---- " .. e.name .. " ----"); print(e.err)
end
os.exit(#errs == 0 and 0 or 1)
