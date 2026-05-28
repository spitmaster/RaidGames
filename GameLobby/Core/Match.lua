-- Core/Match.lua —— 比赛状态机（契约 §5，M1 核心）
-- owner: wow-addon-engineer
--
-- 状态机：IDLE → INVITING → COUNTDOWN → PLAYING → COLLECTING → RESULTS / TIEBREAK
-- 裁判(host)/参与端职责分离（不变量 #3）：排名只在 host 算；参与端只上报与展示。
-- 游戏/通讯解耦（不变量 #2）：游戏只产「分数/事件」，收发全走 GL.Comm；本文件注册 §3 全部 handler。
-- 协议字节级一致（不变量 #4）：Final/Tie 尾段 CSV 用 GL.Comm.SplitLead 切，不靠 a1..a7。
--
-- 同体：首行 aura_env，只挂 GL.Match；不自己监听三档生命周期（用 GL:Init）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

-- 局部缓存
local After = C_Timer and C_Timer.After or function(_, fn) fn() end  -- mock 兜底
local GetTime = GetTime
local time = time

local Match = {}
GL.Match = Match

------------------------------------------------------------
-- 常量
------------------------------------------------------------

local PHASE = {
    IDLE = "IDLE", INVITING = "INVITING", COUNTDOWN = "COUNTDOWN",
    PLAYING = "PLAYING", COLLECTING = "COLLECTING",
    RESULTS = "RESULTS", TIEBREAK = "TIEBREAK",
}

local COLLECT_WINDOW = 3.0      -- 计时结束后收集窗口（秒，契约 §5 / SPEC 功能 5）
local TIEBREAK_DURATION = 5.0   -- 加赛时长（SPEC 功能 6）
local DEFAULT_JOIN_DEADLINE = 30 -- 报名/准备截止（秒，SPEC 功能 3「开赛后 N 秒」）
local MAX_CPS = 20              -- 单秒最大点击数（上限校验，SPEC 功能 5）
local TOP_N = 10                -- Final rankingCSV 截断前 N 名（255 字节防溢出，契约 §3）
local LIVE_THROTTLE = 0.4       -- Live/LIVE_SCORE 节流间隔（≥0.4s/条，契约 §3）

------------------------------------------------------------
-- 内部状态
------------------------------------------------------------

-- 当前比赛上下文（契约 §2 matchCtx）。无比赛时 phase=IDLE。
local function newIdleCtx()
    return { phase = PHASE.IDLE }
end

Match._ctx = Match._ctx or newIdleCtx()

-- 计时/节流句柄（切状态时要能取消，用代号自增令旧定时器失效）。
Match._tick = Match._tick or 0           -- PLAYING/COUNTDOWN/COLLECT 计时代号
Match._liveAccum = Match._liveAccum or false  -- 是否有待广播的 live 分数
Match._liveLast = Match._liveLast or 0   -- 上次 live 广播时刻
Match._liveSent = Match._liveSent or -1  -- 本端上次已广播的 live 分数（去重，-1=未发过）

-- 取当前 ctx
function Match:GetContext()
    return self._ctx
end

-- 注意：协议命令 GetState/State 是 Comm handler（见下方 onGetState/onState），
-- 与本 GetContext 是两码事，别混。对外只读取 ctx 用 GetContext。

------------------------------------------------------------
-- 工具
------------------------------------------------------------

local function emit(event, ...)
    GL:Emit(event, ...)
end

local function logSys(text)  emit("LOG", "sys", text)  end
local function logWarn(text) emit("LOG", "warn", text) end

-- 是否单人/不在队伍（无法发起或广播）。
local function inGroup()
    return GL.Roster and GL.Roster:GetChannel() ~= nil
end

-- 让旧定时器失效：每次进入新阶段前 +1，闭包里比对代号。
local function bumpTick()
    Match._tick = Match._tick + 1
    return Match._tick
end

-- 切 phase + Emit MATCH_STATE（契约 §2）。
local function setPhase(phase)
    Match._ctx.phase = phase
    emit("MATCH_STATE", phase, Match._ctx)
end

-- 构造空 players/scores（按当前 roster 填 players）。
local function buildPlayers(ctx)
    ctx.players = ctx.players or {}
    ctx.scores = ctx.scores or {}
    if not GL.Roster then return end
    local meNorm = GL.Roster:Me()
    for _, m in ipairs(GL.Roster:GetMembers()) do
        local p = ctx.players[m.nameNorm]
        if not p then
            ctx.players[m.nameNorm] = {
                name = m.name,
                classFile = m.classFile,
                ready = false,
                isSelf = (m.nameNorm == meNorm),
                isLeader = m.isLeader,
                spectator = false,
            }
        end
    end
end

