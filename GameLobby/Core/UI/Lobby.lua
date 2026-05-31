-- Core/UI/Lobby.lua —— 屏幕 1 大厅 LobbyScreen（SPEC §4.3）
-- owner: wow-ui-developer
-- 五分区：① 奖品区 ② 参赛者网格 ③ 选择游戏 ④ 操作行 ⑤ 日志条。
-- 订阅 ROSTER_CHANGED 刷参赛者、GAME_REGISTERED 刷游戏格；发起/准备调 GL.Match:*，身份查 GL.Roster:*。
-- 不写任何业务：选游戏只记 selectedId；准备/开始/发起一律调 Match（缺失时降级仍能 Show）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = GL.UI.Widgets

local PLAYER_COLS = 5
-- game-tile 最小宽：设计稿是 5 列 + minmax(170px)，880 宽窗体的 body 836，5 列 tile 宽 ≈ 159。
-- 把阈值压到 140，让 cols 计算公式 (gridW+10)/(W+10) 选到 5。
local TILE_COLS_W = 140
-- game-tile 高度（与 GameTile.lua 的 SetSize 高度保持一致）+ 行间距 = 行步长。
local TILE_H = 120
local TILE_GAP = 10
local TILE_STRIDE = TILE_H + TILE_GAP

local function Build(body)
    local s = CreateFrame("Frame", nil, body)
    s._selectedGame = nil
    s._playerCards = {}
    s._gameTiles = {}

    ------------------------------------------------------------
    -- ① 奖品区
    ------------------------------------------------------------
    local prizeLabel = W.SectionLabel(s, "本次战利品 · LOOT IN DISPUTE")
    prizeLabel:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0)
    prizeLabel:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    s._prizeLabel = prizeLabel

    -- 团长可编辑 LootCard（M1 默认建可编辑卡；纯团员视角时输入框只读由调用方控制）
    local isLeader = false
    if GL.Roster and GL.Roster.IsLeader then
        local ok, r = pcall(function() return GL.Roster:IsLeader() end)
        if ok then isLeader = r end
    end
    local lootCard = W.LootCard(s, isLeader)
    lootCard:SetPoint("TOPLEFT", prizeLabel, "BOTTOMLEFT", 0, -2)
    lootCard:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    lootCard:SetPrize({ mode = "friendly" })
    s._lootCard = lootCard
    -- 团长改奖品 → 通知 Match（缺失时仅本地暂存）
    lootCard:OnPrizeChanged(function(txt)
        s._customPrize = txt
        -- 更新 section-label 文案
        if txt and txt:gsub("%s", "") ~= "" then
            s._prizeLabel:SetLabel("本局奖品 · CUSTOM PRIZE")
        else
            s._prizeLabel:SetLabel("比赛模式 · MATCH MODE")
        end
    end)

    ------------------------------------------------------------
    -- ② 参赛者
    ------------------------------------------------------------
    local pLabel = W.SectionLabel(s, "参赛者")
    pLabel:SetPoint("TOPLEFT", lootCard, "BOTTOMLEFT", 0, -14)
    pLabel:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    s._pCountExtra = pLabel:AddExtra("0 人", "text", "mono")
    s._pReadyExtra = pLabel:AddExtra(W.ICON.ready .. " 0/0", "success", "mono")
    s._pLabel = pLabel

    local pGrid = CreateFrame("Frame", nil, s)
    pGrid:SetPoint("TOPLEFT", pLabel, "BOTTOMLEFT", 0, -2)
    pGrid:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    pGrid:SetHeight(80)
    s._pGrid = pGrid

    ------------------------------------------------------------
    -- ③ 选择游戏
    ------------------------------------------------------------
    local gLabel = W.SectionLabel(s, "选择游戏")
    gLabel:SetPoint("TOPLEFT", pGrid, "BOTTOMLEFT", 0, -14)
    gLabel:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    s._gLabel = gLabel

    -- 「+ 导入游戏」入口（纯插件用户装游戏，功能 9 / D14）：贴右上角，沿用窗体视觉
    local importBtn = W.Button(gLabel, "+ 导入游戏", "default", "sm")
    importBtn:SetPoint("RIGHT", gLabel, "RIGHT", -2, 1)
    importBtn:SetScript("OnClick", function()
        if GL.UI.ShowImport then GL.UI:ShowImport() end
    end)
    s._importBtn = importBtn
    -- section-label 的渐隐横线终点收到导入钮左侧，避免压住按钮
    if gLabel._line then
        gLabel._line:ClearAllPoints()
        gLabel._line:SetPoint("LEFT", gLabel._label, "RIGHT", 10, 0)
        gLabel._line:SetPoint("RIGHT", importBtn, "LEFT", -10, 0)
        W.SetVGradient(gLabel._line, {theme:RGB("divider")}, {theme:RGB("divider", 0)})
    end

    local gGrid = CreateFrame("Frame", nil, s)
    gGrid:SetPoint("TOPLEFT", gLabel, "BOTTOMLEFT", 0, -2)
    gGrid:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    gGrid:SetHeight(TILE_H)
    s._gGrid = gGrid

    ------------------------------------------------------------
    -- ④ 操作行
    ------------------------------------------------------------
    local actionRow = CreateFrame("Frame", nil, s)
    actionRow:SetPoint("TOPLEFT", gGrid, "BOTTOMLEFT", 0, -10)
    actionRow:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    actionRow:SetHeight(44)
    s._actionRow = actionRow

    local statusText = W.Text(actionRow, "ui", theme.font.body, "textMute")
    statusText:SetPoint("RIGHT", actionRow, "RIGHT", -200, 0)
    statusText:SetJustifyH("RIGHT")
    s._statusText = statusText

    -- 团员：准备按钮；团长：开始比赛按钮（同位，按身份显示其一）
    local readyBtn = W.Button(actionRow, "准 备", "primary")
    readyBtn:SetPoint("RIGHT", actionRow, "RIGHT", 0, 0)
    readyBtn:SetScript("OnClick", function()
        if not GL.Match then return end
        local ctx = GL.Match.GetContext and GL.Match:GetContext()
        local me = ctx and ctx.players and ctx.players[GL.Roster and GL.Roster:Me()]
        local ready = me and me.ready
        if GL.Match.SetReady then GL.Match:SetReady(not ready) end
    end)
    s._readyBtn = readyBtn

    local startBtn = W.Button(actionRow, "开 始 比 赛", "primary", "lg")
    startBtn:SetPoint("RIGHT", actionRow, "RIGHT", 0, 0)
    startBtn:SetScript("OnClick", function()
        if not GL.Match then return end
        -- 二段调度：INVITING 阶段 host 点击 = 「立即开局」(Begin)；IDLE = 发起 (Start)。
        local ctx = GL.Match.GetContext and GL.Match:GetContext()
        if ctx and ctx.phase == "INVITING" and ctx.isHost then
            if GL.Match.Begin then GL.Match:Begin() end
            return
        end
        if not s._selectedGame then return end
        if not GL.Match.Start then
            if GL.UI.Log then GL.UI:Log("warn", "比赛模块尚未就绪") end
            return
        end
        local opts = { prize = s:BuildPrize() }
        GL.Match:Start(s._selectedGame, opts)
    end)
    s._startBtn = startBtn

    ------------------------------------------------------------
    -- ⑤ 日志条
    ------------------------------------------------------------
    local log = W.LogStrip(s)
    log:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", 0, 0)
    log:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", 0, 0)
    s._log = log
    GL.UI._lobbyLog = log   -- 供 Popups 的 GL.UI:Log 写入

    ------------------------------------------------------------
    -- 数据组装：当前选择 → prize 结构（交给 Match:Start）
    ------------------------------------------------------------
    function s:BuildPrize()
        if self._lootPrize then return self._lootPrize end   -- 已绑定真实战利品
        local txt = self._customPrize
        if txt and txt:gsub("%s", "") ~= "" then
            return { mode = "custom", text = txt }
        end
        return { mode = "friendly" }
    end

    ------------------------------------------------------------
    -- 刷新参赛者网格
    ------------------------------------------------------------
    function s:RefreshPlayers()
        local members = {}
        if GL.Roster and GL.Roster.GetMembers then
            local ok, res = pcall(function() return GL.Roster:GetMembers() end)
            if ok and res then members = res end
        end
        -- 若有进行中比赛 ctx，用 ctx.players 的 ready/spectator 覆盖
        local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
        local players = ctx and ctx.players
        local me = GL.Roster and GL.Roster.Me and GL.Roster:Me()

        -- 回收旧卡
        for _, c in ipairs(self._playerCards) do c:Hide() end
        local count, readyCount, totalMembers = 0, 0, 0
        local i = 0
        local cardW = (self._pGrid:GetWidth() - (PLAYER_COLS - 1) * 6) / PLAYER_COLS
        if cardW < 60 then cardW = 130 end

        for _, m in ipairs(members) do
            i = i + 1
            local card = self._playerCards[i]
            if not card then
                card = W.PlayerCard(self._pGrid)
                self._playerCards[i] = card
            end
            local pdata = players and players[m.nameNorm]
            local data = {
                name = m.name, classFile = m.classFile,
                isSelf = (m.nameNorm == me) or m.isSelf,
                isLeader = m.isLeader,
                ready = pdata and pdata.ready,
                spectator = pdata and pdata.spectator,
                -- 右键推送目标：用归一化全名（带 -realm，WHISPER 认）。
                pushTarget = m.nameNorm or m.name,
            }
            card:SetData(data)
            card:Show()
            card:SetWidth(cardW)
            local col = (i - 1) % PLAYER_COLS
            local rowN = math.floor((i - 1) / PLAYER_COLS)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", self._pGrid, "TOPLEFT", col * (cardW + 6), -rowN * 38)
            count = count + 1
            if not m.isLeader then
                totalMembers = totalMembers + 1
                if data.ready then readyCount = readyCount + 1 end
            end
        end
        self._pGrid:SetHeight(math.max(38, (math.ceil(i / PLAYER_COLS)) * 38))
        self._pCountExtra:SetText(count .. " 人")
        self._pReadyExtra:SetText(W.ICON.ready .. string.format(" %d/%d", readyCount, totalMembers))
        self:RefreshActionRow(readyCount, totalMembers)
    end

    ------------------------------------------------------------
    -- 刷新操作行（按身份显示准备/开始 + 状态文案）
    ------------------------------------------------------------
    function s:RefreshActionRow(readyCount, totalMembers)
        local leader = false
        if GL.Roster and GL.Roster.IsLeader then
            local ok, r = pcall(function() return GL.Roster:IsLeader() end)
            if ok then leader = r end
        end
        local canInit = leader
        if GL.Roster and GL.Roster.CanInitiate then
            local ok, r = pcall(function() return GL.Roster:CanInitiate() end)
            if ok then canInit = r end
        end

        -- 奖品卡可编辑性随身份切换（可发起者可编辑：单人/团长/助理；其他成员只读）。
        -- 比赛进行中（非 IDLE）一律只读：奖品已定，参与端不应再改。
        local inGroup = GL.Roster and GL.Roster.InGroup and GL.Roster:InGroup()
        if self._lootCard and self._lootCard.SetEditable then
            local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
            local matchOngoing = ctx and ctx.phase and ctx.phase ~= "IDLE"
            self._lootCard:SetEditable(canInit and not matchOngoing)
        end

        if canInit then
            self._readyBtn:Hide(); self._startBtn:Show()
            -- 按钮文案随阶段切换：INVITING 阶段 host 显示「立即开局」(对应 Begin)。
            local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
            local inviting = ctx and ctx.phase == "INVITING" and ctx.isHost
            if self._startBtn.SetLabel then
                self._startBtn:SetLabel(inviting and "立 即 开 局" or "开 始 比 赛")
            end
            if not inGroup then
                -- 单人模式：无须等准备，直接开始。
                self._statusText:SetText(W.ICON.ready .. " 单人模式 · 准备开始")
                self._statusText:SetTextColor(theme:RGB("success"))
            else
                local allReady = totalMembers == 0 or readyCount >= totalMembers
                if allReady then
                    self._statusText:SetText(W.ICON.ready .. " 全员就绪")
                    self._statusText:SetTextColor(theme:RGB("success"))
                else
                    self._statusText:SetText(string.format("等待 %d 人准备", math.max(0, totalMembers - readyCount)))
                    self._statusText:SetTextColor(theme:RGB("textMute"))
                end
            end
            local selDef = self._selectedGame and GL.Games and GL.Games.Get and GL.Games:Get(self._selectedGame)
            local playable = self._selectedGame and (not selDef or not selDef.locked) and canInit
            self._startBtn:SetEnabledLook(playable and true or false)
        else
            self._startBtn:Hide(); self._readyBtn:Show()
            local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
            local me = GL.Roster and GL.Roster.Me and GL.Roster:Me()
            local myReady = ctx and ctx.players and me and ctx.players[me] and ctx.players[me].ready
            if myReady then
                self._statusText:SetText("已准备 · 等待团长开局")
                self._statusText:SetTextColor(theme:RGB("text"))
                self._readyBtn:SetLabel("取消准备")
            else
                self._statusText:SetText("请点击准备")
                self._statusText:SetTextColor(theme:RGB("textMute"))
                self._readyBtn:SetLabel("准 备")
            end
            self._readyBtn:SetEnabledLook(true)
        end
    end

    ------------------------------------------------------------
    -- 刷新游戏格
    ------------------------------------------------------------
    function s:RefreshGames()
        local list = {}
        if GL.Games and GL.Games.List then
            local ok, res = pcall(function() return GL.Games:List() end)
            if ok and res then list = res end
        end
        for _, t in ipairs(self._gameTiles) do t:Hide() end
        local cols = math.max(1, math.floor((self._gGrid:GetWidth() + TILE_GAP) / (TILE_COLS_W + TILE_GAP)))
        local tileW = (self._gGrid:GetWidth() - (cols - 1) * TILE_GAP) / cols
        local i = 0
        for _, def in ipairs(list) do
            i = i + 1
            local tile = self._gameTiles[i]
            if not tile then
                tile = W.GameTile(self._gGrid)
                self._gameTiles[i] = tile
                -- 左键选择：GameTile 的 OnClick 分发器在左键时调本回调；
                -- 右键由 GameTile 自身弹「导出字符串」菜单（不在此处理）。
                tile:SetOnSelect(function(btn)
                    s._selectedGame = btn._gameId
                    s:RefreshGameSelection()
                    s:RefreshActionRow()
                end)
            end
            tile._gameId = def.id
            tile._locked = def.locked
            -- 默认选中首个可玩游戏
            if not s._selectedGame and not def.locked then s._selectedGame = def.id end
            tile:SetGame(def, def.id == s._selectedGame)
            tile:Show()
            tile:SetWidth(tileW)
            local col = (i - 1) % cols
            local rowN = math.floor((i - 1) / cols)
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", self._gGrid, "TOPLEFT", col * (tileW + TILE_GAP), -rowN * TILE_STRIDE)
        end
        self._gGrid:SetHeight(math.max(TILE_H, math.ceil(i / cols) * TILE_STRIDE - TILE_GAP))
        self:RefreshGameSelection()
    end

    function s:RefreshGameSelection()
        for _, t in ipairs(self._gameTiles) do
            if t:IsShown() then t:SetSelected(t._gameId == self._selectedGame) end
        end
    end

    ------------------------------------------------------------
    -- 用 ctx 更新奖品区（收到 Start 后参与端展示）
    ------------------------------------------------------------
    function s:RefreshPrize()
        local ctx = GL.Match and GL.Match.GetContext and GL.Match:GetContext()
        if ctx and ctx.prize and ctx.phase and ctx.phase ~= "IDLE" then
            self._lootCard:SetPrize(ctx.prize)
            local mode = ctx.prize.mode
            self._prizeLabel:SetLabel(
                mode == "loot" and "本次战利品 · LOOT IN DISPUTE"
                or mode == "custom" and "本局奖品 · CUSTOM PRIZE"
                or "比赛模式 · MATCH MODE")
        end
    end

    -- 屏幕显示时整体刷新
    function s._onShow()
        s:RefreshGames()
        s:RefreshPlayers()
        s:RefreshPrize()
    end

    -- 事件订阅
    GL:On("ROSTER_CHANGED", function() if s:IsShown() then s:RefreshPlayers() end end)
    GL:On("GAME_REGISTERED", function() if s:IsShown() then s:RefreshGames() end end)
    GL:On("MATCH_STATE", function() if s:IsShown() then s:RefreshPlayers(); s:RefreshPrize() end end)

    return s
end

GL.UI:RegisterScreen("lobby", Build)
