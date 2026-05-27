--
-- ChatThrottleLib by Mikk
--
-- Manages AddOn chat output to keep player from getting kicked off.
--
-- ChatThrottleLib.SendChatMessage / .SendAddonMessage functions that accept
-- a Priority ("BULK", "NORMAL", "ALERT") plus all the regular parameters.
--
-- Priorities get an equal share of bandwidth when fully loaded.
-- A higher priority does NOT mean a higher absolute output rate.
--
-- Author: Mikk
-- License: Public Domain
-- Source: https://www.wowace.com/projects/chat-throttle-lib (standard community lib)
-- Version embedded here: 24 (compatible with WotLK 3.x clients and the 时光服 38001 build)
--
-- 来源说明：社区标准版 ChatThrottleLib v24（Public Domain），原样嵌入，未改逻辑。
-- 自挂为全局 _G.ChatThrottleLib。我们不依赖大脚，因此必须自带此库。
--

local CTL_VERSION = 24

local _G = _G

if _G.ChatThrottleLib then
    if _G.ChatThrottleLib.version >= CTL_VERSION then
        -- 已有同等或更新版本（可能来自其他插件），让位
        return
    end
end

if not _G.ChatThrottleLib then
    _G.ChatThrottleLib = {}
end

local ChatThrottleLib = _G.ChatThrottleLib
ChatThrottleLib.version = CTL_VERSION

------------------ TWEAKABLES -----------------

ChatThrottleLib.MAX_CPS = 800          -- 字符/秒；游戏本身上限约 ~2000，留余量
ChatThrottleLib.MSG_OVERHEAD = 40      -- 每条消息估算开销字节
ChatThrottleLib.BURST = 4000           -- 突发允许积攒的字符数上限
ChatThrottleLib.MIN_FPS = 20           -- 低于此帧率时降低输出速率

local setmetatable = setmetatable
local table_remove = table.remove
local tostring = tostring
local GetTime = GetTime
local math_min = math.min
local math_max = math.max
local next = next
local strlen = string.len
local GetFramerate = GetFramerate
local strlower = string.lower
local unpack, type, pairs, wipe = unpack, type, pairs, table.wipe

------------------ Double-linked ring implementation -----------------

local Ring = {}
local RingMeta = { __index = Ring }

function Ring:New()
    local ret = {}
    setmetatable(ret, RingMeta)
    return ret
end

function Ring:Add(obj) -- 加到环尾
    if self.pos then
        obj.prev = self.pos.prev
        obj.prev.next = obj
        obj.next = self.pos
        obj.next.prev = obj
    else
        obj.next = obj
        obj.prev = obj
        self.pos = obj
    end
end

function Ring:Remove(obj)
    obj.next.prev = obj.prev
    obj.prev.next = obj.next
    if self.pos == obj then
        self.pos = obj.next
        if self.pos == obj then
            self.pos = nil
        end
    end
end

-- 把 ring2 整段链表移到 self 尾部
function Ring:Link(ring2)
    if not ring2.pos then
        return
    end
    if not self.pos then
        self.pos = ring2.pos
    else
        local oldlast = self.pos.prev
        local last2 = ring2.pos.prev
        oldlast.next = ring2.pos
        ring2.pos.prev = oldlast
        last2.next = self.pos
        self.pos.prev = last2
    end
    ring2.pos = nil
end

------------------ Recycling bin for pipes -----------------

ChatThrottleLib.PipeBin = nil

local PipeBin = setmetatable({}, { __mode = "k" })

local function DelPipe(pipe)
    PipeBin[pipe] = true
end

local function NewPipe()
    local pipe = next(PipeBin)
    if pipe then
        wipe(pipe)
        PipeBin[pipe] = nil
        return pipe
    end
    return {}
end

------------------ Recycling bin for messages -----------------

local MsgBin = setmetatable({}, { __mode = "k" })

local function DelMsg(msg)
    msg[1] = nil
    MsgBin[msg] = true
end

local function NewMsg()
    local msg = next(MsgBin)
    if msg then
        MsgBin[msg] = nil
        return msg
    end
    return {}
end

------------------ ChatThrottleLib:Init -----------------

