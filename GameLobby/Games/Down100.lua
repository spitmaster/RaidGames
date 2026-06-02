-- Games/Down100.lua —— 是男人就下 100 层（自绘档 canvas 游戏，elimination 玩到死）
-- owner: wow-addon-engineer
--
-- 玩法（玩到死，比下降层数）：
--   一行行平台恒定向上滚动；角色站在「安全平台」上会被它托着一起上移（骑乘）。
--   按 方向键/AD 左右移动，走出平台边缘 → 坠到下一行的安全平台；每落到一块新的安全平台 = 层数 +1。
--   死亡：①被托到画布顶被夹死 ②坠出画布底 ③落到带刺平台（扎死）。速度由慢到快（像断网恐龙）。
--
-- 行的两种类型（关键设计）：
--   · 安全行：一块较窄的安全平台（蓝），可落脚。
--   · 带刺行：只有一块带刺平台（红+三角刺）+ 大片空隙，**没有安全落脚点** → 必须从空隙穿过去（更难）。
--
-- 可解性保证（绝不无法继续，难但能通关）：
--   ★ 相邻安全行水平距离 ≤ reachX（一次下落够得着）。
--   ★ 禁止连续两行带刺；带刺行的刺**放在远离下落路径的一侧**（band 之外）→ 沿安全链直落必能绕开。
--
-- 不变量 #2（解耦）：只走 api。公平（§4）：用 api:Random 按种子生成。自包含（§6）：def 在 SOURCE 内。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "down100",
    name      = "是男人就下 100 层",
    version   = "1.5.0",
    glyph     = "Interface\\Icons\\Ability_Rogue_Sprint",
    descLines = { "踩平台往下，越深越高", "刺行无落脚，须穿空隙" },

    --==== 元数据 ====--
    tier        = "canvas",
    endMode     = "elimination",
    scoreOrder  = "desc",
    scoreUnit   = "层",
    duration    = 30,                        -- maxDuration（一般撑不到；越往后越快）
    needsKeyboard = true,
    seeded      = true,
    scoreCap    = function() return 999 end,
    locked      = false,

    --==== 生命周期 ====--

    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end
        local G = {}
        ctx._d100 = G

        local W = (cv.GetWidth and cv:GetWidth()) or 720
        local H = (cv.GetHeight and cv:GetHeight()) or 460
        if not W or W <= 0 then W = 720 end
        if not H or H <= 0 then H = 460 end
        G.W, G.H = W, H

        -- ===== 关卡参数 =====
        local ROW_GAP     = 120
        local SAFE_W_MIN, SAFE_W_MAX = 48, 74     -- 安全平台偏窄 → 落脚要更准
        local SPIKE_W_MIN, SPIKE_W_MAX = 80, 140  -- 带刺平台偏宽 → 更显眼、更凶
        local PLAT_H      = 12
        local CHAR_SZ     = 18
        local NUM_PLAT    = 8
        local SPIKE_PCT   = 42                     -- 带刺行占比（%）
        local reachX      = 90                     -- 相邻安全行水平最大偏移（按最快上滚留余量）
        local skipReach   = 72                     -- 跨过一行刺时，下一安全行离上一安全行的偏移（小→近直落）
        local MARGIN      = 14
        local SBW, SBH, LAYERS = 16, 12, 5
        G.ROW_GAP, G.PLAT_H, G.CHAR_SZ, G.SPIKE_PCT = ROW_GAP, PLAT_H, CHAR_SZ, SPIKE_PCT

        G.nextSpike = function() return api:Random(1, 100) <= SPIKE_PCT end

        -- ===== 生成一行（可解性核心，见 sim 验证）=====
        G.lastSafeX = (W - 110) * 0.5
        G.rowsSinceSafe = 0
        G.genRow = function(p, forceSafe)
            local makeSpike = (not forceSafe) and (G.rowsSinceSafe == 0) and G.nextSpike()
            if makeSpike then
                p.spikeW = api:Random(SPIKE_W_MIN, SPIKE_W_MAX)
                -- 下落时角色可能占据的水平 band（沿安全链直落）；刺放到 band 之外的一侧。
                local bandLo = G.lastSafeX - skipReach - CHAR_SZ
                local bandHi = G.lastSafeX + skipReach + SAFE_W_MAX + CHAR_SZ
                local rightLo = bandHi + MARGIN
                local rightHi = W - p.spikeW
                local leftHi  = bandLo - MARGIN - p.spikeW
                local canR = rightLo <= rightHi
                local canL = leftHi >= 0
                if canR and canL then
                    if (rightHi - rightLo) >= leftHi then p.spikeX = api:Random(math.ceil(rightLo), rightHi)
                    else p.spikeX = api:Random(0, math.floor(leftHi)) end
                elseif canR then p.spikeX = api:Random(math.ceil(rightLo), rightHi)
                elseif canL then p.spikeX = api:Random(0, math.floor(leftHi))
                else makeSpike = false end       -- 画布太窄放不下 → 退化成安全行
            end
            if makeSpike then
                p.hasSpike = true; p.safeW = 0    -- 带刺行：无安全落脚点
                G.rowsSinceSafe = G.rowsSinceSafe + 1
            else
                p.hasSpike = false
                p.safeW = api:Random(SAFE_W_MIN, SAFE_W_MAX)
                local span = (G.rowsSinceSafe == 0) and reachX or skipReach
                local maxX = W - p.safeW; if maxX < 0 then maxX = 0 end
                local lo = G.lastSafeX - span; if lo < 0 then lo = 0 end
                local hi = G.lastSafeX + span; if hi > maxX then hi = maxX end
                if hi < lo then hi = lo end
                p.safeX = api:Random(math.floor(lo), math.floor(hi))
                G.lastSafeX = p.safeX; G.rowsSinceSafe = 0
            end
        end

        -- ===== 对象池 =====
        local maxSpikes = math.ceil(SPIKE_W_MAX / SBW)
        G.plats = {}
        for i = 1, NUM_PLAT do
            local safeTex  = cv:CreateTexture(nil, "ARTWORK")
            local spikeTex = cv:CreateTexture(nil, "ARTWORK")
            local spikes = {}
            for s = 1, maxSpikes do
                local layers = {}
                for k = 1, LAYERS do
                    local t = cv:CreateTexture(nil, "OVERLAY")
                    t:SetColorTexture(0.93, 0.93, 0.97, 1)
                    t:Hide(); layers[k] = t
                end
                spikes[s] = layers
            end
            G.plats[i] = { safeTex = safeTex, spikeTex = spikeTex, spikes = spikes,
                           y = 0, safeX = 0, safeW = 0, spikeX = 0, spikeW = 0,
                           hasSpike = false, _landed = false }
        end

        G.placeRow = function(p)
            if p.safeW and p.safeW > 0 then
                local s = p.safeTex
                s:ClearAllPoints(); s:SetColorTexture(0.45, 0.62, 0.85, 1); s:SetSize(p.safeW, PLAT_H)
                s:SetPoint("TOPLEFT", cv, "TOPLEFT", p.safeX, -p.y); s:Show()
            else
                p.safeTex:Hide()
            end
            if p.hasSpike then
                local r = p.spikeTex
                r:ClearAllPoints(); r:SetColorTexture(0.45, 0.13, 0.11, 1); r:SetSize(p.spikeW, PLAT_H)
                r:SetPoint("TOPLEFT", cv, "TOPLEFT", p.spikeX, -p.y); r:Show()
                local nSp = math.floor(p.spikeW / SBW); if nSp < 1 then nSp = 1 end
                local layerH = SBH / LAYERS
                for si = 1, #p.spikes do
                    local spike = p.spikes[si]
                    if si <= nSp then
                        local cx = p.spikeX + (si - 0.5) * SBW
                        for k = 0, LAYERS - 1 do
                            local lw = SBW * (LAYERS - k) / LAYERS
                            if lw < 1 then lw = 1 end
                            local t = spike[k + 1]
                            t:ClearAllPoints(); t:SetSize(lw, layerH + 0.6)
                            t:SetPoint("TOPLEFT", cv, "TOPLEFT", cx - lw * 0.5, -(p.y - (k + 1) * layerH))
                            t:Show()
                        end
                    else
                        for k = 1, LAYERS do spike[k]:Hide() end
                    end
                end
            else
                p.spikeTex:Hide()
                for si = 1, #p.spikes do for k = 1, #p.spikes[si] do p.spikes[si][k]:Hide() end end
            end
        end

        -- ===== 初始铺行：起始行靠近屏幕底部（上方缓冲），上方行为安全行，下方行混入带刺行 =====
        local startY = H * 0.12
        local heroIdx = 1
        for i = 1, NUM_PLAT do
            if startY + (i - 1) * ROW_GAP <= H - 80 then heroIdx = i end
        end
        if heroIdx > NUM_PLAT - 2 then heroIdx = NUM_PLAT - 2 end
        if heroIdx < 1 then heroIdx = 1 end
        G.heroIdx = heroIdx
        for i = 1, NUM_PLAT do
            local p = G.plats[i]
            if i == heroIdx then
                p.hasSpike = false; p.safeW = 110; p.safeX = (W - p.safeW) * 0.5; p._landed = true
                G.lastSafeX = p.safeX; G.rowsSinceSafe = 0
            elseif i < heroIdx then
                G.genRow(p, true)                 -- 上方行：安全（装饰）
                p._landed = true
            else
                G.genRow(p, i == heroIdx + 1)      -- 下方行：可带刺；紧邻 hero 的一行强制安全起步
                p._landed = false
            end
            p.y = startY + (i - 1) * ROW_GAP
            G.placeRow(p)
        end

        -- ===== 角色 =====
        local hero = cv:CreateTexture(nil, "OVERLAY")
        hero:SetColorTexture(1.0, 0.82, 0.25, 1)
        hero:SetSize(CHAR_SZ, CHAR_SZ)
        G.hero = hero
        local hp = G.plats[heroIdx]
        G.heroX = hp.safeX + (hp.safeW - CHAR_SZ) * 0.5
        G.heroY = hp.y - CHAR_SZ
        G.vy    = 0
        G.placeHero = function()
            hero:ClearAllPoints()
            hero:SetPoint("TOPLEFT", cv, "TOPLEFT", G.heroX, -G.heroY)
        end
        G.placeHero()

        local dtext = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        dtext:SetPoint("CENTER", cv, "CENTER", 0, 0)
        dtext:SetTextColor(1.0, 0.35, 0.25)
        dtext:Hide()
        G.deathText = dtext

        G.depth   = 0
        G.elapsed = 0
        G.held    = { left = false, right = false }
        G.rest    = G.plats[heroIdx]
        G.dead    = false
        G.running = false
    end,

    start = function(ctx, api)
        if api:IsSpectator() then return end
        local cv = api:Canvas()
        local G = ctx._d100
        if not cv or not G then return end

        api:CaptureKeyboard(
            function(key)
                if key == "LEFT" or key == "A" or key == "NUMPAD4" then G.held.left = true
                elseif key == "RIGHT" or key == "D" or key == "NUMPAD6" then G.held.right = true end
            end,
            function(key)
                if key == "LEFT" or key == "A" or key == "NUMPAD4" then G.held.left = false
                elseif key == "RIGHT" or key == "D" or key == "NUMPAD6" then G.held.right = false end
            end
        )

        local MOVE_SPD = 420
        -- 慢启动→渐快（像断网恐龙）：开局慢给反应，RAMP 秒升满；越往后越易死 → 分数拉开避免平局。
        local SCROLL_MIN, SCROLL_MAX, RAMP = 90, 340, 20
        local GRAVITY  = 1100
        local MAX_VY   = 760
        local W, H     = G.W, G.H
        local CHAR_SZ  = G.CHAR_SZ
        local PLAT_H   = G.PLAT_H
        local ROW_GAP  = G.ROW_GAP

        local function over(x, w)
            return (w and w > 0) and (G.heroX < x + w) and (G.heroX + CHAR_SZ > x)
        end

        local function die(msg)
            if G.dead then return end
            G.dead = true; G.running = false
            if cv.SetScript then cv:SetScript("OnUpdate", nil) end
            if G.deathText then G.deathText:SetText(msg); G.deathText:Show() end
            api:Finish(G.depth)
        end
        G._die = die

        G.running = true
        cv:SetScript("OnUpdate", function(_, dt)
            if not G.running or G.dead then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.1 then dt = 0.1 end

            local scroll = SCROLL_MIN + (SCROLL_MAX - SCROLL_MIN) * math.min(1, G.elapsed / RAMP)
            G.elapsed = G.elapsed + dt

            if G.held.left  then G.heroX = G.heroX - MOVE_SPD * dt end
            if G.held.right then G.heroX = G.heroX + MOVE_SPD * dt end
            if G.heroX < 0 then G.heroX = 0 end
            if G.heroX > W - CHAR_SZ then G.heroX = W - CHAR_SZ end

            -- 上滚 + 回收。
            for i = 1, #G.plats do
                local p = G.plats[i]
                p.y = p.y - scroll * dt
                if p.y + PLAT_H < 0 then
                    local maxY = -1e9
                    for j = 1, #G.plats do if G.plats[j].y > maxY then maxY = G.plats[j].y end end
                    p.y = maxY + ROW_GAP
                    G.genRow(p)
                    p._landed = false
                    if G.rest == p then G.rest = nil end
                end
                G.placeRow(p)
            end

            -- 竖直：骑乘安全平台 / 自由下落 + 落点。
            if G.rest and over(G.rest.safeX, G.rest.safeW) then
                G.heroY = G.rest.y - CHAR_SZ
                G.vy = 0
            else
                G.rest = nil
                G.vy = G.vy + GRAVITY * dt
                if G.vy > MAX_VY then G.vy = MAX_VY end
                local prevBottom = G.heroY + CHAR_SZ
                G.heroY = G.heroY + G.vy * dt
                local newBottom = G.heroY + CHAR_SZ
                if G.vy >= 0 then
                    for i = 1, #G.plats do
                        local p = G.plats[i]
                        if prevBottom <= p.y + 2 and newBottom >= p.y then
                            if over(p.safeX, p.safeW) then
                                G.heroY = p.y - CHAR_SZ; G.vy = 0; G.rest = p
                                if not p._landed then
                                    p._landed = true; G.depth = G.depth + 1; api:SetScore(G.depth)
                                end
                                break
                            elseif p.hasSpike and over(p.spikeX, p.spikeW) then
                                die("扎 死 在 刺 上！"); return
                            end
                            -- 否则空隙：穿过去
                        end
                    end
                end
            end

            if G.heroY <= 0 then die("被 夹 死 在 顶 部！"); return end
            if G.heroY > H then die("坠 落 摔 死 了！"); return end
            G.placeHero()
        end)
    end,

    stop = function(ctx, api)
        local G = ctx._d100
        if G then G.running = false end
        local cv = api:Canvas()
        if cv then cv:SetScript("OnUpdate", nil) end
    end,

    teardown = function(ctx, api)
        local cv = api:Canvas()
        local G = ctx._d100
        if cv then cv:SetScript("OnUpdate", nil) end
        if G then
            G.running = false
            if G.plats then
                for i = 1, #G.plats do
                    local p = G.plats[i]
                    if p.safeTex  then p.safeTex:Hide() end
                    if p.spikeTex then p.spikeTex:Hide() end
                    if p.spikes then
                        for s = 1, #p.spikes do for k = 1, #p.spikes[s] do p.spikes[s][k]:Hide() end end
                    end
                end
            end
            if G.hero then G.hero:Hide() end
            if G.deathText then G.deathText:Hide() end
        end
        ctx._d100 = nil
    end,

    onTie = function(ctx, api) end,
    onResult = function(ctx) end,
}
]]

local def = assert(loadstring(SOURCE))()
def.code = SOURCE
local GAME_VERSION = def.version

local GL = _G.GameLobby
if GL and GL.RegisterGame then
    GL:RegisterGame(def)
elseif GL and GL._pendingGames then
    table.insert(GL._pendingGames, def)
else
    _G.GameLobby_pendingGames = _G.GameLobby_pendingGames or {}
    table.insert(_G.GameLobby_pendingGames, def)
end
