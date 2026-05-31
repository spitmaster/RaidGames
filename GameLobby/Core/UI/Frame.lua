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

-- 窗体尺寸：原 760×560 装不下设计稿内容（LootCard+10 人 2 行+6 游戏 2 行+操作+日志 ≈ 600px）。
-- 提到 880×700 才能让 5 列布局舒展开（参赛者 5 列 / 游戏 tile 5 列 / 设计稿同款），含 10px 缓冲。
local FRAME_W = 880
local FRAME_H = 700
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

    -- 页面底色：纯 panel 底。
    -- 设计稿是整屏 radial-gradient（中心稍亮），WoW 端没有真·径向渐变背景；
    -- 之前用 gradientCircle 圆纹理在矩形窗体里铺，渲染成一个居中的椭圆光斑（"莫名其妙的椭圆"），
    -- 既不像渐变也碍眼，干脆去掉，纯底色更干净。
    W.PanelBG(f, "panel")

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

    -- 左上「分享游戏」按钮（贴徽章右侧）：插件↔插件传播小游戏（D19）。
    -- 点击弹出可分享游戏列表 → 选一个 → 导出 !GL: 串供 Ctrl+C 发给朋友（对方大厅「导入游戏」框粘入）。
    -- 即时直推走另一条：右键参赛者卡 → 推送游戏（GL.Push）。
    local shareBtn = CreateFrame("Button", nil, title)
    shareBtn:SetSize(78, 22)
    shareBtn:SetPoint("LEFT", badge, "RIGHT", 8, 0)
    W.PanelBG(shareBtn, "panel2"); W.MetalBorder(shareBtn, "thin")
    local shareFs = W.Text(shareBtn, "display", theme.font.btnSm, "textDim")
    shareFs:SetPoint("CENTER")
    shareFs:SetText("|TInterface\\ChatFrame\\UI-ChatIcon-Share:0|t 分享游戏")
    shareBtn._fs = shareFs
    shareBtn:SetScript("OnEnter", function(s)
        s._fs:SetTextColor(theme:RGB("accent"))
        for _, ring in ipairs(s._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("accent")) end
        end
    end)
    shareBtn:SetScript("OnLeave", function(s)
        s._fs:SetTextColor(theme:RGB("textDim"))
        for _, ring in ipairs(s._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameDark")) end
        end
    end)
    shareBtn:SetScript("OnClick", function(s)
        if not (GL.Games and GL.Games.List and EasyMenu) then
            if GL.UI.Log then GL.UI:Log("warn", "游戏列表尚未就绪") end
            return
        end
        local menu = { { text = "分享游戏字符串", isTitle = true, notCheckable = true } }
        local any = false
        local ok, list = pcall(function() return GL.Games:List() end)
        for _, def in ipairs((ok and list) or {}) do
            if not def.locked and type(def.code) == "string" and def.code ~= "" then
                any = true
                local id, name = def.id, def.name or def.id
                menu[#menu + 1] = {
                    text = name, notCheckable = true,
                    func = function()
                        if not (GL.Import and GL.Import.ExportGame) then
                            if GL.UI.Log then GL.UI:Log("warn", "导出模块未就绪") end
                            return
                        end
                        local str, why = GL.Import:ExportGame(id)
                        if type(str) == "string" then
                            GL.UI:ShowExport("分享：" .. name, str)
                        elseif GL.UI.Log then
                            GL.UI:Log("warn", why or "导出失败")
                        end
                    end,
                }
            end
        end
        if not any then
            menu[#menu + 1] = { text = "（暂无可分享的游戏）", notCheckable = true, disabled = true }
        end
        menu[#menu + 1] = { text = "取消", notCheckable = true, func = function() end }
        if not GL.UI._shareDropdown then
            GL.UI._shareDropdown = CreateFrame("Frame", "GameLobbyShareDropdown", UIParent, "UIDropDownMenuTemplate")
        end
        EasyMenu(menu, GL.UI._shareDropdown, s, 0, 0, "MENU")
    end)
    f._shareBtn = shareBtn

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
-- 屏幕图标启动器（仅 WA 版）—— 沙箱注册不进真实 /命令（核心活在 WeakAuras 沙箱、
-- 外面够不着 SlashCmdList），故 isWA 时不注册 slash，改在屏幕上挂一个可点、可拖的小图标，
-- OnClick → GL.UI:Toggle()。图标须加载后即可见（不依赖 /gl）。
-- 遵守项目 UI 规则：矩形元素禁用 GlowHalo（椭圆光斑），边光一律 W.Ring 描边（hover 用边色变化）。
------------------------------------------------------------

local function BuildLauncherIcon()
    if GL.UI._launcher then return GL.UI._launcher end
    local W = GL.UI.Widgets
    if not W then return nil end   -- Widgets 未就绪（极端加载顺序）：放弃，由后续重试

    local ICON_SZ = 36
    local btn = CreateFrame("Button", "GameLobbyLauncher", UIParent)
    btn:SetSize(ICON_SZ, ICON_SZ)
    -- 默认位置：屏幕右侧中部（可拖动，会话内位置不持久——WA 无 SavedVariables，降级可接受）。
    btn:SetPoint("RIGHT", UIParent, "RIGHT", -8, 0)
    btn:SetFrameStrata("MEDIUM")
    btn:SetToplevel(true)
    btn:EnableMouse(true)
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetClampedToScreen(true)

    -- 铁木风底 + thin 金属描边（矩形，遵守"禁 GlowHalo、边光用 Ring"规则）。
    W.PanelBG(btn, "panel2")
    W.MetalBorder(btn, "thin")

    -- 中心 glyph（用核心闪电图标，与极速按键同源视觉；纯 Texture，非 GlowHalo）。
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\Spell_Nature_Lightning")
    icon:SetPoint("CENTER")
    icon:SetSize(ICON_SZ - 10, ICON_SZ - 10)
    btn._icon = icon

    -- hover：边色转 accent（Ring 描边变色，不用任何径向光团）。
    local function setBorder(token)
        for _, ring in ipairs(btn._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB(token)) end
        end
    end
    btn:SetScript("OnEnter", function(s)
        setBorder("accent")
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:AddLine("游戏大厅")
        GameTooltip:AddLine("|cff808080点击开关  ·  拖动移动|r", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        setBorder("frameDark")
        GameTooltip:Hide()
    end)

    -- 拖动：拖完不算点击（用移动标记区分，避免拖动后误 Toggle）。
    btn:SetScript("OnDragStart", function(s) s._moving = true; s:StartMoving() end)
    btn:SetScript("OnDragStop", function(s) s:StopMovingOrSizing(); s._moving = false end)
    btn:SetScript("OnClick", function(s)
        if s._moving then return end
        GL.UI:Toggle()
    end)

    btn:Show()
    GL.UI._launcher = btn
    GL:_RegisterFrame(btn)   -- 热升级让位时被 Hide（与主窗体一致）
    return btn
end

------------------------------------------------------------
-- slash 命令（/gl /gamelobby /游戏大厅）—— 仅插件版。
-- isWA（沙箱）时跳过 slash 注册：沙箱里写 SlashCmdList 无效（外部够不着），
-- 还可能在 flush 期引发报错；改用屏幕图标启动器（见上）。
------------------------------------------------------------

GL:Init(function()
    if GL.isWA then
        -- WA 版：建屏幕图标启动器替代 /gl。
        BuildLauncherIcon()
    else
        -- 插件版：照旧注册 slash（行为不回归，不建图标）。
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
    end

    -- 身份变化时刷新徽章
    GL:On("ROSTER_CHANGED", function() GL.UI:RefreshBadge() end)
end)
