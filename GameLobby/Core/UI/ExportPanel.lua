-- Core/UI/ExportPanel.lua —— 「导出字符串」弹框（contracts §9：GL.UI:ShowExport(title, str)）
-- owner: wow-ui-developer
-- 展示一个游戏导出后的字符串，只读多行 EditBox，自动全选便于 Ctrl+C 复制发给朋友。
-- 触发链：GameTile 右键 →「导出字符串」→ GL.Import:ExportGame(id) → GL.UI:ShowExport(title, str)。
-- 沿用窗体视觉（铁木主题、金属边框）；不要四角宝石（已全局去除）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme

local PANEL_W = 480
local PANEL_H = 300

------------------------------------------------------------
-- 惰性构建导出面板（作为主窗体上的模态层，结构对齐 ImportPanel）
------------------------------------------------------------

local function BuildExportPanel()
    if GL.UI._exportPanel then return GL.UI._exportPanel end
    local W = GL.UI.Widgets

    -- 父级：主窗体（确保已建）；缺失时挂 UIParent 兜底
    local parent = GL.UI._frame or UIParent

    -- 半透明遮罩（压暗主窗体，聚焦内容）
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
    GL.UI._exportPanel = p
    p._dim = dim
    -- ESC 关闭：由只读 EditBox 的 OnEscapePressed 处理（弹出时 EditBox 自动取焦）。
    -- 不在面板上 EnableKeyboard——WLK 3.3.5 无 SetPropagateKeyboardInput，会吞掉移动键等全部按键。

    -- 标题栏
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
    titleText:SetPoint("RIGHT", titleBar, "RIGHT", -44, 0)
    titleText:SetJustifyH("LEFT")
    titleText:SetText("导  出  游  戏")
    W.GlowText(titleText, "accentDeep")
    p._title = titleText

    -- 关闭 ✕
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -12, 0)
    W.PanelBG(closeBtn, "panel2"); W.MetalBorder(closeBtn, "thin")
    local closeFs = W.Text(closeBtn, "display", 14, "textDim")
    closeFs:SetPoint("CENTER"); closeFs:SetText("×")
    closeBtn:SetScript("OnEnter", function() closeFs:SetTextColor(theme:RGB("danger")) end)
    closeBtn:SetScript("OnLeave", function() closeFs:SetTextColor(theme:RGB("textDim")) end)
    closeBtn:SetScript("OnClick", function() GL.UI:HideExport() end)

    -- 说明文字（复制提示）
    local hint = W.Text(p, "ui", theme.font.body, "textDim")
    hint:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 16, -12)
    hint:SetPoint("RIGHT", p, "RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Ctrl+C 复制，发给朋友粘进他的大厅导入框。")

    -- 只读输入框（多行、凹槽底，已全选便于复制）
    local box = W.Inset(p)
    box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    box:SetPoint("RIGHT", p, "RIGHT", -16, 0)
    box:SetHeight(150)

    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -28, 8)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)          -- 关键：否则抢聊天框键盘焦点
    edit:SetMaxLetters(0)
    edit:SetWidth(PANEL_W - 32 - 36)
    edit:SetFontObject(ChatFontNormal)
    W.SetFont(edit, "mono", theme.font.small, "text")
    edit:SetTextInsets(2, 2, 2, 2)
    -- 只读：任何输入都恢复原文并重新全选（EditBox 无原生只读，靠拦截编辑模拟）
    edit:SetScript("OnEscapePressed", function() GL.UI:HideExport() end)
    edit:SetScript("OnTextChanged", function(s, userInput)
        if userInput and p._str and s:GetText() ~= p._str then
            s:SetText(p._str)
            s:HighlightText()
        end
    end)
    -- 失焦后再点回来自动全选，方便重复复制
    edit:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
    edit:SetScript("OnMouseUp", function(s) s:HighlightText() end)
    scroll:SetScrollChild(edit)
    p._edit = edit

    -- 关闭按钮
    local closeBig = W.Button(p, "关 闭", "primary")
    closeBig:SetPoint("BOTTOM", p, "BOTTOM", 0, 16)
    closeBig:SetScript("OnClick", function() GL.UI:HideExport() end)

    return p
end

------------------------------------------------------------
-- 公开方法：展示 / 关闭导出弹框
------------------------------------------------------------

-- 只读可复制弹框，展示导出的字符串（自动全选便于 Ctrl+C）。
-- title: 弹框标题（如 "导出：极速按键"）；str: 导出字符串。
function GL.UI:ShowExport(title, str)
    self:Show()                 -- 确保主窗体已建（弹框挂其上）
    local p = BuildExportPanel()
    str = tostring(str or "")
    p._str = str
    if title and title ~= "" then p._title:SetText(title) end
    p._dim:Show()
    p:Show()
    p._edit:SetText(str)
    p._edit:SetCursorPosition(0)
    p._edit:SetFocus()          -- AutoFocus 已关，这里手动取焦点便于立即 Ctrl+C
    p._edit:HighlightText()     -- 全选
end

function GL.UI:HideExport()
    local p = self._exportPanel
    if p then
        p._edit:ClearFocus()
        p:Hide()
        p._dim:Hide()
    end
end
