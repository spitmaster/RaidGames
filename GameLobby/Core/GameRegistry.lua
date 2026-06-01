-- Core/GameRegistry.lua —— RegisterGame + 游戏列表（契约 §6）
-- owner: wow-addon-engineer
--
-- 职责：
--   GL:RegisterGame(def)  —— 核心未就绪时 def 压入 GL._pendingGames（Init.lua flush 时回收）；
--                            每游戏独立版本门控（高版本胜，支持 WA 热升级）。
--   GL.Games:Get(id) / GL.Games:List()（有序，含 locked 占位 down100/up100）。
--   注册成功后 GL:Emit("GAME_REGISTERED", gameId)。
--
-- 不变量 #1（同体/版本门控）：游戏逐个独立版本门控，照核心做法（高版本替换低版本）。
-- 注意：Init.lua flush 时调 `GL.RegisterGame` 这个方法名回收 pending，所以方法名必须叫 RegisterGame。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

local Games = {}
GL.Games = Games

-- 注册表：[id] = def；_order 保留插入顺序（List 有序）。
Games._byId = {}
Games._order = {}

------------------------------------------------------------
-- GL:RegisterGame(def)
------------------------------------------------------------
-- 这是核心对外的「注册游戏」入口。游戏文件（SpeedClick / 导入的 WA 串）调它。
-- 若本文件尚未加载（聚合串里游戏子 aura 先于核心跑），def 已被 Bootstrap 的
-- GL._pendingGames 兜住——但本函数定义在 GameRegistry，所以「核心未就绪」实际指
-- GL.RegisterGame 还不存在的阶段，游戏侧需自行判 `if GL and GL.RegisterGame`，
-- 否则压入 GL._pendingGames（见 SpeedClick.lua 的注册逻辑与 Init.lua 的回收）。
function GL:RegisterGame(def)
    if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
        return false
    end
    local Games = self.Games
    local id = def.id

    -- 独立版本门控：已注册同 id 时比版本，新版本 < 旧版本则让位（不降级）。
    local existing = Games._byId[id]
    if existing then
        local oldVer = self.GetVerNum(existing.version)
        local newVer = self.GetVerNum(def.version)
        if newVer < oldVer then
            -- 旧串/低版本：忽略（热升级只准升不准降）。
            return false
        end
        -- 调用旧版自报的卸载钩子（游戏侧可登记 def._teardown 清理残留输入/计时）。
        if type(existing._teardown) == "function" then
            pcall(existing._teardown)
        end
        -- 同版本也允许覆盖（幂等重注册：例如 reload 后再次加载）。
        Games._byId[id] = def
        self:Emit("GAME_REGISTERED", id)
        return true
    end

    -- 首次注册：入表 + 入序。
    Games._byId[id] = def
    Games._order[#Games._order + 1] = id
    self:Emit("GAME_REGISTERED", id)
    return true
end

------------------------------------------------------------
-- 查询
------------------------------------------------------------

function Games:Get(id)
    return self._byId[id]
end

-- 有序列表（含 locked 占位）。返回 def 数组，按注册顺序。
function Games:List()
    local out = {}
    for _, id in ipairs(self._order) do
        local def = self._byId[id]
        if def then out[#out + 1] = def end
    end
    return out
end

------------------------------------------------------------
-- 预注册占位游戏（SPEC 占位功能：是男人就下/上 100 层）
------------------------------------------------------------
-- locked=true：UI 显示「即将上线」灰格、不可发起；无 client/host。
-- 直接进表（本文件即 GameRegistry，GL:RegisterGame 已就绪）。

GL:RegisterGame({
    id = "down100",
    name = "是男人就下 100 层",
    version = "0.0.0",
    glyph = "Interface\\Icons\\Spell_Frost_FrostBolt02",
    descLines = { "深渊速降", "即将上线" },
    duration = 0,
    locked = true,
})

GL:RegisterGame({
    id = "up100",
    name = "是男人就上 100 层",
    version = "0.0.0",
    glyph = "Interface\\Icons\\Ability_Hunter_Pathfinding",
    descLines = { "极限攀登", "即将上线" },
    duration = 0,
    locked = true,
})

