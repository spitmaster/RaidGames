-- GameLobby/Tests/headless_env.lua
-- 无头 WoW 3.3.5(时光服)API 模拟环境，供离线加载整个插件并驱动 UI/状态机/战绩抓运行时错。
-- 目标：复现「点了没反应=静默 Lua 错」那类 bug（nil 索引/调用、字段对不上、ctx 结构不符）。
-- 不模拟真实渲染/网络/多人；库（LibDeflate/Serialize/ChatThrottle）用桩。
-- 用法：被 run_all.lua require/dofile 后，全局已就绪，可 dofile 各插件文件。

local M = {}

-- ============ 事件总线（模拟 frame:RegisterEvent + 触发）============
local allEventFrames = {}   -- 所有注册过事件的 mock frame
function M.FireEvent(event, ...)
    for f in pairs(allEventFrames) do
        if f._events[event] and f._scripts.OnEvent then
            f._scripts.OnEvent(f, event, ...)
        end
    end
end

-- ============ C_Timer 模拟（手动推进）============
local timers = {}   -- { {at=, fn=}, ... }
local NOW = 1000.0
_G.GetTime = function() return NOW end
M.now = function() return NOW end
M.advance = function(dt)   -- 推进时钟并触发到期 timer
    local target = NOW + dt
    -- 反复扫描（timer 可能再排 timer）
    local guard = 0
    while true do
        guard = guard + 1; if guard > 10000 then break end
        local nextT, idx = nil, nil
        for i, t in ipairs(timers) do
            if not t.done and t.at <= target and (not nextT or t.at < nextT) then nextT, idx = t.at, i end
        end
        if not idx then break end
        NOW = timers[idx].at
        timers[idx].done = true
        local fn = timers[idx].fn
        local ok, err = pcall(fn)
        if not ok then error("C_Timer 回调出错: " .. tostring(err), 0) end
    end
    NOW = target
end
_G.C_Timer = {
    After = function(sec, fn) table.insert(timers, { at = NOW + (sec or 0), fn = fn }) end,
    NewTicker = function(sec, fn, iter)
        local t = { at = NOW + (sec or 0), fn = fn }; table.insert(timers, t)
        return { Cancel = function() t.done = true end }
    end,
}

-- ============ Region / Frame mock ============
local Region = {}
Region.__index = Region

local function num(v, d) return type(v) == "number" and v or d end

