-- Core/UI/Frame.lua —— 全局窗体 AddonFrame + slash 命令 + 屏幕路由（契约 §9，SPEC §4.2）
-- owner: wow-ui-developer
-- 金属多层描边窗体 + 四角菱形宝石 + 56px 标题栏（角色徽章 / 居中标题 / 两侧 flair / 右上 [战史][关于][✕]）。
-- 屏幕路由：addon-body 承载 5 个屏幕容器，ShowScreen 切换。
-- 框架建好后 GL:_RegisterFrame 登记（热升级让位时被 Hide），slash 注册由 UI 做。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
-- 注意：.toc 中 Widgets.lua 在 Frame.lua 之后加载（契约 §10），
-- 因此不能在文件加载期捕获 GL.UI.Widgets（那时还是 nil）。在 BuildFrame 内部惰性取。

-- 窗体尺寸（设计 1040px 偏大，WoW 端缩到 760 保留布局结构与视觉语言，§4.10）
local FRAME_W = 760
local FRAME_H = 560
local TITLE_H = 56

GL.UI._screens = GL.UI._screens or {}   -- name → 屏幕容器 frame
GL.UI._screenInit = GL.UI._screenInit or {}  -- name → 初始化函数（各屏幕文件登记）

------------------------------------------------------------
-- 屏幕登记：各屏幕文件调用 GL.UI:RegisterScreen("lobby", builderFn)
-- builderFn(bodyFrame) → 返回该屏幕的容器 frame（首次 ShowScreen 时惰性构建）
------------------------------------------------------------

function GL.UI:RegisterScreen(name, builderFn)
    self._screenInit[name] = builderFn
end

------------------------------------------------------------
-- 构建主窗体
------------------------------------------------------------

local function BuildFrame()
    if GL.UI._frame then return GL.UI._frame end
    local W = GL.UI.Widgets   -- 惰性取（此时 Widgets.lua 已加载）

    local f = CreateFrame("Frame", "GameLobbyFrame", UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()

    -- 页面底色（径向暗色感：panel 底 + 中心稍亮）
    W.PanelBG(f, "panel")
    local centerGlow = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    centerGlow:SetTexture("Interface\\GLUES\\MODELS\\UI_Tauren\\gradientCircle")
    centerGlow:SetVertexColor(theme:RGB("bgPage2", 0.5))
    centerGlow:SetSize(FRAME_W * 0.8, FRAME_H * 0.6)
    centerGlow:SetPoint("CENTER", f, "CENTER", 0, 60)

    -- 金属多层描边（四角装饰已去除）
    W.MetalBorder(f, "frame")

    ----------------------------------------------------------------
    -- 标题栏
    ----------------------------------------------------------------
    local title = CreateFrame("Frame", nil, f)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    title:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    local tbg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    tbg:SetTexture(W.WHITE); tbg:SetAllPoints(title)
    W.SetVGradient(tbg, {theme:RGB("panel2")}, {theme:RGB("panel")})
    -- 底分隔金线
    local tline = W.Solid(title, "frameBright", 0.6, "ARTWORK")
    tline:SetHeight(1)
    tline:SetPoint("BOTTOMLEFT", title, "BOTTOMLEFT", 0, 0)
    tline:SetPoint("BOTTOMRIGHT", title, "BOTTOMRIGHT", 0, 0)
    W.SetVGradient(tline, {theme:RGB("frameBright", 0)}, {theme:RGB("frameBright", 0.6)})

    -- 居中标题 + 副标题
    local titleText = W.Text(title, "display", theme.font.titleText, "accent")
    titleText:SetPoint("CENTER", title, "CENTER", 0, 6)
    titleText:SetText("游  戏  大  厅")    -- 字距感：插全角空格（§4.10）
    W.GlowText(titleText, "accentDeep")
    local titleSub = W.Text(title, "ui", theme.font.titleSub, "textMute")
    titleSub:SetPoint("TOP", titleText, "BOTTOM", 0, -2)
    titleSub:SetText("GAME · HALL · v" .. (GL.version or "0.1"))

    -- 两侧 flair 横线 + ◆
    local function flair(anchorPoint, ox)
        local line = W.Solid(title, "frameBright", 0.8, "ARTWORK")
        line:SetSize(70, 1)
        line:SetPoint(anchorPoint, title, anchorPoint, ox, 4)
        W.SetVGradient(line, {theme:RGB("frameBright", 0)}, {theme:RGB("frameBright", 0.8)})
        local dia = W.Text(title, "display", 8, "frameBright")
        dia:SetText("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:10:10|t")
        dia:SetPoint("CENTER", line, "CENTER", 0, 4)
    end
    flair("LEFT", 64)
    flair("RIGHT", -140)

    -- 左上角色徽章（★ 团长 / 团员）
    local badge = CreateFrame("Frame", nil, title)
    badge:SetSize(56, 20)
    badge:SetPoint("LEFT", title, "LEFT", 14, 0)
    W.PanelBG(badge, "panelInset"); W.MetalBorder(badge, "thin")
    local badgeText = W.Text(badge, "display", theme.font.tiny, "textMute")
    badgeText:SetPoint("CENTER")
    badgeText:SetText("团员")
    f._badge = badge
    f._badgeText = badgeText

    ----------------------------------------------------------------
    -- 标题栏右上按钮：[战史][关于][✕]
    ----------------------------------------------------------------
    local function titleAction(text, ox)
        local b = CreateFrame("Button", nil, title)
        b:SetSize(48, 24)
        b:SetPoint("RIGHT", title, "RIGHT", ox, 0)
        W.PanelBG(b, "panel2"); W.MetalBorder(b, "thin")
        local fs = W.Text(b, "display", theme.font.btnSm, "textDim")
        fs:SetPoint("CENTER"); fs:SetText(text)
        b._fs = fs
        b:SetScript("OnEnter", function(s) s._fs:SetTextColor(theme:RGB("accent")) end)
        b:SetScript("OnLeave", function(s)
            s._fs:SetTextColor(theme:RGB(s._active and "accentGlow" or "textDim"))
        end)
        function b:SetActive(on)
            self._active = on
            self._fs:SetTextColor(theme:RGB(on and "accentGlow" or "textDim"))
            for _, ring in ipairs(self._borders or {}) do
                for _, e in pairs(ring) do e:SetVertexColor(theme:RGB(on and "accent" or "frameDark")) end
            end
        end
        return b
    end

    local closeBtn = CreateFrame("Button", nil, title)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", title, "RIGHT", -14, 0)
    W.PanelBG(closeBtn, "panel2"); W.MetalBorder(closeBtn, "thin")
    local closeFs = W.Text(closeBtn, "display", 14, "textDim")
    closeFs:SetPoint("CENTER"); closeFs:SetText("×")
    closeBtn:SetScript("OnEnter", function() closeFs:SetTextColor(theme:RGB("danger")) end)
    closeBtn:SetScript("OnLeave", function() closeFs:SetTextColor(theme:RGB("textDim")) end)
    closeBtn:SetScript("OnClick", function() GL.UI:Hide() end)

    local aboutBtn = titleAction("关 于", -44)
    local histBtn  = titleAction("战 史", -96)
    histBtn:SetScript("OnClick", function() GL.UI:ToggleScreen("history") end)
    aboutBtn:SetScript("OnClick", function() GL.UI:ToggleScreen("about") end)
    f._histBtn = histBtn
    f._aboutBtn = aboutBtn

    ----------------------------------------------------------------
    -- 内容区 addon-body（承载 5 个屏幕）
    ----------------------------------------------------------------
    local body = CreateFrame("Frame", nil, f)
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 22, -16)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 18)
    f._body = body
    GL.UI._body = body

    GL.UI._frame = f
    GL:_RegisterFrame(f)   -- 热升级登记（让位时被 Hide）

    -- 上一屏（战史/关于 切换返回用）
    GL.UI._lastGameScreen = "lobby"
    return f
