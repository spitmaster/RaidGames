-- Core/UI/Popups.lua —— 邀请 / 信任门 / 倒计时遮罩入口 / 日志（契约 §9）
-- owner: wow-ui-developer
-- GL.UI:Invite(ctx) 邀请 StaticPopup（参与/围观）；GL.UI:ConfirmTrust(source,onYes) 导入信任门（默认拒绝）；
-- GL.UI:Countdown(n) 倒计时遮罩（3→2→1→GO! cdpop 弹入）；GL.UI:Log(level,text) 写日志条（兼订阅 LOG 事件）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local theme = GL.UI.theme
local W = GL.UI.Widgets

------------------------------------------------------------
-- GL.UI:Invite(ctx) —— 收到 Start 的邀请弹窗（参与 / 围观）
------------------------------------------------------------

function GL.UI:Invite(ctx)
    ctx = ctx or {}
    local gameName = "比赛"
    if GL.Games and GL.Games.Get and ctx.gameId then
        local def = GL.Games:Get(ctx.gameId)
        if def then gameName = def.name or gameName end
    end
    local hostName = ctx.host or "团长"
    local prizeTxt
    local p = ctx.prize or {}
    if p.mode == "loot" then prizeTxt = p.name or p.itemLink or "战利品"
    elseif p.mode == "custom" and p.text and p.text ~= "" then prizeTxt = p.text
    else prizeTxt = "友谊赛 · 无奖品" end

    StaticPopupDialogs["GAMELOBBY_INVITE"] = {
        text = string.format("|cfff0c46c%s|r 发起了 |cffffd98a%s|r\n奖品：%s\n\n参与比赛？", hostName, gameName, prizeTxt),
        button1 = "参 与",
        button2 = "围 观",
        button3 = "拒 绝",
        OnButton1 = function()
            if GL.Match and GL.Match.Join then GL.Match:Join() end
            GL.UI:Show(); GL.UI:ShowScreen("lobby")
        end,
        OnButton2 = function()
            if GL.Match and GL.Match.SetSpectator then GL.Match:SetSpectator() end
            GL.UI:Show(); GL.UI:ShowScreen("lobby")
        end,
        OnCancel = function() end,   -- 拒绝：什么都不做
        timeout = 30,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("GAMELOBBY_INVITE")
end

------------------------------------------------------------
-- GL.UI:ConfirmTrust(source, onYes) —— 导入代码信任门（默认拒绝；供 Import 用）
------------------------------------------------------------

function GL.UI:ConfirmTrust(source, onYes)
    StaticPopupDialogs["GAMELOBBY_TRUST"] = {
        text = string.format(
            "|cffd85a3a安全提示|r\n你正要从以下来源导入可执行的游戏代码：\n\n|cffffd98a%s|r\n\n只导入你信任的来源。是否继续？",
            tostring(source or "未知来源")),
        button1 = "我信任 · 导入",
        button2 = "取消",
        OnAccept = function() if onYes then onYes() end end,
        OnCancel = function() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        showAlert = true,
        preferredIndex = 3,
    }
    -- 默认聚焦取消按钮（默认拒绝）
    local dialog = StaticPopup_Show("GAMELOBBY_TRUST")
    return dialog
end

------------------------------------------------------------
-- GL.UI:Countdown(n) —— 倒计时遮罩（n=3/2/1/0=GO）。cdpop 弹入：scale 0.4→1.1→1。
-- 遮罩属于 PlayingScreen（Playing.lua 建 GL.UI._cdOverlay）；本函数驱动其数字与动画。
------------------------------------------------------------

-- cdpop 动画：用 OnUpdate 手动插值 scale + alpha
local function playCdPop(overlay)
    local num = overlay._num
    overlay._animT = 0
    overlay:SetScript("OnUpdate", function(o, elapsed)
        o._animT = o._animT + elapsed
        local t = o._animT
        local scale, alpha
        if t < 0.12 then
            -- 0→0.12s：scale 0.4→1.1，alpha 0→1
            local k = t / 0.12
            scale = 0.4 + 0.7 * k
            alpha = k
        elseif t < 0.28 then
            -- 回弹 1.1→1.0
            local k = (t - 0.12) / 0.16
            scale = 1.1 - 0.1 * k
            alpha = 1
        else
            scale = 1; alpha = 1
            o:SetScript("OnUpdate", nil)
        end
        -- 用字号近似 scale（Texture 无 scale，FontString 改字号）
        local base = (num._baseSize or theme.font.countdown)
        num:SetFont(theme.fontFile.display, base * scale, "")
        num:SetAlpha(alpha)
    end)
end

function GL.UI:Countdown(n)
    -- 确保 PlayingScreen 已建（遮罩在其上），并切到比赛屏
    self:Show()
    self:ShowScreen("playing")
    local overlay = self._cdOverlay
    if not overlay then return end

    -- 副标题：平局加赛时显示「加 赛 · 并列 N 人」，否则常规「准 备 · 极 速 按 键」。
    -- _tiebreakInfo 由 MATCH_TIE 设置，倒计时结束（GO）后清除，避免污染下一局正赛。
    if overlay._sub then
        if self._tiebreakInfo then
            overlay._sub:SetText(self._tiebreakInfo)
            overlay._sub:SetTextColor(theme:RGB("accent"))
        else
            overlay._sub:SetText("准 备 · 极 速 按 键")
            overlay._sub:SetTextColor(theme:RGB("textMute"))
        end
    end

    -- 倒计时中：锁定狂点钮显示「就 位」
    if self._smashButton then
        self._smashButton:SetActive(false)
        self._smashButton:SetPressedLabel(true)
    end

    if n and n > 0 then
        overlay._num._baseSize = theme.font.countdown
        overlay._num:SetText(tostring(n))
        overlay._num:SetTextColor(theme:RGB("accent"))
        W.GlowText(overlay._num, "accentGlow")
        overlay:Show()
        playCdPop(overlay)
    else
        -- GO!（转 success 绿，较小字）
        overlay._num._baseSize = theme.font.countdownGo
        overlay._num:SetText("GO!")
        overlay._num:SetTextColor(theme:RGB("success"))
        overlay._num:SetShadowColor(theme:RGB("success", 0.9)); overlay._num:SetShadowOffset(0, 0)
        overlay:Show()
        playCdPop(overlay)
        self._tiebreakInfo = nil   -- 加赛提示用完即清，下一局正赛恢复常规副标题
        -- 短暂展示后隐藏（MATCH_PLAY_BEGIN 也会隐藏，双保险）
        C_Timer.After(0.5, function() if overlay then overlay:Hide() end end)
    end
end

------------------------------------------------------------
-- GL.UI:Log(level, text) —— 写日志条（系统/战团/警告）
------------------------------------------------------------

function GL.UI:Log(level, text)
    local log = self._lobbyLog
    if log and log.Push then log:Push(level, text) end
end

------------------------------------------------------------
-- 事件订阅
------------------------------------------------------------

GL:Init(function()
    -- 收到 Start 邀请 → 弹邀请框
    GL:On("MATCH_INVITED", function(ctx) GL.UI:Invite(ctx) end)
    -- 倒计时事件 → 驱动遮罩
    GL:On("MATCH_COUNTDOWN", function(n) GL.UI:Countdown(n) end)
    -- 平局加赛 → 记录并列名单（战团日志）+ 设置加赛副标题（随后 MATCH_COUNTDOWN 会展示）。
    -- ctx.tiedNames 是归一化名数组；展示时用 ctx.players 还原可读名，缺失则退回归一化名。
    GL:On("MATCH_TIE", function(ctx)
        ctx = ctx or {}
        local tied = ctx.tiedNames or {}
        local names = {}
        for _, norm in ipairs(tied) do
            local p = ctx.players and ctx.players[norm]
            names[#names + 1] = (p and p.name) or norm
        end
        local n = #names
        GL.UI._tiebreakInfo = string.format("加 赛 · 并列 %d 人", n)
        if n > 0 then
            GL.UI:Log("raid", string.format("冠军并列：%s，进入加赛！", table.concat(names, "、")))
        else
            GL.UI:Log("raid", "冠军并列，进入加赛！")
        end
    end)
    -- LOG 事件 → 写日志条
    GL:On("LOG", function(level, text) GL.UI:Log(level, text) end)
    -- 比赛结束/关闭 → 隐藏倒计时遮罩（防残留）+ 把卡在比赛/结算屏的人退回大厅。
    -- 远端 host 关闭比赛时参与端只收 MATCH_CLOSED（无 MATCH_FINAL），若正停留在
    -- playing/results 会留着过期数据；Close 后 ctx 已 IDLE，退回 lobby 才是干净状态。
    GL:On("MATCH_CLOSED", function()
        if GL.UI._cdOverlay then GL.UI._cdOverlay:Hide() end
        if GL.UI._frame and GL.UI._frame:IsShown()
            and (GL.UI._current == "playing" or GL.UI._current == "results") then
            GL.UI:ShowScreen("lobby")
        end
    end)
end)
