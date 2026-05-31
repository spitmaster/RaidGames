-- Core/Push.lua —— 点对点游戏推送（P2P 分片传输，D17 / SPEC §6「点对点游戏推送」/ 功能 9b）
-- owner: wow-comm-wa-specialist
--
-- 职责（业务模块，范式参考 Match）：把**单个小游戏**直接推给指定玩家，对方一键接收即玩。
-- 先握手（PushOffer）→ 接收端过信任门（默认拒绝）→ PushAccept 后才分片传 → 重组 → 装好即玩。
--
-- ┌─ UI 接入点（右键推送入口由 wow-ui-developer 实现，本文件不做 UI）──────────────┐
-- │ 发送：  GL.Push:SendGame(targetName, gameId)                                    │
-- │   - targetName：目标玩家名（可不带 -realm，内部 Roster:Norm 归一化）            │
-- │   - gameId    ：要推的游戏 id（须是本端已注册、且 def.code 可导出的游戏）       │
-- │   - 返回 ok(bool), msg(string)；ok=false 时 msg 是可读原因（UI 可直接提示）     │
-- │ 接收侧无需 UI 主动调用：收 PushOffer 自动弹信任门（GL.UI:ConfirmTrust）。       │
-- │ 进度/结果统一走 GL:Emit("LOG", level, text)，大厅日志条会显示。                 │
-- └──────────────────────────────────────────────────────────────────────────────┘
--
-- 复用关系（不重造轮子）：
--   - 分片收发原语在 GL.Comm（SendChunked / NewReassembler），业务无关（不变量 #2）。
--   - 串生成 GL.Import:ExportGame、解析 GL.Import:ParseWA、执行+注册 GL.Import:RunPayload，
--     信任门 GL.UI:ConfirmTrust —— 全部复用 GameImport / Popups，不重写。
--   - 版本门控由 RunPayload→RegisterGame 兜（低于已装版本忽略，不降级）。
--
-- 不变量：#1 同体（首行 aura_env）；#2 通讯解耦（收发走 Comm，本文件只编排业务）；
--         #4 字节级一致（命令名/字段顺序/data 末位 与 SPEC §6 表逐字一致）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

local After = (C_Timer and C_Timer.After) or function(_, fn) fn() end

local Push = {}
GL.Push = Push

------------------------------------------------------------
-- 常量
------------------------------------------------------------

local OFFER_TIMEOUT = 30.0     -- 推送方发 Offer 后等 Accept/Deny 的超时（秒）
local RECV_TIMEOUT = 30.0      -- 接收端收齐分片的传输超时（秒，未收齐则丢弃会话）

------------------------------------------------------------
-- 工具
------------------------------------------------------------

local function logSys(text)  GL:Emit("LOG", "sys", text)  end
local function logWarn(text) GL:Emit("LOG", "warn", text) end

local function norm(name)
    return (GL.Roster and GL.Roster:Norm(name)) or name
end

-- 会话单调代号：每次新的发送/接收会话 +1，定时器闭包比对令旧的失效（防串场）。
Push._sendSeq = Push._sendSeq or 0
Push._recvSeq = Push._recvSeq or 0

-- 发送端在途会话：[targetNorm] = { gameId, str, token, accepted }
Push._sending = Push._sending or {}
-- 接收端在途会话：[senderNorm] = { gameId, gameName, gameVer, reassembler, token }
Push._receiving = Push._receiving or {}

------------------------------------------------------------
-- 发送端：SendGame(target, gameId) —— UI 调用入口
------------------------------------------------------------
-- 流程：ExportGame(id) 得 !GL: 串 → 记会话 → 发 PushOffer → 等 PushAccept 才分片发。
-- 返回 ok, msg。ok=true 仅表示「已发出 Offer」，真正完成在收到 Accept 后异步发分片。
function Push:SendGame(target, gameId)
    if not (GL.Comm and GL.Comm.Whisper) then
        return false, "通讯层未就绪，无法推送"
    end
    local targetNorm = norm(target)
    if not targetNorm or targetNorm == "" then
        return false, "推送目标无效"
    end
    -- 不能推给自己（无意义）。
    local me = GL.Roster and GL.Roster:Me()
    if me and targetNorm == me then
        return false, "不能把游戏推给自己"
    end
    if not (GL.Import and GL.Import.ExportGame) then
        return false, "导出模块未就绪，无法推送"
    end

    -- 取游戏元信息（用于 Offer 展示名/版本）。
    local def = GL.Games and GL.Games:Get(gameId)
    if not def then
        return false, "本端未注册该游戏，无法推送"
    end

    -- 导出 !GL: 串（可执行代码必须可导出，占位/locked 游戏无 code）。
    local str, err = GL.Import:ExportGame(gameId)
    if not str then
        return false, "无法导出该游戏：" .. tostring(err)
    end

    -- 记录在途发送会话（同一目标的旧会话被覆盖：以最新一次推送为准）。
    Push._sendSeq = Push._sendSeq + 1
    local token = Push._sendSeq
    Push._sending[targetNorm] = {
        gameId = gameId,
        str = str,
        token = token,
        accepted = false,
    }

    -- 发 PushOffer：gameId,gameName,gameVer,totalLen,nChunks
    -- nChunks 这里给「预估」无意义（真实片数发送时定），SPEC 表里它供接收端展示大小用；
    -- 我们传 totalLen（真实字节数）+ 一个预估 nChunks（按粗略每片估），不作为重组依据
    -- （重组以 PushChunk 自带的 nChunks 为准）。
    local totalLen = #str
    local estChunks = math.max(1, math.ceil(totalLen / 200))
    GL.Comm:Whisper(targetNorm, "PushOffer",
        gameId, def.name or gameId, def.version or "?", totalLen, estChunks)

    logSys(string.format("已向 %s 发出「%s」推送邀请，等待对方确认…",
        targetNorm, tostring(def.name or gameId)))

    -- 超时：到点仍未 accepted 则放弃会话。
    After(OFFER_TIMEOUT, function()
        local s = Push._sending[targetNorm]
        if s and s.token == token and not s.accepted then
            Push._sending[targetNorm] = nil
            logWarn(string.format("推送「%s」给 %s 超时未响应，已取消。",
                tostring(def.name or gameId), targetNorm))
        end
    end)

    return true, "已发出推送邀请"