end

------------------------------------------------------------
-- 屏幕路由
------------------------------------------------------------

-- 惰性构建并返回指定屏幕容器
local function ensureScreen(name)
    if GL.UI._screens[name] then return GL.UI._screens[name] end
    local builder = GL.UI._screenInit[name]
    if not builder then return nil end
    local screen = builder(GL.UI._body)
    GL.UI._screens[name] = screen
    return screen
end

function GL.UI:ShowScreen(name)
    BuildFrame()
    -- 隐藏全部，显示目标
    for n, s in pairs(self._screens) do
        if s then s:Hide() end
    end
    local screen = ensureScreen(name)
    if screen then
        screen:ClearAllPoints()
        screen:SetAllPoints(self._body)
        screen:Show()
        if screen._onShow then screen._onShow() end
    end
    self._current = name
    -- 标题栏按钮高亮（战史/关于）
    if self._frame then
        self._frame._histBtn:SetActive(name == "history")
        self._frame._aboutBtn:SetActive(name == "about")
    end
    -- 记录最近的「游戏流程屏」（非 history/about），供 ToggleScreen 返回
    if name ~= "history" and name ~= "about" then
        self._lastGameScreen = name
    end
end

-- 战史/关于：再点一次返回上一个游戏屏
function GL.UI:ToggleScreen(name)
    if self._current == name then
        self:ShowScreen(self._lastGameScreen or "lobby")
    else
        self:ShowScreen(name)
    end
end

------------------------------------------------------------
-- 显示 / 隐藏 / 开关
------------------------------------------------------------

function GL.UI:Show()
    BuildFrame()
    self:RefreshBadge()
    if not self._current then self:ShowScreen("lobby") end
    self._frame:Show()
end

function GL.UI:Hide()
    if self._frame then self._frame:Hide() end
end

function GL.UI:Toggle()
    BuildFrame()
    if self._frame:IsShown() then self:Hide() else self:Show() end
end

-- 刷新左上角色徽章（团长金 ★ / 团员灰）
function GL.UI:RefreshBadge()
    if not self._frame then return end
    local isLeader = false
    if GL.Roster and GL.Roster.IsLeader then
        local ok, res = pcall(function() return GL.Roster:IsLeader() end)
        if ok then isLeader = res end
    end
    if isLeader then
        self._frame._badgeText:SetText("|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t 团长")
        self._frame._badgeText:SetTextColor(theme:RGB("accent"))
    else
        self._frame._badgeText:SetText("团员")
        self._frame._badgeText:SetTextColor(theme:RGB("textMute"))
    end
end

------------------------------------------------------------
-- slash 命令（/gl /gamelobby /游戏大厅）
------------------------------------------------------------

GL:Init(function()
    SLASH_GAMELOBBY1 = "/gl"
    SLASH_GAMELOBBY2 = "/gamelobby"
    SLASH_GAMELOBBY3 = "/游戏大厅"
    SlashCmdList["GAMELOBBY"] = function(msg)
        msg = (msg or ""):lower():gsub("%s", "")
        if msg == "history" or msg == "战史" then
            GL.UI:Show(); GL.UI:ShowScreen("history")
        elseif msg == "about" or msg == "关于" then
            GL.UI:Show(); GL.UI:ShowScreen("about")
        else
            GL.UI:Toggle()
        end
    end

    -- 身份变化时刷新徽章
    GL:On("ROSTER_CHANGED", function() GL.UI:RefreshBadge() end)
end)
