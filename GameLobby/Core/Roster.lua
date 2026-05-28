-- Core/Roster.lua —— 团长/助理识别、团队名单、名字归一化（契约 §4）
-- owner: wow-addon-engineer
--
-- 职责（契约 §4）：
--   CanInitiate / IsLeader / IsAssist / GetChannel / GetMembers / Norm / Me
--   成员/身份变化时 GL:Emit("ROSTER_CHANGED")（监听 GROUP_ROSTER_UPDATE / PARTY_LEADER_CHANGED）。
--
-- 关键依赖：GetChannel() 是 Comm:Broadcast 的频道来源（RAID/PARTY/nil）。单人返回 nil → Comm 不发。
-- 不变量 #1（同体）：首行 aura_env，全程只挂到 GL.Roster，不自己监听三档生命周期事件。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end

-- 局部缓存常用全局（biaoge 风格，热路径少一次表查找）
local UnitIsGroupLeader = UnitIsGroupLeader
local UnitIsGroupAssistant = UnitIsGroupAssistant
local IsInRaid = IsInRaid
local IsInGroup = IsInGroup
local GetNumGroupMembers = GetNumGroupMembers
local UnitName = UnitName
local UnitClass = UnitClass
local UnitIsConnected = UnitIsConnected
local GetRealmName = GetRealmName

local Roster = {}
GL.Roster = Roster

------------------------------------------------------------
-- 名字归一化（契约 §0：玩家名一律带 -realm；字段内禁止逗号）
------------------------------------------------------------

-- 本服名（去空格/连字符，与跨服名拼接一致）。运行时取一次缓存。
local function localRealm()
    if not Roster._realm then
        local r = GetRealmName and GetRealmName() or ""
        Roster._realm = (r or ""):gsub("%s", ""):gsub("%-", "")
    end
    return Roster._realm
end

-- "Healer" / "Healer-服务器" → "Healer-服务器"（统一带 realm）。
-- nil / 空串 → nil。本服名补本服 realm；已带 realm 的原样保留。
function Roster:Norm(name)
    if type(name) ~= "string" or name == "" then return nil end
    local n, realm = string.match(name, "^([^%-]+)%-?(.*)$")
    if not n or n == "" then return nil end
    if not realm or realm == "" then
        realm = localRealm()
    end
    return n .. "-" .. realm
end

-- 自己的归一化名。
function Roster:Me()
    local n = UnitName("player")
    return self:Norm(n)
end

------------------------------------------------------------
-- 身份判定（契约 §4）
------------------------------------------------------------

-- 在队伍或团队中（单人为 false）。
function Roster:InGroup()
    return IsInGroup() and true or false
end

function Roster:IsLeader()
    return UnitIsGroupLeader("player") and true or false
end

function Roster:IsAssist()
    -- WLK：团队助理；队伍中无助理概念，UnitIsGroupAssistant 返回 false。
    return UnitIsGroupAssistant("player") and true or false
end

-- 能否发起：
--   - 单人：允许（自己跟自己玩，无需身份）；
--   - 小队/团队：仍需团长或助理（SPEC 功能 1/2，避免随便发起骚扰团队）。
function Roster:CanInitiate()
    if not self:InGroup() then return true end
    return self:IsLeader() or self:IsAssist()
end

-- 广播频道（Comm:Broadcast 依赖）：在团队 RAID、仅队伍 PARTY、单人 nil。
function Roster:GetChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

------------------------------------------------------------
-- 团队/队伍名单（契约 §4）
------------------------------------------------------------

-- 返回 { {name, nameNorm, classFile, class, isSelf, isLeader, online}, ... }
--   name      ：原始单位名（用于 UnitClass 等 API）
--   nameNorm  ：归一化名（带 -realm，模块间一律用它做 key）
--   classFile ：职业英文 token（"WARRIOR" 等，UI 取职业色用）
--   class     ：本地化职业名
--   isSelf / isLeader / online
function Roster:GetMembers()
    local out = {}
    local meNorm = self:Me()

    if IsInRaid() then
        local n = GetNumGroupMembers()
        for i = 1, n do
            -- WLK GetRaidRosterInfo: name, rank(0=普通,1=助理,2=团长), ..., online, ..., class(本地化), ..., classFile
            local rname, rank, _, _, class, classFile, _, online = GetRaidRosterInfo(i)
            if rname then
                local norm = self:Norm(rname)
                out[#out + 1] = {
                    name = rname,
                    nameNorm = norm,
                    classFile = classFile,
                    class = class,
                    isSelf = (norm == meNorm),
                    isLeader = (rank == 2),
                    online = online and true or false,
                }
            end
        end
    elseif IsInGroup() then
        -- 小队：player + party1..N
        local units = { "player" }
        local n = GetNumGroupMembers()  -- 含自己
        for i = 1, n - 1 do units[#units + 1] = "party" .. i end
        for _, unit in ipairs(units) do
            local rname = UnitName(unit)
            if rname then
                local class, classFile = UnitClass(unit)
                local norm = self:Norm(rname)
                out[#out + 1] = {
                    name = rname,
                    nameNorm = norm,
                    classFile = classFile,
                    class = class,
                    isSelf = (unit == "player"),
                    isLeader = UnitIsGroupLeader(unit) and true or false,
                    online = (unit == "player") or (UnitIsConnected(unit) and true or false),
                }
            end
        end
    else
        -- 单人：只有自己。
        local rname = UnitName("player")
        local class, classFile = UnitClass("player")
        out[#out + 1] = {
            name = rname,
            nameNorm = meNorm,
            classFile = classFile,
            class = class,
            isSelf = true,
            isLeader = false,
            online = true,
        }
    end

    return out
end

------------------------------------------------------------
-- 名单/身份变化 → Emit ROSTER_CHANGED
------------------------------------------------------------

GL:Init(function()
    -- 专用事件帧；幂等复用（防 flush 重复调用建多帧）。
    local frame = Roster._frame
    if not frame then
        frame = CreateFrame("Frame")
        Roster._frame = frame
    end
    frame:UnregisterAllEvents()
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("PARTY_LEADER_CHANGED")
    frame:SetScript("OnEvent", function()
        -- realm 不变，但成员/身份可能变：广播一次，由 UI/Match 自行重查。
        GL:Emit("ROSTER_CHANGED")
    end)

    -- 热升级让位时停掉本帧。
    GL:_RegisterTeardown(function()
        if frame then
            frame:UnregisterAllEvents()
            frame:SetScript("OnEvent", nil)
        end
    end)
end)
