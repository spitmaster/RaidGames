-- Core/GameImport.lua —— WA 串导入/导出（契约 §8，Phase 2）
-- owner: wow-comm-wa-specialist
--
-- 职责（SPEC 功能 9 + §5「WA 导出与构建」）：
--   GL.Import:ParseWA(str)     —— "!WA:" 前缀串 → 解码 → 解压 → 反序列化 → 从「自控固定字段」
--                                 提取游戏 def 描述（含游戏 Lua 源码）。纯解析，不执行。
--   GL.Import:ImportGame(str)  —— ParseWA + 信任确认门（GL.UI:ConfirmTrust，默认拒绝）
--                                 → loadstring 执行游戏代码 → RegisterGame（核心未就绪走 _pendingGames）
--                                 → 立即可玩，无需 /reload。失败给可读提示，不静默。
--
-- 不变量 #1（同体）：首行 aura_env；本文件插件/WA 两侧都能跑。
-- 不变量 #4（字节级一致）：WA 模板的「自控固定字段结构」是导出端与解析端共用的唯一契约，
--   插件版与 WA 版逐字一致。解析逻辑只认这套字段，不耦合 WeakAuras 的内部表结构细节。
--
-- ⚠️ 真相源：仓库里的游戏 .lua 是源，WA 串是「生成产物」。生成步骤见 dist/README.md（半自动）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

local Import = {}
GL.Import = Import

------------------------------------------------------------
-- 自控 WA 模板：固定字段结构（导出端 / 解析端唯一契约）
------------------------------------------------------------
-- 设计目标（SPEC 功能 9 第 3 点）：把游戏代码放进「我们自己定义的固定字段」，
-- 降低对 WeakAuras 内部表结构的耦合——WA 大改版时只需适配「从哪取这张表」，
-- 字段名/语义稳定不变。
--
-- 我们约定：WA 字符串解开（反序列化）后，得到的 Lua 表里，必然能在某处找到
-- 一个**自控载荷表**（payload），其结构为：
--
--   payload = {
--     __gl       = true,          -- 魔法标记：识别这是「游戏大厅」自控载荷（必填）
--     kind       = "game",        -- 载荷类型："game"（单游戏）| "bundle"（聚合，子项在 items）
--     id         = "speedclick",  -- 游戏 id（kind="game" 时必填；须与 def.id 一致）
--     name       = "极速按键",     -- 展示名（可选，仅提示用；权威名以 def 内为准）
--     version    = "1.0.0",       -- 游戏版本（可选，仅提示用；权威版本以 def 内为准）
--     coreMin    = "0.1.0",       -- 需要的最低核心版本（可选；不满足给「请升级核心」提示）
--     source     = "RaidGames 官方",-- 来源标识（喂给信任门 ConfirmTrust 展示给用户）
--     code       = "return { id=..., client=function() ... end }",  -- 游戏 Lua 源码字符串（必填）
--     items      = { payload1, payload2, ... },  -- kind="bundle" 时的子载荷数组（可选）
--   }
--
-- 关键约定：`code` 是一段 Lua 源码字符串，loadstring 后执行，**必须 return 一个游戏 def 表**
-- （契约 §6 的 def 结构）。ImportGame 拿到 def 后调 GL:RegisterGame(def)。
-- 这样代码与「描述元数据」解耦：解析阶段不执行代码也能拿到 id/version/coreMin 做版本/兼容判断。
--
-- 「自控载荷」放在 WA 数据里的哪个位置？为降低耦合，我们在两个地方都打标并探测（见 _ExtractPayload）：
--   1) WeakAuras 自定义代码 aura 的 actions.init.custom（自定义初始化代码）里 return 我们的 payload
--      —— 但 WA 把它当字符串存，故我们的导出脚本会把 payload 直接放进顶层（见下）。
--   2) 顶层即 payload 本身（当我们用「裸序列化」导出，不经 WeakAuras 时）——M1 半自动脚本采用此法，
--      最稳，解析端零 WA 结构耦合。
--   3) WeakAuras 标准导出表：payload 藏在某个 aura 节点的自控字段 `d.gameLobby` 或 group 的 `c[i].gameLobby`。

local MAGIC = "__gl"        -- 自控载荷魔法标记字段名
Import.MAGIC = MAGIC
Import.PAYLOAD_FIELD = "gameLobby"  -- WA 节点上挂载自控载荷的字段名（方式 3）

------------------------------------------------------------
-- 库取用（插件侧内嵌；WA 侧回退探测 WeakAuras 自带实例）
------------------------------------------------------------

