-- Games/Dino.lua —— 小恐龙跳一跳（canvas 自绘游戏，仿 Chrome 断网恐龙；契约 game-dev-spec §1/§2/§5.3）
-- owner: wow-addon-engineer
--
-- 玩法（玩到死，比跑的距离）：
--   一只小恐龙在原地自动奔跑，地面与障碍（仙人掌/飞鸟）从右往左滚来，速度由慢到快（像断网恐龙）。
--   按 空格/↑/W 跳跃越过障碍；按 ↓/S 下蹲从飞鸟下钻过（飞鸟也可跳过）。撞到障碍 → 立即出局。
--   分数 = 跑过的距离（米）；跑得越远分越高。endMode=elimination：撞死即结算，多人比谁跑得远。
--
-- 可解性保证（绝不出现「躲不掉」的障碍）：
--   ★ 障碍按「世界距离」间隔生成（不是按帧时间）→ 各端关卡完全一致（公平，§4）。
--   ★ 相邻障碍水平间距 ≥ 一次跳跃的滞空横距（按最快速度算），保证总能落地再跳、永远过得去。
--   ★ 飞鸟高度设计成「跳得过、也能蹲下钻过」，不强制下蹲。
--
-- 不变量 #2（解耦）：只走 api（SetScore/Finish/Canvas/CaptureKeyboard/Random/IsSpectator），绝不发通讯。
-- 公平（§4）：障碍序列用 api:Random（框架确定性随机；WoW 无 math.randomseed）按距离生成，各端一致。
-- 自包含（§6）：def 本体写在 SOURCE，只用 ctx/api/全局/自身 local，绝不引用 SOURCE 外 upvalue。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "dino",
    name      = "小恐龙跳一跳",
    version   = "1.0.0",
    glyph     = "Interface\\Icons\\Ability_Hunter_Pet_Devilsaur",
    descLines = { "跳过仙人掌，越跑越快", "撞上即出局，比谁跑得远" },

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

    -- setup：建地面 + 恐龙 + 障碍对象池，用种子准备关卡，但别动。
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

        -- ===== 参数 =====
        local GROUND_Y  = H * 0.82               -- 地面线距画布顶（向下为正）
        local DINO_X    = W * 0.12               -- 恐龙固定横位
        local DINO_W    = 24
        local DINO_H    = 34                      -- 站立高
        local DUCK_H    = 20                      -- 下蹲高
        local GAP_MIN   = 600                     -- 相邻障碍最小水平间距（按最快速度留余量，最快也跳得过）
        local GAP_MAX   = 900
        local BIRD_AFTER = 260                    -- 跑过这么远后才可能出飞鸟
        local BIRD_PCT  = 28                      -- 飞鸟占比（%）
        G.GROUND_Y, G.DINO_X, G.DINO_W, G.DINO_H, G.DUCK_H = GROUND_Y, DINO_X, DINO_W, DINO_H, DUCK_H
        G.GAP_MIN, G.GAP_MAX, G.BIRD_AFTER, G.BIRD_PCT = GAP_MIN, GAP_MAX, BIRD_AFTER, BIRD_PCT

        G.nextGap = function() return api:Random(GAP_MIN, GAP_MAX) end

        -- ===== 地面线 =====
        local ground = cv:CreateTexture(nil, "ARTWORK")
        ground:SetColorTexture(0.55, 0.55, 0.58, 1)
        ground:SetSize(W, 2)
        ground:SetPoint("TOPLEFT", cv, "TOPLEFT", 0, -GROUND_Y)
        ground:Show()
        G.ground = ground

        -- ===== 恐龙（绿色方块 + 眼睛）=====
        local dino = cv:CreateTexture(nil, "OVERLAY")
        dino:SetColorTexture(0.42, 0.78, 0.42, 1)
        dino:SetSize(DINO_W, DINO_H)
        G.dino = dino
        local eye = cv:CreateTexture(nil, "OVERLAY")
        eye:SetColorTexture(0.05, 0.05, 0.05, 1)
        eye:SetSize(4, 4)
        G.eye = eye
        G.placeDino = function(dh)
            local topY = GROUND_Y - G.jumpH - dh        -- 恐龙顶边距画布顶
            dino:SetSize(DINO_W, dh)
            dino:ClearAllPoints()
            dino:SetPoint("TOPLEFT", cv, "TOPLEFT", DINO_X, -topY)
            dino:Show()
            eye:ClearAllPoints()
            eye:SetPoint("TOPLEFT", cv, "TOPLEFT", DINO_X + DINO_W - 8, -(topY + 6))
            eye:Show()
        end

        -- ===== 障碍对象池（仙人掌=深绿条 / 飞鸟=灰条）=====
        local POOL = 7
        G.obs = {}
        for i = 1, POOL do
            local t = cv:CreateTexture(nil, "ARTWORK")
            t:Hide()
            G.obs[i] = { tex = t, active = false, x = 0, w = 0, h = 0, groundOffset = 0, kind = "cactus" }
        end
        G.placeOb = function(o)
            local t = o.tex
            if o.kind == "bird" then t:SetColorTexture(0.78, 0.78, 0.82, 1)
            else t:SetColorTexture(0.20, 0.52, 0.22, 1) end
            t:SetSize(o.w, o.h)
            local topY = GROUND_Y - o.groundOffset - o.h
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", cv, "TOPLEFT", o.x, -topY)
            t:Show()
        end

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
        G.dist     = 0          -- 已跑世界距离
        G.elapsed  = 0          -- 已玩秒数（驱动加速）
        G.nextSpawnDist = api:Random(160, 280)   -- 第一只障碍出现的距离（给点起步缓冲）
        G.dead     = false
        G.running  = false
        G.placeDino(DINO_H)
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

        -- 速度「慢启动→渐快」（像断网恐龙）：top 提到 860，后段更快，分数拉得开避免平局。
        local SPD_MIN, SPD_MAX, RAMP = 280, 860, 22
        local GRAVITY  = 2400
        local JUMP_VEL = 730       -- 滞空 ~0.6s，跳高 ~111px（跳得过最高仙人掌/飞鸟）

        api:CaptureKeyboard(
            function(key)
                if key == "UP" or key == "SPACE" or key == "W" or key == "NUMPAD8" then
                    if G.jumpH <= 0 and not G.ducking then G.vy = JUMP_VEL end   -- 仅在地面起跳
                elseif key == "DOWN" or key == "S" or key == "NUMPAD2" then
                    G.ducking = true
                    if G.jumpH > 0 then G.vy = G.vy - 260 end                    -- 空中按下=加速下坠
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

            local speed = SPD_MIN + (SPD_MAX - SPD_MIN) * math.min(1, G.elapsed / RAMP)
            G.elapsed = G.elapsed + dt
            G.dist = G.dist + speed * dt

            -- 1) 竖直：重力 + 起跳。
            G.vy = G.vy - GRAVITY * dt
            G.jumpH = G.jumpH + G.vy * dt
            if G.jumpH <= 0 then G.jumpH = 0; G.vy = 0 end
            local dh = (G.ducking and G.jumpH <= 0) and DUCK_H or DINO_H

            -- 2) 障碍左移 + 回收。
            for i = 1, #G.obs do
                local o = G.obs[i]
                if o.active then
                    o.x = o.x - speed * dt
                    if o.x + o.w < 0 then o.active = false; o.tex:Hide()
                    else G.placeOb(o) end
                end
            end

            -- 3) 按距离生成新障碍（各端一致）。
            if G.dist >= G.nextSpawnDist then
                local free
                for i = 1, #G.obs do if not G.obs[i].active then free = G.obs[i]; break end end
                if free then
                    local isBird = (G.dist > G.BIRD_AFTER) and (api:Random(1, 100) <= G.BIRD_PCT)
                    if isBird then
                        free.kind = "bird"; free.w = 34; free.h = 18; free.groundOffset = 20
                    else
                        free.kind = "cactus"; free.w = api:Random(16, 40); free.h = api:Random(30, 54)
                        free.groundOffset = 0
                    end
                    free.x = W
                    free.active = true
                    G.placeOb(free)
                end
                G.nextSpawnDist = G.dist + G.nextGap()
            end

            -- 4) 碰撞检测（AABB）：恐龙 vs 每个活动障碍。
            local dTop  = GROUND_Y - G.jumpH - dh
            local dBot  = GROUND_Y - G.jumpH
            for i = 1, #G.obs do
                local o = G.obs[i]
                if o.active then
                    local oTop = GROUND_Y - o.groundOffset - o.h
                    local oBot = GROUND_Y - o.groundOffset
                    if (DINO_X < o.x + o.w) and (DINO_X + DINO_W > o.x)
                       and (dTop < oBot) and (dBot > oTop) then
                        die("撞 上 了！"); return
                    end
                end
            end

            -- 5) 计分（距离/12 = 米）。
            api:SetScore(math.floor(G.dist / 12))

            -- 6) 重绘恐龙。
            G.placeDino(dh)
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
            if G.eye then G.eye:Hide() end
            if G.deathText then G.deathText:Hide() end
            if G.obs then for i = 1, #G.obs do if G.obs[i].tex then G.obs[i].tex:Hide() end end end
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
