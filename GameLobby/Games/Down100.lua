-- Games/Down100.lua —— 是男人就下 100 层（自绘档 canvas 游戏，契约 game-dev-spec §2/§5.3）
-- owner: wow-addon-engineer
--
-- 玩法（30s 定时比层数）：
--   画布里一个小方块角色受重力下落；一排排细长平台以恒定速度「向上滚动」（等效角色下沉）。
--   每排平台留一个缺口；玩家按 方向键 / A D 左右移动，对准缺口让角色掉到下一层。
--   角色每落到（穿过）更低一层平台 = 层数 +1，调 api:SetScore(当前层数)。30s 内层数多者胜。
--   无死亡：被滚动顶到画布顶部不扣分（clamp 在顶部），用户要求「能移动就行」。
--
-- 不变量 #1（同体）：首行 aura_env；本游戏独立版本门控（热升级靠 version）。
-- 不变量 #2（解耦）：只走 api（SetScore/Canvas/CaptureKeyboard/GetSeed/IsSpectator），绝不发通讯。
-- 公平（§4）：setup 里用 api:Random()（框架确定性随机；WoW 无 math.randomseed）生成关卡序列，各端布局一致。
--
-- 【分享/自包含（§6）】：游戏本体写成自包含源码字符串 SOURCE，loadstring 出 def，def.code = SOURCE。
--   SOURCE 内代码只能用 ctx/api 形参 + 全局（GetTime/math/CreateFrame/_G.GameLobby）+ 自己的 local，
--   绝不引用 SOURCE 外的 upvalue（否则导入方 loadstring 时环境缺失会 nil）。

local self = aura_env or {}

