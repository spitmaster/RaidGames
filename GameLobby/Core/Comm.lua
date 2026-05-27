-- Core/Comm.lua —— 通讯层（契约 §3，协议 SPEC §6）
-- owner: wow-comm-wa-specialist
--
-- 职责：把字节级协议封死，上层（Match）只认命令名 + 参数。
--   - 收发：C_ChatInfo.SendAddonMessage 优先，回退旧版全局 SendAddonMessage
--   - 编码：命令,arg1,arg2,...（逗号分隔）；解码 strsplit(",", msg, 8)
--   - 频道：广播 RAID/PARTY（由 Roster:GetChannel 决定），点对点 WHISPER
--   - 节流：ChatThrottleLib
--   - 路由：CHAT_MSG_ADDON → 解码 → 派发到 RegisterHandler 注册的 handler
--
-- 不变量 #2（解耦）：Comm 不懂业务，只收发/解码/路由。
-- 不变量 #4（字节级一致）：编解码是纯函数，插件版与 WA 版逐字共用。
--
-- 注意：本层「不」自行做 matchId 过期过滤——它不持有比赛状态（那是 Match 的）。
--   它只把 sender 归一化、把参数原样交给 handler。Match 在 handler 里判 matchId
--   是否当前局、未知命令丢弃。这样 Comm 对业务零耦合。

local self = aura_env or {}
local GL = _G.GameLobby

local Comm = {}
GL.Comm = Comm

------------------------------------------------------------
-- 协议常量（插件版与 WA 版必须逐字一致）
------------------------------------------------------------

Comm.PREFIX = "GameLobby"   -- C_ChatInfo.RegisterAddonMessagePrefix 注册的前缀
Comm.PROTO_VER = "1"        -- 协议版本号；进 Start 载荷，版本不兼容时给提示
Comm.SEP = ","              -- 字段分隔符；约定字段内不含逗号
Comm.MAX_BYTES = 255        -- 单条 addon message 上限（含前缀消耗，留余量见 SafeBody）

------------------------------------------------------------
-- 编解码（纯函数，无副作用，WA 版直接复用）
------------------------------------------------------------

-- 把 cmd + 任意参数编码成 "cmd,arg1,arg2,..."。
-- nil 参数编码为空串；其余 tostring。调用方负责保证字段内无逗号。
function Comm.Encode(cmd, ...)
    local n = select("#", ...)
    if n == 0 then
        return cmd
    end
    local parts = { cmd }
    for i = 1, n do
        local v = select(i, ...)
        parts[i + 1] = (v == nil) and "" or tostring(v)
    end
    return table.concat(parts, Comm.SEP)
end

-- 最多切出的字段数（命令 + 前 7 参数 + 第 8 段「剩余原文」）。取 8 与 SPEC §6 对齐。
Comm.MAX_FIELDS = 8

-- 核心切分原语：把 str 按逗号切出**前 leadCount 个字段**，第 (leadCount+1) 个
-- 返回值是**整段剩余原文（含其内部逗号）**。字段不足时尾部返回 nil。
-- 纯函数，无副作用，确定行为，WA 版逐字复用（不变量 #4）。
--
-- ⚠️ 为什么不直接用 WoW 原生 strsplit(",", str, n)：原生 strsplit 只在「字段数 > n」时
-- 才把第 n 段当剩余原文；字段数 ≤ n 时它会把所有逗号都切开。对像 Final 的 rankingCSV
-- （内部含逗号、长度可变）这类「尾段是 CSV」的载荷，原生语义会把 CSV 拆散。这里手动
-- 实现「确定地保留尾段」的语义，与字段总数无关。
function Comm.SplitLead(str, leadCount)
    local f1, f2, f3, f4, f5, f6, f7, f8
    local out = { nil, nil, nil, nil, nil, nil, nil, nil }
    local start = 1
    local idx = 0
    while idx < leadCount do
        local s, e = string.find(str, Comm.SEP, start, true)
        if not s then
            -- 没有更多分隔符：剩余即最后一个字段，结束。
            idx = idx + 1
            out[idx] = string.sub(str, start)
            start = nil
            break
        end
        idx = idx + 1
        out[idx] = string.sub(str, start, s - 1)
        start = e + 1
    end
    -- 还有剩余（已切满 leadCount 个前导字段）→ 整段作为「剩余原文」放在下一位。
    if start then
        out[leadCount + 1] = string.sub(str, start)
    end
    return out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8]
end

