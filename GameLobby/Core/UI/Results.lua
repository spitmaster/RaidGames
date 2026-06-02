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
    -- 胜利者横幅的"金光"：原来用 GlowHalo（径向圆纹理）铺在 420×96 的矩形 banner 上，
    -- 渲染成一个椭圆光斑漂在横幅下方（"莫名其妙的椭圆"）。去掉它，靠下面的 accent 描边
    -- + winName 的 GlowText 文字发光来表达"高光感"，不再用矩形泛光。
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

    -- 战利品超链接：所有人都能在结算屏把鼠标移到物品上看 tooltip，Shift+点击塞进聊天框
    -- （等同背包 Shift+点击物品的效果）。靠 award 帧承载 awText 里的 |Hitem:..|h 链接。
    award:EnableMouse(true)
    if award.SetHyperlinksEnabled then award:SetHyperlinksEnabled(true) end
    award:SetScript("OnHyperlinkClick", function(_, link, text, button)
        if _G.SetItemRef then SetItemRef(link, text, button) end   -- 内置：左键开 tooltip / Shift 左键进聊天框
    end)
    award:SetScript("OnHyperlinkEnter", function(self_, link)
        if not _G.GameTooltip then return end
        GameTooltip:SetOwner(self_, "ANCHOR_BOTTOM")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    award:SetScript("OnHyperlinkLeave", function()
        if _G.GameTooltip then GameTooltip:Hide() end
    end)

    ------------------------------------------------------------
    -- ③ final-board
    ------------------------------------------------------------
    -- fbLabel 用 award.BOTTOMLEFT +100 起、s.RIGHT -4 收（贴回 banner 视觉宽度，左对齐 banner.left）。
    local fbLabel = W.SectionLabel(s, "最终排名")
    fbLabel:SetPoint("TOPLEFT", award, "BOTTOMLEFT", 100, -12)
    fbLabel:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    s._fbLabel = fbLabel

    -- board 直接铺满 s 全宽（贴 s.LEFT，不再继承 fbLabel.left 那个 +100 偏移），
    -- 否则 board 整体偏右 → 单列 row 在 board 内居中也仍然视觉偏右。
    local board = CreateFrame("Frame", nil, s)
    board:SetPoint("TOP",   fbLabel, "BOTTOM", 0, -2)
    board:SetPoint("LEFT",  s, "LEFT",   4, 0)
    board:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    board:SetPoint("BOTTOM", s, "BOTTOM", 0, 46)
    s._board = board

    ------------------------------------------------------------
    -- ④ 操作行（仅「返回大厅」。原「再来一局」去掉：它并不直接开新局，只是回大厅，多余；
    --   想再玩在大厅重新发起即可。结算结果会写进大厅日志，可点击重开本窗口看排名。）
    ------------------------------------------------------------
    local closeBtn = W.Button(s, "返 回 大 厅", "default")
    closeBtn:SetPoint("BOTTOM", s, "BOTTOM", 0, 0)
    closeBtn:SetScript("OnClick", function()
        if GL.Match and GL.Match.Close then GL.Match:Close() end
        GL.UI:ShowScreen("lobby")
    end)
    s._closeBtn = closeBtn

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

        -- 归属条三态。loot 态优先用真实 itemLink（带 |Hitem:..|h，可悬停看 tooltip / Shift+点击进聊天框）。
        if prize.mode == "loot" then
            self._awardText:SetText(string.format("战 利 品 已 归 属    %s    →    %s",
                prize.itemLink or prize.name or "战利品", winnerName or "—"))
        elseif prize.mode == "custom" and prize.text and prize.text ~= "" then
            self._awardText:SetText(string.format("奖 品 已 归 属    %s    →    %s",
                prize.text, winnerName or "—"))
        else
            self._awardText:SetText(string.format("友 谊 赛 · 纯 切 磋    %s    赢 得 本 场 荣 誉",
                winnerName or "—"))
        end

        -- final-board（自适应列）。单列(n≤6)时把行宽限到 460 并水平居中——
        -- 否则 1 个 row 会被拉到整个 board 宽（约 560），单人结算看着像"贴着左边歪一条"。
        local n = #ranking
        local cols = (n <= 6) and 1 or (n <= 12) and 2 or 3
        local boardW = self._board:GetWidth()
        local colW = (boardW - (cols - 1) * 5) / cols
        if cols == 1 then colW = math.min(colW, 460) end
        local rowXOffset = (cols == 1) and ((boardW - colW) / 2) or 0
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
            row:SetPoint("TOPLEFT", self._board, "TOPLEFT",
                rowXOffset + col * (colW + 5), -rowN * 38)
            row:SetRow({ rank = i, name = label, classFile = classFile,
                         score = e.score or 0, cps = e.cps or ((e.score or 0) / duration), isSelf = isSelf })
        end
    end

    -- _onShow 优先用缓存的本场结果（从日志重开本窗口时，Match 已 Close → GetContext 是 IDLE 没排名）；
    -- 正常 MATCH_FINAL 也会先缓存再切屏，两路一致。
    function s._onShow()
        local ctx = GL.UI._lastResult or (GL.Match and GL.Match.GetContext and GL.Match:GetContext())
        s:Render(ctx)
    end

    GL:On("MATCH_FINAL", function(ctx)
        s:Render(ctx)
        GL.UI:Show()
        GL.UI:ShowScreen("results")
        -- 缓存本场结果（Match:Close 用 newIdleCtx 换表，旧子表不被 wipe，引用安全）。
        GL.UI._lastResult = {
            ranking = ctx.ranking, winner = ctx.winner, prize = ctx.prize,
            players = ctx.players, duration = ctx.duration, gameId = ctx.gameId,
        }
        -- 写一条可点击的结果日志：回大厅后可见，点击重开本结算窗口看排名。
        -- 战利品直接嵌进通告（itemLink 渲染成彩色物品名；LogStrip 支持悬停 tooltip / Shift+点击进聊天框）。
        local rk = ctx.ranking and ctx.ranking[1]
        local wname = ctx.winner or (rk and rk.name) or "—"
        local wscore = rk and rk.score or 0
        local prize = ctx.prize or {}
        local awardStr
        if prize.mode == "loot" and (prize.itemLink or prize.name) then
            awardStr = "夺得 " .. (prize.itemLink or prize.name)
        elseif prize.mode == "custom" and prize.text and prize.text ~= "" then
            awardStr = "夺得 " .. prize.text
        else
            awardStr = "夺冠"
        end
        GL.UI:Log("raid", string.format("本场结果：%s %s（%d 分）· 点击查看排名", wname, awardStr, wscore), function()
            GL.UI:Show(); GL.UI:ShowScreen("results")
        end)
    end)

    return s
end

GL.UI:RegisterScreen("results", Build)