------------------------------------------------------------
-- game api（Match 构造，传给游戏 client/host，并供 UI 调用）—— 契约 §6
------------------------------------------------------------
-- 每场重建一次，闭包持 ctx。Finish 由 Match 在 duration 到点统一触发 ReportScore，
-- 游戏不必自己调（契约 §6 注释）。
local function buildApi(ctx)
    local meNorm = GL.Roster and GL.Roster:Me() or "self"
    local api = {}

    -- 累加本端分数 → 攒分，节流后 Emit LIVE_SCORE + 广播（契约 §6）。
    function api:AddScore(delta)
        delta = tonumber(delta) or 0
        if ctx.phase ~= PHASE.PLAYING then return end          -- 窗口外不计
        if ctx.players[meNorm] and ctx.players[meNorm].spectator then return end
        local cur = (ctx.scores[meNorm] or 0) + delta
        ctx.scores[meNorm] = cur
        Match._liveAccum = true
        -- 节流：到间隔才真正广播/Emit（别每次点击都发，≥LIVE_THROTTLE 一条，契约 §3）。
        local now = GetTime()
        if now - Match._liveLast >= LIVE_THROTTLE then
            Match._liveLast = now
            Match._liveAccum = false
            -- 真·跨端实时（SPEC 功能4 / §4.5）：广播 Live 让各端 live-board 同步刷新。
            -- 去重：本端上一次已广播的分数若未变化则不重发（避免空转刷屏）。
            if cur ~= Match._liveSent then
                Match._liveSent = cur
                if GL.Comm and inGroup() then
                    GL.Comm:Broadcast("Live", ctx.matchId, meNorm, cur)
                end
            end
            -- 本地也 Emit 刷自己的屏（不依赖回环）。
            emit("LIVE_SCORE", meNorm, cur)
        end
    end

    function api:GetScore()
        return ctx.scores[meNorm] or 0
    end

    -- 返回 UI 暴露的狂点钮句柄（仅 PlayingScreen 存在时）。游戏挂输入用。
    function api:SmashButton()
        if GL.UI and GL.UI.SmashButton then
            return GL.UI:SmashButton()
        end
        return nil
    end

    function api:IsSpectator()
        local p = ctx.players[meNorm]
        return p and p.spectator and true or false
    end

    return api
end

------------------------------------------------------------
-- 发起端（host）—— 契约 §5
------------------------------------------------------------

-- 生成 matchId：时间戳-发起者短名（SPEC 功能 2）。
local function genMatchId()
    local me = GL.Roster and GL.Roster:Me() or "host"
    local short = string.match(me, "^([^%-]+)") or me
    return tostring(time()) .. "-" .. short
end

-- host 发起一场。opts = { prize=..., duration=? }
function Match:Start(gameId, opts)
    opts = opts or {}
    -- 同一时刻只允许一场（契约 §5）。
    if self._ctx.phase ~= PHASE.IDLE then
        logWarn((GL.L and GL.L["已有进行中的比赛"]) or "已有进行中的比赛")
        return false
    end
    if not (GL.Roster and GL.Roster:CanInitiate()) then
        logWarn((GL.L and GL.L["仅团长/助理可发起"]) or "仅团长/助理可发起")
        return false
    end
    local def = GL.Games and GL.Games:Get(gameId)
    if not def or def.locked then
        logWarn((GL.L and GL.L["该游戏不可发起"]) or "该游戏不可发起")
        return false
    end

    local duration = tonumber(opts.duration) or def.duration or 10.0
    local ctx = {
        matchId = genMatchId(),
        gameId = gameId,
        gameVer = def.version,
        host = GL.Roster:Me(),
        isHost = true,
        phase = PHASE.IDLE,
        duration = duration,
        round = 0,
        remaining = duration,
        -- prize 原样透传（不丢字段、不改名）：UI Lobby.BuildPrize() 产出的
        -- {mode="loot",name,rarity,glyph,...} / {mode="custom",text=} / {mode="friendly"} 三态
        -- 整表存入 ctx.prize，host 端即真相。无传入则默认友谊赛。
        prize = opts.prize or { mode = "friendly" },
        players = {},
        scores = {},
        ranking = nil,
        winner = nil,
        _noAddon = 0,   -- host 统计「无插件无法参与」人数（SPEC 功能 3）
    }
    self._ctx = ctx
    buildPlayers(ctx)
    -- 自己作为 host 默认参与并就绪。
    local meNorm = GL.Roster:Me()
    if ctx.players[meNorm] then ctx.players[meNorm].ready = true end

    -- 广播 Start（协议 SPEC §6：matchId,gameId,gameVer,hostName,joinDeadline,duration,prize）
    -- prize 经 Comm:PackPrize 编码为逗号安全串（base64，含 +/= 但无逗号），作为末位字段携带，
    -- 让参与端大厅/结算能显示奖品（SPEC §4.3/§4.6，contracts §3 orchestrator 拍板）。
    local joinDeadline = DEFAULT_JOIN_DEADLINE
    if GL.Comm then
        local prizeStr = GL.Comm:PackPrize(ctx.prize)
        GL.Comm:Broadcast("Start", ctx.matchId, ctx.gameId, ctx.gameVer,
            ctx.host, joinDeadline, duration, prizeStr)
    end

    setPhase(PHASE.INVITING)
    emit("MATCH_INVITED", ctx)
    logSys((GL.L and GL.L["你发起了一场比赛"]) or "你发起了一场比赛")
    if GL.UI and GL.UI.ShowScreen then GL.UI:ShowScreen("lobby") end

    -- 单人模式：无人等准备，直接开局。
    if not (GL.Roster and GL.Roster:InGroup()) then
        self:Begin()
        return true
    end

    -- 报名/准备截止保护（SPEC 功能 3：逾期未就绪视为围观）。
    -- host 端起一个 joinDeadline 秒的定时器：到点仍在 INVITING（host 没开局）则
    -- 把未就绪、未围观的成员统一标围观，避免「等全员就绪」永久卡住（host 仍可手动开局）。
    -- 用 matchId 兜底防串场：定时器触发时若已非本局或已离开 INVITING，则空转。
    local thisMatchId = ctx.matchId
    After(joinDeadline, function()
        local cur = Match._ctx
        if cur.matchId ~= thisMatchId then return end       -- 已换局
        if cur.phase ~= PHASE.INVITING then return end       -- 已开局/已结束
        if not cur.isHost then return end
        local changed = false
        for _, p in pairs(cur.players) do
            if not p.ready and not p.spectator and not p.isSelf then
                p.spectator = true
                p.autoSpectator = true   -- 标记「截止自动转围观」，与主动围观区分（无插件统计用）
                changed = true
            end
        end
        if changed then
            logWarn((GL.L and GL.L["报名截止，未就绪者转为围观"]) or "报名截止，未就绪者转为围观")
            emit("MATCH_STATE", cur.phase, cur)
        end
    end)
    return true
