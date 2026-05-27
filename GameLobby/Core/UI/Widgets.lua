-- Core/UI/Widgets.lua —— 通用组件工厂（SPEC §4.8 / §4.10）
-- owner: wow-ui-developer
-- 提供视觉原语（金属多层描边、菱形宝石角、内嵌凹槽、发光层、渐变填充）+ 复用组件构造函数。
-- CSS 的 box-shadow 多层描边 / conic / blur 无直接对应：用多层纯色 Texture 叠层 + 暴雪自带发光贴图近似（§4.10）。
-- 各组件返回一个 frame，并把可更新句柄挂在 frame 上（如 :SetData / 子区域），供五屏调用刷新。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = {}            -- 组件工厂命名空间
GL.UI.Widgets = W

-- 暴雪自带可复用贴图
local WHITE   = "Interface\\Buttons\\WHITE8X8"                      -- 纯白，染色即得任意纯色块
local GLOW    = "Interface\\GLUES\\MODELS\\UI_Tauren\\gradientCircle" -- 圆形径向发光（用于宝石/狂点钮/发光晕）
local STAR    = "Interface\\COMMON\\ReputationStar"                 -- 备用
local READY   = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NOTREADY= "Interface\\RaidFrame\\ReadyCheck-NotReady"

W.WHITE = WHITE

-- 内联图标：WoW 字体渲染不出 emoji/几何符号（⚡◈✦★✓ 等会变 □），
-- 改用贴图转义串 |Tpath:size|t（任何 FontString 内联可显示）。
W.ICON = {
    leader   = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t",
    ready    = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t",
    waiting  = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:0|t",
    star     = "|TInterface\\COMMON\\ReputationStar:14:14:0:0:32:32:0:16:0:16|t",
}
-- 默认图标贴图（游戏/奖品没指定 glyph 时兜底）
W.ICON_LOOT  = "Interface\\Icons\\INV_Misc_Coin_01"
W.ICON_PRIZE = "Interface\\Icons\\INV_Misc_Gift_01"

-- glyph 是否贴图路径
local function isTexPath(s)
    return type(s) == "string" and (s:find("\\") or s:find("^Interface"))
end
-- glyph 标记：贴图路径→内联贴图串；否则原样当文字。
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

-- 设置一段 FontString 的字体（display/ui/mono）+ 字号 + 颜色 token + 可选阴影发光
function W.SetFont(fs, kind, size, token, flags)
    local file = theme.fontFile[kind or "ui"] or theme.fontFile.ui
    fs:SetFont(file, size or 12, flags or "")
    if token then fs:SetTextColor(theme:RGB(token)) end
    return fs
end

