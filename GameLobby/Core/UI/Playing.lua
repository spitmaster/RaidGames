-- Core/UI/Playing.lua —— 屏幕 3 比赛 PlayingScreen（SPEC §4.5）+ 倒计时遮罩入口（§4.4）
-- owner: wow-ui-developer
-- 通用「计时内刷分」比赛屏：castbar + play-hero（三列：奖品 | 狂点钮 | 计数）+ 实时排名 live-board。
-- 由 ctx 驱动，对 SpeedClick 之外的游戏也复用。狂点钮句柄经 GL.UI:SmashButton() 暴露给游戏 api 挂输入。
-- 订阅 MATCH_PLAY_BEGIN/END、LIVE_SCORE、MATCH_COUNTDOWN。UI 不计分，分数来自 LIVE_SCORE/ctx.scores。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = GL.UI.Widgets

local function Build(body)
    local s = CreateFrame("Frame", nil, body)
    s._liveRows = {}
    s._localScores = {}   -- nameNorm → score（实时累积，来自 LIVE_SCORE）

    ------------------------------------------------------------
    -- ① castbar
    ------------------------------------------------------------
    local castbar = W.Castbar(s)
    castbar:SetPoint("TOPLEFT", s, "TOPLEFT", 4, 0)
    castbar:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    castbar:SetLabel("极 速 按 键")
    castbar:SetProgress(1, 0)
    s._castbar = castbar

    ------------------------------------------------------------
    -- ② play-hero（三列）
    ------------------------------------------------------------
    local hero = CreateFrame("Frame", nil, s)
    hero:SetPoint("TOPLEFT", castbar, "BOTTOMLEFT", 0, -10)
    hero:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    hero:SetHeight(250)
    s._hero = hero

    -- 中：狂点钮（居中）
    local smash = W.SmashButton(hero)
    smash:SetPoint("CENTER", hero, "CENTER", 0, 6)
    s._smash = smash
    GL.UI._smashButton = smash

    -- 左：迷你奖品卡
    local miniLoot = CreateFrame("Frame", nil, hero)
    miniLoot:SetSize(200, 48)
    miniLoot:SetPoint("LEFT", hero, "LEFT", 8, 0)
    W.PanelBG(miniLoot, "panelInset"); W.MetalBorder(miniLoot, "thin")
    local mlBar = W.Solid(miniLoot, "textMute", 1, "ARTWORK")
    mlBar:SetWidth(3); mlBar:SetPoint("TOPLEFT"); mlBar:SetPoint("BOTTOMLEFT")
    miniLoot._bar = mlBar
    local mlGlyph = W.Text(miniLoot, "display", 16, "accent")
    mlGlyph:SetPoint("LEFT", miniLoot, "LEFT", 10, 0)
    miniLoot._glyph = mlGlyph
    local mlName = W.Text(miniLoot, "display", theme.font.body, "accent")
    mlName:SetPoint("TOPLEFT", mlGlyph, "TOPRIGHT", 8, -2)
    mlName:SetPoint("RIGHT", miniLoot, "RIGHT", -6, 0)
    mlName:SetJustifyH("LEFT"); mlName:SetWordWrap(false)
    miniLoot._name = mlName
    local mlSub = W.Text(miniLoot, "ui", theme.font.tiny, "textMute")
    mlSub:SetPoint("TOPLEFT", mlName, "BOTTOMLEFT", 0, -2)
    miniLoot._sub = mlSub
    s._miniLoot = miniLoot

    -- 右：我的计数
    local rightCol = CreateFrame("Frame", nil, hero)
    rightCol:SetSize(180, 100)
    rightCol:SetPoint("RIGHT", hero, "RIGHT", -8, 0)
    local myCount = W.Text(rightCol, "mono", theme.font.myCount, "accentGlow")
    myCount:SetPoint("CENTER", rightCol, "CENTER", 0, 12)
    myCount:SetText("0")
    W.GlowText(myCount, "accent")
    s._myCount = myCount
    local myLabel = W.Text(rightCol, "display", theme.font.small, "textMute")
    myLabel:SetPoint("TOP", myCount, "BOTTOM", 0, -8)
    myLabel:SetText("我的次数 · 第 — 名")
    s._myLabel = myLabel

    ------------------------------------------------------------
    -- ③ 实时排名 live-board
    ------------------------------------------------------------
    local lbLabel = W.SectionLabel(s, "实时排名")
    lbLabel:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, -8)
    lbLabel:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    s._lbCountExtra = lbLabel:AddExtra("0 人激战", "textDim", "mono")
    s._lbLabel = lbLabel

    local board = CreateFrame("Frame", nil, s)
    board:SetPoint("TOPLEFT", lbLabel, "BOTTOMLEFT", 0, -2)
    board:SetPoint("RIGHT", s, "RIGHT", -4, 0)
    board:SetPoint("BOTTOM", s, "BOTTOM", 0, 0)
    s._board = board

    ------------------------------------------------------------
    -- 倒计时遮罩（盖在比赛布局之上，§4.4）
    ------------------------------------------------------------
    local overlay = CreateFrame("Frame", nil, s)
    overlay:SetAllPoints(s)
    overlay:SetFrameLevel(s:GetFrameLevel() + 20)
    overlay:EnableMouse(true)   -- 吃掉点击，避免倒计时中误点狂点钮
    local odark = W.Solid(overlay, nil, 0.8, "BACKGROUND")
    odark:SetAllPoints(overlay); odark:SetVertexColor(0, 0, 0, 0.8)
    local cdNum = W.Text(overlay, "display", theme.font.countdown, "accent")
    cdNum:SetPoint("CENTER", overlay, "CENTER", 0, 20)
    overlay._num = cdNum
    local cdSub = W.Text(overlay, "display", theme.font.small, "textMute")
    cdSub:SetPoint("TOP", cdNum, "BOTTOM", 0, -16)
    cdSub:SetText("准 备 · 极 速 按 键")
    overlay._sub = cdSub   -- 暴露副标题，供平局加赛改成「加 赛」提示（Popups 驱动）
    overlay:Hide()
    s._overlay = overlay
    GL.UI._cdOverlay = overlay

    ------------------------------------------------------------
    -- 渲染：奖品 / 计数 / 实时榜
    ------------------------------------------------------------
    function s:RenderPrize(ctx)
        local prize = ctx and ctx.prize or { mode = "friendly" }
        if prize.mode == "loot" then
            local r, g, b = theme:Rarity(prize.rarity or "epic")
            self._miniLoot:Show()
            self._miniLoot._bar:SetVertexColor(r, g, b)
            self._miniLoot._glyph:SetText(W.GlyphMarkup(W.GlyphTexture(prize.glyph) or W.ICON_LOOT, 18))
            self._miniLoot._name:SetText(prize.name or prize.itemLink or "战利品"); self._miniLoot._name:SetTextColor(r, g, b)
            self._miniLoot._sub:SetText("争 夺 中")
        elseif prize.mode == "custom" and prize.text and prize.text ~= "" then
            local r, g, b = theme:RGB("accent")
            self._miniLoot:Show()
            self._miniLoot._bar:SetVertexColor(r, g, b)
            self._miniLoot._glyph:SetText(W.GlyphMarkup(W.ICON_PRIZE, 18))
            self._miniLoot._name:SetText(prize.text); self._miniLoot._name:SetTextColor(r, g, b)
            self._miniLoot._sub:SetText("争 夺 中")
        else
            -- 友谊赛：隐藏奖品卡，显示「友 谊 赛」
            self._miniLoot:Hide()
        end
    end

    function s:RenderBoard(ctx)
        -- 分数源：优先 ctx.scores，否则本地累积
        local scores = (ctx and ctx.scores) or self._localScores
        local players = ctx and ctx.players or {}
        local me = GL.Roster and GL.Roster.Me and GL.Roster:Me()

        -- 收集非围观者，按分降序
        local arr = {}
        for norm, p in pairs(players) do
            if not p.spectator then
                table.insert(arr, { norm = norm, name = p.name, classFile = p.classFile,
                                    score = scores[norm] or 0, isSelf = (norm == me) or p.isSelf })
            end
        end
        -- 若没有 ctx.players（业务层未就绪），退而用 scores 的 key
        if #arr == 0 then
            for norm, sc in pairs(scores) do
                table.insert(arr, { norm = norm, name = norm, score = sc, isSelf = (norm == me) })
            end
        end
        table.sort(arr, function(a, b) return a.score > b.score end)

        local n = #arr
        local maxScore = 1
        for _, e in ipairs(arr) do if e.score > maxScore then maxScore = e.score end end
        -- 自适应列：≤6→1 / ≤12→2 / 否则 3
        local cols = (n <= 6) and 1 or (n <= 12) and 2 or 3
        local colW = (self._board:GetWidth() - (cols - 1) * 4) / cols

        for _, row in ipairs(self._liveRows) do row:Hide() end
        local myRank = nil
        for i, e in ipairs(arr) do
            local row = self._liveRows[i]
            if not row then
                row = W.RankRow(self._board, "live")
                self._liveRows[i] = row
            end
            row:Show(); row:SetWidth(colW)
            local col = (i - 1) % cols
            local rowN = math.floor((i - 1) / cols)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self._board, "TOPLEFT", col * (colW + 4), -rowN * 32)
            row:SetRow({ rank = i, name = e.name, classFile = e.classFile,
                         score = e.score, isSelf = e.isSelf, maxScore = maxScore })
            if e.isSelf then myRank = i end
        end
        self._lbCountExtra:SetText(n .. " 人激战")

        -- 我的计数 + 名次
        local myScore = me and scores[me] or 0
        self._myCount:SetText(tostring(myScore))
        self._myLabel:SetText(string.format("我的次数 · 第 %s 名", myRank and tostring(myRank) or "—"))
    end

    ------------------------------------------------------------
    -- 计时刷新（OnUpdate 仅本地展示 castbar；剩余秒来自 ctx.remaining，否则本地估算）
    ------------------------------------------------------------
    s._playing = false
    s:SetScript("OnUpdate", function(self2, elapsed)
        if not self2._playing then return end
        local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
        local dur = (ctx and ctx.duration) or self2._duration or 10
        local remaining
        if ctx and ctx.remaining then
            remaining = ctx.remaining
        elseif self2._endTime then
            remaining = self2._endTime - GetTime()
        else
            remaining = dur
        end
        if remaining < 0 then remaining = 0 end
        castbar:SetProgress(remaining / dur, remaining)
        if remaining <= 0 then self2._playing = false end
    end)

    function s._onShow()
        local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
        s:RenderPrize(ctx)
        s:RenderBoard(ctx)
        s._castbar:SetLabel((ctx and ctx.gameId == "speedclick") and "极 速 按 键" or "比 赛 进 行")
    end

    ------------------------------------------------------------
    -- 事件订阅
    ------------------------------------------------------------
    GL:On("MATCH_PLAY_BEGIN", function(ctx)
        wipe(s._localScores)
        s._duration = (ctx and ctx.duration) or 10
        s._endTime = GetTime() + s._duration
        s._playing = true
        s._smash:SetActive(true)
        s._smash:SetPressedLabel(false)   -- 还原"点击"（上一局可能停在"时间到"）
        -- 还原 castbar 左标签（上一局 PLAY_END 改成了"结算中…"，再来一局要复位）
        s._castbar:SetLabel((ctx and ctx.gameId == "speedclick") and "极 速 按 键" or "比 赛 进 行")
        if s._overlay then s._overlay:Hide() end
        s:RenderPrize(ctx)
        s:RenderBoard(ctx)
    end)
    GL:On("MATCH_PLAY_END", function(ctx)
        s._playing = false
        s._smash:SetActive(false)
        -- 读秒归零后到结算屏之间有个收分窗口（单人 ~0.4s / 组队 ~3s）。给出明确过渡提示，
        -- 否则玩家看到时间到、按钮变灰却没反馈，会以为卡死了。
        s._smash:SetCenterLabel("时间到")
        s._castbar:SetProgress(0, 0)
        s._castbar:SetLabel("时间到 · 结算中…")
        s:RenderBoard(ctx)
    end)
    GL:On("LIVE_SCORE", function(nameNorm, score)
        if nameNorm then s._localScores[nameNorm] = score end
        if s:IsShown() then
            local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
            s:RenderBoard(ctx)
        end
    end)

    return s
end

GL.UI:RegisterScreen("playing", Build)

------------------------------------------------------------
-- GL.UI:SmashButton() —— 暴露狂点钮句柄给游戏 api（契约 §6/§9）
-- PlayingScreen 未构建时返回 nil（游戏侧应判空）。
------------------------------------------------------------
function GL.UI:SmashButton()
    return self._smashButton
end