-- 取 base64 解码器：插件用内嵌 GameLobby_Lib.Base64。
local function GetBase64()
    return _G.GameLobby_Lib and _G.GameLobby_Lib.Base64
end

-- 取 LibDeflate：插件用 LibStub 内嵌版；WA 同体场景回退 WeakAuras 暴露的实例。
local function GetDeflate()
    local LibStub = _G.LibStub
    local d = LibStub and LibStub("LibDeflate", true)
    if d then return d end
    -- WA 同体回退（Phase 0 报告 §④第 5 点登记）：WeakAuras 可能把库挂在自己命名空间。
    if _G.WeakAuras and _G.WeakAuras.LibDeflate then return _G.WeakAuras.LibDeflate end
    return nil
end

-- 取 LibSerialize：同上。
local function GetSerialize()
    local LibStub = _G.LibStub
    local s = LibStub and LibStub("LibSerialize", true)
    if s then return s end
    if _G.WeakAuras and _G.WeakAuras.LibSerialize then return _G.WeakAuras.LibSerialize end
    return nil
end

------------------------------------------------------------
-- 内部：从 WA 串解码 + 解压 + 反序列化，得到原始 Lua 数据
------------------------------------------------------------
-- 返回 data(table), err(string)。data 是反序列化后的顶层值（通常是一张表）。
--
-- WeakAuras 真实串格式（兼容三种历史前缀）：
--   "!WA:1!<base64(LibSerialize)>"   —— 旧式：base64（我们 LibBase64） + LibSerialize（无 deflate? 实际有）
--   "!WA:2!<LibDeflate:EncodeForPrint(LibSerialize:Serialize(data))>"  —— 现行 WeakAuras
--   "!GL:1!<...>"                    —— 本项目自控裸串（半自动脚本生成，最稳，见 dist/README.md）
--
-- 现行 WeakAuras（版本 2）的解码链是 DecodeForPrint → DecompressDeflate → Deserialize，
-- **不经过 base64**（EncodeForPrint 是 LibDeflate 自带的可打印编码）。我们两种都支持：
--   - 前缀含 "2!" → 走 LibDeflate:DecodeForPrint
--   - 前缀含 "1!" 或自控 "!GL:" → 走我们的 base64
local function DecodeWAString(str)
    if type(str) ~= "string" then
        return nil, "输入不是字符串"
    end

    -- 去首尾空白（用户复制常带换行/空格）。
    str = str:gsub("^%s+", ""):gsub("%s+$", "")

    -- 解析前缀，分出编码方式与 payload 主体。
    local encMode, body
    -- 现行 WeakAuras：!WA:<ver>!<body>
    local waVer, waBody = str:match("^!WA:(%d+)!(.+)$")
    if waVer then
        encMode = (waVer == "1") and "base64" or "print"
        body = waBody
    else
        -- 自控裸串：!GL:<ver>!<body>（半自动脚本默认产出，走我们 base64）
        local glVer, glBody = str:match("^!GL:(%d+)!(.+)$")
        if glVer then
            encMode = "base64"
            body = glBody
        else
            -- 兼容无版本号的老式 "!WA:" 前缀（极少见）：默认按现行 print 处理。
            local plain = str:match("^!WA:(.+)$")
            if plain then
                encMode = "print"
                body = plain
            end
        end
    end

    if not body then
        return nil, "无法识别的字符串前缀（应以 !WA: 或 !GL: 开头）"
    end

    local Deflate = GetDeflate()
    local Serialize = GetSerialize()
    if not Deflate then return nil, "缺少 LibDeflate 库（无法解压）" end
    if not Serialize then return nil, "缺少 LibSerialize 库（无法反序列化）" end

    -- 1) 解码（得到 deflate 压缩后的字节串）。
    local compressed, decErr
    if encMode == "print" then
        compressed = Deflate:DecodeForPrint(body)
        if not compressed then return nil, "DecodeForPrint 失败（串损坏或非 WeakAuras 可打印编码）" end
    else
        local Base64 = GetBase64()
        if not Base64 then return nil, "缺少 LibBase64 库（无法 base64 解码）" end
        local ok, res = pcall(Base64.Decode, body)
        if not ok or not res then return nil, "base64 解码失败（串损坏）" end
        compressed = res
    end

    -- 2) 解压（DEFLATE）。
    local serialized = Deflate:DecompressDeflate(compressed)
    if not serialized then
        return nil, "DecompressDeflate 失败（压缩数据损坏或非 DEFLATE）"
    end

    -- 3) 反序列化（LibSerialize:Deserialize 返回 success, value）。
    local ok, value = Serialize:Deserialize(serialized)
    if not ok then
        return nil, "反序列化失败（" .. tostring(value) .. "）"
    end

    return value, nil
