-- dist/export-tool.lua —— 半自动 WA 串生成工具（游戏内运行）
-- owner: wow-comm-wa-specialist
--
-- 用途：把「自控载荷」（payload，含游戏 Lua 源码）打包成可被 GL.Import:ParseWA 解析的
--   自控裸串 "!GL:1!<...>"。这是 SPEC §5「半自动」流程里**生成端**的实现：
--   解析端（Core/GameImport.lua）与本生成端**共用同一套自控字段结构与编码链**（不变量 #4）。
--
-- 编码链（与 GameImport DecodeWAString 的 base64 模式逐字对称）：
--   payload(table) → LibSerialize:Serialize → LibDeflate:CompressDeflate → Base64.Encode → 前缀 "!GL:1!"
--
-- 怎么用（游戏内）：
--   1) 装好「游戏大厅」插件（Libs 已内嵌）。
--   2) 把本文件内容贴进一个 WeakAuras「自定义代码」aura 的 actions.init.custom，或用 /run 跑。
--      （游戏内无法读硬盘文件，故游戏代码字符串需手工内联——见下方 SPEC §5 半自动步骤与 dist/README.md。）
--   3) 调 GameLobby_Export.Game(id, codeString[, meta]) / .Bundle({...})，
--      返回串打印到聊天框，复制粘贴到 dist/*.wa.txt。
--
-- ⚠️ 本工具产出的是**自控 !GL: 裸串**（最稳、零 WA 结构耦合，纯插件用户可直接导入）。
--   若要产出能在「WeakAuras 导入框」里也认的 !WA: 串（让 WA 用户也能用 WA 原生导入），
--   需把 payload 包进 WeakAuras 的 d/c 表结构再走 WA 的 !WA:2! 编码——那一步必须在
--   真机 WeakAuras 里用 WeakAuras 自带导出完成（见 dist/README.md「真机待办」）。

local Export = {}
_G.GameLobby_Export = Export

local function getLibs()
    local LibStub = _G.LibStub
    local Deflate = LibStub and LibStub("LibDeflate", true)
    local Serialize = LibStub and LibStub("LibSerialize", true)
    local Base64 = _G.GameLobby_Lib and _G.GameLobby_Lib.Base64
    return Deflate, Serialize, Base64
end

-- 把一个 payload 表编码为 "!GL:1!<base64>"。
local function encode(payload)
    local Deflate, Serialize, Base64 = getLibs()
    assert(Deflate, "缺 LibDeflate")
    assert(Serialize, "缺 LibSerialize")
    assert(Base64, "缺 GameLobby_Lib.Base64")
    local serialized = Serialize:Serialize(payload)
    local compressed = Deflate:CompressDeflate(serialized)
    local b64 = Base64.Encode(compressed)
    -- 去掉 base64 可能插入的换行（Encode 默认不换行，这里保险）。
    b64 = b64:gsub("[\r\n]", "")
    return "!GL:1!" .. b64
end

-- 生成「单游戏」串。codeString 必须是一段 return def 表的 Lua 源码。
-- meta 可选：{ name, version, coreMin, source }。
function Export.Game(id, codeString, meta)
    meta = meta or {}
    local payload = {
        __gl = true,
        kind = "game",
        id = id,
        name = meta.name,
        version = meta.version,
        coreMin = meta.coreMin or "0.1.0",
        source = meta.source or "RaidGames 官方",
        code = codeString,
    }
    local str = encode(payload)
    print("|cff44ff44[GameLobby Export]|r 单游戏串（" .. tostring(id) .. "，" .. #str .. " 字节）：")
    print(str)
    return str
end

-- 生成「聚合（全家桶）」串：items 是若干 { id, code, meta } 的数组。
-- 注意：自控裸串的「全家桶」是把核心代码也作为一个特殊 item 放进去吗？——不。
--   核心是插件主体，自控裸串的 bundle 只聚合**游戏**子载荷；真正的「核心+游戏」全家桶
--   需用 WeakAuras group 聚合（含核心子 aura），见 dist/README.md。
--   本函数用于「多游戏一次导入」的纯游戏聚合（已装核心者批量加游戏）。
function Export.Bundle(items, meta)
    meta = meta or {}
    local payload = {
        __gl = true,
        kind = "bundle",
        name = meta.name or "游戏合集",
        source = meta.source or "RaidGames 官方",
        items = {},
    }
    for _, it in ipairs(items) do
        payload.items[#payload.items + 1] = {
            __gl = true,
            kind = "game",
            id = it.id,
            name = it.meta and it.meta.name,
            version = it.meta and it.meta.version,
            coreMin = (it.meta and it.meta.coreMin) or "0.1.0",
            source = (it.meta and it.meta.source) or payload.source,
            code = it.code,
        }
    end
    local str = encode(payload)
    print("|cff44ff44[GameLobby Export]|r 聚合串（" .. #payload.items .. " 个游戏，" .. #str .. " 字节）：")
    print(str)
    return str
end

return Export