end

-- host 端统计「X 人无插件无法参与」（SPEC 功能 3 / 测试用例「无插件成员」）。
-- 数据源（无 VersionCheck 强依赖时的推断）：团队在线成员中，
--   既未报名就绪（没回 Join，装了插件的人收 Start 后才会 Join/SetReady）、
--   又非主动围观（围观是插件内显式动作）、且不是自己 → 推断为「未装插件，收不到弹窗」。
-- 结果写入 ctx.noAddon，并 Emit 一条 LOG warn 让大厅日志条显示（UI 无需新方法即可呈现）。
-- 仅 host 端有意义（参与端不汇总）。
function Match:_ComputeNoAddon()
    local ctx = self._ctx
    if not ctx.isHost then return 0 end
    if not GL.Roster then ctx.noAddon = 0; return 0 end
    local meNorm = GL.Roster:Me()
    local n = 0
    for _, m in ipairs(GL.Roster:GetMembers()) do
        if m.online ~= false and m.nameNorm ~= meNorm then
            local p = ctx.players and ctx.players[m.nameNorm]
            -- 装了插件的人：要么 ready（回了 Join），要么 *主动* spectator（围观）。
            -- 截止自动转的围观（autoSpectator）不算「响应」——那些人很可能就是无插件没回的。
            local responded = p and (p.ready or (p.spectator and not p.autoSpectator))
            if not responded then n = n + 1 end
        end
    end
    ctx.noAddon = n
    if n > 0 then
        logWarn(string.format("%d 人无插件无法参与", n))
    end
    return n
end

-- 只读取 host 端统计的「无插件人数」（UI/结算可查；无比赛或参与端返回 0）。
function Match:GetNoAddon()
    return self._ctx.noAddon or 0
end

-- host：全员就绪后开局，触发倒计时（契约 §5）。
-- 广播 Begin 让参与端同步进入倒计时（协议新增命令，见 SPEC §6 / 契约 §3）。
function Match:Begin()
    local ctx = self._ctx
    if not ctx.isHost then return false end
    if ctx.phase ~= PHASE.INVITING then return false end
    -- 开局瞬间统计无插件人数（此时谁回了 Join/围观已定局，SPEC 功能 3）。
    self:_ComputeNoAddon()
    if GL.Comm and inGroup() then
        GL.Comm:Broadcast("Begin", ctx.matchId, ctx.round or 0)
    end
    self:_StartCountdown()
    return true
end

-- 再来一局（host）：用相同 game/prize 重新发起。
function Match:Rematch()
    local ctx = self._ctx
    if not ctx.isHost then return false end
    local gameId = ctx.gameId
    local prize = ctx.prize
    self:Close()
    return self:Start(gameId, { prize = prize, duration = ctx.duration })
end

------------------------------------------------------------
-- 倒计时 → 比赛 → 收集（host 与参与端共用的本地流程）
------------------------------------------------------------

-- 倒计时遮罩 3→2→1→GO!，然后 PLAY_BEGIN。
function Match:_StartCountdown()
    local ctx = self._ctx
    setPhase(PHASE.COUNTDOWN)
    local mytick = bumpTick()

    local function step(n)
        if Match._tick ~= mytick then return end  -- 已被新阶段取消
        emit("MATCH_COUNTDOWN", n)
        if GL.UI and GL.UI.Countdown then GL.UI:Countdown(n) end
        if n > 0 then
            After(1.0, function() step(n - 1) end)
        else
            -- GO! 之后稍候进入 PLAYING（让 GO 字样可见 ~0.4s）。
            After(0.4, function()
                if Match._tick ~= mytick then return end
                Match:_BeginPlay()
            end)
        end
    end
    step(3)
end

