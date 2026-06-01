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

    -- 物品品质(0-7) → 稀有度键名；键名 → 中文。供 Shift+点击物品自动识别真实战利品用。
    local Q2K = { [0] = "common", [1] = "common", [2] = "uncommon", [3] = "rare",
                  [4] = "epic", [5] = "legendary", [6] = "legendary", [7] = "legendary" }
    local RNAME = { common = "普通", uncommon = "优秀", rare = "精良", epic = "史诗", legendary = "传说" }
    -- 解析物品链接 → loot prize 表（GetItemInfo 取品质/图标/类型，取不到则从链接名兜底）。
    local function parseLoot(link)
        local name, quality, itype, eqslot, icon
        if GetItemInfo then
            local n, _, q, _, _, c, _, _, slot, tex = GetItemInfo(link)
            name, quality, itype, eqslot, icon = n, q, c, slot, tex
        end
        name = name or link:match("%[(.-)%]") or "战利品"
        local rk = Q2K[quality or 4] or "epic"
        return { mode = "loot", itemLink = link, name = name, rarity = rk, icon = icon,
                 type = itype, slot = eqslot, _rarityName = RNAME[rk] }
    end

    -- 自定义奖品输入框（始终构建，:SetEditable 切显隐）—— 防止 ROSTER_CHANGED 切换身份时控件丢失
    card._editable = isLeaderEditable and true or false
    do
        local input = CreateFrame("EditBox", nil, card)
        input:SetPoint("TOPLEFT", iconF, "TOPRIGHT", 14, -4)
        input:SetPoint("RIGHT", card, "RIGHT", -12, 0)
        -- maxLetters 放宽到 180：物品链接（|cff..|Hitem:..|h[名]|h|r）约 60-120 字符，60 会截断破坏链接。
        input:SetHeight(26); input:SetAutoFocus(false); input:SetMaxLetters(180)
        W.SetFont(input, "ui", 14, "text")
        local ibg = W.Solid(input, "panel2", 1, "BACKGROUND", -1); ibg:SetAllPoints(input)
        W.MetalBorder(input, "thin"); input:SetTextInsets(8, 8, 0, 0)

        local meta2 = W.Text(card, "mono", theme.font.tiny, "textMute")
        meta2:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -3); meta2:SetJustifyH("LEFT")
        -- 初始化空状态提示（OnTextChanged 只在变更时触发，新建为空也得有引导文案）
        meta2:SetText("打字写奖品 / Shift+点击物品设为战利品 · 留空=友谊赛   0/60")
        card._inputMeta = meta2

        input:SetScript("OnTextChanged", function(s)
            local txt = s:GetText() or ""
            -- 含物品链接 → 真实战利品（自动取稀有度/图标）。
            local link = txt:match("(|c%x+|Hitem:.-|h.-|h|r)")
            if link then
                local lp = parseLoot(link)
                card._inputMeta:SetText("战利品 · " .. (lp._rarityName or "") .. "   （清空文本可取消）")
                if card._onLoot then card._onLoot(lp) end
                return
            end
            -- 普通文字 → 自定义奖品 / 友谊赛。
            local len = strlenutf8 and strlenutf8(txt) or #txt
            local has = (txt:gsub("%s", "")) ~= ""
            card._inputMeta:SetText(string.format("%s   %d/60",
                has and "团长设置 · 团员可见" or "打字写奖品 / Shift+点击物品 · 留空=友谊赛", len))
            if card._onLoot then card._onLoot(nil) end           -- 退出战利品态
            if card._onPrizeChanged then card._onPrizeChanged(txt) end
        end)
        input:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        input:SetScript("OnEnterPressed",  function(s) s:ClearFocus() end)
        input:SetScript("OnEditFocusGained", function(s) GL.UI._lootInput = s end)
        card._input = input

        -- Shift+点击背包/拾取物品：把链接塞进当前聚焦的奖品框。WoW 在我们的 EditBox 聚焦时，
        -- ChatEdit_InsertLink 默认不往非聊天框插入；hooksecurefunc 在原函数之后补一刀。
        if _G.hooksecurefunc and _G.ChatEdit_InsertLink and not GL.UI._lootLinkHooked then
            GL.UI._lootLinkHooked = true
            hooksecurefunc("ChatEdit_InsertLink", function(link)
                local box = GL.UI._lootInput
                if box and box.HasFocus and box:HasFocus() and link and link ~= "" then
                    box:SetText(link)                            -- 整框设为链接 → OnTextChanged 识别成战利品
                    if box.SetCursorPosition then box:SetCursorPosition(box:GetText():len()) end
                end
            end)
        end
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
    -- 选中真实战利品（Shift+点击物品）时回调 fn(lootPrize)；清空文本退出战利品态时回调 fn(nil)。
    function card:OnLoot(fn) self._onLoot = fn end
    return card
end
