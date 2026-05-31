-- Core/UI/Widgets/StatCard.lua —— 统计卡（顶部细线 + 大数字 + 底标签）
-- owner: wow-ui-developer
-- 单一职责（SRP）：渲染一组 value/label 数据，并按 accent 切配色（text / gold / rare）。
-- 实例 API：
--   :Set(value, label, accent)   accent: "text"(默认) | "gold" | "rare"

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

function W.StatCard(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(110, 64)
    W.PanelBG(c, "panelInset"); W.MetalBorder(c, "thin")

    -- 顶部 1px 渐变细线
    local top = W.Solid(c, "frameMid", 1, "OVERLAY")
    top:SetHeight(1)
    top:SetPoint("TOPLEFT", c, "TOPLEFT", 12, 0)
    top:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, 0)

    local value = W.Text(c, "display", theme.font.statValue, "text")
    value:SetPoint("CENTER", c, "CENTER", 0, 8)
    c._value = value

    local label = W.Text(c, "display", theme.font.tiny, "textMute")
    label:SetPoint("BOTTOM", c, "BOTTOM", 0, 8)
    c._label = label

    function c:Set(value_, label_, accent)
        self._value:SetText(tostring(value_))
        self._label:SetText(label_ or "")
        if accent == "gold" then
            self._value:SetTextColor(theme:RGB("accent")); W.GlowText(self._value, "accentDeep")
        elseif accent == "rare" then
            self._value:SetTextColor(theme:Rarity("rare")); W.GlowText(self._value, "rare")
        else
            self._value:SetTextColor(theme:RGB("text")); self._value:SetShadowColor(0, 0, 0, 0)
        end
    end
    return c
end
