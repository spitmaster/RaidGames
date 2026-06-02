-- Games/Up100.lua —— 是男人就上 100 层（自绘档 canvas 游戏，Doodle Jump 式弹跳）
-- owner: wow-addon-engineer
--
-- 玩法：小角色自动弹跳往上爬，按 方向键/AD 左右移动对准上方平台落脚；每登上更高一层 = 层数 +1。
--   ★ 带刺平台「只要碰到就死」（不是落上才死）—— 任何方向的接触都判死（touch-death）。
--   ★ 屏幕底部有一条不断上涨且越来越快的「地板/深渊」追着你 —— 爬慢了会被追上吞掉。层数高者胜。
--
-- 层的结构（每层都可落脚 + 可选一块带刺平台）：
--   · 每层都有一块「安全平台」（土黄）→ 永远能继续往上跳（可解性）。
--   · 部分层额外有一块「带刺平台」（红+三角刺），放在远离安全链落脚走廊的一侧 → 沿安全链跳不会碰到。
--
-- 可解性保证（两趟生成 + 走廊外放刺，已 sim 验证）：先生成安全链（相邻层水平偏移 ≤ reachX），
--   再把刺放到「角色沿安全链可达包络」之外 → 难但永远过得去。
--
-- 不变量 #2（解耦）：只走 api。公平（§4）：api:Random 按种子两趟生成，各端一致。自包含（§6）：def 在 SOURCE。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "up100",
    name      = "是男人就上 100 层",
    version   = "1.3.0",
    glyph     = "Interface\\Icons\\Ability_Hunter_Pathfinding",
    descLines = { "弹跳往上，地板在追", "碰刺即死，越高越强" },

    --==== 元数据 ====--
    tier        = "canvas",
    endMode     = "elimination",
    scoreOrder  = "desc",
    scoreUnit   = "层",
    duration    = 30,
    needsKeyboard = true,
    seeded      = true,
    scoreCap    = function() return 999 end,
    locked      = false,

    --==== 生命周期 ====--

    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end
        local W = cv:GetWidth();  if not W or W <= 0 then W = 760 end
        local H = cv:GetHeight(); if not H or H <= 0 then H = 460 end

        local G = {}
        G.cv = cv
        G.W, G.H = W, H

        --==== 调参 ====--
        G.charSize = 18
        G.pltW     = 78
        G.pltH     = 10
        G.gapY     = 64
        G.scrollY  = H * 0.46
        local SBW, SBH, LAYERS = 14, 12, 5
        G.SBW, G.SBH, G.LAYERS = SBW, SBH, LAYERS
        G.SPIKE_HIT = SBH                        -- 刺的判定额外向上加 SBH（覆盖三角刺，碰到即死）

        --==== 两趟生成关卡（各端一致）====--
        local layers = 220
        local reachX = 60                        -- 安全链相邻层水平偏移（小→走廊窄→好放刺）
        local CHAR = G.charSize
        local SPIKE_PCT = 48
        local MARGIN = 8
        local minPx, maxPx = 8, W - G.pltW - 8
        if maxPx < minPx then maxPx = minPx end
        G.layers = {}
        -- 趟 1：安全链。
        local lastSafe = math.floor((minPx + maxPx) / 2)
        for i = 1, layers do
            local lo = math.max(minPx, lastSafe - reachX)
            local hi = math.min(maxPx, lastSafe + reachX)
            if hi < lo then hi = lo end
            local sx = (i == 1) and lastSafe or api:Random(math.floor(lo), math.floor(hi))
            G.layers[i] = { worldY = i * G.gapY, safeX = sx, tier = i, hasSpike = false, spikeX = 0 }
            lastSafe = sx
        end
        -- 趟 2：在「角色沿安全链可达包络」之外放刺（前 2 层不放，给安全起步）。
        for i = 3, layers do
            if api:Random(1, 100) <= SPIKE_PCT then
                local lo, hi = 1e9, -1e9
                for j = math.max(1, i - 1), math.min(layers, i + 1) do
                    local c1 = G.layers[j].safeX - reachX - CHAR
                    local c2 = G.layers[j].safeX + G.pltW + reachX + CHAR
                    if c1 < lo then lo = c1 end
                    if c2 > hi then hi = c2 end
                end
                local rightLo = math.ceil(hi) + MARGIN
                local rightHi = W - G.pltW
                local leftHi  = math.floor(lo) - MARGIN - G.pltW
                local canR = rightLo <= rightHi
                local canL = leftHi >= 0
                if canR and canL then
                    if (rightHi - rightLo) >= leftHi then G.layers[i].spikeX = api:Random(rightLo, rightHi)
                    else G.layers[i].spikeX = api:Random(0, leftHi) end
                    G.layers[i].hasSpike = true
                elseif canR then G.layers[i].spikeX = api:Random(rightLo, rightHi); G.layers[i].hasSpike = true
                elseif canL then G.layers[i].spikeX = api:Random(0, leftHi); G.layers[i].hasSpike = true end
            end
        end

        --==== 角色 ====--
        local ch = cv:CreateTexture(nil, "OVERLAY")
        ch:SetColorTexture(0.30, 0.85, 1.0, 1.0)
        ch:SetSize(G.charSize, G.charSize)
        G.charTex = ch

        --==== 对象池：每槽 = 安全平台 + 刺平台 + 一排三角刺 ====--
        local poolN = math.ceil(H / G.gapY) + 3
        local maxSpikes = math.ceil(G.pltW / SBW)
        G.pool = {}
        for i = 1, poolN do
            local safeTex = cv:CreateTexture(nil, "ARTWORK")
            safeTex:SetColorTexture(0.55, 0.45, 0.30, 1.0)
            safeTex:SetSize(G.pltW, G.pltH); safeTex:Hide()
            local spikeTex = cv:CreateTexture(nil, "ARTWORK")
            spikeTex:SetColorTexture(0.45, 0.13, 0.11, 1.0)
            spikeTex:SetSize(G.pltW, G.pltH); spikeTex:Hide()
            local spikes = {}
            for s = 1, maxSpikes do
                local lyr = {}
                for k = 1, LAYERS do
                    local t = cv:CreateTexture(nil, "OVERLAY")
                    t:SetColorTexture(0.93, 0.93, 0.97, 1); t:Hide()
                    lyr[k] = t
                end
                spikes[s] = lyr
            end
            G.pool[i] = { safeTex = safeTex, spikeTex = spikeTex, spikes = spikes }
        end

        -- 把第 slot 个池槽画成 layer L（y = 平台底距画布底，向上为正）。
        G.drawSlot = function(slot, L, y)
            local s = slot.safeTex
            s:ClearAllPoints(); s:SetPoint("BOTTOMLEFT", cv, "BOTTOMLEFT", L.safeX, y); s:Show()
            if L.hasSpike then
                local r = slot.spikeTex
                r:ClearAllPoints(); r:SetPoint("BOTTOMLEFT", cv, "BOTTOMLEFT", L.spikeX, y); r:Show()
                local nSp = math.floor(G.pltW / SBW); if nSp < 1 then nSp = 1 end
                local layerH = SBH / LAYERS
                local base = y + G.pltH
                for si = 1, #slot.spikes do
                    local spk = slot.spikes[si]
                    if si <= nSp then
                        local cx = L.spikeX + (si - 0.5) * SBW
                        for k = 0, LAYERS - 1 do
                            local lw = SBW * (LAYERS - k) / LAYERS
                            if lw < 1 then lw = 1 end
                            local t = spk[k + 1]
                            t:ClearAllPoints(); t:SetSize(lw, layerH + 0.6)
                            t:SetPoint("BOTTOMLEFT", cv, "BOTTOMLEFT", cx - lw * 0.5, base + k * layerH)
                            t:Show()
                        end
                    else
                        for k = 1, LAYERS do spk[k]:Hide() end
                    end
                end
            else
                slot.spikeTex:Hide()
                for si = 1, #slot.spikes do for k = 1, #slot.spikes[si] do slot.spikes[si][k]:Hide() end end
            end
        end
        G.hideSlot = function(slot)
            slot.safeTex:Hide(); slot.spikeTex:Hide()
            for si = 1, #slot.spikes do for k = 1, #slot.spikes[si] do slot.spikes[si][k]:Hide() end end
        end

        --==== 初始姿态：角色站在第一层，地板从底部起 ====--
        G.camY = 0
        local p1 = G.layers[1]
        G.charX = p1.safeX + (G.pltW - G.charSize) / 2
        G.charWorldY = p1.worldY + G.pltH
        G.vy = 0
        G.maxTier = 1
        G.elapsed = 0
        G.held = { left = false, right = false }
        G.dead = false

        local dtext = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        dtext:SetPoint("CENTER", cv, "CENTER", 0, 0)
        dtext:SetTextColor(1.0, 0.35, 0.25)
        dtext:Hide()
        G.deathText = dtext

        api.G = G
    end,

    start = function(ctx, api)
        if api:IsSpectator() then return end
        local G = api.G
        if not G or not G.cv then return end

        api:CaptureKeyboard(
            function(key)
                if key == "LEFT" or key == "A" then G.held.left = true
                elseif key == "RIGHT" or key == "D" then G.held.right = true end
            end,
            function(key)
                if key == "LEFT" or key == "A" then G.held.left = false
                elseif key == "RIGHT" or key == "D" then G.held.right = false end
            end
        )

        local W, H = G.W, G.H
        local cs, pltW, pltH, gapY = G.charSize, G.pltW, G.pltH, G.gapY
        local SPIKE_HIT = G.SPIKE_HIT
        local MOVE = 340
        local GRAVITY = 1500
        local JUMP = 520               -- 弹跳 ~1.4 层：稳稳够到上一层、几乎不过冲（便于刺的走廊保证）
        -- 地板上涨「慢→快」：越往后追得越凶 → 爬慢者被吞，分数拉开避免平局。
        local AS_MIN, AS_MAX, RAMP = 60, 240, 24

        local function projY(worldY) return worldY - G.camY end

        local function die(msg)
            if G.dead then return end
            G.dead = true
            if G.cv then G.cv:SetScript("OnUpdate", nil) end
            if G.deathText then G.deathText:SetText(msg); G.deathText:Show() end
            api:Finish(G.maxTier - 1)
        end
        G._die = die

        G.vy = JUMP                    -- 开局第一跳

        G.cv:SetScript("OnUpdate", function(_, dt)
            if G.dead then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.05 then dt = 0.05 end

            local autoScroll = AS_MIN + (AS_MAX - AS_MIN) * math.min(1, G.elapsed / RAMP)
            G.elapsed = G.elapsed + dt

            -- 左右移动。
            local dx = 0
            if G.held.left then dx = dx - MOVE * dt end
            if G.held.right then dx = dx + MOVE * dt end
            G.charX = G.charX + dx
            if G.charX < 0 then G.charX = 0 end
            if G.charX > W - cs then G.charX = W - cs end

            -- 竖直：重力 + 弹跳。
            local prevWorldY = G.charWorldY
            G.vy = G.vy - GRAVITY * dt
            G.charWorldY = G.charWorldY + G.vy * dt

            -- 碰撞/落脚：只查角色附近的层（worldY 窗口）。
            local baseIdx = math.floor(G.charWorldY / gapY)
            local n = #G.layers
            for i = math.max(1, baseIdx - 1), math.min(n, baseIdx + 3) do
                local L = G.layers[i]
                -- 带刺平台：任何接触即死（touch-death，含三角刺高度 SPIKE_HIT）。
                if L.hasSpike then
                    if (G.charX < L.spikeX + pltW) and (G.charX + cs > L.spikeX)
                       and (G.charWorldY < L.worldY + pltH + SPIKE_HIT) and (G.charWorldY + cs > L.worldY) then
                        die("扎 死 在 刺 上！"); return
                    end
                end
                -- 安全平台：仅下落中、本帧脚底自上而下穿过平台顶、x 重叠 → 弹起。
                if G.vy <= 0 then
                    local top = L.worldY + pltH
                    if prevWorldY >= top - 1 and G.charWorldY <= top
                       and (G.charX + cs > L.safeX) and (G.charX < L.safeX + pltW) then
                        G.charWorldY = top
                        G.vy = JUMP
                        if L.tier > G.maxTier then G.maxTier = L.tier end
                    end
                end
            end

            -- 地板上涨（加速）+ 相机跟随（角色太高则相机追上，别冲出顶）。
            G.camY = G.camY + autoScroll * dt
            local follow = G.charWorldY - G.scrollY
            if follow > G.camY then G.camY = follow end

            -- 被地板吞 / 坠出视野下方 → 死。
            local chCanvasY = G.charWorldY - G.camY
            if chCanvasY <= 0 then die("被 深 渊 吞 没！"); return end

            api:SetScore(G.maxTier - 1)

            -- 重绘。
            local ch = G.charTex
            ch:ClearAllPoints()
            ch:SetPoint("BOTTOMLEFT", G.cv, "BOTTOMLEFT", G.charX, projY(G.charWorldY))
            ch:Show()
            local slotIdx = 1
            for i = 1, n do
                local L = G.layers[i]
                local y = projY(L.worldY)
                if y > -gapY and y < H + gapY then
                    local slot = G.pool[slotIdx]
                    if not slot then break end
                    G.drawSlot(slot, L, y)
                    slotIdx = slotIdx + 1
                elseif y >= H + gapY then
                    break
                end
            end
            for j = slotIdx, #G.pool do G.hideSlot(G.pool[j]) end
        end)
    end,

    stop = function(ctx, api)
        local G = api.G
        if G and G.cv then G.cv:SetScript("OnUpdate", nil) end
    end,

    teardown = function(ctx, api)
        local G = api.G
        if not G then return end
        if G.cv then G.cv:SetScript("OnUpdate", nil) end
        if G.charTex then G.charTex:Hide() end
        if G.pool then for _, slot in ipairs(G.pool) do
            if slot.safeTex then slot.safeTex:Hide() end
            if slot.spikeTex then slot.spikeTex:Hide() end
            if slot.spikes then for s = 1, #slot.spikes do for k = 1, #slot.spikes[s] do slot.spikes[s][k]:Hide() end end end
        end end
        if G.deathText then G.deathText:Hide() end
        api.G = nil
    end,

    onTie = function(ctx, api) end,
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
