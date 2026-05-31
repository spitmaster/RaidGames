-- Core/UI/Widgets/SmashButton.lua —— 狂点钮（圆形 220，实心金属盘 + hover 反馈）
-- owner: wow-ui-developer
-- 单一职责（SRP）：呈现一个一眼可辨"能点"的圆按钮，暴露 :SetPressedLabel / :SetCenterLabel / :SetActive。
-- 计分逻辑由游戏经 api 挂 OnMouseDown（契约 §6 边界），本组件不计数也不发协议。
--
-- 实现说明（"看起来像按钮"是硬指标）：
-- WLK 3.3.5 没 border-radius / SetMask，但有现成的圆形纹理。这里用 UI-Minimap-Background
-- （小地图圆底，核心 UI 必存在）当**实心圆盘底**——它有清晰的圆形边界，是"这是个圆按钮"的关键。
-- 之前纯用 gradientCircle 多层 ADD 叠出的是"模糊光球"，边缘永远渐隐、看不出可点。
-- 盘底之上叠 glow 提亮做金属高光，再加：
--   - hover：整体放大 1.05 + 外发光增强（明确"可交互"信号，原来完全没有 hover 反馈）
--   - 按下：下沉 + 缩小 0.96 + 高光增强

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

local GLOW = W.GLOW
-- 实心金圆贴图（PIL 离线生成，dist/gen_smashball.py）。WoW 矢量画不出硬边渐变圆，靠贴图还原。
-- 路径必须是游戏内路径（部署后 GameLobby 在 Interface\AddOns 下）。
-- 注意：WA 字符串分发形态没有这个文件，会加载失败 → 退回纯 glow 光球（见下方 fallback）。
local BALL = "Interface\\AddOns\\GameLobby\\Media\\smashball.tga"

function W.SmashButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(220, 220)

    -- 外发光晕（圆形，设计 box-shadow: 0 0 40px accent-deep）—— 氛围
    local halo = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    halo:SetTexture(GLOW); halo:SetBlendMode("ADD")
    halo:SetVertexColor(theme:RGB("accentDeep", 1))
    halo:SetSize(300, 300); halo:SetPoint("CENTER"); halo:SetAlpha(0.8)
    b._halo = halo

    -- 实心金圆（贴图）。带 alpha，普通 BLEND，圆外透明。这是"看得出是按钮"的主体。
    local disc = b:CreateTexture(nil, "ARTWORK")
    disc:SetTexture(BALL)
    disc:SetSize(244, 244); disc:SetPoint("CENTER")
    b._disc = disc

    -- fallback：贴图加载失败（如 WA 字符串形态没有 Media 文件）时，退回代码画的金光球，不至于空/绿块。
    -- 3.3.5 SetTexture 对不存在的文件返回 false（GetTexture 也会是 nil）。
    if disc.GetTexture and not disc:GetTexture() then
        disc:SetTexture(GLOW); disc:SetBlendMode("ADD")
        disc:SetVertexColor(theme:RGB("frameBright")); disc:SetSize(210, 210)
        local mid = b:CreateTexture(nil, "ARTWORK", nil, 1)
        mid:SetTexture(GLOW); mid:SetBlendMode("ADD")
        mid:SetVertexColor(theme:RGB("accentGlow")); mid:SetSize(120, 120); mid:SetPoint("CENTER")
        b._discFallback = mid
    end

    -- 按下闪光（圆形 ADD 高光，盖住盘面，常态透明；每次按下 flash 一下，狂点时连续闪烁=明确"在点"）
    local flash = b:CreateTexture(nil, "OVERLAY")
    flash:SetTexture(GLOW); flash:SetBlendMode("ADD")
    flash:SetVertexColor(theme:RGB("accentGlow"))
    flash:SetSize(244, 244); flash:SetPoint("CENTER"); flash:SetAlpha(0)
    b._flash = flash

    -- 中央文案（深色刻在金面上 + 暖色阴影模拟雕刻感）
    local fs = W.Text(b, "display", theme.font.smashText, nil)
    fs:SetTextColor(0.1, 0.05, 0, 1)
    fs:SetShadowColor(1, 0.86, 0.63, 0.7); fs:SetShadowOffset(0, -1)
    fs:SetPoint("CENTER"); fs:SetText("点 击")
    b._fs = fs

    -- 下方按键提示
    local key = W.Text(b, "mono", theme.font.small, "textMute")
    key:SetPoint("TOP", b, "BOTTOM", 0, -10)
    key:SetText("SPACE · CLICK · TAP")
    b._key = key

    -- 盘面亮度微调（贴图模式：vertexcolor 乘算压暗/提亮，给"可点"反馈）。
    -- fallback（ADD glow）模式跳过，否则会把金色染白。
    local function tintDisc(v)
        if b._discFallback then return end
        b._disc:SetVertexColor(v, v, v)
    end
    tintDisc(0.92)   -- 常态略压暗

    -- 按下/松开动效封装成「公开方法」，而不是只挂在 OnMouseDown handler 上。
    -- 原因：游戏（SpeedClick）会用 SetScript("OnMouseDown") 覆盖本按钮的 down handler 来计分；
    -- 若动效只挂在 handler 上，要么被覆盖丢失，要么靠"调用旧 handler"的脆弱链（旧 handler 真机抛错
    -- 会连带中断计分）。封装成 :PlayPress()/:PlayRelease() 后，游戏显式调用，计分与动效彻底解耦。
    function b:PlayPress()
        self._down = true
        self._fs:SetPoint("CENTER", 0, -3)
        self._halo:SetAlpha(1.3); self._flash:SetAlpha(0.55); tintDisc(1)
        self:SetScale(0.93)
    end
    function b:PlayRelease()
        self._down = false
        self._fs:SetPoint("CENTER", 0, 0)
        self._flash:SetAlpha(0)
        local hovered = self:IsMouseOver()
        self._halo:SetAlpha(hovered and 1.0 or 0.8)
        tintDisc(hovered and 1 or 0.92)
        self:SetScale(hovered and 1.05 or 1.0)
    end

    b:SetScript("OnEnter", function(s)
        if not s:IsEnabled() then return end
        s:SetScale(1.05); s._halo:SetAlpha(1.0); tintDisc(1)
    end)
    b:SetScript("OnLeave", function(s)
        if s._down then return end
        s:SetScale(1.0); s._halo:SetAlpha(0.8); tintDisc(0.92)
    end)
    -- 默认 down/up 动效（未被游戏接管时，如倒计时/演示态）。游戏接管 OnMouseDown 后由游戏调 PlayPress。
    b:SetScript("OnMouseDown", function(s) if s:IsEnabled() then s:PlayPress() end end)
    b:SetScript("OnMouseUp",   function(s) s:PlayRelease() end)

    function b:SetPressedLabel(countdownMode)
        self._fs:SetText(countdownMode and "就 位" or "点 击")
    end
    -- 任意中央文案（结算中 / 时间到 等过渡提示）
    function b:SetCenterLabel(t) self._fs:SetText(t) end
    function b:SetActive(on)
        if on then self:Enable(); self:SetAlpha(1)
        else self:Disable(); self:SetAlpha(0.55); self:SetScale(1.0) end
    end
    return b
end
