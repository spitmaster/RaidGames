-- Games/SpeedClick.lua —— 极速按键（首发游戏，契约 §6 游戏 def）
-- owner: wow-addon-engineer
--
-- 玩法（SPEC 功能 4）：10 秒计时窗口内狂点大按钮，记点击数；多者胜。
--   - 计数用 OnMouseDown（而非 OnClick），每次按下都计入。
--   - 计时不依赖帧率（Match 用 GetTime() 驱动；游戏只负责采集）。
--   - Finish 由 Match 在 duration 到点统一触发 ReportScore，游戏不必自己调（契约 §6）。
--
-- 不变量 #1（同体）：首行 aura_env；本游戏「独立」版本门控（为将来 WA 热升级铺路）。
-- 不变量 #2（解耦）：游戏只调 api:AddScore，绝不直接发通讯。
-- 加载顺序鲁棒：核心未就绪（聚合串里游戏子 aura 先跑）时，把 def 压入 _G.GameLobby._pendingGames，
--   核心引导后由 Init.lua 回收注册（见 Core/Init.lua flush）。
--
-- 【分享/同源（契约 §6、§8）】：def 的「本体」写成一个自包含源码字符串 SOURCE，
--   本文件用 loadstring(SOURCE)() 跑出 def，并把 def.code = SOURCE。
--   - SOURCE 供 GL.Import:ExportGame 打包成可分享字符串；导入方 loadstring 后 return 出同一份 def。
--   - 插件版（本文件）与 WA 版（导出串）由此「同源」：def 本体只有 SOURCE 一处。
--   - 关键约束：SOURCE 内代码必须「自包含」——只能用 ctx/api 参数与全局
--     （GetTime、_G.GameLobby 等），不得引用本文件的 upvalue/local，
--     因为导入方 loadstring 时没有这些环境（与 WA 串自包含要求一致）。

local self = aura_env or {}

------------------------------------------------------------
-- 游戏 def 的自包含源码（SOURCE）
------------------------------------------------------------
-- 这段字符串就是「这个游戏是什么」的全部定义：loadstring 后 return 出一张 def 表。
-- 它不依赖本文件任何 local/upvalue，只用 ctx/api 形参和全局，可被原样分享、原样导入。
-- 注意：版本号在 SOURCE 内硬编码（导入方按串里的版本做门控），与本文件外层一致。

local SOURCE = [[
return {
    id = "speedclick",
    name = "极速按键",
    version = "1.0.0",                       -- 独立版本门控（热升级）；改版本同时改这里
    glyph = "Interface\\Icons\\Spell_Nature_Lightning",
    descLines = { "10 秒狂点", "多者胜" },
    duration = 10.0,
    locked = false,

    -- 参与端：MATCH_PLAY_BEGIN 时 Match 调用，传入 ctx 和 api。
    -- 绑定狂点钮 OnMouseDown → api:AddScore(1)。计时由 Match（GetTime）统一管，这里只采集。
    -- 自包含：只用 api/ctx 形参与全局 _G.GameLobby，无任何外部 upvalue。
    client = function(ctx, api)
        -- 围观者不绑输入（看比赛但不计数）。
        if api:IsSpectator() then return end

        local btn = api:SmashButton()
        if not btn then
            -- UI 尚未提供 PlayingScreen（如先单测状态机）：无按钮可挂，静默返回。
            -- 计分仍可由 UI 之外的途径（如键位）走 api:AddScore，但 M1 以鼠标为主。
            return
        end

        -- OnMouseDown 计数（SPEC 功能 4：每次按下都计入，不等 click）。
        -- 用闭包持 api；保存旧 handler 以便结束时还原（防残留）。
        btn._gl_prevMouseDown = btn:GetScript("OnMouseDown")
        btn:SetScript("OnMouseDown", function()
            api:AddScore(1)
        end)
        if btn.Enable then btn:Enable() end

        -- 登记本局清理：MATCH_PLAY_END / MATCH_CLOSED 时解绑（一次性订阅）。
        local function cleanup()
            if btn and btn:GetScript("OnMouseDown") then
                btn:SetScript("OnMouseDown", btn._gl_prevMouseDown)
            end
            btn._gl_prevMouseDown = nil
            if _G.GameLobby then _G.GameLobby:Off("MATCH_PLAY_END", cleanup) end
            if _G.GameLobby then _G.GameLobby:Off("MATCH_CLOSED", cleanup) end
        end
        if _G.GameLobby then
            _G.GameLobby:On("MATCH_PLAY_END", cleanup)
            _G.GameLobby:On("MATCH_CLOSED", cleanup)
        end
    end,

    -- 裁判端：极速按键无特殊裁判逻辑（汇总由 Match 通用做），留空。
    host = function(ctx, api) end,

    -- FINAL 后游戏侧收尾（可选）：极速按键无需，留空。
    onResult = function(ctx) end,
}
]]

------------------------------------------------------------
-- 从 SOURCE 跑出 def，并把源码挂回 def.code（供 ExportGame 打包，契约 §8）
------------------------------------------------------------
-- assert：SOURCE 自身语法错会在这里立刻暴露（开发期保护）。
local def = assert(loadstring(SOURCE))()
def.code = SOURCE

-- 本游戏独立版本号（外层引导/日志用，与 SOURCE 内 version 保持一致）。
local GAME_VERSION = def.version

------------------------------------------------------------
-- 注册（核心未就绪则压 pending 队列）—— 外层引导逻辑不变
------------------------------------------------------------

local GL = _G.GameLobby
if GL and GL.RegisterGame then
    -- 核心已就绪：直接注册（独立版本门控在 GameRegistry 内部做）。
    GL:RegisterGame(def)
elseif GL and GL._pendingGames then
    -- 核心壳在、但 GameRegistry 尚未加载：压入待注册队列，Init.lua flush 时回收。
    table.insert(GL._pendingGames, def)
else
    -- 连 GL 都没有（极端：游戏子 aura 早于核心 Bootstrap）：建临时队列，
    -- 待 Bootstrap 接管时... 此情形在 .toc 加载下不会发生（Bootstrap 必先于本文件）；
    -- WA 聚合串下 Bootstrap 也会先建 _pendingGames。这里仅作最后兜底，避免脚本错。
    _G.GameLobby_pendingGames = _G.GameLobby_pendingGames or {}
    table.insert(_G.GameLobby_pendingGames, def)
end