-- 在 parent 上建一个 FontString
function W.Text(parent, kind, size, token, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    W.SetFont(fs, kind, size, token)
    return fs
end

-- 发光阴影近似：给 FontString 加柔和外发光（用 shadow 近似 text-shadow 的 0 0 NN）
function W.GlowText(fs, token)
    local r, g, b = theme:RGB(token or "accentDeep")
    fs:SetShadowColor(r, g, b, 0.9)
    fs:SetShadowOffset(0, 0)
    return fs
end

------------------------------------------------------------
-- 纯色 Texture 块（染白色贴图）
------------------------------------------------------------

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

-- 垂直渐变填充。各客户端的渐变 API 差异极大（经典 WLK 用 SetGradientAlpha；
-- 时光服用现代 SetGradient，且对 orientation/颜色对象的接受方式不一），
-- 这里第一次调用时探测出本机能用的写法并缓存；都不行则退化为纯色，保证绝不崩。
-- 注意：颜色用「表」传，不能直接 spread `theme:RGB(...)`——多返回值在非末位参数会被截断成 1 个，
-- 导致第二色的 g/b/a 变 nil（这是个 Lua 陷阱）。调用处务必写 `{theme:RGB(...)}, {theme:RGB(...)}`。
local gradMode  -- nil=未探测 / "alpha" / "enum" / "str" / "flat"
function W.SetVGradient(tex, c1, c2)
    local r1, g1, b1, a1 = c1[1], c1[2], c1[3], c1[4]
    local r2, g2, b2, a2 = c2[1], c2[2], c2[3], c2[4]
    if a1 == nil then a1 = 1 end
    if a2 == nil then a2 = 1 end

    if gradMode == nil then
        if tex.SetGradientAlpha then
            gradMode = "alpha"
        elseif tex.SetGradient and CreateColor then
            local c1, c2 = CreateColor(1, 1, 1, 1), CreateColor(0, 0, 0, 1)
            local enumV = Enum and Enum.Orientation and Enum.Orientation.Vertical
            if enumV ~= nil and pcall(tex.SetGradient, tex, enumV, c1, c2) then
                gradMode = "enum"
            elseif pcall(tex.SetGradient, tex, "VERTICAL", c1, c2) then
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
        -- 兜底：取两色平均做纯色填充，保证窗体能显示
        tex:SetVertexColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

------------------------------------------------------------
-- 金属多层描边面板（近似 .addon 的多层 box-shadow）
-- 在 frame 外缘叠 4 层 1px 边框：暗 → 中 → 亮 → 暗（金属斜面感）。
-- 用 Backdrop 不易做多层，这里手搓 8 条边 Texture。
------------------------------------------------------------

-- 给 frame 加一个底色块（panel 底）
function W.PanelBG(frame, token)
    local bg = W.Solid(frame, token or "panel", 1, "BACKGROUND", -1)
    bg:SetAllPoints(frame)
    frame._bg = bg
    return bg
end

-- 单层描边：在 frame 四周建 inset 偏移 px 的 1px 边框（染 token 色）
local function ringAt(frame, inset, token, alpha, layer)
    local c = {}
    local function edge(side)
        local t = frame:CreateTexture(nil, layer or "BORDER")
        t:SetTexture(WHITE)
        t:SetVertexColor(theme:RGB(token, alpha or 1))
        return t
    end
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
    c.top, c.bottom, c.left, c.right = top, bottom, left, right
    return c
end

-- 金属多层描边（暗→中→亮→暗，模拟 box-shadow 0..6px 的金属斜面）。
-- variant: "frame"（窗体大边框，4 层）| "thin"（组件细边，1 层 frameDark）
function W.MetalBorder(frame, variant)
    frame._borders = frame._borders or {}
    if variant == "thin" then
        table.insert(frame._borders, ringAt(frame, 0, "frameDark", 1, "BORDER"))
        return
    end
    -- frame：从内到外 暗(frameDark) / 亮(frameBright) / 中(frameMid) / 暗(frameOuter)
    table.insert(frame._borders, ringAt(frame, 0, "frameDark",   1, "BORDER"))
    table.insert(frame._borders, ringAt(frame, 1, "frameBright", 1, "BORDER"))
    table.insert(frame._borders, ringAt(frame, 2, "frameMid",    1, "BORDER"))
    table.insert(frame._borders, ringAt(frame, 3, "frameOuter",  1, "BORDER"))
end

-- 内嵌凹槽（.inset：panel-inset 底 + frameDark 边 + 内阴影）
function W.Inset(parent, token)
    local f = CreateFrame("Frame", nil, parent)
    W.PanelBG(f, token or "panelInset")
    W.MetalBorder(f, "thin")
    return f
end

------------------------------------------------------------
-- 菱形宝石角（.addon::before/after：18px 旋转 45° 的径向渐变菱形）
-- WoW Texture 无法旋转纯色块，用圆形径向发光贴图 + 小尺寸近似「宝石」点。
------------------------------------------------------------

function W.CornerGem(frame, point, ox, oy, size)
    size = size or 16
    -- 外暗底
    local base = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    base:SetTexture(GLOW)
    base:SetVertexColor(theme:RGB("frameDark"))
    base:SetSize(size + 4, size + 4)
    base:SetPoint(point, frame, point, ox, oy)
    -- 宝石本体（金属亮 → 高光）
    local gem = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    gem:SetTexture(GLOW)
    gem:SetVertexColor(theme:RGB("frameBright"))
    gem:SetSize(size, size)
    gem:SetPoint("CENTER", base, "CENTER", 0, 0)
    -- 高光点
    local hi = frame:CreateTexture(nil, "OVERLAY", nil, 3)
    hi:SetTexture(GLOW)
    hi:SetVertexColor(theme:RGB("accentGlow"))
    hi:SetSize(size * 0.5, size * 0.5)
    hi:SetPoint("CENTER", base, "CENTER", -size * 0.12, size * 0.12)
    return base
end

-- 给一个 frame 加四角宝石
function W.FourCornerGems(frame, size)
    local s = size or 16
    W.CornerGem(frame, "TOPLEFT",     -s/2,  s/2, s)
    W.CornerGem(frame, "TOPRIGHT",     s/2,  s/2, s)
    W.CornerGem(frame, "BOTTOMLEFT",  -s/2, -s/2, s)
    W.CornerGem(frame, "BOTTOMRIGHT",  s/2, -s/2, s)
end

-- 柔和外发光晕（圆形径向，置于元素底层；用于 winner-banner、宝石、发光强调）
function W.GlowHalo(parent, token, alpha)
    local t = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetTexture(GLOW)
    t:SetVertexColor(theme:RGB(token or "accentDeep", alpha or 0.6))
    t:SetBlendMode("ADD")
    return t
end

------------------------------------------------------------
-- 区段标题 section-label（11px 字距 + 渐隐横线）
------------------------------------------------------------

function W.SectionLabel(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(22)
    local fs = W.Text(f, "display", theme.font.sectionLabel, "textDim")
    fs:SetPoint("LEFT", f, "LEFT", 4, 0)
    fs:SetText(text or "")
    f._label = fs
    -- 右侧渐隐横线
    local line = W.Solid(f, "divider", 0.8, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 10, 0)
    line:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    W.SetVGradient(line, {theme:RGB("divider")}, {theme:RGB("divider", 0)})
    f._line = line
    -- 可挂第二/第三段文字（右侧计数，如「N 人」「✓ x/y」）
    f._extra = {}
    function f:AddExtra(txt, token, kind)
        local e = W.Text(self, kind or "mono", theme.font.small, token or "text")
        e:SetText(txt)
        local anchor = #self._extra > 0 and self._extra[#self._extra] or fs
        e:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
        table.insert(self._extra, e)
        -- 横线起点跟到最后一段后面
        line:ClearAllPoints()
        line:SetPoint("LEFT", e, "RIGHT", 10, 0)
        line:SetPoint("RIGHT", self, "RIGHT", -4, 0)
        return e
    end
    function f:SetLabel(txt) fs:SetText(txt) end
    return f
end

------------------------------------------------------------
-- 按钮 btn / btn-primary（金属渐变底 + 内高光 + hover 发光 + disabled 灰）
------------------------------------------------------------

-- variant: "default" | "primary"；sizeKind: "sm" | nil | "lg"
function W.Button(parent, text, variant, sizeKind)
    local b = CreateFrame("Button", nil, parent)
    variant = variant or "default"
    local padH = (sizeKind == "lg") and 36 or (sizeKind == "sm") and 14 or 22
    local fsize = (sizeKind == "lg") and theme.font.btnLg or (sizeKind == "sm") and theme.font.btnSm or theme.font.btn
    b:SetHeight((sizeKind == "lg") and 42 or (sizeKind == "sm") and 24 or 34)

    -- 底（渐变）
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE)
    bg:SetAllPoints(b)
    if variant == "primary" then
        W.SetVGradient(bg, {theme:RGB("frameBright")}, {theme:RGB("accentDeep")})
    else
        W.SetVGradient(bg, {theme:RGB("panel2", 1)}, {theme:RGB("frameDark", 1)})
    end
    b._bg = bg
    W.MetalBorder(b, "thin")
    -- 内顶高光线
    local hl = W.Solid(b, "accentGlow", variant == "primary" and 0.5 or 0.15, "ARTWORK")
    hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    hl:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -1)
    hl:SetHeight(1)

    -- 文字
    local fs = W.Text(b, "display", fsize, variant == "primary" and nil or "text")
    if variant == "primary" then fs:SetTextColor(0.1, 0.05, 0, 1) end
    fs:SetPoint("CENTER")
    fs:SetText(text or "")
    b._fs = fs
    b._variant = variant
    b:SetWidth(math.max(fs:GetStringWidth() + padH * 2, sizeKind == "sm" and 56 or 90))

    -- hover 发光
    local glow = W.GlowHalo(b, variant == "primary" and "accentGlow" or "accentDeep", 0.0)
    glow:SetPoint("TOPLEFT", b, "TOPLEFT", -8, 8)
    glow:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 8, -8)
    b._glow = glow

    b:SetScript("OnEnter", function(s)
        if not s:IsEnabled() then return end
        s._glow:SetAlpha(0.5)
        if s._variant ~= "primary" then s._fs:SetTextColor(theme:RGB("accentGlow")) end
        for _, ring in ipairs(s._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameBright")) end
        end
    end)
    b:SetScript("OnLeave", function(s)
        s._glow:SetAlpha(0)
        if s._variant ~= "primary" then s._fs:SetTextColor(theme:RGB("text")) end
        for _, ring in ipairs(s._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameDark")) end
        end
    end)
    b:SetScript("OnMouseDown", function(s) if s:IsEnabled() then s._fs:SetPoint("CENTER", 0, -1) end end)
    b:SetScript("OnMouseUp",   function(s) s._fs:SetPoint("CENTER", 0, 0) end)

    -- disabled 灰度
    function b:SetEnabledLook(on)
        if on then
            self:Enable(); self:SetAlpha(1)
        else
            self:Disable(); self:SetAlpha(0.4); self._glow:SetAlpha(0)
        end
    end
    function b:SetLabel(t)
        self._fs:SetText(t)
        self:SetWidth(math.max(self._fs:GetStringWidth() + padH * 2, sizeKind == "sm" and 56 or 90))
    end
    return b
end

------------------------------------------------------------
-- 玩家卡 player（左 3px 职业色边 + 圆形首字头像 + 名字 + 状态 ✓/○/★/计数）
------------------------------------------------------------

function W.PlayerCard(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(32)
    W.PanelBG(c, "panel2")
    W.MetalBorder(c, "thin")
    -- 左 3px 职业色边
    local classBar = W.Solid(c, nil, 1, "ARTWORK")
    classBar:SetWidth(3)
    classBar:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    classBar:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
    c._classBar = classBar
    -- is-self 金底渐变
    local selfBG = W.Solid(c, "accent", 0.0, "BACKGROUND", 1)
    selfBG:SetAllPoints(c)
    W.SetVGradient(selfBG, {theme:RGB("accent", 0.12)}, {theme:RGB("accent", 0)})
    c._selfBG = selfBG
    -- 头像（圆形首字）—— 用 GLOW 圆贴图染职业色 + 首字
    local port = c:CreateTexture(nil, "ARTWORK")
    port:SetTexture(GLOW)
    port:SetSize(22, 22)
    port:SetPoint("LEFT", c, "LEFT", 8, 0)
    c._port = port
    local initial = W.Text(c, "display", 10, nil)
    initial:SetTextColor(0.1, 0.07, 0.03, 0.8)
    initial:SetPoint("CENTER", port, "CENTER", 0, 0)
    c._initial = initial
    -- 名字
    local name = W.Text(c, "ui", theme.font.body, "text")
    name:SetPoint("LEFT", port, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", c, "RIGHT", -22, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    c._name = name
    -- 状态（右侧）
    local status = W.Text(c, "mono", 10, "textMute")
    status:SetPoint("RIGHT", c, "RIGHT", -6, 0)
    c._status = status

    -- data: { name, classFile, isSelf, isLeader, ready, spectator, count, showCount }
    function c:SetData(p)
        p = p or {}
        local r, g, b = theme:ClassColor(p.classFile)
        self._classBar:SetVertexColor(r, g, b, 1)
        self._port:SetVertexColor(r, g, b, 1)
        self._name:SetText(p.name or "?")
        self._name:SetTextColor(r, g, b)
        self._initial:SetText((p.name or "?"):sub(1, 3))   -- 中文取首字（UTF-8 3 字节）
        self._selfBG:SetAlpha(p.isSelf and 1 or 0)
        if p.showCount then
            self._status:SetText(tostring(p.count or 0))
            self._status:SetTextColor(theme:RGB("accentGlow"))
        elseif p.isLeader then
            self._status:SetText(W.ICON.leader)
            self._status:SetTextColor(theme:RGB("accent"))
        elseif p.spectator then
            self._status:SetText("观")
            self._status:SetTextColor(theme:RGB("textMute"))
        elseif p.ready then
            self._status:SetText(W.ICON.ready)
            self._status:SetTextColor(theme:RGB("success"))
        else
            self._status:SetText(W.ICON.waiting)
            self._status:SetTextColor(theme:RGB("textMute"))
        end
    end
    return c
end

------------------------------------------------------------
-- 战利品卡 loot-card（三态：loot / custom / friendly）
-- prize 结构同 ctx.prize：{ mode="loot"|"custom"|"friendly", itemLink, text, rarity, name, glyph, type, slot, stat }
------------------------------------------------------------

function W.LootCard(parent, isLeaderEditable)
    local card = CreateFrame("Frame", nil, parent)
    card:SetHeight(88)
    W.PanelBG(card, "panelInset")
    W.MetalBorder(card, "thin")
    -- 稀有度边光（叠一层染色描边）
    local rarRing = ringAt(card, 0, "textMute", 0.6, "OVERLAY")
    card._rarRing = rarRing
    local function setRingColor(r, g, b)
        for _, e in pairs(rarRing) do e:SetVertexColor(r, g, b, 0.7) end
    end

    -- 物品图标 60×60
    local iconF = CreateFrame("Frame", nil, card)
    iconF:SetSize(60, 60)
    iconF:SetPoint("LEFT", card, "LEFT", 14, 0)
    W.PanelBG(iconF, "panel2")
    local iconBorder = ringAt(iconF, 0, "textMute", 1, "BORDER")
    card._iconBorder = iconBorder
    local glyph = W.Text(iconF, "display", 26, "accent")
    glyph:SetPoint("CENTER")
    card._glyph = glyph
    local iconTex = iconF:CreateTexture(nil, "ARTWORK")  -- 真实物品贴图（loot 模式可用）
    iconTex:SetPoint("TOPLEFT", 2, -2); iconTex:SetPoint("BOTTOMRIGHT", -2, 2)
    iconTex:Hide()
    card._iconTex = iconTex

    -- 信息区
    local name = W.Text(card, "display", 16, "text")
    name:SetPoint("TOPLEFT", iconF, "TOPRIGHT", 14, -2)
    name:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    card._name = name
    local meta = W.Text(card, "ui", theme.font.small, "textMute")
    meta:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
    meta:SetJustifyH("LEFT")
    card._meta = meta
    local stat = W.Text(card, "ui", theme.font.body, "textDim")
    stat:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -4)
    stat:SetJustifyH("LEFT")
    card._stat = stat

    -- 团长可编辑：自定义奖品输入框（custom/friendly 模式）
    local input
    if isLeaderEditable then
        input = CreateFrame("EditBox", nil, card)
        input:SetPoint("TOPLEFT", iconF, "TOPRIGHT", 14, -4)
        input:SetPoint("RIGHT", card, "RIGHT", -12, 0)
        input:SetHeight(26)
        input:SetAutoFocus(false)
        input:SetMaxLetters(60)
        W.SetFont(input, "ui", 14, "text")
        local ibg = W.Solid(input, "panel2", 1, "BACKGROUND", -1)
        ibg:SetAllPoints(input)
        W.MetalBorder(input, "thin")
        input:SetTextInsets(8, 8, 0, 0)
        local meta2 = W.Text(card, "mono", theme.font.tiny, "textMute")
        meta2:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -3)
        meta2:SetJustifyH("LEFT")
        card._inputMeta = meta2
        input:SetScript("OnTextChanged", function(s)
            local txt = s:GetText()
            local len = strlenutf8 and strlenutf8(txt) or #txt
            local has = (txt:gsub("%s", "")) ~= ""
            card._inputMeta:SetText(string.format("%s   %d/60",
                has and "团长设置 · 团员可见" or "留空则为友谊赛 · 仅为娱乐", len))
            if card._onPrizeChanged then card._onPrizeChanged(txt) end
        end)
        input:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        input:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
        card._input = input
    end

    -- prize 渲染
    function card:SetPrize(prize)
        prize = prize or { mode = "friendly" }
        local mode = prize.mode or "friendly"
        if mode == "loot" then
            if self._input then self._input:Hide(); if self._inputMeta then self._inputMeta:Hide() end end
            self._name:Show(); self._meta:Show(); self._stat:Show()
            local rk = prize.rarity or "epic"
            local rr, rg, rb = theme:Rarity(rk)
            setRingColor(rr, rg, rb)
            for _, e in pairs(self._iconBorder) do e:SetVertexColor(rr, rg, rb, 1) end
            local lootIcon = prize.icon or W.GlyphTexture(prize.glyph) or W.ICON_LOOT
            self._iconTex:SetTexture(lootIcon); self._iconTex:Show(); self._glyph:Hide()
            self._name:SetText(prize.name or prize.itemLink or "战利品")
            self._name:SetTextColor(rr, rg, rb)
            local metaTxt = table.concat({ prize.type or "", prize.slot or "", prize.flavor or "" }, "  ·  ")
            self._meta:SetText((metaTxt:gsub("^%s*·%s*", "")))
            self._stat:SetText(prize.stat or "")
        elseif mode == "custom" and prize.text and prize.text ~= "" then
            local ar, ag, ab = theme:RGB("accent")
            setRingColor(ar, ag, ab)
            for _, e in pairs(self._iconBorder) do e:SetVertexColor(ar, ag, ab, 1) end
            self._glyph:Hide(); self._iconTex:SetTexture(W.ICON_PRIZE); self._iconTex:Show()
            if self._input then
                -- 团长：填入输入框
                if self._input:GetText() ~= prize.text then self._input:SetText(prize.text) end
                self._input:Show(); self._name:Hide(); self._meta:Hide(); self._stat:Hide()
                if self._inputMeta then self._inputMeta:Show() end
            else
                self._name:Show(); self._meta:Show(); self._stat:Hide()
                self._name:SetText(prize.text); self._name:SetTextColor(ar, ag, ab)
                self._meta:SetText("团长指定  ·  胜者归属")
            end
        else
            -- friendly / 空
            local mr, mg, mb = theme:RGB("textMute")
            setRingColor(mr, mg, mb)
            for _, e in pairs(self._iconBorder) do e:SetVertexColor(mr, mg, mb, 1) end
            self._glyph:Hide(); self._iconTex:SetTexture(W.ICON_PRIZE); self._iconTex:Show()
            if self._input then
                self._input:Show(); self._name:Hide(); self._meta:Hide(); self._stat:Hide()
                if self._inputMeta then self._inputMeta:Show() end
            else
                self._name:Show(); self._meta:Show(); self._stat:Show()
                self._name:SetText("友谊赛 · 无奖品"); self._name:SetTextColor(theme:RGB("text"))
                self._meta:SetText("纯切磋  ·  胜者享荣誉")
                self._stat:SetText("等待团长指定奖品 · 或直接开局")
                self._stat:SetTextColor(theme:RGB("textMute"))
            end
        end
    end
    function card:OnPrizeChanged(fn) self._onPrizeChanged = fn end
    return card
end

------------------------------------------------------------
-- 游戏格 game-tile（glyph + 标题 + 两行描述；selected / locked）
------------------------------------------------------------

-- 共享的隐藏 UIDropDownMenu 容器（EasyMenu 需要一个 dropdown 框架做载体）。
-- 所有 GameTile 复用同一个，避免每格一个。
local _tileDropdown

function W.GameTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(180, 96)
    -- 左键保留选择逻辑；右键弹下拉菜单（导出字符串）
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    W.PanelBG(t, "panel2")
    W.MetalBorder(t, "thin")
    local selGlow = W.GlowHalo(t, "accentDeep", 0)
    selGlow:SetPoint("TOPLEFT", -6, 6); selGlow:SetPoint("BOTTOMRIGHT", 6, -6)
    t._selGlow = selGlow

    local glyphF = CreateFrame("Frame", nil, t)
    glyphF:SetSize(36, 36)
    glyphF:SetPoint("TOPLEFT", 12, -12)
    W.PanelBG(glyphF, "panelInset"); W.MetalBorder(glyphF, "thin")
    local glyph = W.Text(glyphF, "display", 18, "accent")
    glyph:SetPoint("CENTER")
    t._glyph = glyph

    local title = W.Text(t, "display", 13, "text")
    title:SetPoint("TOPLEFT", glyphF, "BOTTOMLEFT", 0, -8)
    t._title = title
    local desc = W.Text(t, "ui", theme.font.small, "textMute")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    desc:SetJustifyH("LEFT")
    desc:SetJustifyV("TOP")
    t._desc = desc

    local lock = W.Text(t, "ui", theme.font.tiny, "textMute")
    lock:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, -8)
    lock:SetText("即将上线")
    lock:Hide()
    t._lock = lock

    -- def: { id, name, glyph, descLines={...}, locked, selected }
    function t:SetGame(def, selected)
        def = def or {}
        -- 存身份供右键菜单/导出用（Lobby 也会单独设 _gameId，这里复用同一字段）
        self._gameId = def.id
        self._gameName = def.name
        self._locked = def.locked
        self._glyph:SetText(W.GlyphMarkup(def.glyph, 26))
        self._title:SetText(def.name or "")
        local d = def.descLines or {}
        self._desc:SetText(table.concat(d, "\n"))
        if def.locked then
            -- 占位/未上线游戏：视觉置灰、显示「即将上线」徽标。
            -- 注意不调 Disable()——否则按钮不再接收任何鼠标点击，右键菜单也弹不出。
            -- 左键选择由点击分发逻辑按 _locked 拦截；右键菜单仍可弹（导出项置灰/提示不可导出）。
            self:SetAlpha(0.45); self._lock:Show()
        else
            self:SetAlpha(1); self._lock:Hide()
        end
        self:SetSelected(selected)
    end
    function t:SetSelected(on)
        self._selGlow:SetAlpha(on and 0.6 or 0)
        local col = on and "accent" or "frameDark"
        for _, ring in ipairs(self._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB(col)) end
        end
        self._glyph:SetTextColor(theme:RGB(on and "accentGlow" or "accent"))
    end

    -- 左键选择回调（Lobby 注册）：fn(self)
    function t:SetOnSelect(fn) self._onSelect = fn end

    ------------------------------------------------------------
    -- 右键 → 导出字符串：EasyMenu 下拉菜单
    -- 菜单项「导出字符串」点击 → GL.Import:ExportGame(id) → GL.UI:ShowExport / Log
    ------------------------------------------------------------
    function t:ShowContextMenu()
        if not _tileDropdown then
            -- 隐藏 UIDropDownMenu 载体（EasyMenu 必需），全局只建一个
            _tileDropdown = CreateFrame("Frame", "GameLobbyTileDropdown", UIParent, "UIDropDownMenuTemplate")
        end
        if not EasyMenu then return end   -- 极端环境兜底（WLK 自带，正常存在）
        local id    = self._gameId
        local name  = self._gameName
        local locked = self._locked

        -- 占位/locked 游戏：预判导出不可用（ExportGame 会返回 nil + 原因），菜单项置灰并改文案
        local exportDisabled = locked and true or false

        local menu = {
            { text = name or "游戏", isTitle = true, notCheckable = true },
            {
                text = exportDisabled and "导出字符串（不可导出）" or "导出字符串",
                notCheckable = true,
                disabled = exportDisabled,
                func = function()
                    local GL2 = _G.GameLobby
                    if not (GL2 and GL2.Import) then
                        if GL2 and GL2.UI then GL2.UI:Log("warn", "导入/导出模块尚未就绪") end
                        return
                    end
                    -- ExportGame 返回 (str) 或 (nil, reason)
                    local ok, strOrNil, reason = pcall(function()
                        return GL2.Import:ExportGame(id)
                    end)
                    local str, why
                    if ok then
                        str = strOrNil; why = reason
                    else
                        why = "导出出错：" .. tostring(strOrNil)
                    end
                    if type(str) == "string" then
                        GL2.UI:ShowExport("导出：" .. (name or id or "游戏"), str)
                    else
                        GL2.UI:Log("warn", why or "导出失败")
                    end
                end,
            },
            { text = "取消", notCheckable = true, func = function() end },
        }
        EasyMenu(menu, _tileDropdown, "cursor", 0, 0, "MENU")
    end

    -- 点击分发：左键走选择回调，右键弹菜单（locked 也允许弹菜单，仅导出项置灰）
    t:SetScript("OnClick", function(s, button)
        if button == "RightButton" then
            s:ShowContextMenu()
        else
            if s._locked then return end
            if s._onSelect then s._onSelect(s) end
        end
    end)

    return t
end

------------------------------------------------------------
-- castbar 计时条（高 24，金渐变填充 + 前缘火花 + 颗粒纹理）
------------------------------------------------------------

function W.Castbar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(24)
    W.PanelBG(bar, "panelInset"); W.MetalBorder(bar, "thin")
    -- 填充
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(WHITE)
    fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
    W.SetVGradient(fill, {theme:RGB("accentGlow")}, {theme:RGB("accentDeep")})
    bar._fill = fill
    -- 前缘火花
    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(GLOW)
    spark:SetVertexColor(theme:RGB("accentGlow"))
    spark:SetBlendMode("ADD")
    spark:SetSize(14, 30)
    bar._spark = spark
    -- 左标签 + 右计时
    local label = W.Text(bar, "display", theme.font.small, "text")
    label:SetPoint("LEFT", bar, "LEFT", 12, 0)
    bar._label = label
    local time = W.Text(bar, "mono", theme.font.mono, "accentGlow")
    time:SetPoint("RIGHT", bar, "RIGHT", -12, 0)
    bar._time = time

    -- pct 0..1；left=剩余秒
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

------------------------------------------------------------
-- 狂点钮 smash-btn（圆形 220，径向金渐变 + 4px 亮边，按下下沉缩放强发光）
-- UI 只建外观 + 暴露句柄；计数逻辑由游戏经 api 挂 OnMouseDown（契约 §6 边界）。
------------------------------------------------------------

function W.SmashButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(220, 220)
    -- 外发光晕
    local halo = W.GlowHalo(b, "accentDeep", 0.7)
    halo:SetSize(280, 280); halo:SetPoint("CENTER")
    b._halo = halo
    -- 圆形底（径向金渐变近似：GLOW 染金 + 内圈高光）
    local disc = b:CreateTexture(nil, "ARTWORK")
    disc:SetTexture(GLOW)
    disc:SetAllPoints(b)
    disc:SetVertexColor(theme:RGB("accentDeep"))
    b._disc = disc
    local discMid = b:CreateTexture(nil, "ARTWORK", nil, 1)
    discMid:SetTexture(GLOW)
    discMid:SetSize(176, 176); discMid:SetPoint("CENTER")
    discMid:SetVertexColor(theme:RGB("frameBright"))
    b._discMid = discMid
    local discHi = b:CreateTexture(nil, "ARTWORK", nil, 2)
    discHi:SetTexture(GLOW)
    discHi:SetSize(96, 96); discHi:SetPoint("CENTER", b, "CENTER", -16, 16)
    discHi:SetVertexColor(theme:RGB("accentGlow"))
    b._discHi = discHi
    -- 4px 亮边环
    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(GLOW)
    ring:SetAllPoints(b)
    ring:SetVertexColor(theme:RGB("frameBright"))
    ring:SetBlendMode("ADD")
    ring:SetAlpha(0.4)
    b._ring = ring
    -- 文案
    local fs = W.Text(b, "display", theme.font.smashText, nil)
    fs:SetTextColor(0.1, 0.05, 0, 1)
    fs:SetPoint("CENTER")
    fs:SetText("点 击")
    b._fs = fs
    -- 下方提示
    local key = W.Text(b, "mono", theme.font.small, "textMute")
    key:SetPoint("TOP", b, "BOTTOM", 0, -10)
    key:SetText("SPACE · CLICK · TAP")
    b._key = key

    -- 按下反馈（下沉缩放 + 强发光）—— 视觉，不计数
    b:SetScript("OnMouseDown", function(s)
        if not s:IsEnabled() then return end
        s._fs:SetPoint("CENTER", 0, -2)
        s._halo:SetAlpha(1); s._ring:SetAlpha(0.8)
        s:SetScale(0.97)
    end)
    b:SetScript("OnMouseUp", function(s)
        s._fs:SetPoint("CENTER", 0, 0)
        s._halo:SetAlpha(0.7); s._ring:SetAlpha(0.4)
        s:SetScale(1)
    end)

    function b:SetPressedLabel(countdownMode)
        self._fs:SetText(countdownMode and "就 位" or "点 击")
    end
    function b:SetActive(on)
        if on then
            self:Enable(); self:SetAlpha(1)
        else
            self:Disable(); self:SetAlpha(0.55)
        end
    end
    return b
end

------------------------------------------------------------
-- 榜行 live-row / final-row（名次 + 职业色名 + 分数 mono + 进度条；rank-1 高亮 / is-self 金底）
------------------------------------------------------------

-- kind: "live" | "final"
function W.RankRow(parent, kind)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(kind == "final" and 34 or 28)
    W.PanelBG(r, "panel2"); W.MetalBorder(r, "thin")
    local classBar = W.Solid(r, nil, 1, "ARTWORK")
    classBar:SetWidth(3)
    classBar:SetPoint("TOPLEFT"); classBar:SetPoint("BOTTOMLEFT")
    r._classBar = classBar
    local selfBG = W.Solid(r, "accent", 0, "BACKGROUND", 1)
    selfBG:SetAllPoints(r); W.SetVGradient(selfBG, {theme:RGB("accent", 0.15)}, {theme:RGB("accent", 0)})
    r._selfBG = selfBG

    local rank = W.Text(r, "display", kind == "final" and 16 or 13, "textMute")
    rank:SetPoint("LEFT", r, "LEFT", 8, 0)
    rank:SetWidth(24); rank:SetJustifyH("CENTER")
    r._rank = rank
    local name = W.Text(r, "ui", kind == "final" and 13 or theme.font.body, "text")
    name:SetPoint("LEFT", rank, "RIGHT", 6, 0)
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    r._name = name
    local score = W.Text(r, "mono", kind == "final" and 16 or theme.font.mono, "accentGlow")
    score:SetPoint("RIGHT", r, "RIGHT", -10, 0)
    r._score = score
    -- final 模式额外 CPS
    if kind == "final" then
        local cps = W.Text(r, "mono", theme.font.small, "textMute")
        cps:SetPoint("RIGHT", score, "LEFT", -12, 0)
        r._cps = cps
    else
        -- live 模式底部进度条
        local bar = W.Solid(r, "accent", 0.5, "OVERLAY")
        bar:SetHeight(2)
        bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 3, 0)
        r._bar = bar
    end

    -- data: { rank, name, classFile, score, cps, isSelf, maxScore }
    function r:SetRow(d)
        d = d or {}
        local cr, cg, cb = theme:ClassColor(d.classFile)
        self._classBar:SetVertexColor(cr, cg, cb)
        self._name:SetText(d.name or "?")
        self._name:SetTextColor(cr, cg, cb)
        self._selfBG:SetAlpha(d.isSelf and 1 or 0)
        self._score:SetText(tostring(d.score or 0))
        -- 名次（final: 第1名 ✦，否则数字；rank-1/2/3 配色）
        local rk = d.rank or 0
        if kind == "final" and rk == 1 then
            self._rank:SetText(W.ICON.leader); self._rank:SetTextColor(theme:Rarity("legendary"))
        else
            self._rank:SetText(tostring(rk))
            if rk == 1 then
                self._rank:SetTextColor(theme:Rarity("legendary"))
            elseif kind == "final" and rk == 2 then
                self._rank:SetTextColor(0.77, 0.77, 0.77)
            elseif kind == "final" and rk == 3 then
                self._rank:SetTextColor(0.79, 0.48, 0.24)
            else
                self._rank:SetTextColor(theme:RGB("textMute"))
            end
        end
        -- rank-1 行底高亮（传说橙）
        if rk == 1 then
            local lr, lg, lb = theme:Rarity("legendary")
            for _, ring in ipairs(self._borders or {}) do
                for _, e in pairs(ring) do e:SetVertexColor(lr, lg, lb, 0.8) end
            end
        else
            for _, ring in ipairs(self._borders or {}) do
                for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameDark")) end
            end
        end
        if self._cps then self._cps:SetText("CPS " .. string.format("%.1f", d.cps or 0)) end
        if self._bar and d.maxScore and d.maxScore > 0 then
            local w = (self:GetWidth() - 6) * (math.min(d.score or 0, d.maxScore) / d.maxScore)
            self._bar:SetWidth(math.max(0.1, w))
            self._bar:SetVertexColor(cr, cg, cb, 0.5)
        end
    end
    return r
