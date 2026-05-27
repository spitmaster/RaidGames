-- GameLobby/Tests/Match_selftest.lua —— Match 状态机 mock 自检（仿 Phase 0 做法）
-- owner: wow-addon-engineer
--
-- 目的：在「无 WoW、无 UI」的纯 Lua 环境跑通比赛状态机核心路径，覆盖：
--   1) 正常一局排名（降序、winner 正确）
--   2) 第一名并列触发加赛（仅并列者参赛）
--   3) 异常分数（> duration*MAX_CPS）剔除、不计冠军
--   4) 非 host 不算排名（host=false 时 _Tally 不产生 ranking）
--
-- 运行（需任意 Lua 5.1）：
--   lua GameLobby/Tests/Match_selftest.lua
-- 退出码 0 = 全过；非 0 = 有断言失败。
--
-- 设计：用「可手动 pump 的虚拟时钟」替换 C_Timer.After 与 GetTime，使异步状态机
--   在测试里同步推进到终态——这样断言点确定、与帧率无关（也呼应 SPEC「不依赖帧率」）。

------------------------------------------------------------
-- 0. 虚拟时钟 + 调度器（替换 C_Timer.After / GetTime）
------------------------------------------------------------

local VClock = { now = 1000.0, queue = {} }   -- queue: { {at=, fn=}, ... }

local function vAfter(delay, fn)
    delay = tonumber(delay) or 0
    table.insert(VClock.queue, { at = VClock.now + delay, fn = fn })
end

-- 推进虚拟时钟到 targetTime，按时间序触发到期回调（回调里可再 vAfter）。
local function vAdvanceTo(targetTime)
    while true do
        -- 找最早的、且 ≤ target 的回调
        local idx, best
        for i, item in ipairs(VClock.queue) do
            if item.at <= targetTime and (not best or item.at < best) then
                best = item.at; idx = i
            end
        end
        if not idx then break end
        local item = table.remove(VClock.queue, idx)
        VClock.now = item.at
        item.fn()
    end
    VClock.now = targetTime
end

-- 把整个队列跑干（推进到所有挂起回调都触发）。
local function vRunAll()
    local guard = 0
    while #VClock.queue > 0 do
        guard = guard + 1
        if guard > 100000 then error("vRunAll: 疑似死循环") end
        local far = VClock.now
        for _, item in ipairs(VClock.queue) do
            if item.at > far then far = item.at end
        end
        vAdvanceTo(far)
    end
end

------------------------------------------------------------
-- 1. WoW 全局 mock
------------------------------------------------------------

_G.C_Timer = { After = vAfter }
_G.GetTime = function() return VClock.now end
_G.time = function() return 1716800000 end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.geterrorhandler = function() return function(err) error(err, 0) end end
_G.IsInRaid = function() return true end          -- 测试默认在团队
_G.IsInGroup = function() return true end
_G.SendChatMessage = function() end               -- 喊话静默
_G.CreateFrame = function()
    -- 极简 frame stub：支持事件/脚本（Roster/Comm 引导会调，但本测试不触发事件）。
    local f = {}
    function f:RegisterEvent() end
    function f:UnregisterAllEvents() end
    function f:RegisterAllEvents() end
    function f:SetScript() end
    function f:GetScript() end
    function f:Hide() end
    return f
end
_G.string = string
_G.table = table
_G.math = math
_G.select = select
_G.pcall = pcall
_G.pairs = pairs
_G.ipairs = ipairs
_G.tonumber = tonumber
_G.tostring = tostring
_G.type = type

------------------------------------------------------------
-- 2. 最小 GL（Bootstrap 事件总线/Init 的子集）+ 可注入 Roster/Comm
------------------------------------------------------------

local GL = {}
_G.GameLobby = GL
GL.version = "0.1.0"
GL._pendingGames = {}
GL._listeners = {}
GL._initQueue = {}
GL._frames = {}
GL._teardownHooks = {}

function GL.GetVerNum(str)
    if type(str) ~= "string" then return 0 end
    local a, b, c = string.match(str, "(%d+)%.(%d+)%.?(%d*)")
    return (tonumber(a) or 0) * 10000 + (tonumber(b) or 0) * 100 + (tonumber(c) or 0)
