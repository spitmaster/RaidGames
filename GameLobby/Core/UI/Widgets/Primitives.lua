-- Core/UI/Widgets/Primitives.lua —— 视觉原语 + 字体辅助 + 图标
-- owner: wow-ui-developer
--
-- 职责（SRP）：纯渲染底层抽象。
--   - 字体：SetFont / Text / GlowText
--   - 图标：ICON 表 / GlyphMarkup / GlyphTexture
--   - 纯色块 / 垂直渐变：Solid / SetVGradient
--   - 框面：PanelBG / Ring / MetalBorder / Inset
--   - 装饰：CornerGem / FourCornerGems / GlowHalo
--
-- 设计原则（SOLID）：
--   - SRP：只做"画"这一件事，不含组件级业务（数据绑定、状态机）
--   - DIP：所有上层组件（Button/Card/Tile/…）依赖此处的抽象函数，不重复实现纹理细节
--   - OCP：新组件只用本文件 API，不改本文件；本文件若加新原语也不破坏既有组件
--
-- 加载位序：在 Theme.lua 之后、其他 Widgets/*.lua 之前（其他组件依赖 GL.UI.Widgets 命名空间）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = {}
GL.UI.Widgets = W

------------------------------------------------------------
-- 暴雪自带可复用贴图
------------------------------------------------------------
local WHITE = "Interface\\Buttons\\WHITE8X8"                       -- 纯白方块，染色即得任意纯色块
local GLOW  = "Interface\\GLUES\\MODELS\\UI_Tauren\\gradientCircle" -- 圆形径向发光（按钮/宝石/halo 用）

W.WHITE = WHITE
W.GLOW  = GLOW

------------------------------------------------------------
-- 内联图标（FontString 内可显示）：WoW 字体渲染不出 emoji / 几何符号（⚡◈✦★✓ 等会变 □），
-- 改用贴图转义串 |Tpath:size|t。
------------------------------------------------------------
W.ICON = {
    leader   = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t",
    ready    = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t",
    waiting  = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:0|t",
    star     = "|TInterface\\COMMON\\ReputationStar:14:14:0:0:32:32:0:16:0:16|t",
}
W.ICON_LOOT  = "Interface\\Icons\\INV_Misc_Coin_01"   -- 战利品默认
W.ICON_PRIZE = "Interface\\Icons\\INV_Misc_Gift_01"   -- 自定义奖品默认

-- 内部：glyph 是否贴图路径
local function isTexPath(s)
    return type(s) == "string" and (s:find("\\") or s:find("^Interface"))
end

-- glyph → FontString 内联贴图串；非贴图原样当文字
function W.GlyphMarkup(glyph, size)
    size = size or 24
    if isTexPath(glyph) then
        return "|T" .. glyph .. ":" .. size .. ":" .. size .. "|t"
    end
    return glyph or ""
end

-- 若 glyph 是贴图路径则返回路径（供 SetTexture 用），否则 nil
function W.GlyphTexture(glyph)
    if isTexPath(glyph) then return glyph end
    return nil
end

------------------------------------------------------------
-- 字体辅助
------------------------------------------------------------

-- 设置一段 FontString 的字体（kind: display / ui / mono）+ 字号 + 颜色 token + 可选 flags
function W.SetFont(fs, kind, size, token, flags)
    local file = theme.fontFile[kind or "ui"] or theme.fontFile.ui
    fs:SetFont(file, size or 12, flags or "")
    if token then fs:SetTextColor(theme:RGB(token)) end
    return fs
end

-- 在 parent 上建一个 FontString（默认 OVERLAY 层）
function W.Text(parent, kind, size, token, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    W.SetFont(fs, kind, size, token)
    return fs
end

-- 发光阴影近似：给 FontString 加柔和外发光（用 shadow 近似 text-shadow: 0 0 NN）
function W.GlowText(fs, token)
    local r, g, b = theme:RGB(token or "accentDeep")
    fs:SetShadowColor(r, g, b, 0.9)
    fs:SetShadowOffset(0, 0)
    return fs
end

------------------------------------------------------------
-- 纯色 / 渐变 Texture
------------------------------------------------------------

-- 在 parent 上建一个纯色 Texture（WHITE 染 token 色 + alpha）
function W.Solid(parent, token, alpha, layer, sublevel)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel or 0)
    t:SetTexture(WHITE)
    if token then
        t:SetVertexColor(theme:RGB(token, alpha or 1))
    else
        t:SetVertexColor(1, 1, 1, alpha or 1)
    end
    return t
end

-- 垂直渐变填充。各客户端 API 差异（经典 SetGradientAlpha；现代 SetGradient 含 orientation 枚举）：
-- 首次调用时探测能用的写法并缓存，都不行则退化为纯色，保证绝不崩。
-- 注意：颜色用「表」传 —— `theme:RGB(...)` 多返回值在非末位参数会被截断，必须 `{theme:RGB(...)}, {theme:RGB(...)}`。
local gradMode  -- nil=未探 / "alpha" / "enum" / "str" / "flat"
function W.SetVGradient(tex, c1, c2)
    local r1, g1, b1, a1 = c1[1], c1[2], c1[3], c1[4]
    local r2, g2, b2, a2 = c2[1], c2[2], c2[3], c2[4]
    if a1 == nil then a1 = 1 end
    if a2 == nil then a2 = 1 end

    if gradMode == nil then
        if tex.SetGradientAlpha then
            gradMode = "alpha"
        elseif tex.SetGradient and CreateColor then
            local _c1, _c2 = CreateColor(1, 1, 1, 1), CreateColor(0, 0, 0, 1)
            local enumV = Enum and Enum.Orientation and Enum.Orientation.Vertical
            if enumV ~= nil and pcall(tex.SetGradient, tex, enumV, _c1, _c2) then
                gradMode = "enum"
            elseif pcall(tex.SetGradient, tex, "VERTICAL", _c1, _c2) then
                gradMode = "str"
            else
                gradMode = "flat"
            end
        else
            gradMode = "flat"
        end
    end

    if gradMode == "alpha" then
        tex:SetGradientAlpha("VERTICAL", r1, g1, b1, a1, r2, g2, b2, a2)
    elseif gradMode == "enum" then
        tex:SetGradient(Enum.Orientation.Vertical, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    elseif gradMode == "str" then
        tex:SetGradient("VERTICAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    else
        tex:SetVertexColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

------------------------------------------------------------
-- 框面：PanelBG / Ring / MetalBorder / Inset
------------------------------------------------------------

-- 给 frame 加一个底色块（默认 panel 底，挂在 frame._bg）
function W.PanelBG(frame, token)
    local bg = W.Solid(frame, token or "panel", 1, "BACKGROUND", -1)
    bg:SetAllPoints(frame)
    frame._bg = bg
    return bg
end

-- 在 frame 四周建 inset 偏移 px 的 1px 边框（染 token 色），返回 {top,bottom,left,right} 四条 Texture。
-- 公开此原语，让需要"额外一圈染色描边"的组件（LootCard 稀有度边、GameTile 选中态外圈）复用。
function W.Ring(frame, inset, token, alpha, layer)
    local edges = {}
    local function edge() local t = frame:CreateTexture(nil, layer or "BORDER"); t:SetTexture(WHITE);
        t:SetVertexColor(theme:RGB(token, alpha or 1)); return t end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", -inset, inset)
    top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", inset, inset)
    top:SetHeight(1)
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -inset, -inset)
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", inset, -inset)
    bottom:SetHeight(1)
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", -inset, inset)
    left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -inset, -inset)
    left:SetWidth(1)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", inset, inset)
    right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", inset, -inset)
    right:SetWidth(1)
    edges.top, edges.bottom, edges.left, edges.right = top, bottom, left, right
    return edges
end

-- 金属多层描边（暗→中→亮→暗，模拟 box-shadow 0..6px 的金属斜面）。
-- variant: "frame"（窗体大边框，4 层）| "thin"（组件细边，1 层 frameDark）
function W.MetalBorder(frame, variant)
    frame._borders = frame._borders or {}
    if variant == "thin" then
        table.insert(frame._borders, W.Ring(frame, 0, "frameDark", 1, "BORDER"))
        return
    end
    table.insert(frame._borders, W.Ring(frame, 0, "frameDark",   1, "BORDER"))
    table.insert(frame._borders, W.Ring(frame, 1, "frameBright", 1, "BORDER"))
    table.insert(frame._borders, W.Ring(frame, 2, "frameMid",    1, "BORDER"))
    table.insert(frame._borders, W.Ring(frame, 3, "frameOuter",  1, "BORDER"))
end

-- 内嵌凹槽（panel-inset 底 + thin 边）
function W.Inset(parent, token)
    local f = CreateFrame("Frame", nil, parent)
    W.PanelBG(f, token or "panelInset")
    W.MetalBorder(f, "thin")
    return f
end

------------------------------------------------------------
-- 装饰：菱形宝石角 + 圆形发光晕
-- WoW Texture 无法旋转纯色块，用径向发光贴图小尺寸近似宝石点。
------------------------------------------------------------

function W.CornerGem(frame, point, ox, oy, size)
    size = size or 16
    local base = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    base:SetTexture(GLOW); base:SetVertexColor(theme:RGB("frameDark"))
    base:SetSize(size + 4, size + 4); base:SetPoint(point, frame, point, ox, oy)
    local gem = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    gem:SetTexture(GLOW); gem:SetVertexColor(theme:RGB("frameBright"))
    gem:SetSize(size, size); gem:SetPoint("CENTER", base, "CENTER", 0, 0)
    local hi = frame:CreateTexture(nil, "OVERLAY", nil, 3)
    hi:SetTexture(GLOW); hi:SetVertexColor(theme:RGB("accentGlow"))
    hi:SetSize(size * 0.5, size * 0.5)
    hi:SetPoint("CENTER", base, "CENTER", -size * 0.12, size * 0.12)
    return base
end

function W.FourCornerGems(frame, size)
    local s = size or 16
    W.CornerGem(frame, "TOPLEFT",     -s/2,  s/2, s)
    W.CornerGem(frame, "TOPRIGHT",     s/2,  s/2, s)
    W.CornerGem(frame, "BOTTOMLEFT",  -s/2, -s/2, s)
    W.CornerGem(frame, "BOTTOMRIGHT",  s/2, -s/2, s)
end

-- 柔和外发光晕（径向圆，ADD 模式；适合圆形元素的中心发光，不适合长方形元素的边缘外发光）。
-- 注意：长方形元素的"box-shadow"用本函数会渲染成椭圆中心光团（gradientCircle 是径向圆纹理），
--       请改用 W.Ring 多圈染色描边做"沿边亮"近似。
function W.GlowHalo(parent, token, alpha)
    local t = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetTexture(GLOW)
    t:SetVertexColor(theme:RGB(token or "accentDeep", alpha or 0.6))
    t:SetBlendMode("ADD")
    return t
end
