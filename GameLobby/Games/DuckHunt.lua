-- Games/DuckHunt.lua —— 打鸭子（canvas 档自绘游戏，契约 §2 游戏 def / game-dev-spec）
-- owner: wow-addon-engineer
--
-- 玩法：10 秒内画布里有若干飞行方块四处移动（碰边反弹），鼠标点中一个 → 加分、
--   该目标立即在随机位置以新随机速度重生。得分多者胜（desc）。
--   ★ 方块分大/中/小三档：越大越好打→分越低(大=1)，越小越难打→分越高(中=2/小=4)；颜色随尺寸固定(蓝大/金中/红小)。
--   ★ 命中反馈(1.2.0)：点中处冒白色爆闪 + 绿色「+N」飘字（上浮淡出），一眼看清这一下加了多少分。
--   - 移动用 OnUpdate 的 dt 驱动（帧率无关，spec §8）。
--   - 命中只走 api:AddScore(1)，绝不自己发通讯（不变量 #2）。
--   - 初始位置/速度用 api:Random（框架确定性随机，各端开局一致，公平，spec §4）；WoW 无 math.randomseed。
--   - 围观者（api:IsSpectator）目标照飞可看，但点击不计分（命中回调里判空返回）。
--
-- 不变量 #1（同体）：首行 aura_env；本游戏独立版本门控（为 WA 热升级铺路）。
-- 加载顺序鲁棒：核心未就绪则压 _G.GameLobby._pendingGames，Init.lua 回收注册（照 SpeedClick）。
--
-- 【分享/同源（spec §6）】：def 本体写成自包含源码字符串 SOURCE，loadstring(SOURCE)() 出 def，
--   def.code = SOURCE 供 GL.Import:ExportGame 打包分享。SOURCE 内只用 ctx/api/全局/自身 local，
--   不引用本文件外层任何 upvalue（导入方 loadstring 时没有这些环境，会报 nil）。

local self = aura_env or {}