end
function GL:On(e, fn) self._listeners[e] = self._listeners[e] or {}; table.insert(self._listeners[e], fn) end
function GL:Off(e, fn)
    local l = self._listeners[e]; if not l then return end
    for i = #l, 1, -1 do if l[i] == fn then table.remove(l, i) end end
end
function GL:Emit(e, ...)
    local l = self._listeners[e]; if not l then return end
    local snap = {}; for i = 1, #l do snap[i] = l[i] end
    for i = 1, #snap do snap[i](...) end
end
function GL:Init(fn) table.insert(self._initQueue, fn) end
function GL:_FlushInit() for _, fn in ipairs(self._initQueue) do fn() end end
function GL:_RegisterFrame(f) return f end
function GL:_RegisterTeardown(fn) table.insert(self._teardownHooks, fn) end
GL.L = setmetatable({}, { __index = function(_, k) return tostring(k) end })

-- mock Roster：可切换「我是谁」与 host 身份。
local Roster = { _me = "Tank-S" }
GL.Roster = Roster
function Roster:Norm(name)
    if not name or name == "" then return nil end
    if string.find(name, "-", 1, true) then return name end
    return name .. "-S"
end
function Roster:Me() return self._me end
function Roster:GetChannel() return "RAID" end
function Roster:CanInitiate() return true end
function Roster:IsLeader() return true end
function Roster:IsAssist() return false end
function Roster:InGroup() return true end
-- 测试名单：Tank/Healer/Dps（都本服 -S）
Roster._members = {
    { name = "Tank",   nameNorm = "Tank-S",   classFile = "WARRIOR", isLeader = true,  online = true },
    { name = "Healer", nameNorm = "Healer-S", classFile = "PRIEST",  isLeader = false, online = true },
    { name = "Dps",    nameNorm = "Dps-S",    classFile = "MAGE",    isLeader = false, online = true },
}
function Roster:GetMembers()
    local me = self._me
    local out = {}
    for _, m in ipairs(self._members) do
        local c = {}; for k, v in pairs(m) do c[k] = v end
        c.isSelf = (m.nameNorm == me)
        out[#out + 1] = c
    end
    return out
end

-- mock Comm：捕获广播；SplitLead 复用真实语义（与 Comm.lua 一致）。
local Comm = { PREFIX = "GameLobby", SEP = ",", MAX_FIELDS = 8, sent = {} }
GL.Comm = Comm
function Comm.SplitLead(str, leadCount)
    local out = {}
    local start, idx = 1, 0
    while idx < leadCount do
        local s, e = string.find(str, ",", start, true)
        if not s then idx = idx + 1; out[idx] = string.sub(str, start); start = nil; break end
        idx = idx + 1; out[idx] = string.sub(str, start, s - 1); start = e + 1
    end
    if start then out[leadCount + 1] = string.sub(str, start) end
    return out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8]
end
function Comm:Broadcast(cmd, ...)
    local args = { ... }
    table.insert(self.sent, { cmd = cmd, args = args })
    return true
end
function Comm:Whisper(target, cmd, ...)
    -- mock：把 Whisper 也记进 sent（带 target），供 State 往返断言读取。
    local args = { ... }
    table.insert(self.sent, { cmd = cmd, args = args, whisperTo = target })
    return true
end

-- mock PackPrize/UnpackPrize：模拟 Comm 真实语义——prize 表 → 逗号安全串（无裸逗号），可逆。
-- 真实实现走 LibSerialize+LibDeflate+base64；此处只需保证「无逗号 + 三态字段不丢」即可验证 Match 集成。
-- 编码：把 mode/name/text/rarity/glyph/itemLink 逐字段转义后用 "|" 连接，逗号转义成 \c，避免裸逗号。
local PRIZE_FIELDS = { "mode", "name", "text", "rarity", "glyph", "itemLink" }
local function escField(v)
    if v == nil then return "" end
    v = tostring(v)
    v = string.gsub(v, "\\", "\\b")   -- 先转义反斜杠
    v = string.gsub(v, ",", "\\c")    -- 逗号 → \c（确保串内无裸逗号，逗号安全）
    v = string.gsub(v, "|", "\\p")    -- 分隔符 |
    return v
end
local function unescField(v)
    if v == "" then return nil end
    v = string.gsub(v, "\\p", "|")
    v = string.gsub(v, "\\c", ",")
    v = string.gsub(v, "\\b", "\\")
    return v
