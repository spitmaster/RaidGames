-- Core/UI/About.lua —— 关于面板 About（SPEC §4.7b，功能 10）
-- owner: wow-ui-developer
-- 插件名 + 版本号 + 作者；联系方式只读可复制 EditBox（可 Ctrl+C）；可选赞助区。
-- WA 限制：二维码贴图不随 WA 字符串传输 → 赞助区 WA 版用链接文字（GL.isWA 判别），插件版可用 Media 贴图。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = GL.UI.Widgets

-- 联系方式（作者填入）
local CONTACTS = {
    "微信：SuperLazyDog",
    "邮箱：zyjzyj2@126.com",
    "B 站：https://space.bilibili.com/19231724",
}
local AUTHOR = "zyj"
-- 赞助：插件版可放收款码贴图路径；WA 版用文字链接
local SPONSOR_LINK = "afdian.net/a/gamelobby"   -- 收款链接文字（可复制）

-- 只读可复制 EditBox 行
local function readonlyLine(parent, text)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetHeight(24)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    W.SetFont(eb, "mono", theme.font.body, "text")
    local bg = W.Solid(eb, "panel2", 1, "BACKGROUND", -1)
    bg:SetAllPoints(eb)
    W.MetalBorder(eb, "thin")
    eb:SetTextInsets(10, 10, 0, 0)
    eb:SetText(text or "")
    eb:SetCursorPosition(0)
    -- 只读：禁止编辑但允许选择/复制（Ctrl+C）
    eb:SetScript("OnTextChanged", function(s) s:SetText(text); s:SetCursorPosition(0) end)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    eb:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
    eb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    return eb
end

local function Build(body)
    local s = CreateFrame("Frame", nil, body)

    -- 返回大厅按钮（左上角）：让用户一眼就知道怎么回首页
    local backBtn = W.Button(s, "返回大厅", "default", "sm")
    backBtn:SetPoint("TOPLEFT", s, "TOPLEFT", 0, -2)
    backBtn:SetScript("OnClick", function() GL.UI:ShowScreen(GL.UI._lastGameScreen or "lobby") end)

    -- 标题
    local title = W.Text(s, "display", 18, "accent")
    title:SetPoint("TOP", s, "TOP", 0, -4)
    title:SetText("关  于  ·  About")
    W.GlowText(title, "accentDeep")

    -- 插件名 + 版本 + 作者
    local nameFs = W.Text(s, "display", theme.font.statValue, "accentGlow")
    nameFs:SetPoint("TOP", title, "BOTTOM", 0, -18)
    nameFs:SetText("游 戏 大 厅 · GameLobby")
    W.GlowText(nameFs, "accentDeep")
    local verFs = W.Text(s, "mono", theme.font.body, "textDim")
    verFs:SetPoint("TOP", nameFs, "BOTTOM", 0, -8)
    verFs:SetText(string.format("v%s%s   ·   作者 %s",
        GL.version or "0.1.0", GL.isWA and "  (WeakAuras 版)" or "", AUTHOR))

    -- 联系方式区
    local contactLabel = W.SectionLabel(s, "联系作者 · 反馈 BUG")
    contactLabel:SetPoint("TOPLEFT", s, "TOPLEFT", 40, -130)
    contactLabel:SetPoint("RIGHT", s, "RIGHT", -40, 0)

    local prev = contactLabel
    for _, line in ipairs(CONTACTS) do
        local eb = readonlyLine(s, line)
        eb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, prev == contactLabel and -4 or -6)
        eb:SetPoint("RIGHT", s, "RIGHT", -40, 0)
        prev = eb
    end
    local tip = W.Text(s, "ui", theme.font.tiny, "textMute")
    tip:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 2, -6)
    tip:SetText("点击选中后可 Ctrl+C 复制")

    -- 征集小游戏：欢迎联系作者提想法，会持续更新添加
    local invite = W.Text(s, "ui", theme.font.body, "accent")
    invite:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", -2, -14)
    invite:SetPoint("RIGHT", s, "RIGHT", -40, 0)
    invite:SetJustifyH("LEFT")
    invite:SetText("想玩什么小游戏？有好点子欢迎联系作者 —— 会持续更新、不断添加新游戏！")

    -- 赞助区（可选）
    local sponsorLabel = W.SectionLabel(s, "赞助 · SPONSOR")
    sponsorLabel:SetPoint("TOPLEFT", invite, "BOTTOMLEFT", -2, -16)
    sponsorLabel:SetPoint("RIGHT", s, "RIGHT", -40, 0)

    if GL.isWA then
        -- WA 版：二维码贴图不随字符串走 → 用可复制链接文字
        local linkEb = readonlyLine(s, SPONSOR_LINK)
        linkEb:SetPoint("TOPLEFT", sponsorLabel, "BOTTOMLEFT", 0, -4)
        linkEb:SetPoint("RIGHT", s, "RIGHT", -40, 0)
        local note = W.Text(s, "ui", theme.font.tiny, "textMute")
        note:SetPoint("TOPLEFT", linkEb, "BOTTOMLEFT", 2, -6)
        note:SetText("WA 版不含二维码图片，复制以上链接打开收款页")
    else
        -- 插件版：可放收款码贴图（Media/sponsor_qr.tga）。文件缺失时优雅降级为链接文字。
        local qr = s:CreateTexture(nil, "ARTWORK")
        qr:SetSize(120, 120)
        qr:SetPoint("TOPLEFT", sponsorLabel, "BOTTOMLEFT", 0, -8)
        qr:SetTexture("Interface\\AddOns\\GameLobby\\Media\\sponsor_qr")
        local qrFrame = CreateFrame("Frame", nil, s)
        qrFrame:SetSize(124, 124); qrFrame:SetPoint("CENTER", qr, "CENTER")
        W.MetalBorder(qrFrame, "thin")
        local linkEb = readonlyLine(s, SPONSOR_LINK)
        linkEb:SetPoint("LEFT", qr, "RIGHT", 16, 0)
        linkEb:SetWidth(220)
        local note = W.Text(s, "ui", theme.font.tiny, "textMute")
        note:SetPoint("TOPLEFT", linkEb, "BOTTOMLEFT", 2, -6)
        note:SetText("扫码或复制链接赞助 · 感谢支持")
    end

    return s
end

GL.UI:RegisterScreen("about", Build)
