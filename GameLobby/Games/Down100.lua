-- Games/Down100.lua —— 是男人就下 100 层（自绘档 canvas 游戏，elimination 玩到死）
-- owner: wow-addon-engineer
--
-- 玩法（玩到死，比下降层数）：
--   平台一排排恒定向上滚动；角色站在平台上会被平台「托着一起上移」（骑乘）。
--   玩家按 方向键/AD 左右移动，对准平台缺口让角色坠到下一层；每下一层 = 层数 +1。
--   死亡（立即出局、分定格）：①被平台托到画布顶部（出顶）②坠出画布底部 ③落到带刺平台（红色）。
--   平台稀疏（间距大），且约三成平台带刺 → 更容易摔死。endMode=elimination：
--   单人死即结算；多人各自死，全员死或到 maxDuration 结算，下降层数多者胜。
--
-- 不变量 #2（解耦）：只走 api（SetScore/Finish/Canvas/CaptureKeyboard/Random/IsSpectator），绝不发通讯。
-- 公平（§4）：setup 里用 api:Random（框架确定性随机；WoW 无 math.randomseed）生成关卡，各端一致。
-- 自包含（§6）：def 本体写在 SOURCE，只用 ctx/api/全局/自身 local，绝不引用 SOURCE 外 upvalue。

local self = aura_env or {}

