-- Core/UI/Widgets/LogStrip.lua —— 日志条（4 行 mono，标签彩色：系统/战团/警告；行可点击）
-- owner: wow-ui-developer
-- 单一职责（SRP）：维护固定行数环形缓冲，按 level 上色渲染；带 onClick 的行可点击（hover 高亮）。
-- 实例 API：
--   :Push(level, text, onClick?)   level ∈ "sys"|"system" | "raid" | "warn"；onClick 可选→该行可点
--   :Render()                      手动重渲（一般 Push 自动调）

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

function W.LogStrip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(70)
    W.PanelBG(f, "panelInset"); W.MetalBorder(f, "thin")

    f._lines  = {}
    f._buffer = {}
    f._max    = 4

    -- 每行 = 覆盖整行的 Button（承载点击/hover）+ 内嵌 FontString。
    -- 用 |c 内联色码上色（标签+正文分段），所以 hover 不能用 SetTextColor（会被 |c 覆盖），
    -- 改用一层 accent 背景高亮提示"可点"。
    local function makeLine(i)
        local btn = CreateFrame("Button", nil, f)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -7 - (i - 1) * 15)
        btn:SetPoint("RIGHT", f, "RIGHT", -10, 0)
        btn:SetHeight(15)
        btn:RegisterForClicks("LeftButtonUp")
        btn:EnableMouse(false)   -- 默认不可点（无 onClick 的行穿透鼠标）

        local hl = W.Solid(btn, "accent", 0, "BACKGROUND")
        hl:SetAllPoints(btn)
        btn._hl = hl

        local fs = W.Text(btn, "mono", theme.font.small, "textMute")
        fs:SetPoint("LEFT", btn, "LEFT", 2, 0)
        fs:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
        btn._fs = fs

        btn:SetScript("OnClick", function(s) if s._onClick then s._onClick() end end)
        btn:SetScript("OnEnter", function(s) if s._onClick then s._hl:SetAlpha(0.14) end end)
        btn:SetScript("OnLeave", function(s) s._hl:SetAlpha(0) end)

        -- 行内物品链接（|Hitem:..|h）支持：悬停看 tooltip、Shift+点击进聊天框（等同背包点物品）。
        -- 只对含链接的行有意义；普通行不会触发这些回调。
        if btn.SetHyperlinksEnabled then btn:SetHyperlinksEnabled(true) end
        btn:SetScript("OnHyperlinkClick", function(_, link, text, button)
            if _G.SetItemRef then SetItemRef(link, text, button) end
        end)
        btn:SetScript("OnHyperlinkEnter", function(s, link)
            if not _G.GameTooltip then return end
            GameTooltip:SetOwner(s, "ANCHOR_TOPLEFT")
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
        end)
        btn:SetScript("OnHyperlinkLeave", function() if _G.GameTooltip then GameTooltip:Hide() end end)
        return btn
    end
    for i = 1, f._max do f._lines[i] = makeLine(i) end

    local function hexcode(token)
        local hexv
        if token == "rare" then hexv = theme.rarity.rare.hex
        else hexv = (theme.c[token] and theme.c[token].hex) or "#ffffff" end
        return "ff" .. hexv:gsub("#", "")
    end
    local bodyHex = "ff" .. theme.c.textDim.hex:gsub("#", "")

    function f:Push(level, text, onClick)
        local tagTxt, tagColor
        if level == "warn" then
            tagTxt, tagColor = "[警告] ", "danger"
        elseif level == "raid" then
            tagTxt, tagColor = "[战团] ", "accent"
        else
            tagTxt, tagColor = "[系统] ", "rare"
        end
        table.insert(self._buffer, { tag = tagTxt, color = tagColor, text = text or "", onClick = onClick })
        while #self._buffer > self._max do table.remove(self._buffer, 1) end
        self:Render()
    end

    function f:Render()
        for i = 1, self._max do
            local line = self._lines[i]
            local item = self._buffer[i]
            if item then
                line._fs:SetText("|c" .. hexcode(item.color) .. item.tag .. "|r|c" .. bodyHex .. item.text .. "|r")
                line:Show()
                if item.onClick then
                    line:EnableMouse(true); line._onClick = item.onClick
                else
                    line:EnableMouse(false); line._onClick = nil; line._hl:SetAlpha(0)
                end
            else
                line:Hide(); line._onClick = nil; line._hl:SetAlpha(0)
            end
        end
    end
    return f
end