-- 进入 PLAYING：构造 api，调游戏 host/client 生命周期，启动计时。
function Match:_BeginPlay()
    local ctx = self._ctx
    -- 清本轮分数（加赛时只保留并列者，已在 Tie 处理时重建 players）。
    for k in pairs(ctx.scores) do ctx.scores[k] = nil end
    Match._liveLast = 0
    Match._liveAccum = false
    Match._liveSent = -1   -- 新一轮重置去重基线（加赛/正赛各自从头算）

    setPhase(PHASE.PLAYING)
    local def = GL.Games and GL.Games:Get(ctx.gameId)
    local api = buildApi(ctx)
    Match._api = api

    emit("MATCH_PLAY_BEGIN", ctx)
    if GL.UI and GL.UI.ShowScreen then GL.UI:ShowScreen("playing") end

    -- 调游戏生命周期：host 端先 host()，所有端 client()（采集输入）。
    if def then
        if ctx.isHost and type(def.host) == "function" then
            local ok, err = pcall(def.host, ctx, api); if not ok then geterrorhandler()(err) end
        end
        if type(def.client) == "function" then
            local ok, err = pcall(def.client, ctx, api); if not ok then geterrorhandler()(err) end
        end
    end

    -- 计时：GetTime() 基准，不依赖帧率（SPEC 功能 4，误差 ≤±0.1s）。
    local mytick = bumpTick()
    local startT = GetTime()
    local duration = ctx.duration
    local function tick()
        if Match._tick ~= mytick then return end
        local elapsed = GetTime() - startT
        local remaining = duration - elapsed
        if remaining <= 0 then
            ctx.remaining = 0
            Match:_EndPlay()
        else
            ctx.remaining = remaining
            After(0.05, tick)  -- 0.05s 刷新（castbar 平滑 + 误差远小于 ±0.1s）
        end
    end
    tick()
end

-- 计时到点：停止采集，上报本端分数，进入收集窗口。
function Match:_EndPlay()
    local ctx = self._ctx
    bumpTick()  -- 取消 PLAYING tick

    emit("MATCH_PLAY_END", ctx)

    -- 把攒着没广播的最后一笔 live 刷出去（节流尾包）。
    local meNorm = GL.Roster and GL.Roster:Me() or "self"
    if Match._liveAccum then
        emit("LIVE_SCORE", meNorm, ctx.scores[meNorm] or 0)
        Match._liveAccum = false
    end

    -- 本端上报最终分（围观不报）。Finish 语义：Match 统一触发 ReportScore（契约 §6）。
    if not (ctx.players[meNorm] and ctx.players[meNorm].spectator) then
        self:ReportScore(ctx.scores[meNorm] or 0)
    end

    -- 进入收集：host 留 COLLECT_WINDOW 秒收 Result 后算排名；参与端只等 Final。
    setPhase(PHASE.COLLECTING)
    if ctx.isHost then
        local mytick = bumpTick()
        After(COLLECT_WINDOW, function()
            if Match._tick ~= mytick then return end
            Match:_Tally()
        end)
    end
end

------------------------------------------------------------
-- 上报分数（契约 §5）—— 当前端 → Comm Result
------------------------------------------------------------
-- 参与端上报本轮分数。host 端自报也走这里（直接并入本地 scores）。
function Match:ReportScore(score)
    local ctx = self._ctx
    if ctx.phase == PHASE.IDLE then return end
    score = tonumber(score) or 0
    local meNorm = GL.Roster and GL.Roster:Me() or "self"
    ctx.scores[meNorm] = score

    -- 广播 Result（协议 SPEC §6：matchId,playerName,score,round）。
    if GL.Comm and inGroup() then
        GL.Comm:Broadcast("Result", ctx.matchId, meNorm, score, ctx.round)
    end
    -- host 自己也要纳入待汇总（已写 scores[meNorm]，_Tally 会读）。
end