local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "down100",
    name      = "是男人就下 100 层",
    version   = "1.1.0",                    -- 独立版本门控；改版本同步改这里（高版本胜，替换占位）
    glyph     = "Interface\\Icons\\Ability_Rogue_Sprint",
    descLines = { "踩平台往下，越深越高", "撞刺/出顶/坠底即死" },

    --==== 元数据（框架据此通用排名/校验/展示）====--
    tier        = "canvas",
    endMode     = "elimination",             -- 玩到死：撞刺/被顶出/坠落 → 立即出局，分定格在已下层数
    scoreOrder  = "desc",
    scoreUnit   = "层",
    duration    = 60,                        -- maxDuration 兜底（一般撑不到；没死满 60s 也强制结算）
    needsKeyboard = true,
    seeded      = true,
    scoreCap    = function() return 999 end, -- 仅防离谱上报
    locked      = false,

    --==== 生命周期 ====--

    -- setup：建画布元素（角色 + 稀疏平台对象池，约三成带刺）、用种子生成关卡，但别动。
    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end

        local G = {}
        ctx._d100 = G                          -- 私有命名空间，不写 ctx 框架字段

        local W = (cv.GetWidth and cv:GetWidth()) or 720
        local H = (cv.GetHeight and cv:GetHeight()) or 460
        if not W or W <= 0 then W = 720 end
        if not H or H <= 0 then H = 460 end
        G.W, G.H = W, H

        -- ===== 关卡参数（稀疏：行距大、平台少）=====
        local ROW_GAP   = 150                  -- 相邻平台行竖直间距（大 → 稀疏 → 更易摔死）
        local GAP_W     = 80                   -- 平台缺口宽度（角色 18 宽）
        local PLAT_H    = 12
        local CHAR_SZ   = 18
        local NUM_PLAT  = 8                     -- 平台对象池（H 内只铺得下 ~3 行，余量回收）
        local SPIKE_PCT = 28                   -- 带刺平台占比（%）
        G.ROW_GAP, G.GAP_W, G.PLAT_H, G.CHAR_SZ, G.SPIKE_PCT = ROW_GAP, GAP_W, PLAT_H, CHAR_SZ, SPIKE_PCT

        -- 缺口 x（种子确定 → 各端一致）。
        local maxGapX = W - GAP_W
        if maxGapX < 0 then maxGapX = 0 end
        G.nextGapX  = function() return api:Random(0, maxGapX) end
        G.nextSpike = function() return api:Random(1, 100) <= SPIKE_PCT end

        -- ===== 平台对象池（复用 Texture）=====
        -- 每行 = 左段 + 右段（中间缺口）。带刺平台整行染红，落上即死。
        G.plats = {}
        for i = 1, NUM_PLAT do
            local left  = cv:CreateTexture(nil, "ARTWORK")
            local right = cv:CreateTexture(nil, "ARTWORK")
            G.plats[i] = { left = left, right = right, y = 0, gapX = 0, spiked = false, _passed = false }
        end

        -- 放置一行：y = 该行顶距画布顶（向下为正）。带刺=红，普通=蓝。
        G.placeRow = function(p)
            local gapX = p.gapX
            local lw = gapX
            local rw = W - (gapX + GAP_W)
            if lw < 0 then lw = 0 end
            if rw < 0 then rw = 0 end
            local r, g, b = 0.45, 0.62, 0.85
            if p.spiked then r, g, b = 0.90, 0.22, 0.16 end   -- 带刺平台：醒目红
            local L, R = p.left, p.right
            L:ClearAllPoints(); R:ClearAllPoints()
            if lw > 0 then
                L:SetColorTexture(r, g, b, 1); L:SetSize(lw, PLAT_H)
                L:SetPoint("TOPLEFT", cv, "TOPLEFT", 0, -p.y); L:Show()
            else L:Hide() end
            if rw > 0 then
                R:SetColorTexture(r, g, b, 1); R:SetSize(rw, PLAT_H)
                R:SetPoint("TOPLEFT", cv, "TOPLEFT", gapX + GAP_W, -p.y); R:Show()
            else R:Hide() end
        end

        -- 初始铺一串平台（第一行不带刺，给角色安全落脚）。
        local startY = H * 0.42
        for i = 1, NUM_PLAT do
            local p = G.plats[i]
            p.gapX   = G.nextGapX()
            p.spiked = (i > 1) and G.nextSpike() or false
            p.y      = startY + (i - 1) * ROW_GAP
            p._passed = false
            G.placeRow(p)
        end

        -- ===== 角色 =====
        local hero = cv:CreateTexture(nil, "OVERLAY")
        hero:SetColorTexture(1.0, 0.82, 0.25, 1)
        hero:SetSize(CHAR_SZ, CHAR_SZ)
        G.hero = hero
        G.heroX = (W - CHAR_SZ) * 0.5
        G.heroY = H * 0.18                     -- 起点稍高于第一行，落下即站稳
        G.vy    = 0
        G.placeHero = function()
            hero:ClearAllPoints()
            hero:SetPoint("TOPLEFT", cv, "TOPLEFT", G.heroX, -G.heroY)
        end
        G.placeHero()

        -- ===== 死亡提示文字（居中，初始隐藏）=====
        local dtext = cv:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        dtext:SetPoint("CENTER", cv, "CENTER", 0, 0)
        dtext:SetTextColor(1.0, 0.35, 0.25)
        dtext:Hide()
        G.deathText = dtext

        -- ===== 物理 / 计分态 =====
        G.depth    = 0
        G.held     = { left = false, right = false }
        G.rest     = nil        -- 当前所踩平台（骑乘上移）；nil=自由下落
        G.dead     = false
        G.running  = false
    end,

    -- start：申请键盘 + 开 OnUpdate。围观者不绑输入、不跑逻辑。
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

        local MOVE_SPD = 300
        local SCROLL   = 55        -- 平台上滚速度（也是骑乘上移速度）：决定「不动多久被顶死」
        local GRAVITY  = 900
        local MAX_VY   = 560
        local W, H     = G.W, G.H
        local CHAR_SZ  = G.CHAR_SZ
        local PLAT_H   = G.PLAT_H
        local GAP_W    = G.GAP_W
        local ROW_GAP  = G.ROW_GAP

        -- 角色水平区间是否完全落在某行缺口内（在缺口内=可穿过，否则=踩在实心上）。
        local function inGap(p)
            return (G.heroX >= p.gapX) and (G.heroX + CHAR_SZ <= p.gapX + GAP_W)
        end

        local function die(reason)
            if G.dead then return end
            G.dead = true
            G.running = false
            if cv.SetScript then cv:SetScript("OnUpdate", nil) end
            if G.deathText then
                G.deathText:SetText("摔 死 了 · " .. reason)
                G.deathText:Show()
            end
            api:Finish(G.depth)    -- elimination：本端出局 → 框架结算（单人立即出结果）
        end
        G._die = die

        G.running = true
        cv:SetScript("OnUpdate", function(_, dt)
            if not G.running or G.dead then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.1 then dt = 0.1 end

            -- 1) 水平移动。
            if G.held.left  then G.heroX = G.heroX - MOVE_SPD * dt end
            if G.held.right then G.heroX = G.heroX + MOVE_SPD * dt end
            if G.heroX < 0 then G.heroX = 0 end
            if G.heroX > W - CHAR_SZ then G.heroX = W - CHAR_SZ end

            -- 2) 平台上滚 + 回收（滚出顶 → 回收到底部成新一层，重掷缺口/刺）。
            for i = 1, #G.plats do
                local p = G.plats[i]
                p.y = p.y - SCROLL * dt
                if p.y + PLAT_H < 0 then
                    local maxY = -1e9
                    for j = 1, #G.plats do if G.plats[j].y > maxY then maxY = G.plats[j].y end end
                    p.y = maxY + ROW_GAP
                    p.gapX = G.nextGapX()
                    p.spiked = G.nextSpike()
                    p._passed = false
                    if G.rest == p then G.rest = nil end
                end
                G.placeRow(p)
            end

            -- 3) 竖直：骑乘所踩平台一起上移；否则自由下落 + 落点/穿越检测。
            if G.rest and not inGap(G.rest) then
                -- 仍踩在实心上 → 跟随平台上移（被往顶部托）。
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
                            if inGap(p) then
                                if not p._passed then
                                    p._passed = true
                                    G.depth = G.depth + 1
                                    api:SetScore(G.depth)
                                end
                            else
                                -- 落到实心：带刺即死，否则站稳。
                                if p.spiked then die("撞 到 刺"); return end
                                G.heroY = p.y - CHAR_SZ
                                G.vy = 0
                                G.rest = p
                                break
                            end
                        end
                    end
                end
            end

            -- 4) 死亡判定（无 clamp）：被顶出顶部 / 坠出底部。
            if G.heroY <= 0 then die("被 顶 出 顶 部"); return end
            if G.heroY > H then die("坠 落 出 局"); return end

            G.placeHero()
        end)
    end,

    -- stop：时间到（maxDuration）/ 框架收尾 → 停循环、冻结（键盘框架自动归还）。
    stop = function(ctx, api)
        local G = ctx._d100
        if G then G.running = false end
        local cv = api:Canvas()
        if cv then cv:SetScript("OnUpdate", nil) end
    end,

    -- teardown：关闭/热升级 → 清理一切（停循环、隐藏所有元素）。幂等。
    teardown = function(ctx, api)
        local cv = api:Canvas()
        local G = ctx._d100
        if cv then cv:SetScript("OnUpdate", nil) end
        if G then
            G.running = false
            if G.plats then
                for i = 1, #G.plats do
                    local p = G.plats[i]
                    if p.left  then p.left:Hide() end
                    if p.right then p.right:Hide() end
                end
            end
            if G.hero then G.hero:Hide() end
            if G.deathText then G.deathText:Hide() end
        end
        ctx._d100 = nil
    end,

    -- onTie：被选中加赛 → 复用 setup+start（框架换 round → 关卡变）。留空即可。
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
