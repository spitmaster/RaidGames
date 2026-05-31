-- Core/UI/Widgets/Castbar.lua —— 计时进度条（24 高，金渐变填充 + 前缘火花 + 左标签 + 右计时）
-- owner: wow-ui-developer
-- 单一职责（SRP）：纯渲染进度条，对外只暴露 :SetProgress / :SetLabel。
-- 实例 API：
--   :SetProgress(pct, leftSec)  pct ∈ [0, 1]；leftSec 是数字则用 "%.1fs" 渲染右侧
--   :SetLabel(text)             设置左侧标签文字

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

function W.Castbar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(24)
    W.PanelBG(bar, "panelInset"); W.MetalBorder(bar, "thin")

    -- 填充（金渐变 accentGlow→accentDeep，从顶向底）
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(W.WHITE)
    fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
    W.SetVGradient(fill, {theme:RGB("accentGlow")}, {theme:RGB("accentDeep")})
    bar._fill = fill

    -- 前缘火花（圆形径向 ADD，跟随 fill 右沿）
    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(W.GLOW); spark:SetBlendMode("ADD")
    spark:SetVertexColor(theme:RGB("accentGlow"))
    spark:SetSize(14, 30)
    bar._spark = spark

    -- 左标签 + 右计时
    local label = W.Text(bar, "display", theme.font.small, "text")
    label:SetPoint("LEFT", bar, "LEFT", 12, 0)
    bar._label = label
    local time = W.Text(bar, "mono", theme.font.mono, "accentGlow")
    time:SetPoint("RIGHT", bar, "RIGHT", -12, 0)
    bar._time = time

    function bar:SetProgress(pct, leftSec)
        pct = math.max(0, math.min(1, pct or 0))
        local w = (self:GetWidth() - 2) * pct
        self._fill:SetWidth(math.max(0.1, w))
        self._spark:ClearAllPoints()
        self._spark:SetPoint("CENTER", self._fill, "RIGHT", 0, 0)
        self._spark:SetShown(pct > 0.001 and pct < 0.999)
        if leftSec then self._time:SetText(string.format("%.1fs", leftSec)) end
    end
    function bar:SetLabel(t) self._label:SetText(t) end
    return bar
end
