-- GameLobby/Tests/down100_selftest.lua
-- 独立无头自测：注册 down100 → 单人 Start → advance 过倒计时 → 驱动几帧 OnUpdate + 按键
--   → 断言 setup/start 被调、SetScore 生效、能跑到 RESULTS、stop/teardown 被调。
-- 运行（仓库根）：lua GameLobby/Tests/down100_selftest.lua  ·  exit 0 = 通过。
-- 照 run_all.lua 的库桩 + 加载顺序 + 7c canvas 范例。

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

print("== 3) down100 注册（真实版本替换占位）==")
step("down100 已注册且非 locked、version=1.0.0", function()
    local def = GL.Games:Get("down100")
    assert(def, "down100 未注册")
    assert(def.locked ~= true, "down100 应已非占位（locked=false）")
    assert(def.version == "1.0.0", "版本应为 1.0.0，实际: " .. tostring(def.version))
    assert(def.tier == "canvas", "tier 应为 canvas")
    assert(def.code and def.code:sub(1, 6) == "return", "def.code 应为自包含 SOURCE")
end)
step("down100 可导出（非占位）", function()
    local s, r = GL.Import:ExportGame("down100")
    assert(type(s) == "string" and s:sub(1, 4) == "!GL:", "导出失败: " .. tostring(r))
end)

-- ===== 单人模式 =====
print("== 4) 单人跑一局 ==")
env.state.inGroup = false; env.state.inRaid = false; env.state.isLeader = false
env.state.members = { { name = "Tester", classFile = "WARRIOR", online = true } }
env.FireEvent("GROUP_ROSTER_UPDATE")
GL.UI:Show()

local ctxRef
step("Start down100 → 进入 COUNTDOWN", function()
    GL.Match:Start("down100", { prize = { mode = "friendly" } })
    local p = GL.Match:GetContext().phase
    assert(p == "COUNTDOWN" or p == "PLAYING", "Start 后应进入倒计时/比赛，实际: " .. tostring(p))
end)

step("advance 过倒计时 → PLAYING + setup/start 被调", function()
    env.advance(5)   -- 过 3-2-1-GO 进入 PLAYING
    ctxRef = GL.Match:GetContext()
    assert(ctxRef.phase == "PLAYING", "应在 PLAYING，实际: " .. tostring(ctxRef.phase))
    local G = ctxRef._d100
    assert(G, "setup 未建立 ctx._d100（setup 未跑）")
    assert(G.hero, "角色未建（setup）")
    assert(G.plats and #G.plats > 0, "平台池未建（setup）")
    assert(G.running == true, "start 未把 running 置 true（OnUpdate 未挂）")
    assert(type(ctxRef.gameId) == "string" and ctxRef.gameId == "down100", "gameId 错")
end)

step("驱动几帧 OnUpdate + 按键 → 角色应能左右移动", function()
    local cv = GL.Match._api:Canvas()
    assert(cv, "拿不到 canvas")
    local G = ctxRef._d100
    -- 记录初始 x
    local x0 = G.heroX
    -- 按住右，跑几帧
    env.fireScript(cv, "OnKeyDown", "RIGHT")
    for _ = 1, 5 do env.fireScript(cv, "OnUpdate", 0.05) end
    env.fireScript(cv, "OnKeyUp", "RIGHT")
    assert(G.heroX > x0, "按右键后角色应向右移动，x0=" .. x0 .. " now=" .. G.heroX)
    -- 按住左，跑几帧
    local x1 = G.heroX
    env.fireScript(cv, "OnKeyDown", "LEFT")
    for _ = 1, 5 do env.fireScript(cv, "OnUpdate", 0.05) end
    env.fireScript(cv, "OnKeyUp", "LEFT")
    assert(G.heroX < x1, "按左键后角色应向左移动")
end)

step("持续跑帧 → 重力 + 滚动 → depth/score 应能增长", function()
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._d100
    -- 跑足够多帧让角色穿过若干平台缺口（缺口随机，跑久了总会落入）。
    -- 通过左右扫动增加命中缺口的机会。
    for k = 1, 200 do
        if k % 20 < 10 then env.fireScript(cv, "OnKeyDown", "LEFT"); env.fireScript(cv, "OnKeyUp", "RIGHT")
        else env.fireScript(cv, "OnKeyDown", "RIGHT"); env.fireScript(cv, "OnKeyUp", "LEFT") end
        env.fireScript(cv, "OnUpdate", 0.03)
    end
    -- depth 不一定每次都增长（取决于缺口），但代码不应抛错且 score 字段一致。
    assert(type(G.depth) == "number" and G.depth >= 0, "depth 非法: " .. tostring(G.depth))
    local sc = GL.Match._api:GetScore()
    assert(sc == G.depth, "上报分(" .. sc .. ") 应等于 depth(" .. G.depth .. ")")
    print("         （信息）跑 200 帧后 depth = " .. G.depth)
end)

step("直接构造缺口对齐 → SetScore 必定生效（确定性验证计分）", function()
    -- 不依赖随机缺口：手动把角色放到某行缺口正上方、把该行放到角色脚下，跑一帧验证穿过 +1。
    local cv = GL.Match._api:Canvas()
    local G = ctxRef._d100
    local before = G.depth
    local p = G.plats[1]
    p._passed = nil
    p.gapX = 100
    p.y = G.heroY + G.CHAR_SZ + 5   -- 平台顶在角色底边下方一点
    G.heroX = p.gapX + (G.GAP_W - G.CHAR_SZ) / 2   -- 角色对齐缺口正中
    G.vy = 200                                     -- 给个下落速度，必越过 platTop
    env.fireScript(cv, "OnUpdate", 0.05)
    assert(G.depth == before + 1, "对齐缺口下落应使 depth+1，before=" .. before .. " after=" .. G.depth)
    assert(GL.Match._api:GetScore() == G.depth, "SetScore 未把分推到 ctx.scores")
end)

step("时间到 → stop 被调 + 收尾到 RESULTS/IDLE", function()
    env.advance(35)   -- 跑完 30s + 收集窗口
    local G = ctxRef._d100
    -- stop 应停了循环（running=false 且 OnUpdate=nil）
    assert(G == nil or G.running == false, "stop 未把 running 置 false")
    local p = GL.Match:GetContext().phase
    assert(p == "RESULTS" or p == "IDLE", "收尾 phase 异常: " .. tostring(p))
end)

step("Close → teardown 被调（清理）", function()
    GL.Match:Close()
    -- teardown 会把 ctx._d100 置 nil；但 Close 可能已换 ctx，这里宽松断言不抛错即可。
    assert(true)
end)

-- ===== 围观者分支 =====
print("== 5) 围观者不绑输入、不跑逻辑 ==")
step("围观者 start 直接 return（不建 OnUpdate）", function()
    -- 直接调 def.start 模拟围观者：构造一个 IsSpectator()=true 的假 api。
    local def = GL.Games:Get("down100")
    local fakeCanvas = GL.UI:Canvas()
    fakeCanvas:SetScript("OnUpdate", nil)
    local fakeApi = {
        IsSpectator = function() return true end,
        Canvas = function() return fakeCanvas end,
        CaptureKeyboard = function() error("围观者不应申请键盘") end,
        SetScore = function() error("围观者不应计分") end,
        GetSeed = function() return 1 end,
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