end

------------------------------------------------------------
-- 统计卡 stat-card（顶部渐变细线 + 大数字 + 标签；gold/rare 配色）
------------------------------------------------------------

function W.StatCard(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(110, 64)
    W.PanelBG(c, "panelInset"); W.MetalBorder(c, "thin")
    -- 顶部渐变细线
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
    -- accent: "text" | "gold" | "rare"
    function c:Set(value_, label_, accent)
        self._value:SetText(tostring(value_))
        self._label:SetText(label_ or "")
        if accent == "gold" then
            self._value:SetTextColor(theme:RGB("accent")); W.GlowText(self._value, "accentDeep")
        elseif accent == "rare" then
            self._value:SetTextColor(theme:Rarity("rare")); W.GlowText(self._value, "rare")
        else
            self._value:SetTextColor(theme:RGB("text")); self._value:SetShadowColor(0,0,0,0)
        end
    end
    return c
end

------------------------------------------------------------
-- 日志条 log-strip（mono 11，标签 系统(蓝)/战团(金)/警告(红)，最多 ~4 行）
------------------------------------------------------------

function W.LogStrip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(70)
    W.PanelBG(f, "panelInset"); W.MetalBorder(f, "thin")
    f._lines = {}
    f._max = 4
    local function makeLine(i)
        local fs = W.Text(f, "mono", theme.font.small, "textMute")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -8 - (i - 1) * 15)
        fs:SetPoint("RIGHT", f, "RIGHT", -12, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
        return fs
    end
    for i = 1, f._max do f._lines[i] = makeLine(i) end
    f._buffer = {}

    -- level: "sys"|"system" | "raid" | "warn"
    function f:Push(level, text)
        local tagTxt, tagColor
        if level == "warn" then
            tagTxt, tagColor = "[警告] ", "danger"
        elseif level == "raid" then
            tagTxt, tagColor = "[战团] ", "accent"
        else
            tagTxt, tagColor = "[系统] ", "rare"  -- 系统用稀有蓝（设计 .system 用 --rar-rare）
        end
        table.insert(self._buffer, { tag = tagTxt, color = tagColor, text = text or "" })
        while #self._buffer > self._max do table.remove(self._buffer, 1) end
        self:Render()
    end
    -- token → "ffRRGGBB"（|c 颜色码）。稀有度 rare 不在 theme.c 里，单独取。
    local function hexcode(token)
        local hexv
        if token == "rare" then
            hexv = theme.rarity.rare.hex
        else
            hexv = (theme.c[token] and theme.c[token].hex) or "#ffffff"
        end
        return "ff" .. hexv:gsub("#", "")
    end
    local bodyHex = "ff" .. theme.c.textDim.hex:gsub("#", "")   -- 正文用次要文字色
    function f:Render()
        for i = 1, self._max do
            local line = self._lines[i]
            local item = self._buffer[i]
            if item then
                -- 标签上色 + 正文上色（FontString 不支持分段染色 → 用 |c 颜色码内联）
                line:SetText("|c" .. hexcode(item.color) .. item.tag .. "|r|c" .. bodyHex .. item.text .. "|r")
                line:Show()
            else
                line:Hide()
            end
        end
    end
    return f
end

------------------------------------------------------------
-- 滚动列表容器（战史用，max-height + 滚动条）—— 用 FauxScrollFrame 思路简化为 ScrollFrame + child
------------------------------------------------------------

function W.ScrollList(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(1, 1)
    sf:SetScrollChild(child)
    sf._child = child
    function sf:GetContent() return self._child end
    return sf
end

GL.UI.Widgets = W