------------------------------------------------------------
-- 游戏 def 的自包含源码（SOURCE）
------------------------------------------------------------
-- 这段字符串就是「打鸭子是什么」的全部定义：loadstring 后 return 出一张 def 表。
-- 它不依赖本文件任何 local/upvalue，只用 ctx/api 形参和全局（GetTime/math/CreateFrame/_G.GameLobby）。

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "duckhunt",
    name      = "打鸭子",
    version   = "1.2.1",                          -- 独立版本门控（热升级）；改版本同时改这里
    glyph     = "Interface\\Icons\\Ability_Hunter_AspectOfTheViper",
    descLines = { "10 秒打鸭", "越小越值钱" },

    --==== 元数据（框架据此通用排名/校验/展示，spec §3）====--
    tier        = "canvas",                        -- 自绘档：用 api:Canvas() 自己作画
    endMode     = "timed",                         -- 固定时间窗口，到点全员同时停
    scoreOrder  = "desc",                          -- 得分多者胜
    scoreUnit   = "分",                            -- 计分单位（加权：小方块更值钱，不是单纯计数）
    duration    = 10.0,                            -- 10 秒窗口
    needsKeyboard = false,                         -- 鼠标点击，不要键盘
    seeded      = true,                            -- 统一种子定初始布局（公平）
    scoreCap    = function(dur) return (dur or 10) * 20 end,  -- 上限：时长×单秒20，10s=200（小=3 分也够）
    locked      = false,

    --==== 生命周期（spec §2）====--

    -- setup：建目标对象池 + 用种子定初始位置/速度，但**别开始飞**（不挂 OnUpdate）。
    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end                  -- PlayingScreen 未就绪（纯逻辑单测）时静默

        -- 自己的私有状态全挂在 canvas 上（同一画布、跨生命周期共享；teardown 清理）。
        -- 复用对象：对象池只在 setup 建一次，重生只改位置/速度，绝不每次 CreateFrame（spec §8）。
        local state = cv._gl_duckhunt or {}
        cv._gl_duckhunt = state

        local N = 6                                -- 同时在场的目标数（5~8 取 6）
        state.targets = state.targets or {}
        -- 尺寸档：越大越好打→分越低，越小越难打→分越高；颜色随尺寸固定（一眼看出值多少分）。
        local TIERS = {
            { size = 56, score = 1, color = { 0.40, 0.72, 1.0 } },   -- 大·蓝·1 分（易，低）
            { size = 40, score = 2, color = { 1.0, 0.82, 0.20 } },   -- 中·金·2 分
            { size = 26, score = 4, color = { 1.0, 0.36, 0.36 } },   -- 小·红·4 分（最难，最值钱）
        }
        state.tiers = TIERS

        -- ⚠️ WoW 沙箱无 math.randomseed；初始位置/速度用框架确定性随机 api:Random（各端开局一致，公平）。

        -- 画布尺寸：setup 时拿一次估值（可能尚未布局，start 里会再校正）。
        local cw = (cv.GetWidth and cv:GetWidth()) or 600
        local ch = (cv.GetHeight and cv:GetHeight()) or 360
        if not cw or cw < 80 then cw = 600 end
        if not ch or ch < 80 then ch = 360 end

        -- 给定一个目标，随机位置 + 随机速度（重生/初始化共用）。speed 单位：像素/秒。
        local function respawn(t)
            local sz = t.size or 40                -- 用各目标自己的尺寸（边界按各自尺寸算）
            local maxX = (state.cw or cw) - sz
            local maxY = (state.ch or ch) - sz
            if maxX < 1 then maxX = 1 end
            if maxY < 1 then maxY = 1 end
            t.x = api:Random() * maxX
            t.y = api:Random() * maxY
            -- 速度：120~260 px/s，方向随机（避免接近 0 导致几乎不动）。
            local sp = 120 + api:Random() * 140
            local ang = api:Random() * 6.2831853                  -- 0~2π
            t.vx = math.cos(ang) * sp
            t.vy = math.sin(ang) * sp
            -- 防止纯水平/垂直（视觉单调）：分量太小则补一点。
            if math.abs(t.vx) < 30 then t.vx = (t.vx >= 0 and 30 or -30) end
            if math.abs(t.vy) < 30 then t.vy = (t.vy >= 0 and 30 or -30) end
        end
        state.respawn = respawn

        -- 把估算尺寸先存一份（respawn 会用）。
        state.cw, state.ch = cw, ch

        -- 建/复用对象池：每个目标是一个可点击 Frame（EnableMouse + OnMouseDown）。
        for i = 1, N do
            local tier = TIERS[((i - 1) % #TIERS) + 1]   -- 各档均分（6 个 = 2 大 2 中 2 小）
            local t = state.targets[i]
            if not t then
                t = {}
                local btn = CreateFrame("Frame", nil, cv)         -- 画布内子 Frame（不建顶层）
                btn:SetSize(tier.size, tier.size)
                btn:EnableMouse(true)
                -- 纯色方块：颜色随尺寸档固定（蓝大/金中/红小），一眼看出分值。
                local tex = btn:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints(btn)
                local c = tier.color
                if tex.SetColorTexture then tex:SetColorTexture(c[1], c[2], c[3], 1) end
                -- 高光小点（中心），增加可读性。
                local dot = btn:CreateTexture(nil, "OVERLAY")
                dot:SetSize(tier.size * 0.35, tier.size * 0.35)
                dot:SetPoint("CENTER", btn, "CENTER", -tier.size * 0.12, tier.size * 0.12)
                if dot.SetColorTexture then dot:SetColorTexture(1, 1, 1, 0.55) end
                t.frame = btn
                t.tex = tex
                state.targets[i] = t
            end
            -- 尺寸/分值固定一档，重生不变 → 颜色恒等于分值档（满足「同色=同分」）。
            t.size = tier.size
            t.score = tier.score
            -- 命中回调：围观者不计分；命中 → api:AddScore(分值) → 立即重生（新位置/新速度）。
            -- 用 state.respawn（上面这次 setup 的闭包），加赛/重开 setup 会刷新此引用。
            t.frame:SetScript("OnMouseDown", function()
                if not state.active then return end               -- 仅 start 后、stop 前可命中
                if api:IsSpectator() then return end              -- 围观者点击不计分
                local gain = t.score or 1
                -- 命中处（旧位置中心）冒绿字「+N」+ 白色爆闪。
                local cx = (t.x or 0) + (t.size or 40) * 0.5
                local cy = (t.y or 0) + (t.size or 40) * 0.5
                api:AddScore(gain)                                -- 加权计分：大=1 / 中=2 / 小=3
                if state.spawnPop then state.spawnPop(cx, cy, gain, t.size or 40) end
                local rs = state.respawn
                if rs then rs(t) end
                -- 命中后立即应用新位置（不等下一帧），手感更跟手。
                if t.frame and t.frame.ClearAllPoints then
                    t.frame:ClearAllPoints()
                    t.frame:SetPoint("TOPLEFT", state.canvas or cv, "TOPLEFT", t.x, -t.y)
                end
            end)
            -- 初始位置/速度（种子决定）。
            respawn(t)
            t.frame:ClearAllPoints()
            t.frame:SetPoint("TOPLEFT", cv, "TOPLEFT", t.x, -t.y)
            t.frame:Show()
        end
        state.canvas = cv

        -- ===== 命中特效池：绿色「+N」飘字 + 白色爆闪（命中处冒出，上浮淡出；dt 驱动）=====
        state.pops = state.pops or {}
        local POP_N = 10
        for i = 1, POP_N do
            local pop = state.pops[i]
            if not pop then
                local fs = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                if fs.SetTextColor then fs:SetTextColor(0.30, 1.0, 0.35) end   -- 绿字
                fs:Hide()
                local flash = cv:CreateTexture(nil, "OVERLAY")
                if flash.SetColorTexture then flash:SetColorTexture(1, 1, 1, 1) end
                flash:Hide()
                pop = { fs = fs, flash = flash, active = false, t = 0, x = 0, y = 0, sz = 40 }
                state.pops[i] = pop
            end
            pop.active = false; pop.fs:Hide(); pop.flash:Hide()
        end
        state.popIdx = 0
        state.POP_DUR = 0.6
        -- 在命中目标中心 (cx,cy) 冒一个「+score」绿字 + 白色爆闪（循环复用池位）。
        state.spawnPop = function(cx, cy, score, sz)
            local n = #state.pops
            if n == 0 then return end
            state.popIdx = (state.popIdx % n) + 1
            local pop = state.pops[state.popIdx]
            pop.active = true; pop.t = 0; pop.x = cx; pop.y = cy; pop.sz = sz or 40
            if pop.fs.SetText then pop.fs:SetText("+" .. (score or 1)) end
            if pop.fs.SetTextColor then pop.fs:SetTextColor(0.30, 1.0, 0.35) end
            pop.fs:SetAlpha(1)
            pop.fs:ClearAllPoints()
            pop.fs:SetPoint("CENTER", cv, "TOPLEFT", cx, -cy)
            pop.fs:Show()
            pop.flash:SetAlpha(0.55)
            pop.flash:Show()
        end

        state.active = false                       -- setup 只建不动：还不许命中、还不飞
    end,

    -- start："GO!"：校正画布尺寸、开 OnUpdate（dt 驱动移动 + 边界反弹）、允许命中。
    start = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end
        local state = cv._gl_duckhunt
        if not state or not state.targets then return end

        -- 开赛时画布已最终布局，用真实尺寸校正（setup 时可能尚未定尺寸）。
        local cw = (cv.GetWidth and cv:GetWidth()) or state.cw or 600
        local ch = (cv.GetHeight and cv:GetHeight()) or state.ch or 360
        if cw and cw >= 80 then state.cw = cw end
        if ch and ch >= 80 then state.ch = ch end

        state.active = true                        -- 允许命中计分

        -- OnUpdate：用 dt 把每个目标按速度移动，碰画布边界反弹（帧率无关）。
        cv:SetScript("OnUpdate", function(frame, dt)
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.1 then dt = 0.1 end          -- 卡顿/切后台跳帧时夹住，避免穿墙
            local cw2 = (state.cw or 600)
            local ch2 = (state.ch or 360)
            local tgts = state.targets
            for i = 1, #tgts do
                local t = tgts[i]
                local s = t.size or 40             -- 每个目标按各自尺寸算反弹边界
                local maxX = cw2 - s; if maxX < 1 then maxX = 1 end
                local maxY = ch2 - s; if maxY < 1 then maxY = 1 end
                t.x = (t.x or 0) + (t.vx or 0) * dt
                t.y = (t.y or 0) + (t.vy or 0) * dt
                -- 边界反弹（夹回界内 + 反向速度）。
                if t.x < 0 then t.x = 0; t.vx = -(t.vx or 0) end
                if t.x > maxX then t.x = maxX; t.vx = -(t.vx or 0) end
                if t.y < 0 then t.y = 0; t.vy = -(t.vy or 0) end
                if t.y > maxY then t.y = maxY; t.vy = -(t.vy or 0) end
                local f = t.frame
                if f then
                    f:ClearAllPoints()
                    f:SetPoint("TOPLEFT", cv, "TOPLEFT", t.x, -t.y)
                end
            end

            -- 命中飘字 + 爆闪：绿字上浮淡出，白闪先放大再淡出（dt 驱动，帧率无关）。
            local pops = state.pops
            if pops then
                local DUR = state.POP_DUR or 0.6
                for i = 1, #pops do
                    local pop = pops[i]
                    if pop.active then
                        pop.t = pop.t + dt
                        local a = pop.t / DUR
                        if a >= 1 then
                            pop.active = false; pop.fs:Hide(); pop.flash:Hide()
                        else
                            pop.fs:ClearAllPoints()
                            pop.fs:SetPoint("CENTER", cv, "TOPLEFT", pop.x, -(pop.y - 34 * a))
                            pop.fs:SetAlpha(1 - a)
                            if a < 0.45 then
                                local fa = a / 0.45
                                local fsz = pop.sz * (0.6 + fa * 1.1)
                                pop.flash:SetSize(fsz, fsz)
                                pop.flash:ClearAllPoints()
                                pop.flash:SetPoint("CENTER", cv, "TOPLEFT", pop.x, -pop.y)
                                pop.flash:SetAlpha(0.55 * (1 - fa))
                                pop.flash:Show()
                            else
                                pop.flash:Hide()
                            end
                        end
                    end
                end
            end
        end)
    end,

    -- stop：时间到 → 停 OnUpdate、冻结（不再计分）。分数已在 api 里，框架统一收。
    stop = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end
        local state = cv._gl_duckhunt
        if not state then return end
        state.active = false                       -- 命中回调即刻失效（冻结）
        if cv.SetScript then cv:SetScript("OnUpdate", nil) end
    end,

    -- teardown：清理一切（停 OnUpdate、隐藏目标、解绑点击）。必须幂等（可能多次调）。
    teardown = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end
        if cv.SetScript then cv:SetScript("OnUpdate", nil) end
        local state = cv._gl_duckhunt
        if not state then return end
        state.active = false
        if state.targets then
            for i = 1, #state.targets do
                local t = state.targets[i]
                if t and t.frame then
                    if t.frame.SetScript then t.frame:SetScript("OnMouseDown", nil) end
                    if t.frame.Hide then t.frame:Hide() end
                end
            end
        end
        if state.pops then
            for i = 1, #state.pops do
                local pop = state.pops[i]
                pop.active = false
                if pop.fs then pop.fs:Hide() end
                if pop.flash then pop.flash:Hide() end
            end
        end
    end,

    -- onTie：被选中加赛——复用 setup+start（不实现也行，框架会复用）。这里显式留空，
    --   靠框架重走 setup（重新播种 → round 变 → 新布局）+ start。
    onTie = function(ctx, api) end,

    onResult = function(ctx) end,
}
]]

------------------------------------------------------------
-- 从 SOURCE 跑出 def，并把源码挂回 def.code（供 ExportGame 打包，spec §6）
------------------------------------------------------------
local def = assert(loadstring(SOURCE))()
def.code = SOURCE

-- 本游戏独立版本号（外层引导/日志用，与 SOURCE 内 version 一致）。
local GAME_VERSION = def.version

------------------------------------------------------------
-- 注册（核心未就绪则压 pending 队列）—— 照 SpeedClick 的引导逻辑
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