end

------------------------------------------------------------
-- 内部：从反序列化数据里提取「自控载荷」（payload）
------------------------------------------------------------
-- 探测顺序（容忍三种导出布局，降低 WA 结构耦合）：
--   方式 2：顶层即 payload（裸序列化，半自动脚本默认）—— data.__gl == true
--   方式 3a：WeakAuras 单 aura 导出，payload 挂在 data.d.gameLobby（d=display data）
--   方式 3b：WeakAuras group 导出，payload 在 data.c[i].gameLobby（c=children 子项数组）
--           或子项顶层即 payload。
-- 找到 kind="bundle" 时，递归把 items 展开（聚合串多游戏）。
--
-- 返回 payloads(数组), err。payloads 数组里每项都是 kind="game" 的单游戏载荷。
local function IsPayload(t)
    return type(t) == "table" and t[MAGIC] == true
end

local function CollectGames(payload, out)
    if not IsPayload(payload) then return end
    if payload.kind == "bundle" then
        if type(payload.items) == "table" then
            for _, sub in ipairs(payload.items) do
                CollectGames(sub, out)
            end
        end
    else
        -- 默认当作单游戏载荷（kind 缺省也按 game 处理）。
        out[#out + 1] = payload
    end
end

local function ExtractPayloads(data)
    local out = {}

    if type(data) ~= "table" then
        return nil, "数据格式异常（顶层不是表）"
    end

    -- 方式 2：顶层即自控载荷。
    if IsPayload(data) then
        CollectGames(data, out)
        if #out > 0 then return out, nil end
    end

    -- 方式 3a：单 aura 节点 data.d.<PAYLOAD_FIELD>。
    if type(data.d) == "table" and IsPayload(data.d[Import.PAYLOAD_FIELD]) then
        CollectGames(data.d[Import.PAYLOAD_FIELD], out)
    end

    -- 方式 3b：group 子项 data.c[i]。
    if type(data.c) == "table" then
        for _, child in ipairs(data.c) do
            if IsPayload(child) then
                CollectGames(child, out)
            elseif type(child) == "table" and IsPayload(child[Import.PAYLOAD_FIELD]) then
                CollectGames(child[Import.PAYLOAD_FIELD], out)
            end
        end
    end

    -- 兜底：顶层 data 自身可能直接挂了 PAYLOAD_FIELD。
    if #out == 0 and IsPayload(data[Import.PAYLOAD_FIELD]) then
        CollectGames(data[Import.PAYLOAD_FIELD], out)
    end

    if #out == 0 then
        return nil, "未在串中找到「游戏大厅」自控载荷（这可能是一个普通的 WeakAuras，不是游戏大厅游戏串）"
    end
    return out, nil
end

------------------------------------------------------------
-- 公开：ParseWA(str) —— 解析（不执行代码）
------------------------------------------------------------
-- 返回 payloads(数组), err。每项含 { __gl, kind, id, name, version, coreMin, source, code }。
-- 纯解析，绝不 loadstring/执行——执行在 ImportGame 里、信任门之后。
function Import:ParseWA(str)
    local data, err = DecodeWAString(str)
    if not data then
        return nil, err
    end
    return ExtractPayloads(data)
end

------------------------------------------------------------
-- 内部：执行单个游戏载荷（信任门已过）→ loadstring → RegisterGame
------------------------------------------------------------
-- 返回 ok(bool), msg(string)。
local function RunPayload(payload)
    if type(payload.code) ~= "string" or payload.code == "" then
        return false, "载荷缺少游戏代码（code 字段为空）"
    end

    -- 核心版本兼容检查（coreMin 可选）。
    if payload.coreMin then
        local need = GL.GetVerNum(payload.coreMin)
        local have = GL.GetVerNum(GL.version)
        if have < need then
            return false, string.format(
                "此游戏需要核心版本 %s 或更高，当前核心为 %s，请先升级「游戏大厅」核心。",
                tostring(payload.coreMin), tostring(GL.version))
        end
    end

    -- loadstring 编译（5.1 用 loadstring；不在沙箱里跑——已过信任门，用户自担）。
    local chunk, loadErr = loadstring(payload.code, "GameLobby-import:" .. tostring(payload.id or "?"))
    if not chunk then
        return false, "游戏代码编译失败：" .. tostring(loadErr)
    end

    -- 执行 chunk，期望 return 一个 def 表（契约 §6）。
    local ok, def = pcall(chunk)
    if not ok then
        return false, "游戏代码执行出错：" .. tostring(def)
    end
    if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
        return false, "游戏代码未返回有效的游戏定义（应 return 一个含 id 的 def 表）"
    end

    -- 写回 def.code（契约 §6 / §8）：把本次导入的源码挂到 def 上，
    -- 使「导入来的游戏」也能被 ExportGame 再次打包转发（插件↔插件链式分享）。
    -- 若游戏代码自己已 return 了 def.code（建议做法：游戏从 code loadstring 出 def，源同），则不覆盖。
    if type(def.code) ~= "string" or def.code == "" then
        def.code = payload.code
    end

    -- 注册：核心已就绪直接注册（独立版本门控在 GameRegistry 内），否则压 _pendingGames。
    -- 这与 SpeedClick.lua 的注册逻辑一致，衔接 D16 聚合串加载顺序回收（Init.lua flush）。
    if GL.RegisterGame then
        local registered = GL:RegisterGame(def)
        if registered then
            return true, string.format("已导入游戏「%s」（版本 %s），现在即可发起，无需 /reload。",
                tostring(def.name or def.id), tostring(def.version or "?"))
        else
            -- RegisterGame 返回 false 的唯一业务原因：导入版本低于已装版本（不降级）。
            return false, string.format("已装有更高或同等版本的「%s」，本次导入的旧版本被忽略（不降级）。",
                tostring(def.name or def.id))
        end
    elseif GL._pendingGames then
        -- 核心壳在、GameRegistry 尚未加载（极端时序）：压队列，引导后回收。
        table.insert(GL._pendingGames, def)
        return true, string.format("游戏「%s」已排入待注册队列，核心引导完成后自动生效。",
            tostring(def.name or def.id))
    else
        return false, "核心尚未就绪，无法注册游戏。"
    end
end

------------------------------------------------------------
-- 公开：ImportGame(str) —— 完整导入流程（信任门 → 执行 → 注册）
------------------------------------------------------------
-- onDone(ok, msg) 可选回调：导入有「确认 → 异步执行」的人机交互，故结果经回调返回。
--   - 解析阶段同步失败（串损坏/缺库/非游戏串）：直接 onDone(false, err) 并返回。
--   - 用户在信任门拒绝：onDone(false, "已取消导入")。
--   - 用户确认后执行：逐个载荷 RunPayload，汇总结果 onDone(true/false, 汇总文案)。
--
-- 不变量：信任门默认拒绝（SPEC §3 安全）。无论插件入口还是 WA 入口，含可执行代码必弹确认。
-- WeakAuras 入口由 WA 自带导入确认兜底；大厅自建入口由此处经 GL.UI:ConfirmTrust 兜。
function Import:ImportGame(str, onDone)
    onDone = onDone or function(ok, msg)
        -- 默认：把结果丢到日志总线，UI 的日志条会显示。
        GL:Emit("LOG", ok and "sys" or "warn", tostring(msg))
    end

    -- 1) 解析（不执行）。
    local payloads, err = self:ParseWA(str)
    if not payloads then
        onDone(false, "导入失败：" .. tostring(err))
        return
    end

    -- 来源标识（喂给信任门展示）：取第一个载荷的 source，缺省「未知来源」。
    local source = payloads[1].source or "未知来源"
    -- 拼一个简短的「将导入什么」摘要，让用户知情后再决定信任。
    local names = {}
    for _, p in ipairs(payloads) do
        names[#names + 1] = string.format("%s%s", tostring(p.name or p.id or "?"),
            p.version and (" v" .. tostring(p.version)) or "")
    end
    local summary = table.concat(names, "、")

    -- 2) 执行体（确认后才跑）：逐个载荷注册，汇总。
    local function doImport()
        local okCount, failCount = 0, 0
        local lines = {}
        for _, p in ipairs(payloads) do
            local ok, msg = RunPayload(p)
            if ok then okCount = okCount + 1 else failCount = failCount + 1 end
            lines[#lines + 1] = msg
        end
        local allOk = (failCount == 0)
        local head = allOk
            and string.format("导入成功（%d 个游戏）：", okCount)
            or string.format("导入完成：成功 %d、失败 %d。", okCount, failCount)
        onDone(allOk, head .. "\n" .. table.concat(lines, "\n"))
    end

    -- 3) 信任门：默认拒绝。UI 提供 GL.UI:ConfirmTrust(source, onYes)。
    --    源信息里带上「将导入的游戏摘要」，让确认框文案更可信（SPEC §3）。
    local trustSource = string.format("%s — 将导入：%s", tostring(source), summary)
    if GL.UI and GL.UI.ConfirmTrust then
        GL.UI:ConfirmTrust(trustSource, doImport)
    else
        -- UI 信任门尚未就绪（极端：纯逻辑环境 / UI 未加载）：
        -- 安全优先——绝不静默执行。打印提示，要求用户走 UI 入口或确认环境。
        onDone(false, "无法弹出信任确认框（UI 未就绪）。出于安全，已取消导入；请通过大厅界面的「导入游戏字符串」入口重试。")
    end
