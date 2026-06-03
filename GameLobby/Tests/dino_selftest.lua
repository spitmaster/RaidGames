-- GameLobby/Tests/dino_selftest.lua
-- 小恐龙跳一跳（dino）独立无头自测（elimination 版）：
--   注册 dino → 单人 Start → 进 PLAYING → 跳跃（vy/jumpH 变化）→ 跑动计分（dist/score）→
--   强制撞障碍触发死亡 → 断言立即出局结算 → 围观者早退。
-- 运行（仓库根）：lua GameLobby/Tests/dino_selftest.lua  ·  exit 0 = 通过。

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
    "Games/Dino.lua",      -- 被测游戏
    "Core/Init.lua",
}
print("== 1) 加载插件 + Dino ==")
for _, rel in ipairs(loadOrder) do
    step("load " .. rel, function() assert(loadfile("GameLobby/" .. rel))() end)
end

local GL = _G.GameLobby
assert(GL, "致命：_G.GameLobby 未建立")

print("== 2) 引导 flush ==")
step("PLAYER_LOGIN flush", function() env.FireEvent("PLAYER_LOGIN", true, false) end)
step("PLAYER_ENTERING_WORLD", function() env.FireEvent("PLAYER_ENTERING_WORLD", true, false) end)

print("== 3) dino 注册（elimination 真实版）==")
step("dino 已注册、tier=canvas、endMode=elimination、有 code", function()
    local def = GL.Games:Get("dino")
    assert(def, "dino 未注册")
    assert(def.locked ~= true, "应可发起")
    assert(def.tier == "canvas", "tier 应为 canvas")
    assert(def.endMode == "elimination", "endMode 应为 elimination，实际: " .. tostring(def.endMode))
    assert(def.needsKeyboard == true, "needsKeyboard 应为 true")
    assert(def.seeded == true, "seeded 应为 true")
    assert(def.code and def.code:sub(1, 6) == "return", "def.code 应为自包含 SOURCE")
end)
step("dino 可导出（!GL: 串）", function()
    local s, r = GL.Import:ExportGame("dino")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)

-- ===== 单人模式 =====
print("== 4) 单人跑一局（含撞死立即结束）==")
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
GL.UI:Show()

local ctxRef
step("Start dino → COUNTDOWN", function()
    GL.Match:Start("dino", { prize = { mode = "friendly" } })
    local p = GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "实际: " .. tostring(p))
end)

step("advance 过倒计时 → PLAYING + setup/start 被调", function()
    env.advance(5)
    ctxRef = GL.Match:GetContext()
    assert(ctxRef.phase == "PLAYING", "应 PLAYING，实际: " .. tostring(ctxRef.phase))
    local G = ctxRef._dino
    assert(G and G.dino, "setup 未建恐龙")
    assert(G.obs and #G.obs > 0, "障碍池未建")
    assert(G.running == true, "start 未挂 OnUpdate")
end)

step("按跳跃键 → 离地（jumpH>0）", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._dino
    G.jumpH = 0; G.vy = 0; G.ducking = false
    env.fireScript(cv, "OnKeyDown", "UP")
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.jumpH > 0, "起跳后 jumpH 应 >0，实际: " .. tostring(G.jumpH))
end)

step("跑动 → 距离/分数增长", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._dino
    local d0 = G.dist
    for _ = 1, 10 do env.fireScript(cv, "OnUpdate", 0.03) end
    assert(G.dist > d0, "跑动后 dist 应增长")
    assert(GL.Match._api:GetScore() == math.floor(G.dist / 12), "分数应等于 floor(dist/12)")
end)

step("吃加速道具 → 获得加速（boostT>0、不死）", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._dino
    -- 清场：障碍全收，恐龙站地面，加速归零。
    G.dead = false; G.jumpH = 0; G.vy = 0; G.ducking = false; G.boostT = 0
    for i = 1, #G.obs do G.obs[i].active = false end
    -- 在恐龙包围盒内放一颗道具（顶边对齐恐龙顶部，确保竖直重叠）。
    local bz = G.boosts[1]
    bz.active = true; bz.eaten = false
    bz.x = G.DINO_X
    bz.y = (G.GROUND_Y - G.jumpH) - G.DINO_H        -- 恐龙顶边附近
    env.fireScript(cv, "OnUpdate", 0.03)
    assert(G.boostT > 0, "吃到道具后 boostT 应 >0，实际: " .. tostring(G.boostT))
    assert(G.dead == false, "吃道具不应致死")
    assert(bz.active == false, "吃掉的道具应回收")
end)

step("撞障碍 → 死亡检测触发 → 立即出局结算", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._dino
    G.dead = false; G.jumpH = 0; G.vy = 0; G.ducking = false; G.boostT = 0
    for i = 1, #G.obs do G.obs[i].active = false end
    for i = 1, #G.boosts do G.boosts[i].active = false end
    local o = G.obs[1]
    o.active = true; o.kind = "cactus"; o.w = 30; o.h = 44; o.groundOffset = 0; o.x = G.DINO_X
    env.fireScript(cv, "OnUpdate", 0.03)
    assert(G.dead == true, "撞障碍应触发死亡")
    env.advance(2)
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "死亡后应立即结算，phase=" .. tostring(p))
end)

step("Close 不抛错", function() GL.Match:Close(); assert(true) end)

-- ===== 围观者分支 =====
print("== 5) 围观者不绑输入 ==")
step("围观者 start 直接 return（不挂 OnUpdate）", function()
    local def = GL.Games:Get("dino")
    local fakeCanvas = GL.UI:Canvas()
    fakeCanvas:SetScript("OnUpdate", nil)
    local fakeApi = {
        IsSpectator = function() return true end,
        Canvas = function() return fakeCanvas end,
        CaptureKeyboard = function() error("围观者不应申请键盘") end,
        SetScore = function() error("围观者不应计分") end,
        Random = function(_, a, b) return a or 0 end,
    }
    def.start({ _dino = {} }, fakeApi)
    assert(fakeCanvas:GetScript("OnUpdate") == nil, "围观者不应挂 OnUpdate")
end)

print("")
print(string.format("==== 结果：%d 个步骤失败 ====", #errs))
for _, e in ipairs(errs) do
    print("---- " .. e.name .. " ----"); print(e.err)
end
os.exit(#errs == 0 and 0 or 1)
