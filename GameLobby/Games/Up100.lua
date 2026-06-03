-- Games/Up100.lua —— 是男人就上 100 层（自绘档 canvas 游戏，Doodle Jump 式弹跳）
-- owner: wow-addon-engineer
--
-- 玩法：小角色自动弹跳往上爬，按 方向键/AD 左右移动对准上方平台落脚；每登上更高一层 = 层数 +1。
--   ★ 带刺平台「只要碰到就死」（不是落上才死）—— 任何方向的接触都判死（touch-death）。
--   ★ 屏幕底部有一条不断上涨且越来越快的「地板/深渊」追着你 —— 爬慢了会被追上吞掉。层数高者胜。
--
-- 关卡模型（2.1.0：每层一块平台，二选一；刺=「别落空」的惩罚位，永远可解）：
--   · 每一层只有「一块」平台：要么是「可站立安全平台」（土黄、hasSpike=false、用 safeX），
--     要么是「带刺平台」（红+三角刺、hasSpike=true、用 spikeX、碰到即死）。不再「安全+刺」并存。
--   · 安全平台连成可攀爬的链：相邻两块安全平台相隔 1 或 2 层（随机），水平偏移 ≤ reachX（一跳够得着）。
--   · 刺只出现在「相隔 2 层」时夹在中间那层（安全 A 在 T，安全 B 在 T+2，刺在 T+1）→ 自动杜绝「连续两层刺」。
--
-- 可解性铁律（2.0.0 把刺挡在「正上方起跳通道」→ 上升必死，是 bug；本版彻底修掉）：
--   ★ 刺绝不挡住「从 A 正上方竖直起跳」的通道：刺的 X 与起跳列保持 ≥ CLEAR(60px) 净空。
--     → 永远存在解法：起跳后先「竖直」上升越过刺所在层（那一刻角色在 A 列、刺在 ≥CLEAR 外 = 安全），
--       接近顶点再横移对准 B 落脚。CLEAR=60 > 上升期最大可控漂移(~48px)，连「全程朝刺侧推」也撞不到。
--   ★ 跳跃顶点 apex = JUMP^2/(2*GRAVITY) = 700^2/3000 ≈ 163px（>2*72=144）→ 从 A 必能跳到正上方 2 层的 B（19px 富余）。
--   ★ 刺的「意义」= 惩罚：你必须落在 B(T+2) 上；若没对准 B、落空下坠，会摔回刺(T+1)送命。刺偏 B 那一侧，
--     想抄近路径直朝 B 冲、起步太早横移者会贴刺飞过 → 逼出「先竖直、后横移」的节奏。
--
-- 死亡体验：撞刺/坠落/被吞后不立刻切结果屏，先冻结 ~2s 显示死因 + 到达层数，再结算（见 die()）。
--
-- 无敌星加速道具（2.2.0）：攀爬路径上确定性地（api:Random）每隔 7~11 块安全平台浮一颗金色「无敌星」五角星。
--   角色 AABB 碰到即吃下 → 整局以 2× 速度运行 BOOST_DUR(2s)。实现用「子步 driver」：加速期一帧内跑 2 个
--   子步、每子步同一 dt（保留碰撞精度、绝不穿模/穿过刺），真实 dt 只扣一次 → boost 真实时长就是 2 秒。
--   收益：吃了不失误能明显多爬几层涨分；风险：2× 下手忙脚乱撞刺/落空更易死。加速期角色染金脉冲反馈。
--   ★ 2.2.1：加速只快进「竖直上爬 + 地板」，左右移动速度保持 1×（横移按子步反比缩放）—— 避免操作被放大失控。
--
-- 不变量 #2（解耦）：只走 api。公平（§4）：api:Random 按种子生成，各端一致。自包含（§6）：def 在 SOURCE。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "up100",
    name      = "是男人就上 100 层",
    version   = "2.2.1",
    glyph     = "Interface\\Icons\\Ability_Hunter_Pathfinding",
    descLines = { "弹跳往上，地板在追", "碰刺即死，吃星加速" },

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
        G.gapY     = 72                          -- 层距（2.0.0：64→72，稍大）
        G.scrollY  = H * 0.46
        local SBW, SBH, LAYERS = 14, 12, 5
        G.SBW, G.SBH, G.LAYERS = SBW, SBH, LAYERS
        G.SPIKE_HIT = SBH                        -- 刺的判定额外向上加 SBH（覆盖三角刺，碰到即死）

        --==== 单趟生成关卡：安全链 +（隔 2 层时）夹层刺（各端一致）====--
        -- 模型：每层一块平台。安全平台沿链递进（相隔 1 或 2 层）；相隔 2 层时，中间那层放刺。
        -- 刺放置铁律：与「起跳列」保持 CLEAR 净空 → 任何关卡都能「先竖直越过刺、再横移对准 B」过去（可解性优先）。
        local layers = 220
        local reachX = 100                       -- 相邻两块安全平台的水平最大偏移（一跳够得着+够横向对准）
        local CLEAR  = 60                        -- 刺距起跳列的最小净空（> 上升期最大可控漂移 ~48px，连全程推也撞不到）
        local CHAR = G.charSize
        local minPx, maxPx = 8, W - G.pltW - 8
        if maxPx < minPx then maxPx = minPx end
        G.layers = {}
        -- 先全部置空（默认无平台，下面再填）。
        for i = 1, layers do
            G.layers[i] = { worldY = i * G.gapY, tier = i, hasSpike = false, safeX = 0, spikeX = 0 }
        end

        -- 安全链：从第 1 层起步，每步前进 1 或 2 层（前 2 层强制每层安全，给稳妥起步）。
        local startX = math.floor((minPx + maxPx) / 2)
        G.layers[1].hasSpike = false; G.layers[1].safeX = startX
        G.layers[2].hasSpike = false
        do
            local lo = math.max(minPx, startX - reachX)
            local hi = math.min(maxPx, startX + reachX)
            if hi < lo then hi = lo end
            G.layers[2].safeX = api:Random(math.floor(lo), math.floor(hi))
        end

        local lastSafeTier = 2
        local lastSafeX = G.layers[2].safeX
        while lastSafeTier < layers do
            -- 下一块安全平台相隔 1 或 2 层。
            local step = api:Random(1, 2)
            local nextTier = lastSafeTier + step
            if nextTier > layers then nextTier = layers; step = nextTier - lastSafeTier end
            -- 安全 B 的 X：在 reachX 范围内随机（一跳够得着）。
            local lo = math.max(minPx, lastSafeX - reachX)
            local hi = math.min(maxPx, lastSafeX + reachX)
            if hi < lo then hi = lo end
            local nextX = api:Random(math.floor(lo), math.floor(hi))
            local nb = G.layers[nextTier]
            nb.hasSpike = false; nb.safeX = nextX

            -- 若相隔 2 层 → 中间那层放刺（与起跳列保持 CLEAR 净空 → 永远可解）。
            if step == 2 then
                local midTier = lastSafeTier + 1
                local mid = G.layers[midTier]
                -- 起跳列：角色站在 A 中央起跳（中心 cx0）。净空区 = 该列两侧各留 CLEAR，刺不得侵入。
                local cx0     = lastSafeX + G.pltW * 0.5
                local halfC   = CHAR * 0.5
                local clearLo = cx0 - halfC - CLEAR    -- 刺右缘须 ≤ 此值（放左侧）
                local clearHi = cx0 + halfC + CLEAR    -- 刺左缘须 ≥ 此值（放右侧）
                local function clears(x) return (x + G.pltW <= clearLo) or (x >= clearHi) end
                -- 朝 B 那一侧放刺（B≈正上方则随机一侧）：想抄近路朝 B 冲、横移太早者会贴刺 → 逼「先竖直后横移」。
                local dir
                if nextX > lastSafeX + 4 then dir = 1
                elseif nextX < lastSafeX - 4 then dir = -1
                else dir = (api:Random(0, 1) == 0) and -1 or 1 end
                local function place(d) if d > 0 then return clearHi else return clearLo - G.pltW end end
                local sx = place(dir)
                if sx < minPx then sx = minPx end
                if sx > maxPx then sx = maxPx end
                if not clears(sx) then                 -- 该侧夹回后侵入净空（画布这侧太窄）→ 换另一侧
                    sx = place(-dir)
                    if sx < minPx then sx = minPx end
                    if sx > maxPx then sx = maxPx end
                end
                if clears(sx) then
                    mid.hasSpike = true; mid.spikeX = math.floor(sx); mid.safeX = 0
                else
                    -- 两侧都放不下「带净空」的刺（画布太窄）→ 退化为安全平台，绝不卡死（可解性优先）。
                    mid.hasSpike = false; mid.safeX = lastSafeX
                end
            end

            lastSafeTier = nextTier
            lastSafeX = nextX
        end

        --==== 无敌星放置（确定性、在攀爬路径上）====--
        -- 必须在关卡生成完之后追加（绝不打乱上面安全链/刺的 RNG 调用顺序）。全程 api:Random（各端一致），绝不用 math.random。
        -- 规则：遍历安全平台链，每隔 api:Random(7,11) 块安全平台，在该平台上方约 0.45 层、X 居中处放一颗星。
        G.STAR_SZ = 24
        G.stars = {}
        do
            local STAR_SZ = G.STAR_SZ
            local sinceStar = 0
            local nextGap = api:Random(7, 11)
            for i = 1, layers do
                local L = G.layers[i]
                if not L.hasSpike and L.safeX and L.safeX > 0 then
                    sinceStar = sinceStar + 1
                    if sinceStar >= nextGap then
                        sinceStar = 0
                        nextGap = api:Random(7, 11)
                        local sx = L.safeX + (G.pltW - STAR_SZ) / 2     -- X 居中于该安全平台
                        if sx < 0 then sx = 0 end
                        if sx > W - STAR_SZ then sx = W - STAR_SZ end
                        local sy = L.worldY + G.pltH + G.gapY * 0.45      -- 平台顶上方约 0.45 层（要跳起来才够）
                        G.stars[#G.stars + 1] = { worldY = sy, x = sx, eaten = false }
                    end
                end
            end
        end

        --==== 角色 ====--
        local ch = cv:CreateTexture(nil, "OVERLAY")
        ch:SetColorTexture(0.30, 0.85, 1.0, 1.0)
        ch:SetSize(G.charSize, G.charSize)
        G.charTex = ch

        --==== 对象池：每槽 = 安全平台 OR 刺平台（一块）+ 一排三角刺 ====--
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

        -- 把第 slot 个池槽画成 layer L（y = 平台底距画布底，向上为正）。每层只画一块平台。
        G.drawSlot = function(slot, L, y)
            if L.hasSpike then
                -- 刺平台：画红底 + 三角刺，隐藏安全块。
                slot.safeTex:Hide()
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
                -- 安全平台：画土黄块，隐藏刺。
                local s = slot.safeTex
                s:ClearAllPoints(); s:SetPoint("BOTTOMLEFT", cv, "BOTTOMLEFT", L.safeX, y); s:Show()
                slot.spikeTex:Hide()
                for si = 1, #slot.spikes do for k = 1, #slot.spikes[si] do slot.spikes[si][k]:Hide() end end
            end
        end
        G.hideSlot = function(slot)
            slot.safeTex:Hide(); slot.spikeTex:Hide()
            for si = 1, #slot.spikes do for k = 1, #slot.spikes[si] do slot.spikes[si][k]:Hide() end end
        end

        --==== 无敌星纹理对象池（复用，不每帧 CreateTexture）====--
        -- 五角星位图（13×13，"1"=实心），逐行 RLE 并成横向 run，金色矩形画出（程序化，不依赖贴图文件）。
        local STAR_SZ = G.STAR_SZ
        local STAR_BMP = {
            "0000001000000", "0000011100000", "0000011100000", "0000111110000",
            "1111111111111", "0111111111110", "0011111111100", "0001111111000",
            "0001111111000", "0011110111100", "0111100011110", "1111000001111",
            "1110000000111",
        }
        local STAR_BW, STAR_BH = #STAR_BMP[1], #STAR_BMP
        local STAR_RUNS = {}
        for r = 1, STAR_BH do
            local line = STAR_BMP[r]; local c = 1
            while c <= STAR_BW do
                if line:sub(c, c) == "1" then
                    local len = 1
                    while (c + len) <= STAR_BW and line:sub(c + len, c + len) == "1" do len = len + 1 end
                    STAR_RUNS[#STAR_RUNS + 1] = { row = r - 1, col0 = c - 1, len = len }
                    c = c + len
                else c = c + 1 end
            end
        end
        local SCX, SCY = STAR_SZ / STAR_BW, STAR_SZ / STAR_BH    -- 每逻辑像素 → 画布像素
        G.C_STAR  = { 1.0, 0.86, 0.22 }                          -- 亮金
        G.C_STARD = { 0.5, 0.40, 0.12 }                          -- 暗金
        -- 每颗星 = #STAR_RUNS 个 OVERLAY 纹理；池大小 = 屏内最多可见星数（保守给足）。
        local starPoolN = math.ceil(H / (G.gapY)) + 4
        if starPoolN < 4 then starPoolN = 4 end
        G.starPool = {}
        for i = 1, starPoolN do
            local rects = {}
            for k = 1, #STAR_RUNS do
                local t = cv:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(G.C_STAR[1], G.C_STAR[2], G.C_STAR[3], 1)
                t:Hide()
                rects[k] = t
            end
            G.starPool[i] = rects
        end
        -- placeStar：把一组星纹理（rects）画到 canvas 坐标 (x, projY)（左下原点、向上为正；projY=星框底边距画布底）。
        G.placeStar = function(rects, x, projY, blink)
            local col = blink and G.C_STAR or G.C_STARD
            for k = 1, #STAR_RUNS do
                local run = STAR_RUNS[k]
                local t = rects[k]
                t:SetColorTexture(col[1], col[2], col[3], 1)
                t:SetSize(run.len * SCX, SCY + 0.5)
                t:ClearAllPoints()
                -- 位图 row=0 是星顶 → 画到框顶（projY + STAR_SZ 处往下数）。
                t:SetPoint("BOTTOMLEFT", cv, "BOTTOMLEFT",
                    x + run.col0 * SCX, projY + (STAR_BH - 1 - run.row) * SCY)
                t:Show()
            end
        end
        G.hideStar = function(rects)
            for k = 1, #rects do rects[k]:Hide() end
        end

        --==== 初始姿态：角色站在第一层（安全），地板从底部起 ====--
        G.camY = 0
        local p1 = G.layers[1]
        G.charX = p1.safeX + (G.pltW - G.charSize) / 2
        G.charWorldY = p1.worldY + G.pltH
        G.vy = 0
        G.maxTier = 1
        G.elapsed = 0
        G.boostT = 0                             -- 剩余加速秒数（>0 时整局 2× 子步运行）
        G.held = { left = false, right = false }
        G.dead = false

        local dtext = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        dtext:SetPoint("CENTER", cv, "CENTER", 0, 18)
        dtext:SetTextColor(1.0, 0.35, 0.25)
        dtext:Hide()
        G.deathText = dtext
        -- 死亡副标题：到达层数 + 「即将结算」提示（死后冻结 ~2s 再切结果，让玩家看清，见 die()）。
        local dsub = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dsub:SetPoint("TOP", dtext, "BOTTOM", 0, -10)
        dsub:SetTextColor(1.0, 0.82, 0.30)
        dsub:Hide()
        G.deathSub = dsub

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
        local JUMP = 700               -- apex=JUMP^2/(2*GRAVITY)≈163px（>2*72=144）→ 从安全 A 稳跳到正上方 2 层的安全 B（19px 富余）
        -- 地板上涨「慢→快」：峰值(185) < 连跳 2 层的净爬升(≈217px/s) → 手稳者永远爬得过地板；
        -- 手生者（一跳只上 1 层≈86px/s）会被吞 → 分数按熟练度拉开，避免人人满分平局。
        local AS_MIN, AS_MAX, RAMP = 70, 185, 22

        local DEATH_HOLD = 2.0         -- 死后冻结秒数：先让玩家看清「怎么死的/到第几层」，再结算（不立刻切结果屏）

        local function projY(worldY) return worldY - G.camY end

        local function die(msg)
            if G.dead then return end
            G.dead = true
            if G.cv then G.cv:SetScript("OnUpdate", nil) end     -- 冻结画面（停物理）
            if G.deathText then G.deathText:SetText(msg); G.deathText:Show() end
            if G.deathSub then
                G.deathSub:SetText(string.format("到达第 %d 层 · %d 秒后结算…", G.maxTier - 1, DEATH_HOLD))
                G.deathSub:Show()
            end
            -- 死后不立刻 Finish：冻结 ~2s 显示死因，再结算（elimination）。用 C_Timer 延时（真机/无头都支持）。
            if _G.C_Timer and _G.C_Timer.After then
                _G.C_Timer.After(DEATH_HOLD, function()
                    if G.aborted or G.finished then return end    -- 比赛已关闭/已结算 → 丢弃迟到回调
                    G.finished = true
                    api:Finish(G.maxTier - 1)
                end)
            else
                G.finished = true
                api:Finish(G.maxTier - 1)                          -- 兜底：无 C_Timer 时直接结算
            end
        end
        G._die = die

        G.vy = JUMP                    -- 开局第一跳

        local STAR_SZ = G.STAR_SZ
        local BOOST_DUR = 2.0          -- 吃星后的加速持续秒数（真实时长；driver 里 dt 只扣一次）
        local C_CHAR = { 0.30, 0.85, 1.0 }    -- 角色常态青色

        -- 单帧物理体：被 driver 调用 1 次（常态）或 2 次（加速）。dt 已由 driver clamp，这里不再 clamp。
        -- hmove = 横向移动的本子步缩放（driver 传 1/steps）：加速期跑 2 子步、每步横移 ×0.5 → 左右总速仍是 1×，
        --   只「快进」竖直上爬 + 地板（修复「吃星后左右移动也跟着变快、操作被放大失控」）。
        -- 凡 die(...) 后 return：return 只结束本子步，driver 检测 G.dead 跳出。
        local function frameStep(dt, hmove)
            hmove = hmove or 1
            local autoScroll = AS_MIN + (AS_MAX - AS_MIN) * math.min(1, G.elapsed / RAMP)
            G.elapsed = G.elapsed + dt    -- 加速时游戏时间也 2× 是预期的「快进」（仅竖直/地板，横移不受影响）

            -- 左右移动（横移速度恒定 1×，不随加速放大）。
            local dx = 0
            if G.held.left then dx = dx - MOVE * dt * hmove end
            if G.held.right then dx = dx + MOVE * dt * hmove end
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
                if L.hasSpike then
                    -- 带刺平台：任何接触即死（touch-death，含三角刺高度 SPIKE_HIT）。
                    if (G.charX < L.spikeX + pltW) and (G.charX + cs > L.spikeX)
                       and (G.charWorldY < L.worldY + pltH + SPIKE_HIT) and (G.charWorldY + cs > L.worldY) then
                        die("扎 死 在 刺 上！"); return
                    end
                else
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
            end

            -- 无敌星拾取：角色位置更新后、重绘前。未 eaten 且 AABB 重叠 → 吃下、（重）触发加速。
            if G.stars then
                local clo, chi = G.charX, G.charX + cs
                local cblo, cbhi = G.charWorldY, G.charWorldY + cs
                for si = 1, #G.stars do
                    local s = G.stars[si]
                    if not s.eaten then
                        if (clo < s.x + STAR_SZ) and (chi > s.x)
                           and (cblo < s.worldY + STAR_SZ) and (cbhi > s.worldY) then
                            s.eaten = true
                            G.boostT = BOOST_DUR
                        end
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

            -- 重绘：角色（加速期染金脉冲，否则常态青）。
            local boosting = (G.boostT or 0) > 0
            local ch = G.charTex
            if boosting then
                if math.floor(G.elapsed * 12) % 2 == 0 then ch:SetColorTexture(1.0, 0.86, 0.22, 1.0)
                else ch:SetColorTexture(0.6, 0.5, 0.15, 1.0) end
            else
                ch:SetColorTexture(C_CHAR[1], C_CHAR[2], C_CHAR[3], 1.0)
            end
            ch:ClearAllPoints()
            ch:SetPoint("BOTTOMLEFT", G.cv, "BOTTOMLEFT", G.charX, projY(G.charWorldY))
            ch:Show()

            -- 重绘：平台。
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

            -- 重绘：无敌星（明暗脉冲；只画投影落在画布内的未吃星，复用 starPool）。
            if G.stars and G.starPool then
                local blink = (math.floor(G.elapsed * 6) % 2 == 0)
                local sp = 1
                for si = 1, #G.stars do
                    local s = G.stars[si]
                    if not s.eaten then
                        local py = projY(s.worldY)
                        if py > -STAR_SZ and py < H then
                            local rects = G.starPool[sp]
                            if rects then
                                G.placeStar(rects, s.x, py, blink)
                                sp = sp + 1
                            end
                        end
                    end
                end
                for j = sp, #G.starPool do G.hideStar(G.starPool[j]) end
            end
        end
        G._frameStep = frameStep

        -- driver：一帧内跑 1（常态）或 2（加速）个子步，每子步同一 dt → 2× 速度但保留碰撞精度，绝不穿模。
        -- 真实 dt 只扣一次 boostT → boost 真实时长就是 BOOST_DUR(2s)。
        G.cv:SetScript("OnUpdate", function(_, dt)
            if G.dead then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.05 then dt = 0.05 end
            local boosting = (G.boostT or 0) > 0
            if boosting then G.boostT = G.boostT - dt end
            local steps = boosting and 2 or 1
            local hmove = 1 / steps        -- 横移按子步数反比缩放 → 加速期左右速度不变（只快进竖直+地板）
            for _ = 1, steps do
                if G.dead then break end
                frameStep(dt, hmove)
            end
        end)
    end,

    stop = function(ctx, api)
        local G = api.G
        if not G then return end
        G.aborted = true                 -- 停止后作废在途的死亡延时回调
        if G.cv then G.cv:SetScript("OnUpdate", nil) end
    end,

    teardown = function(ctx, api)
        local G = api.G
        if not G then return end
        G.aborted = true                 -- 作废任何在途的死亡延时回调（别 Finish 到下一局）
        if G.cv then G.cv:SetScript("OnUpdate", nil) end
        if G.charTex then G.charTex:Hide() end
        if G.pool then for _, slot in ipairs(G.pool) do
            if slot.safeTex then slot.safeTex:Hide() end
            if slot.spikeTex then slot.spikeTex:Hide() end
            if slot.spikes then for s = 1, #slot.spikes do for k = 1, #slot.spikes[s] do slot.spikes[s][k]:Hide() end end end
        end end
        if G.starPool then for _, rects in ipairs(G.starPool) do
            for k = 1, #rects do rects[k]:Hide() end
        end end
        if G.deathText then G.deathText:Hide() end
        if G.deathSub then G.deathSub:Hide() end
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
