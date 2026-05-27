-- Core/UI/History.lua —— 屏幕 5 战史 HistoryScreen（SPEC §4.7）
-- owner: wow-ui-developer
-- 5 个统计卡（总场次/胜场/胜率/奖品收获/平均分）+ 对战记录列表（可滚动，胜局金色高亮）。
-- 数据查 GL.Stats:GetSummary/GetHistory；清空调 GL.Stats:Clear（本屏弹二次确认）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = GL.UI.Widgets

-- 时间格式（仿设计稿 formatTime）
local function formatTime(ts)
    if not ts then return "" end
    local now = time()
    local diff = now - ts
    if diff < 60 then return "刚刚" end
    if diff < 3600 then return string.format("%d 分钟前", math.floor(diff / 60)) end
    local hm = date("%H:%M", ts)
    if diff < 86400 then return "今天 " .. hm end
    if diff < 2 * 86400 then return "昨天 " .. hm end
    local days = math.floor(diff / 86400)
    if days < 7 then return string.format("%d 天前", days) end
    return date("%m/%d %H:%M", ts)
end

------------------------------------------------------------
-- 单条战史行
------------------------------------------------------------
local function makeHistoryRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(34)
    W.PanelBG(r, "panel2"); W.MetalBorder(r, "thin")
    local winBar = W.Solid(r, "textMute", 1, "ARTWORK")
    winBar:SetWidth(3); winBar:SetPoint("TOPLEFT"); winBar:SetPoint("BOTTOMLEFT")
    r._winBar = winBar
    local winBG = W.Solid(r, "accent", 0, "BACKGROUND", 1)
    winBG:SetAllPoints(r); W.SetVGradient(winBG, {theme:RGB("accent", 0.1)}, {theme:RGB("accent", 0)})
    r._winBG = winBG

    local timeFs = W.Text(r, "mono", theme.font.small, "textMute")
    timeFs:SetPoint("LEFT", r, "LEFT", 10, 0); timeFs:SetWidth(86); timeFs:SetJustifyH("LEFT")
    r._time = timeFs
    local gameFs = W.Text(r, "display", theme.font.body, "text")
    gameFs:SetPoint("LEFT", timeFs, "RIGHT", 8, 0); gameFs:SetWidth(120); gameFs:SetJustifyH("LEFT")
    r._game = gameFs
    local prizeFs = W.Text(r, "ui", theme.font.body, "accent")
    prizeFs:SetPoint("LEFT", gameFs, "RIGHT", 8, 0); prizeFs:SetWidth(160); prizeFs:SetJustifyH("LEFT"); prizeFs:SetWordWrap(false)
    r._prize = prizeFs
    local winnerFs = W.Text(r, "ui", theme.font.body, "text")
    winnerFs:SetPoint("LEFT", prizeFs, "RIGHT", 8, 0); winnerFs:SetWidth(120); winnerFs:SetJustifyH("LEFT"); winnerFs:SetWordWrap(false)
    r._winner = winnerFs
    -- 结果徽章
    local badge = W.Text(r, "display", theme.font.btnSm, "textMute")
    badge:SetPoint("RIGHT", r, "RIGHT", -10, 0)
    r._badge = badge

    function r:SetRecord(h)
        local won = h.myResult and h.myResult.isWin
        self._time:SetText(formatTime(h.time))
        local glyph = ""
        if GL.Games and GL.Games.Get and h.gameId then
            local def = GL.Games:Get(h.gameId)
            if def and def.glyph then glyph = def.glyph .. " " end
        end
        self._game:SetText(string.format("%s%s · %d 人", glyph, h.gameName or h.gameId or "?", h.count or 0))
        -- 奖品
        local prize = h.prize or {}
        if prize.mode == "loot" then
            local rr, rg, rb = theme:Rarity(prize.rarity or "epic")
            self._prize:SetText(W.GlyphMarkup(W.GlyphTexture(prize.glyph) or W.ICON_LOOT, 14) .. " " .. (prize.name or prize.itemLink or "战利品"))
            self._prize:SetTextColor(rr, rg, rb)
        elseif prize.mode == "custom" and prize.text and prize.text ~= "" then
            self._prize:SetText(W.GlyphMarkup(W.ICON_PRIZE, 14) .. " " .. prize.text)
            self._prize:SetTextColor(theme:RGB("accent"))
        else
            self._prize:SetText("· 友谊赛")
            self._prize:SetTextColor(theme:RGB("textMute"))
        end
        -- 胜者
        local wname = h.winner or "—"
        self._winner:SetText("胜者 " .. wname .. (h.winnerScore and ("  " .. h.winnerScore) or ""))
        self._winner:SetTextColor(theme:RGB("textDim"))
        -- 结果徽章 + 高亮
        if won then
            self._badge:SetText("胜  " .. ((h.myResult and h.myResult.score) or 0) .. " 次")
            self._badge:SetTextColor(theme:RGB("accentGlow"))
            self._winBar:SetVertexColor(theme:RGB("accent"))
            self._winBG:SetAlpha(1)
        else
            local rank = h.myResult and h.myResult.rank
            self._badge:SetText(string.format("第 %s 名  %s 次", rank or "?", (h.myResult and h.myResult.score) or 0))
            self._badge:SetTextColor(theme:RGB("textMute"))
            self._winBar:SetVertexColor(theme:RGB("textMute"))
            self._winBG:SetAlpha(0)
        end
    end
    return r