-- 真实实现的方法（其余走 __index 兜底 no-op）
local realMethods = {
    -- 几何
    SetWidth = function(s, w) s._w = w end,
    SetHeight = function(s, h) s._h = h end,
    SetSize = function(s, w, h) s._w, s._h = w, h end,
    GetWidth = function(s) return num(s._w, 760) end,
    GetHeight = function(s) return num(s._h, 500) end,
    GetLeft = function() return 0 end, GetRight = function(s) return num(s._w, 760) end,
    GetTop = function(s) return num(s._h, 500) end, GetBottom = function() return 0 end,
    GetEffectiveScale = function() return 1 end, GetScale = function() return 1 end,
    SetScale = function() end,
    GetNumPoints = function(s) return #s._points end,
    GetPoint = function(s, i)
        local p = s._points[i or 1]; if not p then return "CENTER", nil, "CENTER", 0, 0 end
        return p[1], p[2], p[3], p[4], p[5]
    end,
    SetPoint = function(s, ...) table.insert(s._points, { ... }) end,
    SetAllPoints = function(s) s._allPoints = true end,
    ClearAllPoints = function(s) s._points = {} end,
    -- 显隐
    Show = function(s) s._shown = true end,
    Hide = function(s) s._shown = false end,
    SetShown = function(s, b) s._shown = not not b end,
    IsShown = function(s) return s._shown end,
    IsVisible = function(s) return s._shown end,
    IsMouseEnabled = function(s) return s._mouse end,
    EnableMouse = function(s, b) s._mouse = not not b end,
    EnableKeyboard = function(s, b) s._kbd = not not b end,
    SetAlpha = function(s, a) s._alpha = a end,
    GetAlpha = function(s) return num(s._alpha, 1) end,
    -- 文本
    SetText = function(s, t) s._text = t end,
    GetText = function(s) return s._text or "" end,
    SetFormattedText = function(s, fmt, ...) s._text = string.format(fmt or "", ...) end,
    SetTextColor = function() end, SetVertexColor = function() end,
    SetFont = function() return true end, SetFontObject = function() end,
    GetFont = function() return "Fonts\\ARKai_T.ttf", 12, "" end,
    SetShadowColor = function() end, SetShadowOffset = function() end,
    SetJustifyH = function() end, SetJustifyV = function() end,
    SetWordWrap = function() end, SetNonSpaceWrap = function() end,
    SetMaxLetters = function() end, SetTextInsets = function() end,
    SetAutoFocus = function() end, SetFocus = function() end, ClearFocus = function() end,
    HighlightText = function() end, SetCursorPosition = function() end,
    SetMultiLine = function() end, Insert = function() end,
    GetStringWidth = function(s) return #(s._text or "") * 6 end,
    -- 贴图
    SetTexture = function() return true end, GetTexture = function() return nil end,
    SetColorTexture = function() end, SetTexCoord = function() end,
    SetBlendMode = function() end, SetDrawLayer = function() end,
    SetDesaturated = function() end, SetRotation = function() end,
    SetGradient = function() end, SetGradientAlpha = function() end,
    -- 脚本/事件
    SetScript = function(s, name, fn) s._scripts[name] = fn end,
    GetScript = function(s, name) return s._scripts[name] end,
    HookScript = function(s, name, fn) s._scripts[name .. "_hook"] = fn end,
    SetScripts = function() end,
    RegisterEvent = function(s, e) s._events[e] = true; allEventFrames[s] = true end,
    UnregisterEvent = function(s, e) s._events[e] = nil end,
    UnregisterAllEvents = function(s) s._events = {} end,
    RegisterForClicks = function() end, RegisterForDrag = function() end,
    RegisterUnitEvent = function(s, e) s._events[e] = true; allEventFrames[s] = true end,
    -- 层级/属性
    SetFrameStrata = function() end, GetFrameStrata = function() return "MEDIUM" end,
    SetFrameLevel = function() end, GetFrameLevel = function() return 1 end,
    SetToplevel = function() end, SetMovable = function() end, SetResizable = function() end,
    SetClampedToScreen = function() end, SetUserPlaced = function() end,
    StartMoving = function() end, StopMovingOrSizing = function() end,
    SetParent = function(s, p) s._parent = p end, GetParent = function(s) return s._parent end,
    GetName = function(s) return s._name end,
    GetObjectType = function(s) return s._otype or "Frame" end,
    IsObjectType = function(s, t) return s._otype == t end,
    SetID = function(s, id) s._id = id end, GetID = function(s) return s._id or 0 end,
    SetBackdrop = function() end, SetBackdropColor = function() end, SetBackdropBorderColor = function() end,
    SetHitRectInsets = function() end, SetClipsChildren = function() end,
    -- 按钮
    Enable = function(s) s._enabled = true end, Disable = function(s) s._enabled = false end,
    IsEnabled = function(s) return s._enabled ~= false end,
    SetEnabled = function(s, b) s._enabled = not not b end,
    SetEnabledLook = function() end,
    SetNormalTexture = function() end, SetPushedTexture = function() end,
    SetHighlightTexture = function() end, GetNormalTexture = function(s) return s:CreateTexture() end,
    Click = function(s) if s._scripts.OnClick then s._scripts.OnClick(s, "LeftButton") end end,
    -- slider/editbox/scroll 杂项
    SetMinMaxValues = function() end, SetValue = function() end, GetValue = function() return 0 end,
    SetValueStep = function() end, SetOrientation = function() end,
    SetScrollChild = function(s, c) s._scrollChild = c end, GetScrollChild = function(s) return s._scrollChild end,
    SetVerticalScroll = function() end, GetVerticalScrollRange = function() return 0 end,
    UpdateScrollChildRect = function() end,
    GetNumChildren = function() return 0 end,
}