function ChatThrottleLib:Init()
    -- 创建/复用环结构
    if not self.Prio then
        self.Prio = {
            ["ALERT"] = { ByName = {}, Ring = Ring:New(), avail = 0 },
            ["NORMAL"] = { ByName = {}, Ring = Ring:New(), avail = 0 },
            ["BULK"] = { ByName = {}, Ring = Ring:New(), avail = 0 },
        }
    end

    if not self.avail then
        self.avail = 0
    end
    if not self.nTotalSent then
        self.nTotalSent = 0
    end

    -- 兼容旧版升级
    if self.Frame then
        self.Frame:UnregisterAllEvents()
        self.Frame:SetScript("OnEvent", nil)
        self.Frame:SetScript("OnUpdate", nil)
    end

    self.Frame = CreateFrame("Frame")
    self.Frame:Hide()
    self.Frame:SetScript("OnEvent", self.OnEvent)
    self.Frame:SetScript("OnUpdate", self.OnUpdate)
    self.Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self.OnUpdateDelay = 0
    self.LastAvailUpdate = GetTime()
    self.HardThrottlingBeginTime = GetTime()

    -- 安装 hook（旧版 SendChatMessage 限速 hook，新版主要靠 ChatFrame 自身）
    if not self.securelyHooked then
        self.securelyHooked = true
        hooksecurefunc("SendChatMessage", function(...) return ChatThrottleLib.Hook_SendChatMessage(...) end)
        if _G.C_ChatInfo then
            hooksecurefunc(_G.C_ChatInfo, "SendAddonMessage",
                function(...) return ChatThrottleLib.Hook_SendAddonMessage_C(...) end)
        elseif _G.SendAddonMessage then
            hooksecurefunc("SendAddonMessage",
                function(...) return ChatThrottleLib.Hook_SendAddonMessage(...) end)
        end
    end
    self.nBypass = 0
end

------------------ Hooks 用于统计「计划外发送」抢占的带宽 -----------------

function ChatThrottleLib.Hook_SendChatMessage(text, chattype, language, destination, ...)
    local self = ChatThrottleLib
    local size = strlen(tostring(text or "")) + strlen(tostring(destination or "")) + self.MSG_OVERHEAD
    self.avail = self.avail - size
    self.nBypass = self.nBypass + size
end

function ChatThrottleLib.Hook_SendAddonMessage(text, chattype, destination, ...)
    local self = ChatThrottleLib
    local size = strlen(tostring(text or "")) + strlen(tostring(destination or "")) + self.MSG_OVERHEAD
    self.avail = self.avail - size
    self.nBypass = self.nBypass + size
end

function ChatThrottleLib.Hook_SendAddonMessage_C(prefix, text, chattype, destination, ...)
    local self = ChatThrottleLib
    local size = strlen(tostring(prefix or "")) + strlen(tostring(text or "")) +
        strlen(tostring(destination or "")) + self.MSG_OVERHEAD
    self.avail = self.avail - size
    self.nBypass = self.nBypass + size
end

------------------ 带宽计算 -----------------

function ChatThrottleLib:UpdateAvail()
    local now = GetTime()
    local MAX_CPS = self.MAX_CPS
    local newavail = MAX_CPS * (now - self.LastAvailUpdate)
    local avail = self.avail

    if now - self.HardThrottlingBeginTime < 5 then
        -- 刚登录/进副本时硬限速，避免被踢
        avail = math_min(avail + (newavail * 0.1), MAX_CPS * 0.5)
        self.bChoking = true
    elseif GetFramerate() < self.MIN_FPS then
        avail = math_min(MAX_CPS, avail + newavail * 0.5)
        self.bChoking = true
    else
        avail = math_min(self.BURST, avail + newavail)
        self.bChoking = false
    end

    avail = math_max(avail, 0 - (MAX_CPS * 2))

    self.avail = avail
    self.LastAvailUpdate = now

    return avail
end

------------------ 发送实现 -----------------

function ChatThrottleLib:Despool(Prio)
    local ring = Prio.Ring
    while ring.pos and Prio.avail > ring.pos[1].nSize do
        local msg = table_remove(ring.pos, 1)
        if not ring.pos[1] then -- 该 pipe 空了
            local pipe = ring.pos
            ring:Remove(pipe)
            Prio.ByName[pipe.name] = nil
            DelPipe(pipe)
        else
            ring.pos = ring.pos.next
        end
        Prio.avail = Prio.avail - msg.nSize
        msg.f(unpack(msg, 1, msg.n))
        DelMsg(msg)
    end