end

------------------------------------------------------------
-- 内部：把自控载荷（payload）编码为 "!GL:1!<base64>"
------------------------------------------------------------
-- 与 DecodeWAString 的 base64 模式（encMode=="base64"）**逐字对称**，
-- 也与 dist/export-tool.lua 的 encode() 共用同一套链路（不变量 #4，避免两套格式分叉）：
--   payload(table) → LibSerialize:Serialize → LibDeflate:CompressDeflate → Base64.Encode → 前缀 "!GL:1!"
-- 注意：DecodeWAString 对 "!GL:" 走的是「base64 解码 → DecompressDeflate → Deserialize」，
--   故此处必须压缩（CompressDeflate），三步与解析端严格逆序对应，否则往返不一致。
-- 返回 str, err。
local function EncodePayload(payload)
    local Deflate = GetDeflate()
    local Serialize = GetSerialize()
    local Base64 = GetBase64()
    if not Serialize then return nil, "缺少 LibSerialize 库（无法序列化）" end
    if not Deflate then return nil, "缺少 LibDeflate 库（无法压缩）" end
    if not Base64 then return nil, "缺少 LibBase64 库（无法 base64 编码）" end

    local ok, serialized = pcall(function() return Serialize:Serialize(payload) end)
    if not ok or type(serialized) ~= "string" then
        return nil, "序列化失败（" .. tostring(serialized) .. "）"
    end
    local compressed = Deflate:CompressDeflate(serialized)
    if not compressed then return nil, "CompressDeflate 失败" end
    local b64 = Base64.Encode(compressed)
    if type(b64) ~= "string" then return nil, "base64 编码失败" end
    -- 去掉 base64 可能插入的换行（Encode 默认不换行，这里保险——与 export-tool.lua 一致）。
    b64 = b64:gsub("[\r\n]", "")
    return "!GL:1!" .. b64, nil