end
function Comm:PackPrize(prize)
    prize = prize or { mode = "friendly" }
    local parts = {}
    for _, f in ipairs(PRIZE_FIELDS) do
        parts[#parts + 1] = escField(prize[f])
    end
    local s = table.concat(parts, "|")
    -- 自检不变量：编码结果绝不含裸逗号（否则会撑爆 CSV 协议）。
    assert(not string.find(s, ",", 1, true), "PackPrize 产出含裸逗号，违反逗号安全")
    return s
end
function Comm:UnpackPrize(str)
    local out = {}
    local i = 1
    -- 按 "|" 切（escField 已把内容里的 | 转义为 \p），逐段还原。
    local idx = 0
    local start = 1
    while true do
        local s, e = string.find(str, "|", start, true)
        local seg
        if s then seg = string.sub(str, start, s - 1) else seg = string.sub(str, start) end
        idx = idx + 1
        local field = PRIZE_FIELDS[idx]
        if field then out[field] = unescField(seg) end
        if not s then break end
        start = e + 1
    end
    if not out.mode then out.mode = "friendly" end
    return out
end

Comm._handlers = {}
function Comm:RegisterHandler(cmd, fn) self._handlers[cmd] = fn end
function Comm:UnregisterHandler(cmd) self._handlers[cmd] = nil end

------------------------------------------------------------
-- 3. 加载被测模块（路径相对本文件所在 Tests/，回到 Core/Games）
------------------------------------------------------------

-- dofile 相对路径：从仓库根跑时给完整相对路径。允许用环境变量覆盖前缀。
local PREFIX = os.getenv("GL_SRC") or "GameLobby/"
local function load(rel)
    local path = PREFIX .. rel
    local chunk, err = loadfile(path)
    if not chunk then error("加载失败 " .. path .. ": " .. tostring(err)) end
    chunk()
end

-- aura_env 不存在 → 各文件走插件分支。
load("Core/GameRegistry.lua")
load("Core/Stats.lua")
load("Core/Match.lua")
load("Games/SpeedClick.lua")

-- flush Init（注册 handler、订阅 MATCH_FINAL）。
GL:_FlushInit()
-- 回收 pending（SpeedClick 在核心未"就绪"时本应直接注册——这里 GL.RegisterGame 已在，直接注册了）。
for _, def in ipairs(GL._pendingGames) do GL:RegisterGame(def) end
GL._pendingGames = {}

------------------------------------------------------------
-- 4. 断言工具
------------------------------------------------------------

local failures = 0
local function check(cond, msg)
    if cond then
        print("  [PASS] " .. msg)
    else
        failures = failures + 1
        print("  [FAIL] " .. msg)
    end
end

-- 跑一局：host 发起 → Begin → 各端用 mock Result 写分 → 推进时钟到终态。
-- scores: { [nameNorm]=score }。
-- stopAtTie=true：只跑到「第一次 _Tally 产出结果（Final 或 Tie 广播）」就停，
--   避免「加赛后无人写分→永远并列」在测试里把虚拟时钟拖死循环。
-- 返回最终 ctx。
local function runMatch(isHost, scores, duration, stopAtTie)
    Roster._me = Roster._me or "Tank-S"
    GL.Match:Close()
    VClock.queue = {}
    Comm.sent = {}

    local M = GL.Match
    -- 走 Start 更贴真实（含广播 + 建 ctx）。
    M:Start("speedclick", { duration = duration, prize = { mode = "friendly" } })
    M._ctx.isHost = isHost

    if isHost then
        M:Begin()
    else
        -- 非 host：模拟收到 host 的 Begin（参与端据此自行进入倒计时）。
        M:_StartCountdown()
    end
    -- 推进过倒计时(3+2+1+0+0.4)≈3.4s 到 PLAYING。
    vAdvanceTo(VClock.now + 3.5)
    -- PLAYING 中：把分数写入（模拟点击 + 收到的 Result）。
    for nm, sc in pairs(scores) do
        M._ctx.scores[nm] = sc
    end

    if stopAtTie then
        -- 逐步推进，直到 ranking 出现或广播了 Final/Tie，然后停（不进加赛递归）。
        local guard = 0
        while true do
            guard = guard + 1
            if guard > 1000 then break end
            -- 找最早的挂起回调时间，推进到它。
            local nextAt
            for _, item in ipairs(VClock.queue) do
                if not nextAt or item.at < nextAt then nextAt = item.at end
            end
            if not nextAt then break end
            vAdvanceTo(nextAt)
            -- 已产出 ranking（_Tally 跑过）或广播了 Final/Tie → 停。
            for _, m in ipairs(Comm.sent) do
                if m.cmd == "Final" or m.cmd == "Tie" then return M._ctx end
            end
            if M._ctx.ranking then return M._ctx end
        end
        return M._ctx
    end

    -- 正常用例：推进到终态（duration + 收集窗口都过完）。
    vRunAll()
    return M._ctx
end

------------------------------------------------------------
-- 5. 用例
------------------------------------------------------------

print("== 用例 1：正常一局排名（降序 + winner）==")
do
    local ctx = runMatch(true, { ["Tank-S"] = 100, ["Healer-S"] = 187, ["Dps-S"] = 150 }, 10.0)
    check(ctx.phase == "RESULTS", "终态为 RESULTS（phase=" .. tostring(ctx.phase) .. "）")
    check(ctx.ranking and ctx.ranking[1] and ctx.ranking[1].name == "Healer-S",
        "第 1 名是 Healer-S（实际 " .. tostring(ctx.ranking and ctx.ranking[1] and ctx.ranking[1].name) .. "）")
    check(ctx.ranking[2].name == "Dps-S", "第 2 名是 Dps-S")
    check(ctx.ranking[3].name == "Tank-S", "第 3 名是 Tank-S")
    check(ctx.winner == "Healer-S", "winner=Healer-S（实际 " .. tostring(ctx.winner) .. "）")
    -- CPS = 187/10 = 18.7
    check(math.abs(ctx.ranking[1].cps - 18.7) < 0.001, "冠军 CPS=18.7")
end

print("== 用例 2：第一名并列 → 触发加赛（仅并列者参赛）==")
do
    local ctx = runMatch(true, { ["Tank-S"] = 150, ["Healer-S"] = 187, ["Dps-S"] = 187 }, 10.0, true)
    -- stopAtTie=true：跑到广播 Tie 即停（不进加赛递归，避免无人写分的永远并列拖死时钟）。
    -- 验证「第一名并列正确触发了加赛」：Comm 广播过 Tie，且并列名单为 Healer/Dps。
    local tieMsg
    for _, m in ipairs(Comm.sent) do if m.cmd == "Tie" then tieMsg = m end end
    check(tieMsg ~= nil, "host 广播了 Tie")
    if tieMsg then
        local tiedCSV = tieMsg.args[2]
        check(tiedCSV == "Healer-S,Dps-S" or tiedCSV == "Dps-S,Healer-S",
            "并列名单为 Healer-S+Dps-S（实际 " .. tostring(tiedCSV) .. "）")
        check(tonumber(tieMsg.args[3]) == 1, "加赛轮次 round=1")
        check(tonumber(tieMsg.args[4]) == 5, "加赛时长 duration=5")
    end
    -- 验证加赛把非并列者（Tank）标围观、并列者保留：
    check(GL.Match._ctx.players["Tank-S"].spectator == true, "Tank-S 加赛时围观")
    check(GL.Match._ctx.players["Healer-S"].spectator == false, "Healer-S 加赛时参赛")
end

print("== 用例 3：异常分数剔除（> duration*20）==")
do
    -- duration=10 → cap=200。Dps 报 5000（异常），Healer 187（正常最高）。
    local ctx = runMatch(true, { ["Tank-S"] = 100, ["Healer-S"] = 187, ["Dps-S"] = 5000 }, 10.0)
    check(ctx.winner == "Healer-S", "异常分 Dps 不夺冠，winner=Healer-S（实际 " .. tostring(ctx.winner) .. "）")
    -- 异常分应沉底（排在所有正常分之后）。
    local last = ctx.ranking[#ctx.ranking]
    check(last.name == "Dps-S" and last.abnormal == true, "异常分 Dps-S 沉底并标 abnormal")
    check(ctx.ranking[1].name == "Healer-S", "正常最高分 Healer-S 居首")
end

print("== 用例 4：非 host 不算排名 ==")
do
    local ctx = runMatch(false, { ["Tank-S"] = 100, ["Healer-S"] = 187, ["Dps-S"] = 150 }, 10.0)
    -- 非 host：_EndPlay 后进 COLLECTING，不调 _Tally，无 ranking、不广播 Final。
    check(ctx.ranking == nil, "非 host 端不产生 ranking（实际 " .. tostring(ctx.ranking) .. "）")
    local hasFinal = false
    for _, m in ipairs(Comm.sent) do if m.cmd == "Final" then hasFinal = true end end
    check(hasFinal == false, "非 host 端不广播 Final")
    check(ctx.phase == "COLLECTING", "非 host 端停在 COLLECTING 等 host 的 Final（phase=" .. tostring(ctx.phase) .. "）")
end

print("== 用例 6：ranking 项带 classFile（host 端，供 UI 直接着色）==")
do
    -- Tank=WARRIOR / Healer=PRIEST / Dps=MAGE（见 mock roster）。
    local ctx = runMatch(true, { ["Tank-S"] = 100, ["Healer-S"] = 187, ["Dps-S"] = 150 }, 10.0)
    check(ctx.ranking[1].classFile == "PRIEST", "冠军 Healer-S 带 classFile=PRIEST（实际 "
        .. tostring(ctx.ranking[1].classFile) .. "）")
    check(ctx.ranking[2].classFile == "MAGE", "Dps-S 带 classFile=MAGE")
    check(ctx.ranking[3].classFile == "WARRIOR", "Tank-S 带 classFile=WARRIOR")
end

print("== 用例 7：Live 节流（≥0.4s/条）+ 去重 + 跨端 Emit ==")
do
    GL.Match:Close()
    VClock.queue = {}
    Comm.sent = {}
    Roster._me = "Tank-S"

    local M = GL.Match
    M:Start("speedclick", { duration = 10.0, prize = { mode = "friendly" } })
    M._ctx.isHost = false          -- 当参与端测 Live 广播
    M:_StartCountdown()
    vAdvanceTo(VClock.now + 3.5)    -- 进 PLAYING

    -- 收集本端 Emit 的 LIVE_SCORE。
    local liveEmits = {}
    GL:On("LIVE_SCORE", function(name, score)
        if name == "Tank-S" then liveEmits[#liveEmits + 1] = score end
    end)

    local function liveSent()
        local n = 0
        for _, m in ipairs(Comm.sent) do if m.cmd == "Live" then n = n + 1 end end
        return n
    end
    -- 取第 i 条 Live 消息（不依赖 sent 的绝对下标——Start 等命令也在 sent 里）。
    local function nthLive(i)
        local n = 0
        for _, m in ipairs(Comm.sent) do
            if m.cmd == "Live" then n = n + 1; if n == i then return m end end
        end
        return nil
    end

    local api = M._api
    -- 在同一时刻连点 5 次：节流窗口内只应广播 1 条 Live（first 即过门）。
    -- _liveLast 在 _BeginPlay 已置 0，now≈起始 → 第一次点击 now-0=PLAYING起 ≥0.4 立即过。
    for i = 1, 5 do api:AddScore(1) end
    check(liveSent() == 1, "同一时刻连点 5 次只广播 1 条 Live（节流，实际 " .. liveSent() .. "）")
    -- 取第 1 条 Live（不能用 Comm.sent[1]——M:Start 的 Start 命令也在 sent 里占了首位）。
    -- 节流语义：首次点击即过门广播 Live(1)，同一时刻后续 4 次只攒分不补发——
    -- 故首条 Live 载荷=1（首次点击瞬时值），累计的 5 要等下个节流窗口才会发。
    local firstLive = nthLive(1)
    check(firstLive and firstLive.args[3] == 1,
        "首条 Live 载荷=首次点击值 1（节流窗口内后续不补发，实际 " .. tostring(firstLive and firstLive.args[3]) .. "）")

    -- 推进 0.4s 后再点，应再广播 1 条（窗口已开）。
    vAdvanceTo(VClock.now + 0.45)
    api:AddScore(1)   -- 分数 6
    check(liveSent() == 2, "过 0.4s 节流窗口后再点广播第 2 条 Live（实际 " .. liveSent() .. "）")

    -- 去重：分数无变化时（推进窗口后再触发同值）不重发。
    -- 模拟「窗口已开但分数未涨」——直接置回当前已发值再 AddScore(0)。
    vAdvanceTo(VClock.now + 0.45)
    api:AddScore(0)   -- 分数仍 6，与 _liveSent 相同 → 不重发
    check(liveSent() == 2, "分数未变化时不重发 Live（去重，实际 " .. liveSent() .. "）")

    -- 跨端：模拟收到他人 Live → 更新 ctx.scores + Emit LIVE_SCORE。
    local otherEmit
    GL:On("LIVE_SCORE", function(name, score)
        if name == "Healer-S" then otherEmit = score end
    end)
    Comm._handlers["Live"]("Healer-S", M._ctx.matchId, "Healer-S", 42)
    check(M._ctx.scores["Healer-S"] == 42, "收他人 Live 更新 ctx.scores[Healer-S]=42（实际 "
        .. tostring(M._ctx.scores["Healer-S"]) .. "）")
    check(otherEmit == 42, "收他人 Live 触发 LIVE_SCORE Emit（实际 " .. tostring(otherEmit) .. "）")

    -- 过期 matchId 的 Live 丢弃。
    M._ctx.scores["Dps-S"] = nil
    Comm._handlers["Live"]("Dps-S", "STALE-matchid", "Dps-S", 999)
    check(M._ctx.scores["Dps-S"] == nil, "过期 matchId 的 Live 被丢弃（不污染 ctx.scores）")

    -- 自己的 Live 回环忽略（不被网络回灌覆盖本地累加）。
    M._ctx.scores["Tank-S"] = 6
    Comm._handlers["Live"]("Tank-S", M._ctx.matchId, "Tank-S", 0)
    check(M._ctx.scores["Tank-S"] == 6, "自己的 Live 回环被忽略（本地累加为准，实际 "
        .. tostring(M._ctx.scores["Tank-S"]) .. "）")
end

print("== 用例 8：prize 三态经 Start 往返（参与端 ctx.prize 不丢字段）==")
do
    -- 三态：loot（含 rarity/itemLink）/ custom（文本含逗号，验证逗号安全）/ friendly。
    local cases = {
        { name = "loot",     prize = { mode = "loot", name = "霜之哀伤", rarity = 5, itemLink = "|cffabc[item]" } },
        { name = "custom含逗号", prize = { mode = "custom", text = "金币,外加附魔,随机" } },
        { name = "friendly", prize = { mode = "friendly" } },
    }
    for _, c in ipairs(cases) do
        GL.Match:Close()
        VClock.queue = {}
        Comm.sent = {}
        Roster._me = "Tank-S"

        -- host 发起，prize 经 PackPrize 进 Start 末位字段广播。
        GL.Match:Start("speedclick", { duration = 10.0, prize = c.prize })
        -- 找到广播的 Start，取末位字段（prizeStr），重建完整 rawBody 喂给参与端 onStart。
        local startMsg
        for _, m in ipairs(Comm.sent) do if m.cmd == "Start" then startMsg = m end end
        check(startMsg ~= nil, "[" .. c.name .. "] host 广播了 Start")
        local a = startMsg.args
        -- a = { matchId,gameId,gameVer,host,joinDeadline,duration,prizeStr }
        check(#a == 7, "[" .. c.name .. "] Start 载荷 7 段（prize 在末位，实际 " .. #a .. " 段）")
        local prizeStr = a[7]
        check(prizeStr and not string.find(prizeStr, ",", 1, true),
            "[" .. c.name .. "] prize 末位字段无裸逗号（逗号安全，实际 " .. tostring(prizeStr) .. "）")

        -- 模拟参与端：另起一个"干净"ctx，喂 onStart（带 rawBody）。
        -- rawBody = 去掉 "Start," 前缀的整段 body：用 SEP 拼回 7 段。
        local rawBody = table.concat({ tostring(a[1]), tostring(a[2]), tostring(a[3]),
            tostring(a[4]), tostring(a[5]), tostring(a[6]), tostring(a[7]) }, ",")
        -- 切回参与端身份：换"我"为 Healer-S 并清当前 ctx（避免 host 回环忽略）。
        GL.Match:Close()
        Roster._me = "Healer-S"
        local onStart = Comm._handlers["Start"]
        onStart("Tank-S", a[1], a[2], a[3], a[4], a[5], a[6], a[7], rawBody)

        local got = GL.Match._ctx.prize
        check(got ~= nil, "[" .. c.name .. "] 参与端还原出 ctx.prize")
        check(got.mode == c.prize.mode,
            "[" .. c.name .. "] mode 不丢（期望 " .. c.prize.mode .. "，实际 " .. tostring(got.mode) .. "）")
        if c.prize.name then
            check(got.name == c.prize.name, "[" .. c.name .. "] name 往返一致（实际 " .. tostring(got.name) .. "）")
        end
        if c.prize.text then
            check(got.text == c.prize.text,
                "[" .. c.name .. "] text 含逗号往返一致（实际 " .. tostring(got.text) .. "）")
        end
        if c.prize.rarity then
            check(tostring(got.rarity) == tostring(c.prize.rarity),
                "[" .. c.name .. "] rarity 往返一致（实际 " .. tostring(got.rarity) .. "）")
        end
        if c.prize.itemLink then
            check(got.itemLink == c.prize.itemLink,
                "[" .. c.name .. "] itemLink 往返一致（实际 " .. tostring(got.itemLink) .. "）")
        end
    end
    Roster._me = "Tank-S"
end

print("== 用例 9：State 携带 prize（晚到者 onState 还原 ctx.prize）==")
do
    GL.Match:Close()
    VClock.queue = {}
    Comm.sent = {}
    Roster._me = "Tank-S"

    -- 在场者建一局（custom 含逗号 prize），收到 GetState 时应 Whisper 回 State 带 prize。
    local prize = { mode = "custom", text = "随机附魔,或金币" }
    GL.Match:Start("speedclick", { duration = 10.0, prize = prize })
    -- host 收到某晚到者的 GetState → onGetState 回 State（mock Whisper 记入 sent）。
    Comm.sent = {}
    Comm._handlers["GetState"]("Latecomer-S")
    local stateMsg
    for _, m in ipairs(Comm.sent) do if m.cmd == "State" then stateMsg = m end end
    check(stateMsg ~= nil, "在场者收 GetState 后 Whisper 回 State")
    local a = stateMsg.args
    -- a = { matchId,gameId,phase,remaining,round,duration,host,prizeStr }
    check(#a == 8, "State 载荷 8 段（prize 在末位，实际 " .. #a .. " 段）")
    local prizeStr = a[8]
    check(prizeStr and not string.find(prizeStr, ",", 1, true),
        "State prize 末位字段无裸逗号（逗号安全，实际 " .. tostring(prizeStr) .. "）")

    -- 模拟晚到者：清本地、换身份，喂 onState（带 rawBody）。
    local rawBody = table.concat({ tostring(a[1]), tostring(a[2]), tostring(a[3]),
        tostring(a[4]), tostring(a[5]), tostring(a[6]), tostring(a[7]), tostring(a[8]) }, ",")
    GL.Match:Close()
    Roster._me = "Latecomer-S"
    local onState = Comm._handlers["State"]
    onState("Tank-S", a[1], a[2], a[3], a[4], a[5], a[6], a[7], rawBody)

    local got = GL.Match._ctx.prize
    check(got and got.mode == "custom", "晚到者 onState 还原 prize.mode=custom（实际 " .. tostring(got and got.mode) .. "）")
    check(got and got.text == "随机附魔,或金币",
        "晚到者还原 prize.text 含逗号一致（实际 " .. tostring(got and got.text) .. "）")
    Roster._me = "Tank-S"
end

print("== 用例 5：Stats 记录一局（MATCH_FINAL）==")
do
    -- 用例 1 已 Emit 过 MATCH_FINAL；这里再跑一局确保 Stats 累计。
    GL.Stats:Clear()
    Roster._me = "Healer-S"  -- 让"我"是冠军，验证 isWin
    local ctx = runMatch(true, { ["Tank-S"] = 100, ["Healer-S"] = 187, ["Dps-S"] = 150 }, 10.0)
    local sum = GL.Stats:GetSummary()
    check(sum.total == 1, "战绩总场次=1（实际 " .. tostring(sum.total) .. "）")
    check(sum.wins == 1, "胜场=1（我是冠军）")
    check(math.abs(sum.avgScore - 187) < 0.001, "平均分=187")
    Roster._me = "Tank-S"
end

------------------------------------------------------------
-- 6. 汇总
------------------------------------------------------------
print("")
if failures == 0 then
    print("全部用例通过 ✔")
    os.exit(0)
else
    print(failures .. " 个断言失败 ✘")
    os.exit(1)
end