end

function ChatThrottleLib.OnEvent(this, event)
    local self = ChatThrottleLib
    if event == "PLAYER_ENTERING_WORLD" then
        self.HardThrottlingBeginTime = GetTime()
    end
end

function ChatThrottleLib.OnUpdate(this, delay)
    local self = ChatThrottleLib

    self.OnUpdateDelay = self.OnUpdateDelay + delay
    if self.OnUpdateDelay < 0.08 then
        return
    end
    self.OnUpdateDelay = 0

    self:UpdateAvail()

    if self.avail < 0 then
        return
    end

    -- 按优先级公平分配带宽
    local Prio = self.Prio
    local n = 0
    for _, prio in pairs(Prio) do
        if prio.Ring.pos or prio.avail < 0 then
            n = n + 1
        end
    end

    if n == 0 then
        for _, prio in pairs(Prio) do
            self.avail = self.avail + prio.avail
            prio.avail = 0
        end
        self.bQueueing = false
        self.Frame:Hide()
        return
    end

    local avail = self.avail / n
    self.avail = 0

    for _, prio in pairs(Prio) do
        if prio.Ring.pos or prio.avail < 0 then
            -- 给本优先级分配它应得的那份带宽，发送其队列；剩余带宽回收。
            prio.avail = prio.avail + avail
            self:Despool(prio)
            self.avail = self.avail + prio.avail
            prio.avail = 0
        end
    end
end

------------------ 入队 -----------------

function ChatThrottleLib:Enqueue(prioname, pipename, msg)
    local Prio = self.Prio[prioname]
    local pipe = Prio.ByName[pipename]
    if not pipe then
        self.Frame:Show()
        pipe = NewPipe()
        pipe.name = pipename
        Prio.ByName[pipename] = pipe
        Prio.Ring:Add(pipe)
    end
    pipe[#pipe + 1] = msg
    self.bQueueing = true
end

-- prio, prefix, text, chattype, target
function ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
    if not (prio and prefix and text and chattype) then
        error('Usage: ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype[, target])', 2)
    end
    if not self.Prio[prio] then
        error('ChatThrottleLib:SendAddonMessage(): invalid priority "' .. tostring(prio) .. '"', 2)
    end

    local nSize = #text

    -- 优先用现代 C_ChatInfo.SendAddonMessage
    local sendFn
    if _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessage then
        sendFn = function(...) _G.C_ChatInfo.SendAddonMessage(...) end
    else
        sendFn = _G.SendAddonMessage
    end

    if nSize > 255 then
        error('ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes', 2)
    end

    nSize = nSize + self.MSG_OVERHEAD

    -- 快路径：有余量直接发
    self:UpdateAvail()
    if self.avail > nSize and not self.bQueueing then
        self.avail = self.avail - nSize
        sendFn(prefix, text, chattype, target)
        self.nTotalSent = self.nTotalSent + nSize
        return
    end

    -- 否则入队
    local msg = NewMsg()
    msg.f = sendFn
    msg[1] = prefix
    msg[2] = text
    msg[3] = chattype
    msg[4] = target
    msg.n = 4
    msg.nSize = nSize

    self:Enqueue(prio, (queueName or (prefix .. (chattype or "") .. (target or ""))), msg)
end

function ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination, queueName, callbackFn, callbackArg)
    if not (prio and prefix and text and self.Prio[prio]) then
        error('Usage: ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination)', 2)
    end

    local nSize = strlen(text) + self.MSG_OVERHEAD

    self:UpdateAvail()
    if self.avail > nSize and not self.bQueueing then
        self.avail = self.avail - nSize
        _G.SendChatMessage(text, chattype, language, destination)
        self.nTotalSent = self.nTotalSent + nSize
        return
    end

    local msg = NewMsg()
    msg.f = _G.SendChatMessage
    msg[1] = text
    msg[2] = chattype
    msg[3] = language
    msg[4] = destination
    msg.n = 4
    msg.nSize = nSize

    self:Enqueue(prio, (queueName or (prefix .. (chattype or "") .. (destination or ""))), msg)
end

ChatThrottleLib:Init()
