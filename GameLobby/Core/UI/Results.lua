-- Core/UI/Results.lua —— 屏幕 4 结算 ResultsScreen（SPEC §4.6）
-- owner: wow-ui-developer
-- winner-banner 胜利者横幅 + loot-award 归属条（三态）+ final-board 最终榜（含 CPS）+ [关闭]/[再来一局]。
-- 订阅 MATCH_FINAL（切到本屏并渲染 ctx.ranking/winner）；操作调 GL.Match:Rematch/Close。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = GL.UI.Widgets

local function Build(body)
    local s = CreateFrame("Frame", nil, body)
    s._finalRows = {}

    ------------------------------------------------------------
    -- ① winner-banner
    ------------------------------------------------------------
    local banner = CreateFrame("Frame", nil, s)
    banner:SetHeight(96)
    banner:SetPoint("TOP", s, "TOP", 0, 0)
    banner:SetWidth(420)
    W.PanelBG(banner, "panelInset")
    -- 径向金光底
    local halo = W.GlowHalo(banner, "accentDeep", 0.5)
    halo:SetSize(440, 110); halo:SetPoint("CENTER")
    -- accent 边框
    local bring = {}
    do
        local function edge() local t = W.Solid(banner, "accent", 1, "OVERLAY"); return t end
        local top, bottom, left, right = edge(), edge(), edge(), edge()
        top:SetHeight(1); top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
        bottom:SetHeight(1); bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT")
        left:SetWidth(1); left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT")
        right:SetWidth(1); right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT")
    end
    local winLabel = W.Text(banner, "display", theme.font.small, "accent")
    winLabel:SetPoint("TOP", banner, "TOP", 0, -12)
    winLabel:SetText("—  胜  利  者  —")
    local winName = W.Text(banner, "display", theme.font.winnerName, "accentGlow")
    winName:SetPoint("CENTER", banner, "CENTER", 0, 4)
    W.GlowText(winName, "accent")
    s._winName = winName
    local winScore = W.Text(banner, "ui", theme.font.body, "textDim")
    winScore:SetPoint("BOTTOM", banner, "BOTTOM", 0, 10)
    s._winScore = winScore

    ------------------------------------------------------------
    -- ② loot-award 归属条
    ------------------------------------------------------------
    local award = CreateFrame("Frame", nil, s)
    award:SetHeight(36)
    award:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", -100, -12)
    award:SetPoint("TOPRIGHT", banner, "BOTTOMRIGHT", 100, -12)
    -- 顶/底分隔线
    local awTop = W.Solid(award, "divider", 1, "ARTWORK"); awTop:SetHeight(1)
    awTop:SetPoint("TOPLEFT"); awTop:SetPoint("TOPRIGHT")
    local awBot = W.Solid(award, "divider", 1, "ARTWORK"); awBot:SetHeight(1)
    awBot:SetPoint("BOTTOMLEFT"); awBot:SetPoint("BOTTOMRIGHT")
    local awText = W.Text(award, "display", theme.font.body, "textDim")
    awText:SetPoint("CENTER")
    s._awardText = awText

    ------------------------------------------------------------
    -- ③ final-board
    ------------------------------------------------------------
    local fbLabel = W.SectionLabel(s, "最终排名")
    fbLabel:SetPoint("TOPLEFT", award, "BOTTOMLEFT", 100, -12)
    fbLabel:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    s._fbLabel = fbLabel

    local board = CreateFrame("Frame", nil, s)
    board:SetPoint("TOPLEFT", fbLabel, "BOTTOMLEFT", 0, -2)
    board:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    board:SetPoint("BOTTOM", s, "BOTTOM", 0, 46)
    s._board = board

    ------------------------------------------------------------
    -- ④ 操作行
    ------------------------------------------------------------
    local closeBtn = W.Button(s, "关 闭", "default")
    closeBtn:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", 0, 0)
    closeBtn:SetScript("OnClick", function()
        if GL.Match and GL.Match.Close then GL.Match:Close() end
        GL.UI:ShowScreen("lobby")
    end)
    s._closeBtn = closeBtn

    local rematchBtn = W.Button(s, "再 来 一 局", "primary")
    rematchBtn:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", 0, 0)
    rematchBtn:SetScript("OnClick", function()
        if GL.Match and GL.Match.Rematch then GL.Match:Rematch() end
    end)
    s._rematchBtn = rematchBtn

    ------------------------------------------------------------
    -- 渲染
    ------------------------------------------------------------
    function s:Render(ctx)
        ctx = ctx or {}
        local ranking = ctx.ranking or {}
        local prize = ctx.prize or { mode = "friendly" }
        local me = GL.Roster and GL.Roster.Me and GL.Roster:Me()
        local duration = ctx.duration or 10

        -- 胜者（ctx.winner 或榜首）
        local winnerName = ctx.winner
        local winnerEntry = ranking[1]
        if winnerEntry and not winnerName then winnerName = winnerEntry.name end
        local winnerClass = winnerEntry and winnerEntry.classFile
        -- 从 players 找职业色
        if ctx.players and winnerName then
            for norm, p in pairs(ctx.players) do
                if norm == winnerName or p.name == winnerName then winnerClass = p.classFile end
            end
        end
        local cr, cg, cb = theme:ClassColor(winnerClass)
        self._winName:SetText(winnerName or "—")
        self._winName:SetTextColor(cr, cg, cb)
        local hasPrize = prize.mode == "loot" or (prize.mode == "custom" and prize.text and prize.text ~= "")
        local wscore = winnerEntry and winnerEntry.score or 0
        self._winScore:SetFormattedText("以 %d 次按键%s", wscore, hasPrize and "夺得奖品" or "技压全场")

        -- 归属条三态
        if prize.mode == "loot" then
            self._awardText:SetText(string.format("战 利 品 已 归 属    %s    →    %s",
                prize.name or prize.itemLink or "战利品", winnerName or "—"))
        elseif prize.mode == "custom" and prize.text and prize.text ~= "" then
            self._awardText:SetText(string.format("奖 品 已 归 属    %s    →    %s",
                prize.text, winnerName or "—"))
        else
            self._awardText:SetText(string.format("友 谊 赛 · 纯 切 磋    %s    赢 得 本 场 荣 誉",
                winnerName or "—"))
        end

        -- final-board（自适应列）
        local n = #ranking
        local cols = (n <= 6) and 1 or (n <= 12) and 2 or 3
        local colW = (self._board:GetWidth() - (cols - 1) * 5) / cols
        for _, row in ipairs(self._finalRows) do row:Hide() end
        for i, e in ipairs(ranking) do
            local row = self._finalRows[i]
            if not row then row = W.RankRow(self._board, "final"); self._finalRows[i] = row end
            -- 职业色：ranking 项可能没带 classFile，从 players 补
            local classFile = e.classFile
            if not classFile and ctx.players then
                local p = ctx.players[e.name]
                if p then classFile = p.classFile end
            end
            local isSelf = (e.name == me)
            local label = e.name .. (isSelf and "  (你)" or "")
            row:Show(); row:SetWidth(colW)
            local col = (i - 1) % cols
            local rowN = math.floor((i - 1) / cols)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self._board, "TOPLEFT", col * (colW + 5), -rowN * 38)
            row:SetRow({ rank = i, name = label, classFile = classFile,
                         score = e.score or 0, cps = e.cps or ((e.score or 0) / duration), isSelf = isSelf })
        end

        -- 团长才显示再来一局
        local leader = false
        if GL.Roster and GL.Roster.IsLeader then
            local ok, r = pcall(function() return GL.Roster:IsLeader() end)
            if ok then leader = r end
        end
        self._rematchBtn:SetShown(leader)
    end

    function s._onShow()
        local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
        s:Render(ctx)
    end

    GL:On("MATCH_FINAL", function(ctx)
        s:Render(ctx)
        GL.UI:Show()
        GL.UI:ShowScreen("results")
    end)

    return s
end

GL.UI:RegisterScreen("results", Build)