function Region.__index(s, k)
    local rm = realMethods[k]
    if rm then return rm end
    -- 子区域工厂方法
    if k == "CreateTexture" or k == "CreateFontString" or k == "CreateMaskTexture" then
        return function(self, name)
            return M.newRegion(name, self, k == "CreateFontString" and "FontString" or "Texture")
        end
    end
    if k == "CreateAnimationGroup" then
        return function() return M.newAnimGroup() end
    end
    -- 关键：只有「像 WoW API 方法名」(PascalCase，首字母大写) 才返回 no-op 方法；
    -- 否则视为「代码自己挂的数据字段」(_borders/_bg/_frame 等)，未设置就返回 nil，
    -- 这样 `x = x or {}` 和 `if self._foo then` 才正确（否则 nil 会变 no-op 函数=真值）。
    if type(k) == "string" and k:match("^%u") then
        return function(self) return self end
    end
    return nil
end

local regionCount = 0
function M.newRegion(name, parent, otype)
    regionCount = regionCount + 1
    local r = setmetatable({
        _name = name, _parent = parent, _otype = otype or "Frame",
        _w = nil, _h = nil, _points = {}, _scripts = {}, _events = {},
        _shown = true, _alpha = 1, _mouse = false, _enabled = true, _text = nil,
    }, Region)
    if name then _G[name] = r end
    return r
end

function M.newAnimGroup()
    return setmetatable({ _scripts = {} }, {
        __index = function(_, k)
            if k == "CreateAnimation" then return function() return M.newAnimGroup() end end
            return function(self) return self end
        end,
    })
end

-- ============ 全局 API ============
_G.CreateFrame = function(ftype, name, parent, template)
    local f = M.newRegion(name, parent, ftype or "Frame")
    f._shown = (ftype ~= "Frame") and f._shown or false  -- 顶层 Frame 默认按代码 Show/Hide
    f._shown = true
    return f
end
_G.UIParent = M.newRegion("UIParent", nil, "Frame")
_G.WorldFrame = M.newRegion("WorldFrame", nil, "Frame")
_G.SlashCmdList = {}   -- slash 命令注册表（SLASH_XXX1 + SlashCmdList[token]）

-- 颜色对象（现代 API）
local ColorMixin = {}
ColorMixin.__index = ColorMixin
function ColorMixin:GetRGB() return self.r, self.g, self.b end
function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a end
function ColorMixin:GetRGBAAsBytes() return self.r*255, self.g*255, self.b*255, (self.a or 1)*255 end
_G.CreateColor = function(r, g, b, a) return setmetatable({ r=r, g=g, b=b, a=a or 1 }, ColorMixin) end
_G.Enum = { Orientation = { Horizontal = 0, Vertical = 1 } }