end

------------------------------------------------------------
-- 发送端：收到 PushAccept → 分片逐条 PushChunk 发
------------------------------------------------------------
-- PushAccept: gameId（来自 target）。
local function onPushAccept(sender, gameId)
    local senderNorm = norm(sender)
    local s = Push._sending[senderNorm]
    if not s then return end                      -- 无对应在途会话，忽略
    if s.gameId ~= gameId then return end          -- 游戏对不上（陈旧 Accept），忽略
    if s.accepted then return end                  -- 重复 Accept，去重
    s.accepted = true

    -- 分片逐条发：PushChunk,gameId,seq,nChunks,data（data 末位，走 Comm 原语）。
    local nChunks = GL.Comm:SendChunked(senderNorm, "PushChunk", { gameId }, s.str)
    if not nChunks then
        Push._sending[senderNorm] = nil
        logWarn(string.format("向 %s 发送「%s」分片失败。", senderNorm, tostring(gameId)))
        return
    end
    logSys(string.format("%s 已接受，正在发送「%s」（%d 片）…", senderNorm, tostring(gameId), nChunks))
    -- 发完即清会话（接收端重组/注册是对端的事，我们不需要再保留）。
    Push._sending[senderNorm] = nil
end

-- PushDeny: gameId,reason（来自 target）。
local function onPushDeny(sender, gameId, reason)
    local senderNorm = norm(sender)
    local s = Push._sending[senderNorm]
    if not s or s.gameId ~= gameId then return end
    Push._sending[senderNorm] = nil
    logWarn(string.format("%s 拒绝了「%s」推送（%s）。",
        senderNorm, tostring(gameId), tostring(reason ~= "" and reason or "对方取消")))
end

------------------------------------------------------------
-- 接收端：收 PushOffer → 信任门 → Accept / Deny
------------------------------------------------------------
-- PushOffer: gameId,gameName,gameVer,totalLen,nChunks（来自推送方）。
local function onPushOffer(sender, gameId, gameName, gameVer, totalLen, nChunks)
    local senderNorm = norm(sender)
    if not senderNorm or not gameId or gameId == "" then return end

    -- 已有同源在途接收会话：忽略重复 Offer（防对方重发刷信任门）。
    if Push._receiving[senderNorm] then return end

    local function deny(reason)
        if GL.Comm then GL.Comm:Whisper(senderNorm, "PushDeny", gameId, reason or "") end
    end

    -- 信任门（默认拒绝，SPEC §3 安全）：复用 GL.UI:ConfirmTrust。
    -- 来源串带上「谁推的、什么游戏」让用户知情。
    local source = string.format("%s 推送的游戏「%s」%s",
        senderNorm, tostring(gameName or gameId),
        gameVer and (" v" .. tostring(gameVer)) or "")

    local function accept()
        -- 信任门通过：建接收会话（reassembler 在收到第一片 PushChunk 时按其 nChunks 建），
        -- 这里只标记「已同意、等分片」，并发 PushAccept。
        Push._recvSeq = Push._recvSeq + 1
        local token = Push._recvSeq
        Push._receiving[senderNorm] = {
            gameId = gameId,
            gameName = gameName,
            gameVer = gameVer,
            reassembler = nil,   -- 收到首片再建（依赖片自带 nChunks）
            token = token,
        }
        if GL.Comm then GL.Comm:Whisper(senderNorm, "PushAccept", gameId) end
        logSys(string.format("已同意接收 %s 的「%s」，等待数据…", senderNorm, tostring(gameName or gameId)))

        -- 传输超时：到点仍未收齐则丢弃会话（防半截传输占着会话不放）。
        After(RECV_TIMEOUT, function()
            local r = Push._receiving[senderNorm]
            if r and r.token == token then
                Push._receiving[senderNorm] = nil
                logWarn(string.format("接收 %s 的「%s」超时未收齐，已丢弃。",
                    senderNorm, tostring(gameName or gameId)))
            end
        end)
    end

    if GL.UI and GL.UI.ConfirmTrust then
        GL.UI:ConfirmTrust(source, accept)
        -- 注意：ConfirmTrust 取消时不会回调；我们不主动发 Deny（避免用户没看清就拒），
        -- 推送方侧 OFFER_TIMEOUT 会兜底放弃。若要显式 Deny，UI 信任门需提供 onNo 回调（M1 不强求）。
    else
        -- 无 UI 信任门（纯逻辑环境）：安全优先，直接 Deny，绝不静默接收执行外来代码。
        deny("no-ui")
        logWarn("收到游戏推送，但信任确认框不可用，已自动拒绝（请通过大厅界面操作）。")
    end