------------------------------------------------------------
-- 游戏 def 的自包含源码（SOURCE）
------------------------------------------------------------
local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "down100",
    name      = "是男人就下 100 层",
    version   = "1.0.0",                    -- 独立版本门控；改版本同步改这里（高版本胜，替换占位）
    glyph     = "Interface\\Icons\\Ability_Rogue_Sprint",
    descLines = { "30 秒速降", "踩平台往下，越深越高" },

    --==== 元数据（框架据此通用排名/校验/展示）====--
    tier        = "canvas",
    endMode     = "timed",
    scoreOrder  = "desc",
    scoreUnit   = "层",
    duration    = 30,
    needsKeyboard = true,
    seeded      = true,
    scoreCap    = function() return 999 end,   -- 30s 理论上限远超实际，仅防离谱上报
    locked      = false,

    --==== 生命周期 ====--

    -- setup：建画布元素（角色 + 平台对象池）、用种子生成关卡序列，但别动（别开循环、别收输入）。
    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end

        -- 本游戏所有运行态挂在 ctx._d100（不写 ctx 其它字段；这是给本游戏自用的私有命名空间）。
        local G = {}
        ctx._d100 = G

        -- 画布尺寸（锚定布局，运行期才有真实尺寸；取不到给默认）。
        local W = (cv.GetWidth and cv:GetWidth()) or 720
        local H = (cv.GetHeight and cv:GetHeight()) or 460
        if not W or W <= 0 then W = 720 end
        if not H or H <= 0 then H = 460 end
        G.W, G.H = W, H

        -- ===== 关卡参数 =====
        local ROW_GAP   = 90              -- 相邻平台行的竖直间距（逻辑像素）
        local GAP_W     = 70              -- 平台缺口宽度（角色 18 宽，留足通过余量）
        local PLAT_H    = 12              -- 平台厚度
        local CHAR_SZ   = 18              -- 角色边长
        local NUM_PLAT  = 12              -- 平台对象池大小（够铺满画布高度 + 余量）
        G.ROW_GAP, G.GAP_W, G.PLAT_H, G.CHAR_SZ = ROW_GAP, GAP_W, PLAT_H, CHAR_SZ

        -- ===== 关卡序列（种子驱动，各端一致）=====
        -- 每行只需记一个缺口左边缘 x（缺口范围 [gapX, gapX+GAP_W]）。
        -- 用一个确定性的 next() 闭包按需取下一行缺口，避免预生成无限数组。
        local maxGapX = W - GAP_W
        if maxGapX < 0 then maxGapX = 0 end
        G.nextGapX = function()
            return api:Random(0, maxGapX)    -- 框架确定性随机（各端一致）；WoW 无 math.randomseed
        end

        -- ===== 平台对象池（复用 Texture，OnUpdate 只改位置/显隐）=====
        -- 每个平台元素 = 一行（横跨画布、中间留缺口），用「左段 + 右段」两个 Texture 表现缺口。
        G.plats = {}
        for i = 1, NUM_PLAT do
            local left  = cv:CreateTexture(nil, "ARTWORK")
            left:SetColorTexture(0.45, 0.62, 0.85, 1)
            local right = cv:CreateTexture(nil, "ARTWORK")
            right:SetColorTexture(0.45, 0.62, 0.85, 1)
            G.plats[i] = { left = left, right = right, y = 0, gapX = 0, level = 0, active = false }
        end

        -- 用 anchorTop（画布顶部为基准，向下为正）放置一行：y 是该行顶距画布顶的逻辑距离。
        -- WoW 坐标：TOPLEFT 偏移 yOff 向下为负，所以 SetPoint 用 -y。
        G.placeRow = function(p)
            local gapX = p.gapX
            local lw = gapX
            local rw = W - (gapX + GAP_W)
            if lw < 0 then lw = 0 end
            if rw < 0 then rw = 0 end
            local L, R = p.left, p.right
            L:ClearAllPoints(); R:ClearAllPoints()
            if lw > 0 then
                L:SetSize(lw, PLAT_H)
                L:SetPoint("TOPLEFT", cv, "TOPLEFT", 0, -p.y)
                L:Show()
            else
                L:Hide()
            end
            if rw > 0 then
                R:SetSize(rw, PLAT_H)
                R:SetPoint("TOPLEFT", cv, "TOPLEFT", gapX + GAP_W, -p.y)
                R:Show()
            else
                R:Hide()
            end
        end

        -- 初始化平台：从画布底部往下铺一串，level 递增（level 即「第几层」）。
        -- 角色从顶部开始；最近的平台在角色下方，往下越来越多。
        G.levelCounter = 0
        local startY = H * 0.45                -- 第一行初始位置（画布中上部，角色脚下不远）
        for i = 1, NUM_PLAT do
            local p = G.plats[i]
            G.levelCounter = G.levelCounter + 1
            p.level  = G.levelCounter
            p.gapX   = G.nextGapX()
            p.y      = startY + (i - 1) * ROW_GAP
            p.active = true
            G.placeRow(p)
        end

        -- ===== 角色 =====
        local hero = cv:CreateTexture(nil, "OVERLAY")
        hero:SetColorTexture(1.0, 0.82, 0.25, 1)   -- 暖黄方块
        hero:SetSize(CHAR_SZ, CHAR_SZ)
        G.hero = hero
        -- 角色逻辑坐标：heroX = 左边缘距画布左；heroY = 顶边缘距画布顶（向下为正）。
        G.heroX = (W - CHAR_SZ) * 0.5
        G.heroY = H * 0.20
        G.vy    = 0                              -- 竖直速度（逻辑像素/秒，向下为正）
        G.placeHero = function()
            hero:ClearAllPoints()
            hero:SetPoint("TOPLEFT", cv, "TOPLEFT", G.heroX, -G.heroY)
        end
        G.placeHero()

        -- ===== 物理 / 计分态 =====
        G.depth     = 0      -- 已下降的「层数」（即得分）；角色穿过一行平台 +1
        G.held      = { left = false, right = false }
        G.running   = false  -- start() 才置 true；setup 阶段不动
    end,

    -- start："GO!"：申请键盘 + 开 OnUpdate 循环。围观者不绑输入、不跑逻辑。
    start = function(ctx, api)
        if api:IsSpectator() then return end
        local cv = api:Canvas()
        local G = ctx._d100
        if not cv or not G then return end

        -- 键盘：框架托管 propagate/ESC/归还，这里只记 held 表（方向键 / A D）。
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

        -- ===== 调参 =====
        local MOVE_SPD  = 320      -- 水平移动速度（逻辑像素/秒）
        local SCROLL    = 70       -- 平台恒定向上滚动速度（等效持续下沉，逻辑像素/秒）
        local GRAVITY   = 900      -- 重力加速度（逻辑像素/秒²）
        local MAX_VY    = 520      -- 终端下落速度
        local W, H      = G.W, G.H
        local CHAR_SZ   = G.CHAR_SZ
        local PLAT_H    = G.PLAT_H
        local GAP_W     = G.GAP_W
        local ROW_GAP   = G.ROW_GAP

        G.running = true
        cv:SetScript("OnUpdate", function(_, dt)
            if not G.running then return end
            dt = tonumber(dt) or 0
            if dt <= 0 then return end
            if dt > 0.1 then dt = 0.1 end   -- 卡顿/补帧 clamp，防一帧穿透平台

            -- 1) 水平移动（held + dt，帧率无关）。
            local dx = 0
            if G.held.left  then dx = dx - MOVE_SPD * dt end
            if G.held.right then dx = dx + MOVE_SPD * dt end
            if dx ~= 0 then
                G.heroX = G.heroX + dx
                if G.heroX < 0 then G.heroX = 0 end
                if G.heroX > W - CHAR_SZ then G.heroX = W - CHAR_SZ end
            end

            -- 2) 平台向上滚动（所有 active 行 y 减小）；滚出顶部的行回收到底部，level +1。
            for i = 1, #G.plats do
                local p = G.plats[i]
                if p.active then
                    p.y = p.y - SCROLL * dt
                    if p.y + PLAT_H < 0 then
                        -- 滚出画布顶：回收到当前最底行的下方，作为新的更深一层。
                        local maxY = -1e9
                        for j = 1, #G.plats do
                            local q = G.plats[j]
                            if q.active and q.y > maxY then maxY = q.y end
                        end
                        G.levelCounter = G.levelCounter + 1
                        p.level = G.levelCounter
                        p.gapX  = G.nextGapX()
                        p.y     = maxY + ROW_GAP
                        p._passed = nil   -- 回收为新一层：清穿越标记，再次穿过仍计层数（否则漏计）
                    end
                    G.placeRow(p)
                end
            end

            -- 3) 重力 + 落点检测。
            local prevBottom = G.heroY + CHAR_SZ      -- 落地前角色底边 y
            G.vy = G.vy + GRAVITY * dt
            if G.vy > MAX_VY then G.vy = MAX_VY end
            G.heroY = G.heroY + G.vy * dt
            local newBottom = G.heroY + CHAR_SZ

            -- 与每行平台做「自上而下穿越」检测：仅当角色在下落(vy>0)且底边从平台上方越到下方，
            -- 且水平不在缺口内 → 落在平台上（停在平台顶）。在缺口内 → 穿过该行，depth +1。
            local landed = false
            for i = 1, #G.plats do
                local p = G.plats[i]
                if p.active then
                    local platTop = p.y
                    -- 角色这帧的底边从 platTop 之上跨到之下（或正落在平台厚度内）
                    if G.vy >= 0 and prevBottom <= platTop + 1 and newBottom >= platTop then
                        local heroL = G.heroX
                        local heroR = G.heroX + CHAR_SZ
                        local gapL  = p.gapX
                        local gapR  = p.gapX + GAP_W
                        -- 角色完全落在缺口内才算「穿过」；否则被平台接住。
                        local inGap = (heroL >= gapL) and (heroR <= gapR)
                        if inGap then
                            -- 穿过这一行 → 记一次下降（每行只记一次）。
                            if not p._passed then
                                p._passed = true
                                G.depth = G.depth + 1
                                api:SetScore(G.depth)
                            end
                        else
                            -- 落在平台上：停住。
                            G.heroY = platTop - CHAR_SZ
                            G.vy = 0
                            landed = true
                            p._passed = nil   -- 站在这行上方，下次穿过仍可计
                            break
                        end
                    end
                end
            end
            if landed then
                -- 站稳，无操作
            end

            -- 4) 顶/底 clamp（无死亡）：被滚动顶到画布顶 → 贴顶不扣分；别掉出底部。
            if G.heroY < 0 then G.heroY = 0; if G.vy < 0 then G.vy = 0 end end
            if G.heroY > H - CHAR_SZ then G.heroY = H - CHAR_SZ; G.vy = 0 end

            G.placeHero()
        end)
    end,

    -- stop：时间到 / Finish → 停循环、冻结（键盘框架自动归还）。
    stop = function(ctx, api)
        local cv = api:Canvas()
        local G = ctx._d100
        if G then G.running = false end
        if cv then cv:SetScript("OnUpdate", nil) end
    end,

    -- teardown：关闭/热升级 → 清理一切（停循环、隐藏所有 Texture）。幂等。
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
        end
        ctx._d100 = nil
    end,

    -- onTie：被选中加赛 → 复用 setup+start（框架会换 round → GetSeed 变 → 新布局）。
    -- 不实现则框架默认复用 setup/start，这里显式留空即可。
    onTie = function(ctx, api) end,

    -- onResult：结算后收尾（可选）。无需。
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