end

------------------------------------------------------------
-- 公开：ExportGame(id) —— 把已注册游戏打包成可分享的 !GL:1! 自控串
------------------------------------------------------------
-- 用途（契约 §8）：插件↔插件分享。返回的串可直接粘进别人大厅的「导入游戏字符串」框，
--   被本文件的 ParseWA/ImportGame 原样还原（往返一致）。
-- 这是「给人复制」的串（聊天框/外部渠道），不走 addon message，无 255 字节限制；
--   游戏代码几 KB、base64 膨胀 ~33% 都没问题。
-- 返回 (str) 成功 / (nil, reason) 失败：
--   - 未找到该 id 的游戏 → nil, 原因
--   - 该游戏未提供可导出源码（def.code 缺失，如占位/locked 游戏）→ nil, 原因
function Import:ExportGame(id)
    if not (GL.Games and GL.Games.Get) then
        return nil, "游戏注册表未就绪（核心未加载完成）"
    end
    local def = GL.Games:Get(id)
    if type(def) ~= "table" then
        return nil, "未找到该游戏"
    end
    if type(def.code) ~= "string" or def.code == "" then
        return nil, "此游戏未提供可导出源码（内置游戏需自带 code，或该游戏不可导出）"
    end

    -- 组装自控载荷：结构与 ParseWA 解析端、export-tool.lua 生成端完全一致。
    -- coreMin 取当前核心版本：本端能跑的源码，接收端至少需同等核心方能保证兼容。
    local payload = {
        __gl    = true,
        kind    = "game",
        id      = def.id or id,
        name    = def.name,
        version = def.version,
        coreMin = GL.version or "0.1.0",
        source  = "本地导出",
        code    = def.code,
    }

    return EncodePayload(payload)
end

------------------------------------------------------------
-- 便捷：探测一个字符串是否「像」游戏大厅可导入串（供 UI 做输入即时校验）
------------------------------------------------------------
-- 仅看前缀，不解码（轻量）。返回 bool。
function Import:LooksImportable(str)
    if type(str) ~= "string" then return false end
    str = str:gsub("^%s+", "")
    return str:match("^!WA:") ~= nil or str:match("^!GL:") ~= nil
end