end

-- PushChunk: gameId,seq,nChunks,data（data 末位，含其内部字符）。
-- handler 签名 fn(sender, a1..a7, rawBody)：a1=gameId, a2=seq, a3=nChunks, a4..=data 起始，
-- 但 data 是「剩余原文」，必须用 SplitLead(rawBody, 3) 精确取第 4 段（gameId,seq,nChunks 之后全部）。
local function onPushChunk(sender, a1, a2, a3, a4, a5, a6, a7, rawBody)
    local senderNorm = norm(sender)
    local r = Push._receiving[senderNorm]
    if not r then return end   -- 没同意过 / 已超时丢弃 / 非预期来源 → 忽略（健壮性）

    -- 精确切：rawBody = gameId,seq,nChunks,<data>。前 3 段切完，第 4 段是完整 data。
    local gameId, seq, nChunks, data
    if rawBody and GL.Comm and GL.Comm.SplitLead then
        gameId, seq, nChunks, data = GL.Comm.SplitLead(rawBody, 3)
    else
        gameId, seq, nChunks, data = a1, a2, a3, a4
    end

    if gameId ~= r.gameId then return end   -- 游戏对不上（串场），忽略

    -- 首片：据片自带 nChunks 建 reassembler（含上限护栏，越界则拒收并丢弃会话）。
    if not r.reassembler then
        local re = GL.Comm:NewReassembler(nChunks)
        if not re then
            Push._receiving[senderNorm] = nil
            logWarn(string.format("「%s」分片数异常（%s），已拒收。",
                tostring(r.gameName or gameId), tostring(nChunks)))
            return
        end
        r.reassembler = re
    end

    local done, full = r.reassembler:Feed(seq, data)
    if not done then return end

    -- 收齐：清会话 → ParseWA → RunPayload（信任门已过，直接装）。
    Push._receiving[senderNorm] = nil

    if not (GL.Import and GL.Import.ParseWA and GL.Import.RunPayload) then
        logWarn("导入模块未就绪，无法装载推来的游戏。")
        return
    end

    local payloads, perr = GL.Import:ParseWA(full)
    if not payloads then
        logWarn(string.format("接收的「%s」解析失败：%s",
            tostring(r.gameName or gameId), tostring(perr)))
        return
    end

    -- 逐个载荷执行+注册（单游戏一般只有 1 个；bundle 不走 P2P，但容错处理多个）。
    local okCount, lastMsg = 0, nil
    for _, p in ipairs(payloads) do
        local ok, msg = GL.Import:RunPayload(p)
        lastMsg = msg
        if ok then okCount = okCount + 1 end
    end

    if okCount > 0 then
        logSys(string.format("已收到并装好「%s」，立即可玩！",
            tostring(r.gameName or gameId)))
    else
        -- 全失败：通常是版本门控忽略（不降级）或编译失败，把最后一条原因透出。
        logWarn(string.format("接收的「%s」未能装载：%s",
            tostring(r.gameName or gameId), tostring(lastMsg or "未知原因")))
    end
end

------------------------------------------------------------
-- 引导：注册 handler（随 Comm 一起）
------------------------------------------------------------
GL:Init(function()
    if not GL.Comm then return end
    GL.Comm:RegisterHandler("PushOffer", onPushOffer)
    GL.Comm:RegisterHandler("PushAccept", onPushAccept)
    GL.Comm:RegisterHandler("PushDeny", onPushDeny)
    GL.Comm:RegisterHandler("PushChunk", onPushChunk)

    GL:_RegisterTeardown(function()
        if GL.Comm and GL.Comm.UnregisterHandler then
            for _, cmd in ipairs({ "PushOffer", "PushAccept", "PushDeny", "PushChunk" }) do
                GL.Comm:UnregisterHandler(cmd)
            end
        end
        -- 清在途会话（热升级让位）。
        Push._sending = {}
        Push._receiving = {}
    end)
end)