-- 通用解码：cmd + 前 6 参数 + 第 8 段剩余原文。用于「固定元数 + 可变尾段」的命令。
-- ⚠️ 对 Final（`cmd,matchId,winner,rankingCSV`，rankingCSV 内部含逗号）：因 rankingCSV
-- 不是从第 8 段开始，通用 Decode 会把短 rankingCSV 拆散。Final 的 handler 应改用
-- Comm.SplitLead(body, 2)（body 是去掉 cmd 后的部分），把第 3 段当完整 rankingCSV。
-- 路由层（Dispatch）已用通用 Decode 取出 cmd；Match 在 Final handler 内对 rest 再处理，
-- 或直接对原始 message 用 SplitLead(msg, 3)。见 docs/contracts 与本文件「接口风险」备注。
--
-- 返回 cmd, a1, a2, a3, a4, a5, a6, rest（不足返回 nil）。
function Comm.Decode(msg)
    if type(msg) ~= "string" then return nil end
    return Comm.SplitLead(msg, Comm.MAX_FIELDS - 1)
end

------------------------------------------------------------
-- prize 逗号安全编解码（契约 §3：Start/State 末位字段携带）
------------------------------------------------------------
-- 为什么需要：prize 表的 name/text 是自由文本，可能含逗号，违反 §0「字段内禁逗号」。
-- 故把整张 prize 表序列化 + base64，得到「逗号安全串」（base64 字母表 A-Za-z0-9+/=
-- 不含逗号），作为 Start/State 的**末位**字段塞进逗号协议里，接收端原样取出再还原。
--
-- 编码链：LibSerialize:Serialize(tbl) → Base64.Encode(bytes)
--   - 不经 LibDeflate：prize 表极小（mode + 几个短字段），压缩收益≈0 反而多一层依赖；
--     base64 把 ~40 字节序列化结果膨胀到 ~55 字节仍远低于 255 上限。
--   - Base64.Encode 不传 maxLineLength → 不插 \r\n（单行连续 base64，无换行无逗号）。
--
-- 取库（与 GameImport 同style：插件内嵌；WA 同体回退 WeakAuras 实例）。
local function GetSerialize()
    local LibStub = _G.LibStub
    local s = LibStub and LibStub("LibSerialize", true)
    if s then return s end
    if _G.WeakAuras and _G.WeakAuras.LibSerialize then return _G.WeakAuras.LibSerialize end
    return nil
end

local function GetBase64()
    return _G.GameLobby_Lib and _G.GameLobby_Lib.Base64
end

-- 注：UnpackPrize 所有失败路径都返回**新建**的 { mode="friendly" }，不共用单例常量，
-- 避免调用方（Match 写入 ctx.prize 后）误改到共享表污染下一次兜底。

-- 自定义文字硬上限：编码后整串计入 255 字节预算（Start/State 末位字段）。
-- 中文 1 字符≈3 字节(UTF-8)，序列化+base64 后约 ×1.4。Start 前导字段约 ~80 字节，
-- 给 prize 串留 ~150 字节预算 ÷ 1.4(base64) ÷ ~1.05(序列化开销) ≈ 100 字节原文，
-- 取保守 90 字节（≈30 汉字，覆盖 SPEC §4.3 自定义奖品「≤60 字」里的常用短名）。
-- 真实战利品的 itemLink **不截断**（截断会破坏 hyperlink 结构）；其长度可控
-- （WotLK itemLink ≈55-65 字节），由 Match 决定是否携带，详见 PackPrize 内备注。
local PRIZE_TEXT_MAX_BYTES = 90   -- text/name 原文字节软上限，超出按字节安全截断