end

local function Build(body)
    local s = CreateFrame("Frame", nil, body)
    s._rows = {}

    ------------------------------------------------------------
    -- ① 5 个统计卡
    ------------------------------------------------------------
    local statsRow = CreateFrame("Frame", nil, s)
    statsRow:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0)
    statsRow:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    statsRow:SetHeight(64)
    s._cards = {}
    for i = 1, 5 do
        local card = W.StatCard(statsRow)
        s._cards[i] = card
    end

    ------------------------------------------------------------
    -- ② 对战记录列表
    ------------------------------------------------------------
    local lbl = W.SectionLabel(s, "对战记录")
    lbl:SetPoint("TOPLEFT", statsRow, "BOTTOMLEFT", 0, -14)
    lbl:SetPoint("RIGHT", s, "RIGHT", -90, 0)
    s._recentExtra = lbl:AddExtra("最近 0 局", "textDim", "mono")
    s._lbl = lbl

    -- 清空按钮（右上）
    local clearBtn = W.Button(s, "清 空", "default", "sm")
    clearBtn:SetPoint("TOPRIGHT", statsRow, "BOTTOMRIGHT", 0, -10)
    clearBtn:SetScript("OnClick", function()
        if not (GL.Stats and GL.Stats.Clear) then return end
        StaticPopupDialogs["GAMELOBBY_CLEAR_HISTORY"] = {
            text = "确定清空全部对战记录？此操作不可撤销。",
            button1 = "清空", button2 = "取消",
            OnAccept = function()
                GL.Stats:Clear()
                s:Refresh()
            end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("GAMELOBBY_CLEAR_HISTORY")
    end)
    s._clearBtn = clearBtn

    local scroll = W.ScrollList(s)
    scroll:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    scroll:SetPoint("RIGHT", s, "RIGHT", -22, 0)   -- 留滚动条位
    scroll:SetPoint("BOTTOM", s, "BOTTOM", 0, 0)
    s._scroll = scroll

    ------------------------------------------------------------
    -- 布局统计卡（按宽度均分）
    ------------------------------------------------------------
    function s:LayoutCards()
        local total = statsRow:GetWidth()
        local cardW = (total - 4 * 8) / 5
        for i, card in ipairs(self._cards) do
            card:SetWidth(cardW)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", statsRow, "TOPLEFT", (i - 1) * (cardW + 8), 0)
        end
    end

    function s:Refresh()
        self:LayoutCards()
        -- 统计卡
        local sum = { total = 0, wins = 0, winRate = 0, prizeCount = 0, avgScore = 0 }
        if GL.Stats and GL.Stats.GetSummary then
            local ok, res = pcall(function() return GL.Stats:GetSummary() end)
            if ok and res then sum = res end
        end
        local wr = sum.winRate or 0
        self._cards[1]:Set(sum.total or 0, "总 场 次", "text")
        self._cards[2]:Set(sum.wins or 0, "胜 场", "gold")
        self._cards[3]:Set(string.format("%.0f%%", wr <= 1 and wr * 100 or wr), "胜 率", (wr >= 0.3 or wr >= 30) and "gold" or "text")
        self._cards[4]:Set(sum.prizeCount or 0, "奖 品 收 获", "rare")
        self._cards[5]:Set(math.floor(sum.avgScore or 0), "平 均 分", "text")

        -- 记录列表
        local hist = {}
        if GL.Stats and GL.Stats.GetHistory then
            local ok, res = pcall(function() return GL.Stats:GetHistory() end)
            if ok and res then hist = res end
        end
        self._recentExtra:SetText(string.format("最近 %d 局", #hist))
        local content = self._scroll:GetContent()
        content:SetWidth(self._scroll:GetWidth())
        for _, r in ipairs(self._rows) do r:Hide() end
        local y = 0
        for i, h in ipairs(hist) do
            local row = self._rows[i]
            if not row then row = makeHistoryRow(content); self._rows[i] = row end
            row:Show()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            row:SetRecord(h)
            y = y + 38
        end
        content:SetHeight(math.max(1, y))
    end

    function s._onShow() s:Refresh() end

    GL:On("MATCH_FINAL", function() if s:IsShown() then s:Refresh() end end)

    return s
end

GL.UI:RegisterScreen("history", Build)
