-- Core/ShareBundle.lua —— 「分享整个插件」内置 WA 整包串（核心 + 极速按键，给没装插件的新人）
-- owner: wow-comm-wa-specialist
--
-- 为什么是「内置常量」而不是「运行时生成」：
--   运行中的插件**读不到自己的源码**（Lua 加载后不保留源文本），故无法在运行时把自身打包成串。
--   整包「一串即玩」的 WeakAuras 原生串(!WA:2!)必须在**游戏内用 WeakAuras 自带导出**生成一次
--   （流程见 dist/README.md B 档），再把那串粘到下面 BUNDLE_WA 常量里随插件发布。
--   左上角「分享」按钮(GL.UI:ShowShare)只负责把这串展示出来供 Ctrl+C。
--
-- 真相源：dist/GameLobby-bundle.wa.txt。本常量是它的「随插件内置副本」，两者须一致；
--   重新生成串时同时更新这两处（dist 文件 + 本常量）。
--
-- 不变量 #1（同体）：首行 aura_env；插件/WA 两侧都能跑。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

------------------------------------------------------------
-- 内置整包串（占位：待真机用 WeakAuras 导出后替换整段）
------------------------------------------------------------
-- 替换说明：把 dist/README.md「B 档·全家桶」流程在游戏内导出的 !WA:2!.... 整行
--   原样贴到下面 [[...]] 之间（替换 PENDING 文本即可，别动前后结构）。
--   贴入后 ready 自动变 true（靠前缀判定），分享按钮即给出真串。
local BUNDLE_WA = [[PENDING]]

-- 同体内置版本（与核心版本一致；仅展示用）。
local BUNDLE_VERSION = GL.version or "0.1.0"

------------------------------------------------------------
-- GL:GetShareBundle() —— 返回整包分享串描述
------------------------------------------------------------
-- 返回 { ready=bool, str=string, version=string }：
--   ready=true  且 str 是真正的 !WA:/!GL: 串时，按钮直接给串；
--   ready=false（仍是占位）时，按钮展示「尚未内置 + 生成指引」，绝不发出假串。
function GL:GetShareBundle()
    local s = BUNDLE_WA
    local ready = type(s) == "string"
        and (s:match("^%s*!WA:") ~= nil or s:match("^%s*!GL:") ~= nil)
    return {
        ready   = ready,
        str     = ready and (s:gsub("^%s+", ""):gsub("%s+$", "")) or "",
        version = BUNDLE_VERSION,
    }
end
