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
-- 可解性保证（难但永远过得去）：
--   ★ 相邻安全行水平距离 ≤ reachX（一次下落够得着）。
--   ★ 禁止连续两行带刺；带刺行的刺**正对下落走廊**（不操作就扎死，须主动左右闪避）→ 两侧仍留大片
--     空隙、移速够在本行滚到身前前闪开，故总有可过的路（不再是「直落必安全」那种无挑战）。
--
-- 无敌星加速道具（1.7.2）：下降路径上的「安全行」确定性地（api:Random）以 STAR_PCT 概率悬一颗金色「无敌星」
--   五角星（悬浮在该行安全平台上方）。角色 AABB 碰到即吃下 → 加速 BOOST_DUR(2s)。
--   ★ 加速「只加速板子上升(scroll)的速度 = 2×」，不加速玩家的坠落与左右移动（都保持 1×，操作手感不变）。
--   实现用「子步 driver」：加速期一帧跑 2 子步、每子步同一 dt（保留碰撞精度、绝不穿模）；scroll 逐子步全速→2×，
--   而横移(hmove)/坠落(vmove)各按 1/子步数 缩放 → 总速仍 1×。真实 dt 只扣一次 → boost 真实 2 秒。
--   收益：板子上升更快 = 同时间多下降几层涨分；风险：板子冲得快，留给对位/避刺的反应时间更短。加速期角色染金脉冲。
--
-- 死亡体验（1.7.0）：撞刺/夹顶/坠底后不立刻切结果屏，先冻结 ~2s 显示死因 + 到达层数，再结算（见 die()）。
--
-- 不变量 #2（解耦）：只走 api。公平（§4）：用 api:Random 按种子生成。自包含（§6）：def 在 SOURCE 内。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "down100",
    name      = "是男人就下 100 层",
    version   = "1.7.2",
    glyph     = "Interface\\Icons\\Ability_Rogue_Sprint",
    descLines = { "踩平台往下，越深越高", "刺行须穿空隙，吃星加速" },

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
        local SBW, SBH, LAYERS = 16, 12, 5
        G.ROW_GAP, G.PLAT_H, G.CHAR_SZ, G.SPIKE_PCT = ROW_GAP, PLAT_H, CHAR_SZ, SPIKE_PCT

        -- 无敌星参数
        local STAR_SZ    = 24                      -- 五角星渲染尺寸（正方形包围盒）
        local STAR_PCT   = 18                      -- 安全行挂星概率（%）
        local STAR_HOVER = 34                      -- 星顶边距安全平台顶的悬浮高度（屏上方=更小 y）
        local BOOST_DUR  = 2.0                     -- 吃星后加速持续秒数
        G.STAR_SZ, G.STAR_HOVER, G.BOOST_DUR = STAR_SZ, STAR_HOVER, BOOST_DUR

        -- 五角星 13×13 位图（"1"=实心）；逐行 RLE 合并横向 run → 金色矩形画出（程序化、可分享）。
        local STAR_BMP = {
            "0000001000000", "0000011100000", "0000011100000", "0000111110000",
            "1111111111111", "0111111111110", "0011111111100", "0001111111000",
            "0001111111000", "0011110111100", "0111100011110", "1111000001111",
            "1110000000111",
        }
        local STAR_DIM = #STAR_BMP                 -- 13
        local STAR_CELL = STAR_SZ / STAR_DIM       -- 每个位图单元的像素边长
        -- 预扫描每颗星需要的横向 run 数（合并连续 "1"）→ 决定每 plat 的星纹理池容量。
        G.starRuns = {}                            -- { {row=,c0=,len=} ... }（位图坐标，渲染时按 cell 缩放）
        for r = 1, STAR_DIM do
            local line = STAR_BMP[r]
            local c = 1
            while c <= STAR_DIM do
                if line:sub(c, c) == "1" then
                    local c0 = c
                    while c <= STAR_DIM and line:sub(c, c) == "1" do c = c + 1 end
                    G.starRuns[#G.starRuns + 1] = { row = r - 1, c0 = c0 - 1, len = c - c0 }
                else
                    c = c + 1
                end
            end
        end
        G.STAR_CELL = STAR_CELL

        G.nextSpike = function() return api:Random(1, 100) <= SPIKE_PCT end

        -- ===== 生成一行（可解性核心，见 sim 验证）=====
        G.lastSafeX = (W - 110) * 0.5
        G.lastSafeW = 110
        G.rowsSinceSafe = 0
        G.genRow = function(p, forceSafe)
            local makeSpike = (not forceSafe) and (G.rowsSinceSafe == 0) and G.nextSpike()
            if makeSpike then
                p.spikeW = api:Random(SPIKE_W_MIN, SPIKE_W_MAX)
                if p.spikeW > W then p.spikeW = W end
                -- 把刺摆在角色「直落走廊」正对位置 → 不操作就扎死，必须主动左右闪避（这才有挑战）。
                -- 仍可解：刺只占一块（≤SPIKE_W_MAX），两侧留大片空隙，移速够在本行滚到身前前闪开。
                local dropC = G.lastSafeX + (G.lastSafeW or SAFE_W_MAX) * 0.5
                local sx = dropC - p.spikeW * 0.5 + api:Random(-16, 16)
                if sx > W - p.spikeW then sx = W - p.spikeW end
                if sx < 0 then sx = 0 end
                p.spikeX = math.floor(sx)
                p.hasSpike = true; p.safeW = 0    -- 带刺行：无安全落脚点
                p.hasStar = false; p.starEaten = false   -- 带刺行不挂星
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
                G.lastSafeX = p.safeX; G.lastSafeW = p.safeW; G.rowsSinceSafe = 0
                -- 安全行末尾掷星（放在 RNG 顺序最后，不打乱带刺行判定）：居中于安全平台上方。
                if api:Random(1, 100) <= STAR_PCT then
                    p.hasStar = true; p.starEaten = false
                    p.starX = p.safeX + (p.safeW - STAR_SZ) / 2
                else
                    p.hasStar = false; p.starEaten = false
                end
            end
        end

        -- ===== 对象池 =====
        local maxSpikes = math.ceil(SPIKE_W_MAX / SBW)
        local nStarRun = #G.starRuns               -- 每颗星需要的横向 run 纹理数（复用、不每帧 CreateTexture）
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
            -- 无敌星纹理：每个 plat 一组 run（OVERLAY，金色），复用不每帧新建。
            local starTex = {}
            for s = 1, nStarRun do
                local t = cv:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(1.0, 0.86, 0.22, 1)
                t:Hide(); starTex[s] = t
            end
            G.plats[i] = { safeTex = safeTex, spikeTex = spikeTex, spikes = spikes, starTex = starTex,
                           y = 0, safeX = 0, safeW = 0, spikeX = 0, spikeW = 0,
                           hasSpike = false, hasStar = false, starEaten = false, starX = 0, _landed = false }
        end

        -- 画/隐一颗星：画在该行 star 位置（屏幕坐标，星顶边 y = p.y - STAR_HOVER）。blink ∈ [0,1] 控金色脉冲。
        G.placeStar = function(p, blink)
            local topY = p.y - STAR_HOVER
            local b = blink or 0
            -- 金色脉冲：亮 {1,0.86,0.22} ↔ 暗 {0.5,0.4,0.12}
            local rr = 0.5 + 0.5 * b
            local gg = 0.40 + 0.46 * b
            local bb = 0.12 + 0.10 * b
            for s = 1, #G.starRuns do
                local run = G.starRuns[s]
                local t = p.starTex[s]
                if t then
                    local rx = p.starX + run.c0 * STAR_CELL
                    local ry = topY + run.row * STAR_CELL
                    t:ClearAllPoints()
                    t:SetColorTexture(rr, gg, bb, 1)
                    t:SetSize(run.len * STAR_CELL, STAR_CELL + 0.6)
                    t:SetPoint("TOPLEFT", cv, "TOPLEFT", rx, -ry)
                    t:Show()
                end
            end
        end
        G.hideStar = function(p)
            for s = 1, #p.starTex do p.starTex[s]:Hide() end
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
            -- 无敌星：未吃且在画布可见范围 → 画（带脉冲）；否则隐。
            if p.hasStar and not p.starEaten and p.y > -ROW_GAP and p.y < H + ROW_GAP then
                local blink = 0.5 + 0.5 * math.sin((G.elapsed or 0) * 6)
                G.placeStar(p, blink)
            else
                G.hideStar(p)
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
                p.hasStar = false; p.starEaten = false      -- 起始行不挂星（角色已站上）
                G.lastSafeX = p.safeX; G.lastSafeW = p.safeW; G.rowsSinceSafe = 0
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
        -- 死亡副标题：到达层数 + 「即将结算」提示（死后冻结 ~2s 再切结果，让玩家看清，见 die()）。
        local dsub = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dsub:SetPoint("TOP", dtext, "BOTTOM", 0, -10)
        dsub:SetTextColor(1.0, 0.82, 0.30)
        dsub:Hide()
        G.deathSub = dsub

        G.depth   = 0
        G.elapsed = 0
        G.boostT  = 0
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
        local STAR_SZ    = G.STAR_SZ
        local STAR_HOVER = G.STAR_HOVER
        local BOOST_DUR  = G.BOOST_DUR
        local DEATH_HOLD = 2.0         -- 死后冻结秒数：先让玩家看清「怎么死的/到第几层」，再结算（不立刻切结果屏）

        local function over(x, w)
            return (w and w > 0) and (G.heroX < x + w) and (G.heroX + CHAR_SZ > x)
        end

        local function die(msg)
            if G.dead then return end
            G.dead = true; G.running = false
            if cv.SetScript then cv:SetScript("OnUpdate", nil) end   -- 冻结画面（停物理）
            if G.deathText then G.deathText:SetText(msg); G.deathText:Show() end
            if G.deathSub then
                G.deathSub:SetText(string.format("到达第 %d 层 · %d 秒后结算…", G.depth, DEATH_HOLD))
                G.deathSub:Show()
            end
            -- 死后不立刻 Finish：冻结 ~2s 显示死因，再结算（elimination）。用 C_Timer 延时（真机/无头都支持）。
            if _G.C_Timer and _G.C_Timer.After then
                _G.C_Timer.After(DEATH_HOLD, function()
                    if G.aborted or G.finished then return end        -- 比赛已关闭/已结算 → 丢弃迟到回调
                    G.finished = true
                    api:Finish(G.depth)
                end)
            else
                G.finished = true
                api:Finish(G.depth)                                   -- 兜底：无 C_Timer 时直接结算
            end
        end
        G._die = die

        -- 一帧（或一子步）的物理体：用同一 dt（driver 已 clamp，这里不再 clamp）。
        -- hmove/vmove = 横移/竖直坠落的本子步缩放（driver 传 1/steps）：加速期跑 2 子步、横移与坠落各 ×0.5
        --   → 它们总速都仍是 1×（玩家操作手感不变）；而「板子上升(scroll)」逐子步全速 → 2 子步 = 2×。
        --   即：无敌星只加速板子上升，不加速玩家的坠落/左右移动。
        -- 注意：die() 后本子步必须 return；driver 会检测 G.dead 跳出 step 循环。
        local function frameStep(dt, hmove, vmove)
            hmove = hmove or 1
            vmove = vmove or 1
            local scroll = SCROLL_MIN + (SCROLL_MAX - SCROLL_MIN) * math.min(1, G.elapsed / RAMP)
            G.elapsed = G.elapsed + dt

            -- 左右移动（横移速度恒定 1×，不随加速放大）。
            if G.held.left  then G.heroX = G.heroX - MOVE_SPD * dt * hmove end
            if G.held.right then G.heroX = G.heroX + MOVE_SPD * dt * hmove end
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
                -- 坠落按 vmove 缩放 → 加速期坠落总速仍 1×（只板子上升加速，玩家下落手感不变）。
                G.vy = G.vy + GRAVITY * dt * vmove
                if G.vy > MAX_VY then G.vy = MAX_VY end
                local prevBottom = G.heroY + CHAR_SZ
                G.heroY = G.heroY + G.vy * dt * vmove
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

            -- 无敌星拾取（hero 位置更新后）：AABB 重叠 → 吃星 → 启动加速。
            for i = 1, #G.plats do
                local p = G.plats[i]
                if p.hasStar and not p.starEaten then
                    local sx0, sy0 = p.starX, p.y - STAR_HOVER
                    if (G.heroX < sx0 + STAR_SZ) and (G.heroX + CHAR_SZ > sx0)
                       and (G.heroY < sy0 + STAR_SZ) and (G.heroY + CHAR_SZ > sy0) then
                        p.starEaten = true
                        G.boostT = BOOST_DUR
                        G.hideStar(p)
                    end
                end
            end

            if G.heroY <= 0 then die("被 夹 死 在 顶 部！"); return end
            if G.heroY > H then die("坠 落 摔 死 了！"); return end

            -- 加速期角色染更亮金/脉冲；否则恢复单色金。
            if G.hero then
                if (G.boostT or 0) > 0 then
                    local b = 0.5 + 0.5 * math.sin(G.elapsed * 18)
                    G.hero:SetColorTexture(1.0, 0.82 + 0.18 * b, 0.25 + 0.45 * b, 1)
                else
                    G.hero:SetColorTexture(1.0, 0.82, 0.25, 1)
                end
            end
            G.placeHero()
        end
        G._frameStep = frameStep

        G.running = true
        -- driver：加速期一帧跑 2 子步（同一 dt，保留碰撞精度，绝不穿模）；真实 dt 只扣 boostT 一次 → boost 真实 2 秒。
        cv:SetScript("OnUpdate", function(_, dt)
            if not G.running or G.dead then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.05 then dt = 0.05 end
            local boosting = (G.boostT or 0) > 0
            if boosting then G.boostT = G.boostT - dt end   -- 真实 dt 只扣一次 → boost 真实时长 2 秒
            local steps = boosting and 2 or 1
            -- 横移/坠落按子步数反比缩放 → 它们总速恒定 1×；scroll 不缩放 → 2 子步 = 2×（只加速板子上升）。
            local hmove = 1 / steps
            local vmove = 1 / steps
            for _ = 1, steps do
                if G.dead or not G.running then break end
                frameStep(dt, hmove, vmove)
            end
        end)
    end,

    stop = function(ctx, api)
        local G = ctx._d100
        if G then G.running = false; G.aborted = true end   -- 作废在途的死亡延时回调（别 Finish 到下一局）
        local cv = api:Canvas()
        if cv then cv:SetScript("OnUpdate", nil) end
    end,

    teardown = function(ctx, api)
        local cv = api:Canvas()
        local G = ctx._d100
        if cv then cv:SetScript("OnUpdate", nil) end
        if G then
            G.running = false
            G.aborted = true                                -- 作废任何在途的死亡延时回调
            if G.plats then
                for i = 1, #G.plats do
                    local p = G.plats[i]
                    if p.safeTex  then p.safeTex:Hide() end
                    if p.spikeTex then p.spikeTex:Hide() end
                    if p.spikes then
                        for s = 1, #p.spikes do for k = 1, #p.spikes[s] do p.spikes[s][k]:Hide() end end
                    end
                    if p.starTex then
                        for s = 1, #p.starTex do p.starTex[s]:Hide() end
                    end
                end
            end
            if G.hero then G.hero:Hide() end
            if G.deathText then G.deathText:Hide() end
            if G.deathSub then G.deathSub:Hide() end
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
