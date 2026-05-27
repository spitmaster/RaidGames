-- Core/UI/ImportPanel.lua —— 「导入游戏字符串」面板（功能 9 / 决策 D14，SPEC §4.8 / contracts §8）
-- owner: wow-ui-developer
-- 纯插件用户装游戏的入口：弹一个带多行 EditBox 的面板，粘贴 WA/自控串 → [导入] 调 GL.Import:ImportGame。
-- 即时校验用 GL.Import:LooksImportable 决定 [导入] 可用态；信任门由 ImportGame 内部自动弹（本面板不再弹确认）。
-- 全部对 GL.Import 做防御（if GL.Import then ...）。沿用窗体视觉/铁木令牌。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme

local PANEL_W = 460
local PANEL_H = 320

------------------------------------------------------------
-- 惰性构建导入面板（作为主窗体上的模态层）
------------------------------------------------------------

local function BuildImportPanel()
    if GL.UI._importPanel then return GL.UI._importPanel end
    local W = GL.UI.Widgets

    -- 父级：主窗体（确保已建）；缺失时挂 UIParent 兜底
    local parent = GL.UI._frame or UIParent

    -- 半透明遮罩（点击空白不关，仅压暗主窗体，聚焦输入）
    local dim = CreateFrame("Frame", nil, parent)
    dim:SetAllPoints(parent)
    dim:SetFrameStrata("DIALOG")
    dim:EnableMouse(true)
    local dimBG = W.Solid(dim, "panelInset", 0.6, "BACKGROUND", -1)
    dimBG:SetAllPoints(dim)
    dim:Hide()

    -- 面板本体
    local p = CreateFrame("Frame", nil, dim)
    p:SetSize(PANEL_W, PANEL_H)
    p:SetPoint("CENTER", dim, "CENTER", 0, 0)
    W.PanelBG(p, "panel")
    W.MetalBorder(p, "frame")
    GL.UI._importPanel = p
    p._dim = dim

    -- 标题
    local titleBar = CreateFrame("Frame", nil, p)
    titleBar:SetHeight(40)
    titleBar:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    local tbg = W.Solid(titleBar, "panel2", 1, "BACKGROUND", 1)
    tbg:SetAllPoints(titleBar)
    local tline = W.Solid(titleBar, "frameBright", 0.6, "ARTWORK")
    tline:SetHeight(1)
    tline:SetPoint("BOTTOMLEFT"); tline:SetPoint("BOTTOMRIGHT")
    W.SetVGradient(tline, {theme:RGB("frameBright", 0)}, {theme:RGB("frameBright", 0.6)})
    local titleText = W.Text(titleBar, "display", theme.font.titleText - 4, "accent")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 16, 0)
    titleText:SetText("导  入  游  戏")
    W.GlowText(titleText, "accentDeep")

    -- 关闭 ✕
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -12, 0)
    W.PanelBG(closeBtn, "panel2"); W.MetalBorder(closeBtn, "thin")
    local closeFs = W.Text(closeBtn, "display", 14, "textDim")
    closeFs:SetPoint("CENTER"); closeFs:SetText("×")
    closeBtn:SetScript("OnEnter", function() closeFs:SetTextColor(theme:RGB("danger")) end)
    closeBtn:SetScript("OnLeave", function() closeFs:SetTextColor(theme:RGB("textDim")) end)
    closeBtn:SetScript("OnClick", function() GL.UI:HideImport() end)

    -- 说明文字
    local hint = W.Text(p, "ui", theme.font.body, "textDim")
    hint:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 16, -12)
    hint:SetPoint("RIGHT", p, "RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("粘贴游戏字符串（WeakAuras / 自控串），点 [导入] 即可装入新游戏，无需 /reload。")

    -- 输入框（多行，凹槽底）
    local box = W.Inset(p)
    box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    box:SetPoint("RIGHT", p, "RIGHT", -16, 0)
    box:SetHeight(150)

    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -28, 8)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetWidth(PANEL_W - 32 - 36)
    edit:SetFontObject(ChatFontNormal)
    W.SetFont(edit, "mono", theme.font.small, "text")
    edit:SetTextInsets(2, 2, 2, 2)
    edit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    scroll:SetScrollChild(edit)
    p._edit = edit

    -- 状态文字（即时校验反馈）
    local statusFs = W.Text(p, "mono", theme.font.small, "textMute")
    statusFs:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -10)
    statusFs:SetPoint("RIGHT", p, "RIGHT", -16, 0)
    statusFs:SetJustifyH("LEFT")
    p._status = statusFs

    -- 按钮行
    local cancelBtn = W.Button(p, "取 消", "default")
    cancelBtn:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 16, 16)
    cancelBtn:SetScript("OnClick", function() GL.UI:HideImport() end)

    local importBtn = W.Button(p, "导 入", "primary", "lg")
    importBtn:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -16, 16)
    p._importBtn = importBtn

    -- 即时校验：输入变化 → LooksImportable 决定 [导入] 可用态
    local function refreshValid()
        local str = edit:GetText() or ""
        local trimmed = str:gsub("%s", "")
        if trimmed == "" then
            importBtn:SetEnabledLook(false)
            statusFs:SetText("")
            return
        end
        local looks = false
        if GL.Import and GL.Import.LooksImportable then
            local ok, r = pcall(function() return GL.Import:LooksImportable(str) end)
            if ok then looks = r and true or false end
        else
            -- Import 模块未就绪：保守允许尝试（ImportGame 会再校验），但提示
            looks = true
        end
        importBtn:SetEnabledLook(looks)
        if not GL.Import then
            statusFs:SetText("导入模块尚未就绪")
            statusFs:SetTextColor(theme:RGB("textMute"))
        elseif looks then
            statusFs:SetText(W.ICON.ready .. " 看起来是有效的游戏字符串")
            statusFs:SetTextColor(theme:RGB("success"))
        else
            statusFs:SetText("无法识别的字符串（应以 !WA: 或 !GL: 开头）")
            statusFs:SetTextColor(theme:RGB("textMute"))
        end
    end
    edit:SetScript("OnTextChanged", refreshValid)
    p._refreshValid = refreshValid

    importBtn:SetScript("OnClick", function(b)
        if not b:IsEnabled() then return end
        local str = edit:GetText() or ""
        if str:gsub("%s", "") == "" then return end
        if not (GL.Import and GL.Import.ImportGame) then
            statusFs:SetText("导入模块尚未就绪，无法导入")
            statusFs:SetTextColor(theme:RGB("danger"))
            return
        end
        statusFs:SetText("正在导入…")
        statusFs:SetTextColor(theme:RGB("textDim"))
        b:SetEnabledLook(false)
        -- 信任门由 ImportGame 内部自动弹（GL.UI:ConfirmTrust），本面板不再弹确认
        local ok, err = pcall(function()
            GL.Import:ImportGame(str, function(success, msg)
                if not p:IsShown() then
                    -- 面板已关：反馈走 LOG（GL.Import 内部也会 Emit LOG）
                    return
                end
                if success then
                    statusFs:SetText(W.ICON.ready .. " " .. (msg or "导入成功"))
                    statusFs:SetTextColor(theme:RGB("success"))
                    edit:SetText("")
                    -- 成功后短暂展示再关闭
                    C_Timer.After(1.2, function() if p:IsShown() then GL.UI:HideImport() end end)
                else
                    statusFs:SetText("× " .. (msg or "导入失败"))
                    statusFs:SetTextColor(theme:RGB("danger"))
                    refreshValid()
                end
            end)
        end)
        if not ok then
            statusFs:SetText("× 导入出错：" .. tostring(err))
            statusFs:SetTextColor(theme:RGB("danger"))
            refreshValid()
        end
    end)

    return p
end

------------------------------------------------------------
-- 公开方法：打开 / 关闭导入面板（供 Lobby 入口按钮调用）
------------------------------------------------------------

function GL.UI:ShowImport()
    self:Show()             -- 确保主窗体已建（导入面板挂其上）
    local p = BuildImportPanel()
    p._dim:Show()
    p:Show()
    p._edit:SetText("")
    if p._refreshValid then p._refreshValid() end
    p._edit:SetFocus()
end

function GL.UI:HideImport()
    local p = self._importPanel
    if p then
        p._edit:ClearFocus()
        p:Hide()
        p._dim:Hide()
    end
end