-- 字符串/表全局别名
_G.strsplit = function(sep, str, limit)
    local out, n = {}, 0
    local pat = "([^" .. sep .. "]*)"
    -- 简化：按单字符 sep 切；够 GameLobby 用（实际收发走 Comm.SplitLead）
    local s = str
    while true do
        n = n + 1
        if limit and n >= limit then table.insert(out, s); break end
        local i = string.find(s, sep, 1, true)
        if not i then table.insert(out, s); break end
        table.insert(out, string.sub(s, 1, i - 1))
        s = string.sub(s, i + #sep)
    end
    return unpack(out)
end
_G.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
_G.strtrim = function(s, chars) return (s:gsub("^%s*(.-)%s*$", "%1")) end
_G.strmatch = string.match; _G.strfind = string.find; _G.strsub = string.sub
_G.strlen = string.len; _G.strrep = string.rep; _G.strlower = string.lower
_G.strupper = string.upper; _G.gsub = string.gsub; _G.format = string.format
_G.gmatch = string.gmatch; _G.strbyte = string.byte; _G.strchar = string.char
_G.tinsert = table.insert; _G.tremove = table.remove; _G.tContains = function(t, v)
    for _, x in ipairs(t) do if x == v then return true end end; return false
end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.strsplittable = function(sep, str) return { strsplit(sep, str) } end
_G.strlenutf8 = function(s) local _, c = s:gsub("[^\128-\191]", ""); return c end
_G.max = math.max; _G.min = math.min; _G.abs = math.abs; _G.floor = math.floor; _G.ceil = math.ceil
_G.securecall = function(f, ...) return f(...) end
_G.hooksecurefunc = function(tbl, name, fn)
    if type(tbl) == "string" then fn = name; name = tbl; tbl = _G end
    local orig = tbl[name]; tbl[name] = function(...) if orig then orig(...) end return fn(...) end
end
_G.geterrorhandler = function() return function(e) error("[geterrorhandler] " .. tostring(e), 0) end end

-- bit 库（LibDeflate/Serialize 可能用；提供纯 lua shim）
if not _G.bit then
    local function tobit(x) x = x % 0x100000000; if x >= 0x80000000 then x = x - 0x100000000 end return x end
    local bit = {}
    function bit.band(a, b) local r, m = 0, 1; a=a%0x100000000; b=b%0x100000000; for i=0,31 do if (a%2==1) and (b%2==1) then r=r+m end a=math.floor(a/2); b=math.floor(b/2); m=m*2 end return tobit(r) end
    function bit.bor(a, b) local r, m = 0, 1; a=a%0x100000000; b=b%0x100000000; for i=0,31 do if (a%2==1) or (b%2==1) then r=r+m end a=math.floor(a/2); b=math.floor(b/2); m=m*2 end return tobit(r) end
    function bit.bxor(a, b) local r, m = 0, 1; a=a%0x100000000; b=b%0x100000000; for i=0,31 do if (a%2)~=(b%2) then r=r+m end a=math.floor(a/2); b=math.floor(b/2); m=m*2 end return tobit(r) end
    function bit.bnot(a) return tobit(-1 - (a%0x100000000)) end
    function bit.lshift(a, n) return tobit((a%0x100000000) * 2^n) end
    function bit.rshift(a, n) return tobit(math.floor((a%0x100000000) / 2^n)) end
    function bit.arshift(a, n) return tobit(math.floor(tobit(a) / 2^n)) end
    _G.bit = bit
end

-- 玩家/队伍 API（默认：单人、是团长）
M.state = { isLeader = true, isAssist = false, inRaid = false, inGroup = false,
            playerName = "Tester", realm = "测试服", members = {} }
_G.UnitName = function(unit) if unit == "player" then return M.state.playerName end return unit end
_G.UnitClass = function() return "战士", "WARRIOR" end
_G.UnitIsGroupLeader = function() return M.state.isLeader end
_G.UnitIsGroupAssistant = function() return M.state.isAssist end
_G.UnitExists = function() return true end
_G.UnitIsConnected = function() return true end
_G.IsInRaid = function() return M.state.inRaid end
_G.IsInGroup = function() return M.state.inGroup end
_G.GetNumGroupMembers = function() return #M.state.members end
_G.GetNumRaidMembers = function() return M.state.inRaid and #M.state.members or 0 end
_G.GetNumPartyMembers = function() return (M.state.inGroup and not M.state.inRaid) and (#M.state.members - 1) or 0 end
_G.GetRaidRosterInfo = function(i)
    local m = M.state.members[i]; if not m then return nil end
    return m.name, (m.isLeader and 2 or (m.isAssist and 1 or 0)), nil, nil, m.class, m.classFile, nil, m.online ~= false
end
_G.GetClassColor = function(cf)
    local c = (_G.RAID_CLASS_COLORS or {})[cf]; if c then return c.r, c.g, c.b end
    return 1, 1, 1
end
_G.RAID_CLASS_COLORS = {
    WARRIOR={r=.78,g=.61,b=.43}, MAGE={r=.41,g=.8,b=.94}, PRIEST={r=1,g=1,b=1},
    ROGUE={r=1,g=.96,b=.41}, PALADIN={r=.96,g=.55,b=.73}, HUNTER={r=.67,g=.83,b=.45},
    WARLOCK={r=.58,g=.51,b=.79}, SHAMAN={r=0,g=.44,b=.87}, DRUID={r=1,g=.49,b=.04},
    DEATHKNIGHT={r=.77,g=.12,b=.23},
}
_G.GetLocale = function() return "zhCN" end
_G.UnitGUID = function() return "Player-0000-" .. (M.state.playerName) end
_G.GetRealmName = function() return M.state.realm end
_G.GetNormalizedRealmName = function() return (M.state.realm:gsub("%s", "")) end

-- 通讯 API（桩：记录发出的 addon message）
M.sent = {}
_G.C_ChatInfo = {
    SendAddonMessage = function(prefix, msg, chan, target)
        table.insert(M.sent, { prefix = prefix, msg = msg, chan = chan, target = target }); return true
    end,
    RegisterAddonMessagePrefix = function() return true end,
}
_G.SendAddonMessage = function(prefix, msg, chan, target)
    table.insert(M.sent, { prefix = prefix, msg = msg, chan = chan, target = target }); return true
end
_G.SendChatMessage = function(msg, chan) table.insert(M.sent, { chat = msg, chan = chan }) end
_G.ChatThrottleLib = {
    SendAddonMessage = function(_, _, prefix, msg, chan, target)
        table.insert(M.sent, { prefix = prefix, msg = msg, chan = chan, target = target })
    end,
}

-- 弹窗/菜单
_G.StaticPopupDialogs = {}
_G.StaticPopup_Show = function(which)
    local d = _G.StaticPopupDialogs[which]
    if not d then return nil end
    -- 复刻 WLK 3.3.5 StaticPopup.lua:289 的约束：OnCancel 与 OnButton2 不可并存
    -- （真机会 assert 报错；桩里也查，让这类弹窗 bug 离线就能抓到）。
    if d.OnCancel and d.OnButton2 then
        error("Dialog " .. tostring(which) .. " cannot have both OnCancel and OnButton2")
    end
    return M.newRegion(nil, nil, "Frame")
end
_G.StaticPopup_Hide = function() end
_G.UIDropDownMenu_Initialize = function() end
_G.UIDropDownMenu_AddButton = function() end
_G.UIDropDownMenu_CreateInfo = function() return {} end
_G.ToggleDropDownMenu = function() end
_G.CloseDropDownMenus = function() end
_G.EasyMenu = function() end
_G.PlaySound = function() end
_G.PlaySoundFile = function() end
_G.GameTooltip = M.newRegion("GameTooltip", nil, "GameTooltip")
_G.GameTooltip.SetOwner = function() end; _G.GameTooltip.AddLine = function() end
_G.GameTooltip.ClearLines = function() end; _G.GameTooltip.SetText = function() end

-- Item/物品 API（结算/战利品可能用）
_G.GetItemInfo = function(link) return "测试物品", link or "item:1", 4, 80, 80, "护甲", "板甲", 1, "INVTYPE_CHEST", "Interface\\Icons\\INV_Chest_Plate01" end
_G.GetItemQualityColor = function(q) return 0.64, 0.21, 0.93, "|cffa335ee" end
_G.ITEM_QUALITY_COLORS = setmetatable({}, { __index = function() return { r=1, g=1, b=1, hex="|cffffffff" } end })

-- 字体常量
_G.STANDARD_TEXT_FONT = "Fonts\\ARKai_T.ttf"
_G.ChatFontNormal = M.newRegion(nil, nil, "Font")
_G.GameFontNormal = M.newRegion(nil, nil, "Font")
_G.NORMAL_FONT_COLOR = { r = 1, g = .82, b = 0 }
_G.UISpecialFrames = {}
_G.UIParentLoadAddOn = function() end
_G.IsAddOnLoaded = function() return true end
_G.InCombatLockdown = function() return false end
_G.GetAddOnMetadata = function() return nil end
_G.date = os.date; _G.time = os.time

return M
