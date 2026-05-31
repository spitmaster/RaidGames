-- Core/UI/Widgets/LootCard.lua —— 战利品卡（三态：loot / custom / friendly）
-- owner: wow-ui-developer
-- 单一职责（SRP）：渲染 prize 数据 + 团长可编辑文本框。不知道"自己是哪种 prize"，由调用方传入。
-- prize 形参：{ mode="loot"|"custom"|"friendly", itemLink, text, rarity, name, glyph, type, slot, stat, icon, flavor }
-- 实例 API：
--   :SetPrize(prize)        渲染（记忆 _lastPrize，便于 SetEditable 后无参重渲染）
--   :SetEditable(on)        切换输入框可用性（团长↔团员，随 ROSTER_CHANGED 调用）
--   :OnPrizeChanged(fn)     文本变更回调（团长改奖品 → 通知上层）

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

function W.LootCard(parent, isLeaderEditable)
    local card = CreateFrame("Frame", nil, parent)
    card:SetHeight(88)
    W.PanelBG(card, "panelInset"); W.MetalBorder(card, "thin")

    -- 稀有度边（设计 .loot-card::before：rarity 描边 + box-shadow 0 0 20px rarity）
    -- WoW 没真 box-shadow；改用「2 层 1px rarity 染色描边」叠出厚边感（沿边走，不是浮光）。
    local rarRing  = W.Ring(card, 0, "textMute", 0.7,  "OVERLAY")
    local rarRing2 = W.Ring(card, 1, "textMute", 0.55, "OVERLAY")
    card._rarRing, card._rarRing2 = rarRing, rarRing2
    local function setRingColor(r, g, b)
        for _, e in pairs(rarRing)  do e:SetVertexColor(r, g, b, 0.95) end
        for _, e in pairs(rarRing2) do e:SetVertexColor(r, g, b, 0.55) end
    end

    -- 物品图标 60×60，3 层 rarity 描边（前 2 层实，第 3 层 alpha 低做过渡）
    local iconF = CreateFrame("Frame", nil, card)
    iconF:SetSize(60, 60); iconF:SetPoint("LEFT", card, "LEFT", 14, 0)
    W.PanelBG(iconF, "panel2")
    local iconBorder  = W.Ring(iconF, 0, "textMute", 1,    "BORDER")
    local iconBorder2 = W.Ring(iconF, 1, "textMute", 1,    "BORDER")
    local iconBorder3 = W.Ring(iconF, 2, "textMute", 0.45, "BORDER")
    card._iconBorder, card._iconBorder2, card._iconBorder3 = iconBorder, iconBorder2, iconBorder3

    local glyph = W.Text(iconF, "display", 26, "accent"); glyph:SetPoint("CENTER")
    card._glyph = glyph
    local iconTex = iconF:CreateTexture(nil, "ARTWORK")
    iconTex:SetPoint("TOPLEFT", 2, -2); iconTex:SetPoint("BOTTOMRIGHT", -2, 2); iconTex:Hide()
    card._iconTex = iconTex

    -- 信息区（三行：name / meta / stat）
    local name = W.Text(card, "display", 16, "text")
    name:SetPoint("TOPLEFT", iconF, "TOPRIGHT", 14, -2)
    name:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    card._name = name
    local meta = W.Text(card, "ui", theme.font.small, "textMute")
    meta:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4); meta:SetJustifyH("LEFT")
    card._meta = meta
    local stat = W.Text(card, "ui", theme.font.body, "textDim")
    stat:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -4); stat:SetJustifyH("LEFT")
    card._stat = stat

    -- 自定义奖品输入框（始终构建，:SetEditable 切显隐）—— 防止 ROSTER_CHANGED 切换身份时控件丢失
    card._editable = isLeaderEditable and true or false
    do
        local input = CreateFrame("EditBox", nil, card)
        input:SetPoint("TOPLEFT", iconF, "TOPRIGHT", 14, -4)
        input:SetPoint("RIGHT", card, "RIGHT", -12, 0)
        input:SetHeight(26); input:SetAutoFocus(false); input:SetMaxLetters(60)
        W.SetFont(input, "ui", 14, "text")
        local ibg = W.Solid(input, "panel2", 1, "BACKGROUND", -1); ibg:SetAllPoints(input)
        W.MetalBorder(input, "thin"); input:SetTextInsets(8, 8, 0, 0)

        local meta2 = W.Text(card, "mono", theme.font.tiny, "textMute")
        meta2:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -3); meta2:SetJustifyH("LEFT")
        -- 初始化空状态提示（OnTextChanged 只在变更时触发，新建为空也得有引导文案）
        meta2:SetText("留空则为友谊赛 · 仅为娱乐   0/60")
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
        input:SetScript("OnEnterPressed",  function(s) s:ClearFocus() end)
        card._input = input
    end

    -- 内部：三态渲染分发
    local function renderLoot(self_, prize)
        self_._input:Hide(); if self_._inputMeta then self_._inputMeta:Hide() end
        self_._name:Show(); self_._meta:Show(); self_._stat:Show()
        local rk = prize.rarity or "epic"
        local rr, rg, rb = theme:Rarity(rk)
        setRingColor(rr, rg, rb)
        for _, e in pairs(self_._iconBorder)  do e:SetVertexColor(rr, rg, rb, 1)   end
        for _, e in pairs(self_._iconBorder2) do e:SetVertexColor(rr, rg, rb, 1)   end
        for _, e in pairs(self_._iconBorder3) do e:SetVertexColor(rr, rg, rb, 0.5) end
        local lootIcon = prize.icon or W.GlyphTexture(prize.glyph) or W.ICON_LOOT
        self_._iconTex:SetTexture(lootIcon); self_._iconTex:Show(); self_._glyph:Hide()
        self_._name:SetText(prize.name or prize.itemLink or "战利品")
        self_._name:SetTextColor(rr, rg, rb)
        local metaTxt = table.concat({ prize.type or "", prize.slot or "", prize.flavor or "" }, "  ·  ")
        self_._meta:SetText((metaTxt:gsub("^%s*·%s*", "")))
        self_._stat:SetText(prize.stat or "")
    end

    local function renderCustom(self_, prize)
        local ar, ag, ab = theme:RGB("accent")
        setRingColor(ar, ag, ab)
        for _, e in pairs(self_._iconBorder)  do e:SetVertexColor(ar, ag, ab, 1)   end
        for _, e in pairs(self_._iconBorder2) do e:SetVertexColor(ar, ag, ab, 1)   end
        for _, e in pairs(self_._iconBorder3) do e:SetVertexColor(ar, ag, ab, 0.4) end
        self_._glyph:Hide(); self_._iconTex:SetTexture(W.ICON_PRIZE); self_._iconTex:Show()
        if self_._editable then
            if self_._input:GetText() ~= prize.text then self_._input:SetText(prize.text) end
            self_._input:Show(); self_._name:Hide(); self_._meta:Hide(); self_._stat:Hide()
            if self_._inputMeta then self_._inputMeta:Show() end
        else
            self_._input:Hide(); if self_._inputMeta then self_._inputMeta:Hide() end
            self_._name:Show(); self_._meta:Show(); self_._stat:Hide()
            self_._name:SetText(prize.text); self_._name:SetTextColor(ar, ag, ab)
            self_._meta:SetText("团长指定  ·  胜者归属")
        end
    end

    local function renderFriendly(self_)
        local mr, mg, mb = theme:RGB("textMute")
        setRingColor(mr, mg, mb)
        for _, e in pairs(self_._iconBorder)  do e:SetVertexColor(mr, mg, mb, 1)   end
        for _, e in pairs(self_._iconBorder2) do e:SetVertexColor(mr, mg, mb, 0.4) end
        for _, e in pairs(self_._iconBorder3) do e:SetVertexColor(mr, mg, mb, 0)   end
        self_._glyph:Hide(); self_._iconTex:SetTexture(W.ICON_PRIZE); self_._iconTex:Show()
        if self_._editable then
            self_._input:Show(); self_._name:Hide(); self_._meta:Hide(); self_._stat:Hide()
            if self_._inputMeta then self_._inputMeta:Show() end
        else
            self_._input:Hide(); if self_._inputMeta then self_._inputMeta:Hide() end
            self_._name:Show(); self_._meta:Show(); self_._stat:Show()
            self_._name:SetText("友谊赛 · 无奖品"); self_._name:SetTextColor(theme:RGB("text"))
            self_._meta:SetText("纯切磋  ·  胜者享荣誉")
            self_._stat:SetText("等待团长指定奖品 · 或直接开局")
            self_._stat:SetTextColor(theme:RGB("textMute"))
        end
    end

    -- 公开 API
    function card:SetPrize(prize)
        prize = prize or self._lastPrize or { mode = "friendly" }
        self._lastPrize = prize
        local mode = prize.mode or "friendly"
        if mode == "loot" then
            renderLoot(self, prize)
        elseif mode == "custom" and prize.text and prize.text ~= "" then
            renderCustom(self, prize)
        else
            renderFriendly(self)
        end
    end

    function card:SetEditable(on)
        on = on and true or false
        if self._editable == on then return end
        self._editable = on
        self:SetPrize()   -- 用 _lastPrize 重渲
    end

    function card:OnPrizeChanged(fn) self._onPrizeChanged = fn end
    return card
end