-- 按字节截断但不切碎多字节 UTF-8 序列（避免产出非法字符串）。
local function SafeTruncate(s, maxBytes)
    if type(s) ~= "string" or #s <= maxBytes then return s end
    local cut = maxBytes
    -- 回退到一个 UTF-8 字符边界：续接字节形如 10xxxxxx（0x80..0xBF）。
    while cut > 0 do
        local b = string.byte(s, cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return string.sub(s, 1, cut)
end

-- prize 表 → 逗号安全串。空/nil/非表 → 空串（Start/State 末位留空即「无 prize」）。
-- 三态（loot/custom/friendly）字段都原样序列化，往返不丢。
function Comm:PackPrize(prizeTbl)
    if type(prizeTbl) ~= "table" then return "" end

    local ser = GetSerialize()
    local b64 = GetBase64()
    if not ser or not b64 then
        -- 库缺失（理论上内嵌不会发生）：无法编码，返回空串当「无 prize」处理。
        return ""
    end

    -- 拷一份并对自由文本字段做长度截断（不改调用方的原表）。
    local p = {}
    for k, v in pairs(prizeTbl) do p[k] = v end
    if type(p.name) == "string" then p.name = SafeTruncate(p.name, PRIZE_TEXT_MAX_BYTES) end
    if type(p.text) == "string" then p.text = SafeTruncate(p.text, PRIZE_TEXT_MAX_BYTES) end

    local okS, bytes = pcall(function() return ser:Serialize(p) end)
    if not okS or type(bytes) ~= "string" then return "" end

    -- maxLineLength 留空 → 单行，无 \r\n；输出仅含 A-Za-z0-9+/= ，逗号安全。
    local okB, encoded = pcall(b64.Encode, bytes)
    if not okB or type(encoded) ~= "string" then return "" end

    -- 末位字段长度兜底：若编码后过长（极端的超长 itemLink + name + glyph 叠加），
    -- 给 Match 一个可见告警，但**不在此截断**——截断 base64 会让 UnpackPrize 整串解析失败、
    -- 反而丢掉 prize；过长的根因应由 Match 在构造 prize 时收敛（如只传 itemLink 不再附 name）。
    -- 这里取一个保守的「单字段安全预算」：255 - Start 前导约 80 - 余量 ≈ 150。
    if #encoded > 150 and GL.Emit then
        GL:Emit("LOG", "warn", "prize 编码后过长（" .. #encoded .. " 字节），可能撑爆消息，请精简奖品")
    end
    return encoded
end

-- 逗号安全串 → prize 表。空串/解析失败一律返回友谊赛兜底（{mode="friendly"}）。
function Comm:UnpackPrize(str)
    if type(str) ~= "string" or str == "" then
        return { mode = "friendly" }   -- 新表，避免调用方误改共享常量
    end

    local ser = GetSerialize()
    local b64 = GetBase64()
    if not ser or not b64 then return { mode = "friendly" } end

    local okB, bytes = pcall(b64.Decode, str)
    if not okB or type(bytes) ~= "string" then return { mode = "friendly" } end

    -- LibSerialize:Deserialize 返回 (success:bool, value)。pcall 包一层防 lib 内部 error，
    -- 然后还要看 lib 自报的 success，再校验 value 是表，三道关都过才采用，否则友谊赛兜底。
    local pcOk, libOk, value = pcall(function() return ser:Deserialize(bytes) end)
    if not pcOk or not libOk or type(value) ~= "table" then
        return { mode = "friendly" }
    end
    -- 最低限度校验：mode 必须是已知三态之一，否则视为脏数据兜底。
    if value.mode ~= "loot" and value.mode ~= "custom" and value.mode ~= "friendly" then
        return { mode = "friendly" }
    end
    return value
end

------------------------------------------------------------
-- 发送底层：优先 C_ChatInfo，经 ChatThrottleLib 节流
------------------------------------------------------------

-- 安全发送：截断超长（理论上各命令应自控长度，这里是最后兜底）。
local function rawSend(text, channel, target)
    if #text > Comm.MAX_BYTES then
        -- 兜底截断：宁可丢尾也别让消息被系统整条丢弃。
        -- 各命令（如 Final 的 rankingCSV）应在编码前自行截断前 N 名。
        text = text:sub(1, Comm.MAX_BYTES)
    end

    local ctl = _G.ChatThrottleLib
    if ctl then
        -- ChatThrottleLib 内部已优先 C_ChatInfo.SendAddonMessage、回退旧版。
        ctl:SendAddonMessage("NORMAL", Comm.PREFIX, text, channel, target)
        return true
    end

    -- 没有 ChatThrottleLib（理论上内嵌了不会发生）：直接发。
    if _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessage then
        _G.C_ChatInfo.SendAddonMessage(Comm.PREFIX, text, channel, target)
    elseif _G.SendAddonMessage then
        _G.SendAddonMessage(Comm.PREFIX, text, channel, target)
    else
        return false
    end
    return true
end

------------------------------------------------------------
-- 对外发送接口
------------------------------------------------------------

-- 广播到团队/队伍。频道由 Roster:GetChannel 决定（RAID/PARTY/nil）。
-- 单人（nil）时不发，返回 false。
function Comm:Broadcast(cmd, ...)
    local channel = GL.Roster and GL.Roster:GetChannel() or nil
    if not channel then
        return false
    end
    local text = Comm.Encode(cmd, ...)
    return rawSend(text, channel, nil)
end

-- 点对点私聊（状态同步用）。target 应为归一化名（name-realm）。
function Comm:Whisper(target, cmd, ...)
    if not target then return false end
    local text = Comm.Encode(cmd, ...)
    return rawSend(text, "WHISPER", target)
end

------------------------------------------------------------
-- handler 注册与路由
------------------------------------------------------------

Comm._handlers = {}   -- [cmd] = fn(sender, a1, a2, ..., a7, rawBody)

-- 注册命令处理器。Match 在此注册 Start/Join/Result/Final/Tie/GetState/State/VersionCheck/MyVer。
--
-- handler 签名：fn(sender, a1, a2, a3, a4, a5, a6, a7, rawBody)
--   - sender ：已归一化（带 -realm）。
--   - a1..a7 ：**命令之后**的参数，按逗号切分（a7 是「第 7 段起的剩余原文」）。
--   - rawBody：去掉 "cmd," 前缀后的整段原文（含所有逗号）。
--
-- 处理「尾段是可变长 CSV」的命令（如 Final 的 rankingCSV）：在 handler 内对 rawBody
-- 调用 Comm.SplitLead(rawBody, k) 自行切分——例如 Final body = "matchId,winner,rankingCSV"，
-- 用 SplitLead(rawBody, 2) 得到 matchId, winner, rankingCSV（rankingCSV 含内部逗号，完整）。
-- 这样无论 ranking 长短，CSV 都不会被拆散（不变量 #4 字节级一致的关键）。
function Comm:RegisterHandler(cmd, fn)
    if type(cmd) ~= "string" or type(fn) ~= "function" then return end
    Comm._handlers[cmd] = fn
end

function Comm:UnregisterHandler(cmd)
    Comm._handlers[cmd] = nil
end

-- 收到一条本前缀的 addon message：取命令 → 归一化 sender → 派发 body。
-- 未知命令静默丢弃（不报错，符合 SPEC §6「未知命令丢弃」）。
function Comm:Dispatch(rawMsg, rawSender)
    if type(rawMsg) ~= "string" then return end

    -- 先剥离命令名：找第一个逗号；之前是 cmd，之后是 body（无逗号则 body 为空串）。
    local cmd, rawBody
    local s = string.find(rawMsg, Comm.SEP, 1, true)
    if s then
        cmd = string.sub(rawMsg, 1, s - 1)
        rawBody = string.sub(rawMsg, s + 1)
    else
        cmd = rawMsg
        rawBody = ""
    end

    local handler = Comm._handlers[cmd]
    if not handler then
        return  -- 未知命令丢弃
    end

    -- 把 body 切成便捷参数（a1..a7，a7 为剩余原文）。无 body 时全为 nil。
    local a1, a2, a3, a4, a5, a6, a7
    if rawBody ~= "" then
        a1, a2, a3, a4, a5, a6, a7 = Comm.SplitLead(rawBody, Comm.MAX_FIELDS - 1)
    end

    -- 归一化发送者（带 -realm）。Roster 未就绪时退回原始名。
    local sender = rawSender
    if GL.Roster and GL.Roster.Norm then
        sender = GL.Roster:Norm(rawSender) or rawSender
    end

    local ok, err = pcall(handler, sender, a1, a2, a3, a4, a5, a6, a7, rawBody)
    if not ok then geterrorhandler()(err) end
end

------------------------------------------------------------
-- 引导：注册前缀 + 监听 CHAT_MSG_ADDON
------------------------------------------------------------

GL:Init(function()
    -- 注册前缀（功能 8 验收）。
    if _G.C_ChatInfo and _G.C_ChatInfo.RegisterAddonMessagePrefix then
        _G.C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
    end

    -- 监听 addon message。新建专用事件帧（幂等：已建则复用，防 flush 被重复调用）。
    -- 同时登记到 GL._eventFrame，供热升级时 Bootstrap 统一 UnregisterAllEvents。
    local frame = GL._commFrame
    if not frame then
        frame = CreateFrame("Frame")
        GL._commFrame = frame
        GL._eventFrame = GL._eventFrame or frame
    end

    frame:UnregisterAllEvents()
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
        if event ~= "CHAT_MSG_ADDON" then return end
        if prefix ~= Comm.PREFIX then return end
        Comm:Dispatch(message, sender)
    end)

    -- 登记卸载钩子：热升级让位时停掉本帧。
    GL:_RegisterTeardown(function()
        if frame then
            frame:UnregisterAllEvents()
            frame:SetScript("OnEvent", nil)
        end
    end)
end)
