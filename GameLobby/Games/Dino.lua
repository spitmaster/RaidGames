-- Games/Dino.lua —— 小恐龙跳一跳（canvas 自绘游戏，Chrome 原版雪碧图像素级还原；契约 game-dev-spec §1/§2/§5.3）
-- owner: wow-addon-engineer ＋ wow-ui-developer（渲染层）
--
-- 玩法（玩到死，比跑的距离）：
--   一只小恐龙在原地自动奔跑（跑动两帧交替），地面/障碍（仙人掌/翼龙）/云从右往左滚来，速度由慢到快（像断网恐龙）。
--   按 空格/↑/W/小键盘8 跳跃越过障碍；按 ↓/S/小键盘2 下蹲从翼龙下钻过（翼龙也可跳过；空中按下=加速下坠）。
--   撞到障碍 → 立即出局。分数 = 跑过的距离（米）。endMode=elimination：撞死即结算，多人比谁跑得远。
--
-- 「加速道具·无敌星」（风险/收益，分数/世界速度解耦）：
--   路上偶尔出一颗「无敌星」五角星（多矩形拼，明暗脉冲发光）。80% 在地上（黄色，跑过去就吃到，加速 1s），
--   20% 在天上（红色，要跳起来才够得到，加速 3s）—— 天上红星收益翻倍，但得冒一次跳跃。
--   吃到 → 加速：分数提速 BOOST_SCORE(×1.5，收益明显多吃分)、世界/障碍提速 BOOST_WORLD(×1.2，风险但温和→
--   GAP_MIN 仍保证落地再跳，绝不变成「躲不掉」)。失误撞障碍照样死。再吃刷新计时。
--   加速反馈(3.2.1)：吃黄星 → 恐龙金色闪烁；吃红星 → 恐龙恒发红光（不闪），一眼区分拿的是哪种星。
--
-- 画面（Chrome 原版雪碧图，atlas 贴图渲染 —— 不再用 SetColorTexture 横条马赛克）：
--   一张图集贴图 Media\dino\atlas.tga（512×256 POT、32 位带 alpha、不压缩；从 Chrome 雪碧图切片打包）。
--   每个游戏对象 = 一个 Texture，SetTexture(atlas) + SetTexCoord 选区域 + SetSize 按比例缩放。
--   动画：跑动 run1/run2 交替；离地 jump；下蹲 duck1/duck2 交替；撞死换 dead（叉叉眼）；翼龙 fly1/fly2 扇翅。
--   深色画布 → 精灵用图集里的原灰（Chrome 夜间模式：深底直接贴原图灰，无需改色）。
--   加速期间恐龙整体 SetVertexColor 染金/闪烁（替代旧的换色逻辑）。
--
-- 可解性保证（绝不出现「躲不掉」的障碍）：
--   ★ 障碍/道具按「世界距离」间隔生成（不是按帧时间）→ 各端关卡完全一致（公平，§4）。
--   ★ 相邻障碍水平间距 ≥ 一次跳跃滞空横距（按最快世界速度算，含加速 BOOST_WORLD），保证总能落地再跳。
--   ★ 翼龙高度设计成「跳得过、也能蹲下钻过」，不强制下蹲。
--   ★ 道具是可选的（不跳就跳过），单独对象池 + 单独距离节奏；道具碰撞=吃，障碍碰撞=死，两套互不混。
--
-- 不变量 #2（解耦）：只走 api（SetScore/Finish/Canvas/CaptureKeyboard/Random/IsSpectator），绝不发通讯。
-- 公平（§4）：障碍/道具序列用 api:Random（框架确定性随机；WoW 无 math.randomseed）按距离生成，各端一致。
-- 自包含（§6）：def 本体写在 SOURCE，只用 ctx/api/全局/自身 local（贴图路径是字符串字面量，OK）；绝不引用 SOURCE 外 upvalue。
--
-- ★ TGA 排错点（无头环境无法验证 WoW 显示，仅真机能确认）：
--   atlas.tga 已确认为 512×256 POT、imagetype=2 不压缩、32bpp、descriptor bit5=0（底原点，WoW 标准朝向）。
--   若真机里贴图上下颠倒 → 在 sample/dino/_build_atlas.py 存图前加 ImageOps.flip(atlas) 重新生成即可（已在脚本注释里写明）。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "dino",
    name      = "小恐龙跳一跳",
    version   = "3.2.1",
    glyph     = "Interface\\Icons\\Ability_Hunter_Pet_Devilsaur",
    descLines = { "跳障碍，吃道具加速", "撞上即出局，比谁远" },

    --==== 元数据 ====--
    tier        = "canvas",
    endMode     = "elimination",             -- 玩到死：撞障碍 → 立即出局，分定格在已跑距离
    scoreOrder  = "desc",
    scoreUnit   = "米",
    duration    = 25,                        -- maxDuration 兜底（一般撑不到）
    needsKeyboard = true,
    seeded      = true,
    scoreCap    = function() return 99999 end,
    locked      = false,

    --==== 生命周期 ====--

    -- setup：建地面 + 恐龙 + 障碍/道具/云对象，用种子准备关卡，但别动。
    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end

        local G = {}
        ctx._dino = G

        local W = (cv.GetWidth and cv:GetWidth()) or 720
        local H = (cv.GetHeight and cv:GetHeight()) or 460
        if not W or W <= 0 then W = 720 end
        if not H or H <= 0 then H = 460 end
        G.W, G.H = W, H

        -- ========= Chrome 雪碧图集 =========
        -- 贴图字面量路径（纯插件路线：每个用户都装了大厅插件 → 都有此文件，不破坏分发）。
        local ATLAS  = "Interface\\AddOns\\GameLobby\\Media\\dino\\atlas.tga"
        local AW, AH = 512, 256                  -- atlas POT 尺寸（SetTexCoord 归一化用）
        G.ATLAS, G.AW, G.AH = ATLAS, AW, AH
        -- 每个精灵在 atlas 里的像素矩形 {x, y, w, h}（左上原点，与 _build_atlas.py 打印一致）。
        local FR = {
            run1     = {192,   2,  88,  94},
            run2     = {282,   2,  88,  94},
            jump     = {372,   2,  88,  94},
            dead     = {  2, 103,  80,  86},
            duck1    = {274, 103, 118,  60},
            duck2    = {  2, 191, 118,  60},
            fly1     = {180, 103,  92,  68},
            fly2     = {122, 191,  92,  60},
            cactusS  = { 84, 103,  34,  70},
            cactusS2 = {120, 103,  58,  70},
            cactusL  = {  2,   2,  98,  99},
            cactusL2 = {102,   2,  88,  99},
            cloud    = {216, 191,  84,  27},
        }
        G.FR = FR

        -- 渲染缩放：CELL = 「画布像素 / 雪碧图像素」。雪碧图恐龙高 94，旧版逻辑恐龙高 44 → CELL≈0.47。
        -- 取 0.5 让恐龙更醒目；所有精灵共用同一 CELL，比例与原版一致。
        local CELL = 0.5
        G.CELL = CELL

        -- setTex：把一个 Texture 设到 atlas 的某精灵区域 + 按 CELL 缩放，锚点 anchor（默认 BOTTOMLEFT 贴 (x,baseBotY)）。
        --   frameKey → FR 区域；coords 用 SetTexCoord(l,r,t,b) = (x/AW,(x+w)/AW, y/AH,(y+h)/AH)。
        --   返回该精灵渲染后的画布尺寸 dw,dh（= w*CELL, h*CELL）。
        G.applyFrame = function(t, key)
            local f = FR[key]
            if not f then return 0, 0 end
            local x, y, w, h = f[1], f[2], f[3], f[4]
            t:SetTexture(ATLAS)
            t:SetTexCoord(x / AW, (x + w) / AW, y / AH, (y + h) / AH)
            local dw, dh = w * CELL, h * CELL
            t:SetSize(dw, dh)
            return dw, dh
        end

        -- ===== 参数 =====
        local GROUND_Y  = H * 0.82                -- 地面线距画布顶（向下为正）
        local DINO_X    = W * 0.12                -- 恐龙固定横位
        -- 恐龙包围盒（用雪碧图尺寸 × CELL；测试断言 DINO_W/DINO_H 字段存在）
        local DINO_W    = FR.run1[3] * CELL       -- 44
        local DINO_H    = FR.run1[4] * CELL       -- 47 站立高
        local DUCK_H    = FR.duck1[4] * CELL      -- 30 下蹲高
        local GAP_MIN   = 680                     -- 相邻障碍最小水平间距：≥ 最快世界速(860×1.2)×滞空(0.63s)≈653
        local GAP_MAX   = 1000                    --   → 即便满速+加速也总能落地再跳（可解性），非加速时更宽松
        local BIRD_AFTER = 280                    -- 跑过这么远后才可能出翼龙
        local BIRD_PCT  = 26                      -- 翼龙占比（%）
        G.GROUND_Y, G.DINO_X, G.DINO_W, G.DINO_H, G.DUCK_H = GROUND_Y, DINO_X, DINO_W, DINO_H, DUCK_H
        G.GAP_MIN, G.GAP_MAX, G.BIRD_AFTER, G.BIRD_PCT = GAP_MIN, GAP_MAX, BIRD_AFTER, BIRD_PCT

        G.nextGap = function() return api:Random(GAP_MIN, GAP_MAX) end

        -- ===== 颜色（Chrome 夜间模式：深底直接贴原图灰；加速时染金）=====
        local C_SPRITE  = { 1.0, 1.0, 1.0 }       -- 原图灰直接显示（顶点色白=不改色）
        local C_BOOST   = { 1.0, 0.82, 0.28 }     -- 加速期间恐龙染金（黄星：金/原交替闪）
        local C_BOOST_RED = { 1.0, 0.20, 0.20 }   -- 红星加速：恒红光（不闪）
        local C_GROUND  = { 0.55, 0.55, 0.58 }    -- 地面线中灰
        local C_BOLT    = { 1.0, 0.86, 0.22 }     -- 道具金色（恐龙图染金充当闪电）
        G.C_SPRITE, G.C_BOOST = C_SPRITE, C_BOOST
        G.C_BOOST_RED = C_BOOST_RED
        G.C_BOLT = C_BOLT
        G.C_STAR_GROUND = { 1.0, 0.86, 0.22 }     -- 地上无敌星：黄（加速 1s）
        G.C_STAR_AIR    = { 1.0, 0.30, 0.30 }     -- 天上无敌星：红（加速 3s）

        -- ===== 地面线（保留 SetColorTexture 横线）=====
        local ground = cv:CreateTexture(nil, "BACKGROUND")
        ground:SetColorTexture(C_GROUND[1], C_GROUND[2], C_GROUND[3], 1)
        ground:SetSize(W, 2)
        ground:SetPoint("TOPLEFT", cv, "TOPLEFT", 0, -GROUND_Y)
        ground:Show()
        G.ground = ground

        -- ===== 恐龙：单张 atlas 贴图 =====
        -- 测试断言 G.dino 存在并为「恐龙的代表纹理」：现在就是这张贴图本体。
        local dino = cv:CreateTexture(nil, "OVERLAY")
        dino:Hide()
        G.dino = dino

        -- placeDino：按当前帧/姿态画恐龙。dh=当前高度（站立/下蹲），boosting=加速中，blink=闪烁开。
        G.placeDino = function(dh, frameKey, boosting, blink)
            local t = G.dino
            local dw = G.applyFrame(t, frameKey)
            -- 顶点色：加速时——红星(G.boostRed)恒红光不闪；黄星金/原交替闪。否则原图。
            local col = G.C_SPRITE
            if boosting then
                if G.boostRed then col = G.C_BOOST_RED                 -- 红星：恒红光（不闪）
                else col = blink and G.C_BOOST or G.C_SPRITE end       -- 黄星：金/原交替闪
            end
            t:SetVertexColor(col[1], col[2], col[3], 1)
            -- 恐龙底边贴在 (GROUND_Y - jumpH)；左下角锚定。注意 dh 是逻辑包围盒高度，
            -- 渲染高 = 该帧 atlas 高×CELL（站立/跳=47，蹲=30），applyFrame 已设好 SetSize。
            local botY = G.GROUND_Y - G.jumpH
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", cv, "TOPLEFT", G.DINO_X, -botY)
            t:Show()
        end

        -- ===== 障碍对象（每个障碍 = 一张 atlas 贴图）=====
        local POOL = 6
        G.obs = {}
        for i = 1, POOL do
            local t = cv:CreateTexture(nil, "ARTWORK")
            t:Hide()
            G.obs[i] = {
                tex = t,
                active = false, x = 0, w = 0, h = 0, groundOffset = 0,
                kind = "cactus", spriteKey = "cactusS",
            }
        end
        -- 障碍 spriteKey → 渲染包围盒尺寸（雪碧图尺寸×CELL）
        G.obSize = function(key)
            local f = G.FR[key]
            return f[3] * G.CELL, f[4] * G.CELL
        end
        G.placeOb = function(o)
            local t = o.tex
            G.applyFrame(t, o.spriteKey)
            t:SetVertexColor(1, 1, 1, 1)
            -- 障碍底边 = GROUND_Y - groundOffset；左下角锚定。
            local botY = G.GROUND_Y - o.groundOffset
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", cv, "TOPLEFT", o.x, -botY)
            t:Show()
        end

        -- ===== 加速道具对象（独立，碰撞=吃；金色「无敌星」五角星，一眼就是增益/拾取物，不会被当成要躲的东西）=====
        local BPOOL = 2
        local BOLT_W, BOLT_H = 26, 26
        G.BOLT_W, G.BOLT_H = BOLT_W, BOLT_H
        -- 五角星位图（13×13，"1"=实心）：经典「无敌星」造型，金色 = 吃了变强、冲过去拿。
        local STAR_BMP = {
            "0000001000000", "0000011100000", "0000011100000", "0000111110000",
            "1111111111111", "0111111111110", "0011111111100", "0001111111000",
            "0001111111000", "0011110111100", "0111100011110", "1111000001111",
            "1110000000111",
        }
        -- 逐行 RLE：连续 1 并成一条横向 run（少量矩形即可画出五角星，含底部两腿的分叉）。
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
        local BCX, BCY = BOLT_W / STAR_BW, BOLT_H / STAR_BH   -- 每逻辑像素 → 画布像素（2×2）
        G.boosts = {}
        for i = 1, BPOOL do
            local rects = {}
            for k = 1, #STAR_RUNS do
                local t = cv:CreateTexture(nil, "OVERLAY")
                t:Hide(); rects[k] = t
            end
            G.boosts[i] = { rects = rects, active = false, x = 0, y = 0, eaten = false }
        end
        G.hideBoost = function(bz)
            if bz.rects then for k = 1, #bz.rects do bz.rects[k]:Hide() end end
        end
        G.placeBoost = function(bz, blink)
            -- 明暗脉冲：亮 ↔ 暗，像在发光闪烁（增益拾取物感）。bz.x/bz.y = 左上角。bz.col = 该星颜色（黄/红）。
            local base = bz.col or G.C_BOLT
            local c = blink and base or { base[1] * 0.5, base[2] * 0.4, base[3] * 0.12 }
            for k = 1, #STAR_RUNS do
                local run = STAR_RUNS[k]
                local t = bz.rects[k]
                t:SetColorTexture(c[1], c[2], c[3], 1)
                t:SetSize(run.len * BCX, BCY + 0.5)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", cv, "TOPLEFT", bz.x + run.col0 * BCX, -(bz.y + run.row * BCY))
                t:Show()
            end
        end
        -- 道具悬浮高度：需要跳起来才够得到（底边离地 ~ 跳跃中段高度）
        G.BOOST_HOVER = 70                        -- 道具底边离地高度（必须跳才够）
        G.nextBoostDist = api:Random(700, 1100)   -- 首个道具出现距离
        G.BOOST_GAP_MIN, G.BOOST_GAP_MAX = 1200, 2000  -- 道具生成间隔（比障碍稀疏）

        -- ===== 云（纯装饰，不计碰撞；慢速视差飘）=====
        local CPOOL = 3
        local cloudW, cloudH = G.obSize("cloud")
        G.cloudW = cloudW
        G.clouds = {}
        for i = 1, CPOOL do
            local t = cv:CreateTexture(nil, "BACKGROUND")
            t:Hide()
            G.clouds[i] = {
                tex = t,
                active = false, x = 0, y = 0,
            }
        end
        G.placeCloud = function(cz)
            local t = cz.tex
            G.applyFrame(t, "cloud")
            t:SetVertexColor(0.7, 0.7, 0.74, 1)   -- 云略淡（深底上更柔）
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", cv, "TOPLEFT", cz.x, -cz.y)
            t:Show()
        end
        G.nextCloudDist = api:Random(200, 500)

        -- ===== 死亡提示文字 =====
        local dtext = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        dtext:SetPoint("CENTER", cv, "CENTER", 0, 0)
        dtext:SetTextColor(1.0, 0.35, 0.25)
        dtext:Hide()
        G.deathText = dtext

        -- ===== 状态 =====
        G.jumpH    = 0          -- 恐龙底边离地高度（0=在地面）
        G.vy       = 0          -- 竖直速度（向上为正）
        G.ducking  = false
        G.dist     = 0          -- 累计分数距离（计分用；加速时涨更快=收益）
        G.worldDist = 0         -- 累计世界距离（障碍/道具/云移动 + 生成节奏；与可解性挂钩）
        G.elapsed  = 0          -- 已玩秒数（驱动加速 ramp + 动画切帧）
        G.boostT   = 0          -- 剩余加速秒数（>0 时加速生效）
        G.boostRed = false      -- 当前加速是否由红星（天上 3s）触发 → 恒红光不闪
        G.nextSpawnDist = api:Random(160, 280)   -- 第一只障碍出现的距离（给点起步缓冲）
        G.dead     = false
        G.running  = false
        G.placeDino(DINO_H, "run1", false, false)
    end,

    -- start：申请键盘 + 开 OnUpdate。围观者不绑输入、不跑逻辑。
    start = function(ctx, api)
        if api:IsSpectator() then return end
        local cv = api:Canvas()
        local G = ctx._dino
        if not cv or not G then return end

        local GROUND_Y = G.GROUND_Y
        local DINO_X, DINO_W, DINO_H, DUCK_H = G.DINO_X, G.DINO_W, G.DINO_H, G.DUCK_H
        local W = G.W

        -- 速度「慢启动→渐快」（像断网恐龙）。
        local SPD_MIN, SPD_MAX, RAMP = 280, 860, 22
        local GRAVITY  = 2400
        local JUMP_VEL = 760       -- 滞空 ~0.63s，跳高 ~120px（跳得过最高仙人掌/翼龙，够得到道具）

        -- 加速道具数值（分数/世界解耦）
        local BOOST_WORLD = 1.2    -- 加速时世界/障碍提速（风险，但 GAP_MIN 保证仍能落地再跳）
        local BOOST_SCORE = 1.5    -- 加速时分数提速（收益，吃道具明显多得分）
        local BOOST_DUR   = 1.0    -- 持续秒（默认/地上黄星）
        G.BOOST_WORLD, G.BOOST_SCORE, G.BOOST_DUR = BOOST_WORLD, BOOST_SCORE, BOOST_DUR
        G.BOOST_DUR_GROUND = 1.0   -- 地上黄星：加速 1s
        G.BOOST_DUR_AIR    = 3.0   -- 天上红星：加速 3s

        api:CaptureKeyboard(
            function(key)
                if key == "UP" or key == "SPACE" or key == "W" or key == "NUMPAD8" then
                    if G.jumpH <= 0 and not G.ducking then G.vy = JUMP_VEL end   -- 仅在地面起跳
                elseif key == "DOWN" or key == "S" or key == "NUMPAD2" then
                    G.ducking = true
                    if G.jumpH > 0 then G.vy = G.vy - 280 end                    -- 空中按下=加速下坠
                end
            end,
            function(key)
                if key == "DOWN" or key == "S" or key == "NUMPAD2" then G.ducking = false end
            end
        )

        local function die(msg)
            if G.dead then return end
            G.dead = true
            G.running = false
            if cv.SetScript then cv:SetScript("OnUpdate", nil) end
            -- 撞死那一刻把恐龙换成 dead 帧（叉叉眼）。
            if G.dino and G.applyFrame then
                G.applyFrame(G.dino, "dead")
                G.dino:SetVertexColor(1, 1, 1, 1)
                local botY = G.GROUND_Y - G.jumpH
                G.dino:ClearAllPoints()
                G.dino:SetPoint("BOTTOMLEFT", cv, "TOPLEFT", G.DINO_X, -botY)
                G.dino:Show()
            end
            if G.deathText then G.deathText:SetText(msg); G.deathText:Show() end
            api:Finish(math.floor(G.dist / 12))
        end
        G._die = die

        G.running = true
        cv:SetScript("OnUpdate", function(_, dt)
            if not G.running or G.dead then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.05 then dt = 0.05 end          -- 卡顿封顶（跳快 → 收紧防穿模）

            -- 基础速度 ramp + 加速道具加成（解耦：世界提速温和→保证可解；分数提速明显→吃道具值）。
            local base = SPD_MIN + (SPD_MAX - SPD_MIN) * math.min(1, G.elapsed / RAMP)
            local boosting = G.boostT > 0
            local worldSpeed = boosting and (base * G.BOOST_WORLD) or base
            local scoreSpeed = boosting and (base * G.BOOST_SCORE) or base
            if boosting then G.boostT = G.boostT - dt end
            G.elapsed = G.elapsed + dt
            G.worldDist = G.worldDist + worldSpeed * dt   -- 障碍/道具/生成节奏走世界距离
            G.dist = G.dist + scoreSpeed * dt              -- 计分走分数距离（加速时涨更快）

            -- 1) 竖直：重力 + 起跳。
            G.vy = G.vy - GRAVITY * dt
            G.jumpH = G.jumpH + G.vy * dt
            if G.jumpH <= 0 then G.jumpH = 0; G.vy = 0 end
            local airborne = G.jumpH > 0
            local dh = (G.ducking and not airborne) and DUCK_H or DINO_H

            -- 2) 障碍左移 + 回收。
            for i = 1, #G.obs do
                local o = G.obs[i]
                if o.active then
                    o.x = o.x - worldSpeed * dt
                    if o.x + o.w < 0 then o.active = false; o.tex:Hide()
                    else G.placeOb(o) end
                end
            end

            -- 2b) 道具左移 + 回收（独立池）。
            for i = 1, #G.boosts do
                local bz = G.boosts[i]
                if bz.active then
                    bz.x = bz.x - worldSpeed * dt
                    if bz.x + G.BOLT_W < 0 then bz.active = false; G.hideBoost(bz) end
                end
            end

            -- 2c) 云左移（装饰，慢速视差：用 0.4 倍速更有层次）。
            for i = 1, #G.clouds do
                local cz = G.clouds[i]
                if cz.active then
                    cz.x = cz.x - worldSpeed * 0.4 * dt
                    if cz.x + G.cloudW < 0 then cz.active = false; cz.tex:Hide()
                    else
                        cz.tex:ClearAllPoints()
                        cz.tex:SetPoint("TOPLEFT", cv, "TOPLEFT", cz.x, -cz.y)
                    end
                end
            end

            -- 3) 按世界距离生成新障碍（各端一致）。
            if G.worldDist >= G.nextSpawnDist then
                local free
                for i = 1, #G.obs do if not G.obs[i].active then free = G.obs[i]; break end end
                if free then
                    -- 用「触发本次生成的阈值」(=本障碍的世界距离，各端一致) 判定，绝不用受加速影响的 G.dist，
                    -- 否则 and 短路会让吃了加速的人少消耗一次 api:Random → 关卡序列各端不一致（不公平）。
                    local isBird = (G.nextSpawnDist >= G.BIRD_AFTER) and (api:Random(1, 100) <= G.BIRD_PCT)
                    if isBird then
                        free.kind = "bird"
                        free.spriteKey = "fly1"
                        free.w, free.h = G.obSize("fly1")
                        free.groundOffset = 40    -- 翼龙悬空（跳得过、也能蹲下钻过）
                    else
                        free.kind = "cactus"
                        -- 4 种仙人掌：小单/小双/大双/大丛
                        local pick = api:Random(1, 4)
                        free.spriteKey = (pick == 1 and "cactusS") or (pick == 2 and "cactusS2")
                                      or (pick == 3 and "cactusL") or "cactusL2"
                        free.w, free.h = G.obSize(free.spriteKey)
                        free.groundOffset = 0
                    end
                    free.x = W
                    free.active = true
                    G.placeOb(free)
                end
                G.nextSpawnDist = G.worldDist + G.nextGap()
            end

            -- 3b) 按世界距离生成加速道具（独立节奏；放在相对空旷处的高空）。
            if G.worldDist >= G.nextBoostDist then
                local free
                for i = 1, #G.boosts do if not G.boosts[i].active then free = G.boosts[i]; break end end
                -- 80% 地上黄星（加速 1s，跑过去就吃到）/ 20% 天上红星（加速 3s，必须跳起来才够）。
                -- ⚠️ 无论是否拿到 free 都先消耗这一次 api:Random，保证各端 RNG 序列一致（公平）。
                local onGround = api:Random(1, 100) <= 80
                if free then
                    free.x = W
                    if onGround then
                        free.y   = GROUND_Y - G.BOLT_H                  -- 贴地（底边落在地面线，跑过去就吃到）
                        free.col = G.C_STAR_GROUND                      -- 黄
                        free.dur = G.BOOST_DUR_GROUND                   -- 1s
                    else
                        free.y   = GROUND_Y - G.BOOST_HOVER - G.BOLT_H  -- 悬浮（需跳起来才够）
                        free.col = G.C_STAR_AIR                         -- 红
                        free.dur = G.BOOST_DUR_AIR                      -- 3s
                    end
                    free.active = true
                    G.placeBoost(free, true)
                end
                G.nextBoostDist = G.worldDist + api:Random(G.BOOST_GAP_MIN, G.BOOST_GAP_MAX)
            end

            -- 3c) 按世界距离生成云（纯装饰）。
            if G.worldDist >= G.nextCloudDist then
                local free
                for i = 1, #G.clouds do if not G.clouds[i].active then free = G.clouds[i]; break end end
                if free then
                    free.x = W
                    free.y = api:Random(20, math.floor(GROUND_Y * 0.45))  -- 顶部空域
                    free.active = true
                    G.placeCloud(free)
                end
                G.nextCloudDist = G.worldDist + api:Random(500, 1000)
            end

            -- 4) 碰撞检测（AABB）：恐龙包围盒。
            local dBot  = GROUND_Y - G.jumpH
            local dTop  = dBot - dh
            -- 4a) 障碍碰撞 = 死。
            for i = 1, #G.obs do
                local o = G.obs[i]
                if o.active then
                    local oTop = GROUND_Y - o.groundOffset - o.h
                    local oBot = GROUND_Y - o.groundOffset
                    -- 用略收紧的包围盒（精灵留白），手感更宽容。
                    local PAD = 4
                    if (DINO_X + PAD < o.x + o.w) and (DINO_X + DINO_W - PAD > o.x)
                       and (dTop + PAD < oBot) and (dBot - PAD > oTop) then
                        die("撞 上 了！"); return
                    end
                end
            end
            -- 4b) 道具碰撞 = 吃（获得/刷新加速，不死）。
            for i = 1, #G.boosts do
                local bz = G.boosts[i]
                if bz.active and not bz.eaten then
                    local bTop = bz.y
                    local bBot = bz.y + G.BOLT_H
                    if (DINO_X < bz.x + G.BOLT_W) and (DINO_X + DINO_W > bz.x)
                       and (dTop < bBot) and (dBot > bTop) then
                        bz.active = false
                        G.hideBoost(bz)
                        G.boostT = bz.dur or G.BOOST_DUR   -- 获得/刷新加速（地上黄星 1s / 天上红星 3s）
                        G.boostRed = (bz.col == G.C_STAR_AIR)   -- 红星 → 恒红光不闪；黄星 → 金色闪
                    end
                end
            end

            -- 5) 计分（距离/12 = 米）。
            api:SetScore(math.floor(G.dist / 12))

            -- 6) 选帧 + 重绘恐龙。
            local frameKey
            if airborne then
                frameKey = "jump"
            elseif G.ducking then
                -- 下蹲跑动两帧（约 10fps）
                frameKey = (math.floor(G.elapsed * 10) % 2 == 0) and "duck1" or "duck2"
            else
                -- 站立跑动两帧（约 10fps，两腿交替）
                frameKey = (math.floor(G.elapsed * 10) % 2 == 0) and "run1" or "run2"
            end
            -- 加速着色闪烁（约 14fps 金/原交替）
            local blink = (math.floor(G.elapsed * 14) % 2 == 0)
            G.placeDino(dh, frameKey, boosting, blink)

            -- 6b) 道具闪烁重绘（活动中的道具持续闪光）。
            local bblink = (math.floor(G.elapsed * 8) % 2 == 0)
            for i = 1, #G.boosts do
                local bz = G.boosts[i]
                if bz.active and not bz.eaten then G.placeBoost(bz, bblink) end
            end
        end)
    end,

    -- stop：时间到 / 收尾 → 停循环冻结。
    stop = function(ctx, api)
        local G = ctx._dino
        if G then G.running = false end
        local cv = api:Canvas()
        if cv then cv:SetScript("OnUpdate", nil) end
    end,

    -- teardown：清理一切（停循环、隐藏元素）。幂等。
    teardown = function(ctx, api)
        local cv = api:Canvas()
        local G = ctx._dino
        if cv then cv:SetScript("OnUpdate", nil) end
        if G then
            G.running = false
            if G.ground then G.ground:Hide() end
            if G.dino then G.dino:Hide() end
            if G.deathText then G.deathText:Hide() end
            if G.obs then for i = 1, #G.obs do if G.obs[i].tex then G.obs[i].tex:Hide() end end end
            if G.boosts then for i = 1, #G.boosts do
                local bz = G.boosts[i]
                if bz.rects then for k = 1, #bz.rects do bz.rects[k]:Hide() end end
            end end
            if G.clouds then for i = 1, #G.clouds do if G.clouds[i].tex then G.clouds[i].tex:Hide() end end end
        end
        ctx._dino = nil
    end,

    onTie = function(ctx, api) end,
    onResult = function(ctx) end,
}
]]

------------------------------------------------------------
-- 从 SOURCE 跑出 def，并把源码挂回 def.code（供 ExportGame 打包，§6）
------------------------------------------------------------
local def = assert(loadstring(SOURCE))()
def.code = SOURCE

local GAME_VERSION = def.version

------------------------------------------------------------
-- 注册（核心未就绪则压 pending 队列）—— 照 SpeedClick 外层引导
------------------------------------------------------------
local GL = _G.GameLobby
if GL and GL.RegisterGame then
    GL:RegisterGame(def)
elseif GL and GL._pendingGames then
    table.insert(GL._pendingGames, def)
else
    _G.GameLobby_pendingGames = _G.GameLobby_pendingGames or {}
    table.insert(_G.GameLobby_pendingGames, def)
end