------------------------------------------------------------
-- host 汇总：算 ranking（降序）、上限校验、判第一名并列 → Tie 或 Final（契约 §5）
------------------------------------------------------------
function Match:_Tally()
    local ctx = self._ctx
    if not ctx.isHost then return end

    local duration = ctx.duration or 10.0
    local cap = duration * MAX_CPS   -- 分数上限（> 此值标异常，SPEC 功能 5）

    -- 收集所有上报分数（只取参与者：在 players 且非围观；host 用 scores 累计的）。
    local rows = {}
    for nameNorm, score in pairs(ctx.scores) do
        local p = ctx.players[nameNorm]
        local spectator = p and p.spectator
        if not spectator then
            local abnormal = (score > cap)
            rows[#rows + 1] = {
                name = nameNorm,
                score = score,
                cps = (duration > 0) and (score / duration) or 0,
                classFile = p and p.classFile,   -- 带职业供 UI 直接着色（契约 §2，省一次回查）
                abnormal = abnormal,
            }
        end
    end

    -- 降序排名（异常分沉底：不计入冠军）。先按 abnormal（正常在前），再按分数降序。
    table.sort(rows, function(a, b)
        if a.abnormal ~= b.abnormal then
            return not a.abnormal   -- 正常的排前
        end
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.name < b.name      -- 稳定：同分按名字
    end)

    ctx.ranking = rows

    -- 判第一名并列（仅正常分参与）：取并列冠军名单。
    local tied = {}
    local topScore = nil
    for _, r in ipairs(rows) do
        if not r.abnormal then
            if topScore == nil then
                topScore = r.score
                tied[#tied + 1] = r.name
            elseif r.score == topScore then
                tied[#tied + 1] = r.name
            else
                break
            end
        end
    end

    if #tied >= 2 then
        -- 第一名并列 → 触发突然死亡加赛（仅并列者，SPEC 功能 6）。
        self:_StartTiebreak(tied)
        return
    end

    -- 唯一冠军（或无人有正常分时 winner=nil）。
    ctx.winner = (#tied == 1) and tied[1] or nil
    self:_BroadcastFinal()
end

-- host 编码并广播 Final（契约 §3：rankingCSV 含逗号，自行截断前 TOP_N 名）。
function Match:_BroadcastFinal()
    local ctx = self._ctx

    -- 构造 rankingCSV：`名字:分数` 用逗号分隔，截断前 TOP_N（255 字节防溢出，契约 §3）。
    local parts = {}
    for i, r in ipairs(ctx.ranking) do
        if i > TOP_N then break end
        parts[#parts + 1] = r.name .. ":" .. r.score
    end
    local rankingCSV = table.concat(parts, ",")

    if GL.Comm and inGroup() then
        -- Final body = matchId,winner,rankingCSV（rankingCSV 内含逗号，接收端用 SplitLead(rawBody,2)）。
        GL.Comm:Broadcast("Final", ctx.matchId, ctx.winner or "", rankingCSV)
    end

    self:_ApplyFinal(ctx.winner, ctx.ranking)
end

-- 收尾：进入 RESULTS，Emit MATCH_FINAL（Stats/UI 消费），调游戏 onResult。
function Match:_ApplyFinal(winner, ranking)
    local ctx = self._ctx
    ctx.winner = winner
    ctx.ranking = ranking
    setPhase(PHASE.RESULTS)
    emit("MATCH_FINAL", ctx)

    local def = GL.Games and GL.Games:Get(ctx.gameId)
    if def and type(def.onResult) == "function" then
        local ok, err = pcall(def.onResult, ctx); if not ok then geterrorhandler()(err) end
    end

    if GL.UI and GL.UI.ShowScreen then GL.UI:ShowScreen("results") end

    -- host 喊话公示（仅 host，避免刷屏，SPEC §6 / 功能 5）。
    if ctx.isHost and winner and SendChatMessage and GL.Roster then
        local short = string.match(winner, "^([^%-]+)") or winner
        local topScore = ranking[1] and ranking[1].score or 0
        local channel = IsInRaid() and "RAID" or "PARTY"
        local def2 = def or {}
        SendChatMessage(string.format("【游戏大厅·%s】冠军：%s（%d 次）！",
            def2.name or ctx.gameId, short, topScore), channel)
    end
end

------------------------------------------------------------
-- 平局加赛（契约 §5 / SPEC 功能 6）
------------------------------------------------------------
-- 仅并列冠军进入 5 秒加赛，其余人围观。仍并列则下一轮，直至分出唯一冠军。
function Match:_StartTiebreak(tiedNames)
    local ctx = self._ctx

    -- 广播 Tie（协议 SPEC §6：matchId,tiedNamesCSV,round,duration）。
    local tiedCSV = table.concat(tiedNames, ",")
    ctx.round = (ctx.round or 0) + 1
    ctx.duration = TIEBREAK_DURATION

    if GL.Comm and inGroup() then
        GL.Comm:Broadcast("Tie", ctx.matchId, tiedCSV, ctx.round, TIEBREAK_DURATION)
    end

    self:_ApplyTiebreak(tiedNames)
end

-- 本地应用加赛：把非并列者标围观，重建 ctx，进 TIEBREAK → 倒计时 → 比赛。
function Match:_ApplyTiebreak(tiedNames)
    local ctx = self._ctx
    local tiedSet = {}
    for _, n in ipairs(tiedNames) do tiedSet[n] = true end

    -- 非并列者改围观；并列者保留参赛。
    for nameNorm, p in pairs(ctx.players) do
        p.spectator = not tiedSet[nameNorm]
        p.ready = tiedSet[nameNorm] and true or false
    end
    ctx.tiedNames = tiedNames
    ctx.winner = nil
    ctx.ranking = nil

    setPhase(PHASE.TIEBREAK)
    emit("MATCH_TIE", ctx)

    -- 加赛直接进倒计时（不再走报名）。
    self:_StartCountdown()
end

------------------------------------------------------------
-- 参与端动作（契约 §5）
------------------------------------------------------------

-- 报名 + 打开大厅（参与端）。
function Match:Join()
    local ctx = self._ctx
    if ctx.phase == PHASE.IDLE then return false end
    local meNorm = GL.Roster and GL.Roster:Me()
    if meNorm then
        buildPlayers(ctx)
        if ctx.players[meNorm] then ctx.players[meNorm].spectator = false end
        if GL.Comm and inGroup() then
            GL.Comm:Broadcast("Join", ctx.matchId, meNorm)
        end
    end
    if GL.UI and GL.UI.ShowScreen then GL.UI:ShowScreen("lobby") end
    return true
end

-- 准备/取消准备。
function Match:SetReady(ready)
    local ctx = self._ctx
    if ctx.phase ~= PHASE.INVITING then return false end
    local meNorm = GL.Roster and GL.Roster:Me()
    if not meNorm then return false end
    buildPlayers(ctx)
    if ctx.players[meNorm] then
        ctx.players[meNorm].ready = ready and true or false
        ctx.players[meNorm].spectator = false
    end
    -- 准备态搭 Join 广播（让 host 知道谁要参赛）。
    if ready and GL.Comm and inGroup() then
        GL.Comm:Broadcast("Join", ctx.matchId, meNorm)
    end
    emit("MATCH_STATE", ctx.phase, ctx)  -- 刷新就绪计数
    return true
end

-- 选择围观。
function Match:SetSpectator()
    local ctx = self._ctx
    if ctx.phase == PHASE.IDLE then return false end
    local meNorm = GL.Roster and GL.Roster:Me()
    if meNorm and ctx.players[meNorm] then
        ctx.players[meNorm].spectator = true
        ctx.players[meNorm].ready = false
        ctx.players[meNorm].autoSpectator = nil   -- 主动围观，清除截止自动标记
    end
    emit("MATCH_STATE", ctx.phase, ctx)
    return true
end

------------------------------------------------------------
-- 关闭
------------------------------------------------------------
function Match:Close()
    bumpTick()  -- 取消所有挂起定时器
    self._ctx = newIdleCtx()
    Match._api = nil
    emit("MATCH_CLOSED")
end

------------------------------------------------------------
-- 通讯 handler（契约 §3）—— Match 注册，Comm 只路由
------------------------------------------------------------
-- handler 签名：fn(sender, a1..a7, rawBody)

-- 仅处理「当前 matchId」的消息（过期/未知丢弃，SPEC §6）。
local function isCurrent(matchId)
    return Match._ctx.matchId == matchId
end

-- Start: matchId,gameId,gameVer,hostName,joinDeadline,duration,prize
-- prize 是末位字段（base64 逗号安全串，可能含 +/= 但无逗号）。handler 签名 a1..a7 只覆盖前 7 段，
-- prize 恰好是第 7 段，但为统一走 Comm 解析、避免依赖 a7 的"剩余原文"语义边界，
-- 用 SplitLead(rawBody,6) 安全取第 7 段（前 6 段切完后，含逗号尾段原样保留——此处无逗号）。
local function onStart(sender, matchId, gameId, gameVer, hostName, joinDeadline, duration, a7, rawBody)
    -- 自己发起的回环忽略（host 本地已建 ctx）。
    if Match._ctx.isHost and Match._ctx.matchId == matchId then return end
    -- 已有进行中比赛：忽略新发起（同一时刻只一场）。
    if Match._ctx.phase ~= PHASE.IDLE and Match._ctx.matchId ~= matchId then return end

    duration = tonumber(duration) or 10.0
    local def = GL.Games and GL.Games:Get(gameId)
    if not def then
        -- 缺该游戏：提示索取（SPEC 功能 9，不静默失败）。
        logWarn("你缺少游戏【" .. tostring(gameId or "?") .. "】，向对方索取 WA 字符串")
        return
    end

    -- 还原 prize：取末位字段。优先用 SplitLead(rawBody,6) 拿第 7 段（最稳妥），
    -- rawBody 缺失时回落到 handler 透传的 a7（兼容 mock/旧路由）。无 prize 段（旧版本）→ 友谊赛兜底。
    local prizeStr
    if rawBody and GL.Comm and GL.Comm.SplitLead then
        local _, _, _, _, _, _, p7 = GL.Comm.SplitLead(rawBody, 6)
        prizeStr = p7
    end
    prizeStr = prizeStr or a7
    local prize = (prizeStr and prizeStr ~= "" and GL.Comm and GL.Comm:UnpackPrize(prizeStr))
        or { mode = "friendly" }

    local ctx = {
        matchId = matchId,
        gameId = gameId,
        gameVer = gameVer,
        host = hostName,
        isHost = false,
        phase = PHASE.IDLE,
        duration = duration,
        round = 0,
        remaining = duration,
        prize = prize,  -- 经 UnpackPrize 还原的奖品三态（loot/custom/friendly），供 UI 大厅/结算显示
        players = {},
        scores = {},
    }
    Match._ctx = ctx
    buildPlayers(ctx)
    setPhase(PHASE.INVITING)
    emit("MATCH_INVITED", ctx)
    if GL.UI and GL.UI.Invite then GL.UI:Invite(ctx) end
end

-- Begin: matchId,round —— host 开局，参与端同步进入倒计时（协议新增，SPEC §6）。
local function onBegin(sender, matchId, round)
    if not isCurrent(matchId) then return end
    local ctx = Match._ctx
    if ctx.isHost then return end             -- host 本地已 _StartCountdown
    if ctx.phase == PHASE.IDLE then return end
    -- 已在倒计时/比赛中（重复 Begin）忽略。
    if ctx.phase == PHASE.COUNTDOWN or ctx.phase == PHASE.PLAYING then return end
    ctx.round = tonumber(round) or ctx.round or 0
    Match:_StartCountdown()
end

-- Join: matchId,playerName
local function onJoin(sender, matchId, playerName)
    if not isCurrent(matchId) then return end
    local ctx = Match._ctx
    local norm = GL.Roster and GL.Roster:Norm(playerName) or playerName
    buildPlayers(ctx)
    local p = ctx.players[norm]
    if not p then
        p = { name = string.match(norm, "^([^%-]+)") or norm, ready = false, spectator = false }
        ctx.players[norm] = p
    end
    p.ready = true
    p.spectator = false
    emit("MATCH_STATE", ctx.phase, ctx)  -- 刷新就绪计数
end

-- Result: matchId,playerName,score,round
local function onResult(sender, matchId, playerName, score, round)
    if not isCurrent(matchId) then return end
    local ctx = Match._ctx
    -- 只有 host 才需要收别人的分数做汇总（参与端只显示自己的，最终看 Final）。
    if not ctx.isHost then return end
    -- 只收本轮（round 一致）。
    if tonumber(round) ~= ctx.round then return end
    local norm = GL.Roster and GL.Roster:Norm(playerName) or playerName
    ctx.scores[norm] = tonumber(score) or 0
end

-- Live: matchId,name,score —— 比赛中节流广播的实时分数（仅供观感，不参与排名裁决）。
-- 各端收到后更新 ctx.scores 并 Emit LIVE_SCORE，使 live-board 真·跨端实时刷新。
-- 不变量 #3 不破坏：host 最终排名仍只认计时结束后 Result 汇总；过期 matchId 丢弃。
local function onLive(sender, matchId, name, score)
    if not isCurrent(matchId) then return end   -- 过期/未知 matchId 丢弃
    local ctx = Match._ctx
    -- 仅比赛中（含加赛）的实时刷新有意义；其它阶段忽略，避免污染最终分。
    if ctx.phase ~= PHASE.PLAYING then return end
    local norm = GL.Roster and GL.Roster:Norm(name) or name
    if not norm then return end
    -- 自己的回环忽略（本端 AddScore 已本地 Emit；以本地累加为准，不被网络回灌覆盖）。
    local meNorm = GL.Roster and GL.Roster:Me() or "self"
    if norm == meNorm then return end
    local sc = tonumber(score) or 0
    ctx.scores[norm] = sc
    emit("LIVE_SCORE", norm, sc)
end

-- Final: matchId,winner,rankingCSV（尾段含逗号，必须 SplitLead(rawBody,2)）
local function onFinal(sender, a1, a2, a3, a4, a5, a6, a7, rawBody)
    -- 用 SplitLead 取 matchId, winner, rankingCSV（rankingCSV 完整保尾段）。
    local matchId, winner, rankingCSV = GL.Comm.SplitLead(rawBody, 2)
    if not isCurrent(matchId) then return end
    local ctx = Match._ctx
    -- host 已本地 _ApplyFinal，忽略自己的回环。
    if ctx.isHost then return end

    -- 解析 rankingCSV：`名字:分数,名字:分数,...`
    local ranking = {}
    if rankingCSV and rankingCSV ~= "" then
        for pair in string.gmatch(rankingCSV, "([^,]+)") do
            local nm, sc = string.match(pair, "^(.-):(%-?%d+)$")
            if nm then
                local score = tonumber(sc) or 0
                local lp = ctx.players and ctx.players[nm]
                ranking[#ranking + 1] = {
                    name = nm,
                    score = score,
                    cps = (ctx.duration > 0) and (score / ctx.duration) or 0,
                    classFile = lp and lp.classFile,   -- 参与端用本地 roster 回填职业（CSV 不带）
                }
            end
        end
    end
    ctx.winner = (winner ~= "" and winner) or nil
    Match:_ApplyFinal(ctx.winner, ranking)
end

-- Tie: matchId,tiedNamesCSV,round,duration（tiedNamesCSV 含逗号，SplitLead(rawBody,1) 后还要拆尾）
local function onTie(sender, a1, a2, a3, a4, a5, a6, a7, rawBody)
    -- body = matchId,tiedNamesCSV,round,duration —— tiedNamesCSV 含逗号、round/duration 在其后。
    -- 用 SplitLead(rawBody,1) 取 matchId + 余下；余下尾部是 ...,round,duration，中间是 CSV。
    -- 更稳妥：从右侧剥 round,duration。
    local matchId, rest = GL.Comm.SplitLead(rawBody, 1)
    if not isCurrent(matchId) then return end
    if not rest then return end
    -- 从 rest 右侧剥两段：tiedCSV,round,duration
    local tiedCSV, round, duration = string.match(rest, "^(.-),(%d+),([%d%.]+)$")
    if not tiedCSV then
        -- 容错：无 round/duration，整段当 CSV。
        tiedCSV = rest
    end
    local ctx = Match._ctx
    if ctx.isHost then return end  -- host 本地已 _ApplyTiebreak

    local tiedNames = {}
    for nm in string.gmatch(tiedCSV, "([^,]+)") do
        tiedNames[#tiedNames + 1] = nm
    end
    ctx.round = tonumber(round) or ((ctx.round or 0) + 1)
    ctx.duration = tonumber(duration) or TIEBREAK_DURATION
    Match:_ApplyTiebreak(tiedNames)
end

-- GetState: （无载荷）—— 在场者 WHISPER 回 State（契约 §3 / SPEC §6）。
local function onGetState(sender)
    local ctx = Match._ctx
    if ctx.phase == PHASE.IDLE then return end  -- 无进行中比赛不回
    if not GL.Comm then return end
    -- State: matchId,gameId,phase,remaining,round,duration,host,prize
    -- prize 同 Start 经 PackPrize 编码为末位字段，使晚到者/重载者也能看到奖品（SPEC §6 状态恢复）。
    local prizeStr = GL.Comm:PackPrize(ctx.prize)
    GL.Comm:Whisper(sender, "State", ctx.matchId, ctx.gameId, ctx.phase,
        string.format("%.1f", ctx.remaining or 0), ctx.round or 0,
        ctx.duration or 0, ctx.host or "", prizeStr)
end

-- State: matchId,gameId,phase,remaining,round,duration,host,prize —— 晚到者据此补建 ctx。
-- prize 是第 8 段（末位），超出 handler a1..a7 命名参数范围，故用 SplitLead(rawBody,7) 取末段。
-- 前 7 段（含 host 的 -realm，无逗号）按逗号切，第 8 段保留为 prize 串。
local function onState(sender, matchId, gameId, phase, remaining, round, duration, host, rawBody)
    -- 已有同局或更靠后的本地状态则不覆盖。
    if Match._ctx.phase ~= PHASE.IDLE and Match._ctx.matchId == matchId then return end
    local def = GL.Games and GL.Games:Get(gameId)

    -- 还原 prize：取第 8 段（末位）。rawBody 缺失时回落到友谊赛兜底（兼容旧版本/无 prize 段）。
    local prize
    if rawBody and GL.Comm and GL.Comm.SplitLead then
        local _, _, _, _, _, _, _, p8 = GL.Comm.SplitLead(rawBody, 7)
        if p8 and p8 ~= "" and GL.Comm.UnpackPrize then
            prize = GL.Comm:UnpackPrize(p8)
        end
    end
    prize = prize or { mode = "friendly" }

    local ctx = {
        matchId = matchId,
        gameId = gameId,
        gameVer = def and def.version,
        host = host,
        isHost = false,
        phase = phase or PHASE.INVITING,
        duration = tonumber(duration) or 10.0,
        round = tonumber(round) or 0,
        remaining = tonumber(remaining) or 0,
        prize = prize,  -- 还原的奖品（晚到/重载者也能在大厅/结算看到，SPEC §6）
        players = {},
        scores = {},
    }
    Match._ctx = ctx
    buildPlayers(ctx)
    -- 据 phase 切到对应屏（补建比赛 UI，SPEC §6 状态恢复）。
    emit("MATCH_STATE", ctx.phase, ctx)
    if GL.UI and GL.UI.ShowScreen then
        if phase == PHASE.PLAYING or phase == PHASE.COUNTDOWN or phase == PHASE.TIEBREAK then
            GL.UI:ShowScreen("playing")
        elseif phase == PHASE.RESULTS then
            GL.UI:ShowScreen("results")
        else
            GL.UI:ShowScreen("lobby")
        end
    end
end

-- VersionCheck / MyVer（版本探测，SPEC 功能 9）
local function onVersionCheck(sender)
    if not GL.Comm then return end
    -- MyVer: coreVer,gameListCSV
    local ids = {}
    if GL.Games then
        for _, def in ipairs(GL.Games:List()) do
            if not def.locked then ids[#ids + 1] = def.id end
        end
    end
    GL.Comm:Broadcast("MyVer", GL.version, table.concat(ids, "|"))
end

local function onMyVer(sender, coreVer, gameListCSV)
    -- M1：仅记录/可供 UI 显示；不做强校验。占位（避免未注册命令丢弃日志噪声）。
end

------------------------------------------------------------
-- 引导：注册所有 handler
------------------------------------------------------------
GL:Init(function()
    if not GL.Comm then return end
    GL.Comm:RegisterHandler("Start", onStart)
    GL.Comm:RegisterHandler("Begin", onBegin)
    GL.Comm:RegisterHandler("Join", onJoin)
    GL.Comm:RegisterHandler("Result", onResult)
    GL.Comm:RegisterHandler("Live", onLive)
    GL.Comm:RegisterHandler("Final", onFinal)
    GL.Comm:RegisterHandler("Tie", onTie)
    GL.Comm:RegisterHandler("GetState", onGetState)
    GL.Comm:RegisterHandler("State", onState)
    GL.Comm:RegisterHandler("VersionCheck", onVersionCheck)
    GL.Comm:RegisterHandler("MyVer", onMyVer)

    GL:_RegisterTeardown(function()
        bumpTick()
        if GL.Comm and GL.Comm.UnregisterHandler then
            for _, cmd in ipairs({ "Start", "Begin", "Join", "Result", "Live", "Final", "Tie",
                "GetState", "State", "VersionCheck", "MyVer" }) do
                GL.Comm:UnregisterHandler(cmd)
            end
        end
    end)
end)

-- 暴露常量给自检/UI（只读参考）。
Match.PHASE = PHASE
Match.MAX_CPS = MAX_CPS
Match.COLLECT_WINDOW = COLLECT_WINDOW
Match.TIEBREAK_DURATION = TIEBREAK_DURATION
