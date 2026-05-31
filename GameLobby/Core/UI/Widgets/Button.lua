-- Core/UI/Widgets/Button.lua —— 通用按钮（default / primary，sm / md / lg 三档）
-- owner: wow-ui-developer
-- 单一职责（SRP）：按钮的视觉与交互（hover/disabled），不含业务回调（业务由调用方 SetScript("OnClick", ...)）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

local WHITE = W.WHITE

-- variant: "default" | "primary"；sizeKind: "sm" | nil(md) | "lg"
function W.Button(parent, text, variant, sizeKind)
    local b = CreateFrame("Button", nil, parent)
    variant = variant or "default"
    local padH  = (sizeKind == "lg") and 36 or (sizeKind == "sm") and 14 or 22
    local fsize = (sizeKind == "lg") and theme.font.btnLg
               or (sizeKind == "sm") and theme.font.btnSm
               or theme.font.btn
    b:SetHeight((sizeKind == "lg") and 42 or (sizeKind == "sm") and 24 or 34)

    -- 底（渐变）：primary = 金渐变；default = 暗渐变
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE); bg:SetAllPoints(b)
    if variant == "primary" then
        W.SetVGradient(bg, {theme:RGB("frameBright")}, {theme:RGB("accentDeep")})
    else
        W.SetVGradient(bg, {theme:RGB("panel2", 1)}, {theme:RGB("frameDark", 1)})
    end
    b._bg = bg
    W.MetalBorder(b, "thin")

    -- 内顶 1px 高光
    local hl = W.Solid(b, "accentGlow", variant == "primary" and 0.5 or 0.15, "ARTWORK")
    hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    hl:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -1)
    hl:SetHeight(1)

    -- 文字（primary 用深色刻在金底；default 用 text 色）
    local fs = W.Text(b, "display", fsize, variant == "primary" and nil or "text")
    if variant == "primary" then fs:SetTextColor(0.1, 0.05, 0, 1) end
    fs:SetPoint("CENTER"); fs:SetText(text or "")
    b._fs = fs; b._variant = variant
    b:SetWidth(math.max(fs:GetStringWidth() + padH * 2, sizeKind == "sm" and 56 or 90))

    -- hover 边缘高光：沿四边走的 2 层染色描边（外层淡、内层实，模拟向外渐淡的边光）。
    -- 不用 GlowHalo —— 径向圆纹理铺在矩形按钮上会渲染成中间一个椭圆光斑（不是沿边光）。
    -- 这是真"按钮四周一圈亮"，与 GameTile 选中态用的是同一套 W.Ring 方案。
    local glowToken = (variant == "primary") and "accentGlow" or "frameBright"
    local edgeIn  = W.Ring(b, 1, glowToken, 0, "OVERLAY")   -- 紧贴边，实
    local edgeOut = W.Ring(b, 2, glowToken, 0, "OVERLAY")   -- 外一圈，淡（渐隐过渡）
    b._edgeIn, b._edgeOut = edgeIn, edgeOut
    local function setEdge(on)
        for _, e in pairs(edgeIn)  do e:SetAlpha(on and 0.9  or 0) end
        for _, e in pairs(edgeOut) do e:SetAlpha(on and 0.4  or 0) end
    end
    b._setEdge = setEdge

    b:SetScript("OnEnter", function(s)
        if not s:IsEnabled() then return end
        s._setEdge(true)
        if s._variant ~= "primary" then s._fs:SetTextColor(theme:RGB("accentGlow")) end
        for _, ring in ipairs(s._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameBright")) end
        end
    end)
    b:SetScript("OnLeave", function(s)
        s._setEdge(false)
        if s._variant ~= "primary" then s._fs:SetTextColor(theme:RGB("text")) end
        for _, ring in ipairs(s._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameDark")) end
        end
    end)
    b:SetScript("OnMouseDown", function(s) if s:IsEnabled() then s._fs:SetPoint("CENTER", 0, -1) end end)
    b:SetScript("OnMouseUp",   function(s) s._fs:SetPoint("CENTER", 0, 0) end)

    -- 实例方法（OO 风格）：可达性 / 文案
    function b:SetEnabledLook(on)
        if on then
            self:Enable(); self:SetAlpha(1)
        else
            self:Disable(); self:SetAlpha(0.4); self._setEdge(false)
        end
    end
    function b:SetLabel(t)
        self._fs:SetText(t)
        self:SetWidth(math.max(self._fs:GetStringWidth() + padH * 2, sizeKind == "sm" and 56 or 90))
    end
    return b
end
