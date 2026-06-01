-- Games/Up100.lua —— 是男人就上 100 层（自绘档 canvas 游戏，契约 game-dev-spec §1/§2/§5.3）
-- owner: wow-addon-engineer
--
-- 玩法：30 秒内尽量往上爬。一个小角色靠自动弹跳（Doodle Jump 式）持续上升，
--   一排排平台向下滚动（等效角色在向上攀爬）。玩家按 方向键 / AD 左右移动，
--   对准上方平台落脚；每登上更高一层 = 层数 +1。层数多者胜。
--   无死亡机制：踩空掉到底部会被 clamp 并重新弹起，不惩罚（用户要求「能移动就行」）。
--
-- 与「是男人就下 100 层」(down100) 对称：同样的「平台滚动 + 左右移动对准 + 每层+1」结构，
--   只是滚动方向 / 冲力方向相反（up100 向上爬，down100 向下落）。命名/骨架尽量一致便于统一维护。
--
-- 不变量 #1（同体）：首行 aura_env；本游戏独立版本门控（version="1.0.0"，自动替换 GameRegistry 占位）。
-- 不变量 #2（解耦）：只走 api（SetScore/Canvas/CaptureKeyboard/GetSeed/IsSpectator），绝不自己发通讯。
-- 自包含（§6）：SOURCE 内只用 ctx/api 形参与全局（math/GetTime/_G.GameLobby），无任何外部 upvalue。

local self = aura_env or {}

------------------------------------------------------------
-- 游戏 def 的自包含源码（SOURCE）—— loadstring 后 return 一张 def 表
------------------------------------------------------------
local SOURCE = [[
return {
    --==== 身份 ====--
    id        = "up100",
    name      = "是男人就上 100 层",
    version   = "1.0.0",                                   -- 改版本同时改这里（热升级门控）
    glyph     = "Interface\\Icons\\Ability_Hunter_Pathfinding",
    descLines = { "极限攀登", "踩平台往上，越高越强" },

    --==== 元数据（框架据此通用排名/校验/展示）====--
    tier        = "canvas",          -- 自绘档
    endMode     = "timed",           -- 固定 30s 窗口，到点全员同时停
    scoreOrder  = "desc",            -- 层数高者胜
    scoreUnit   = "层",
    duration    = 30,
    needsKeyboard = true,            -- 方向键控角色
    seeded      = true,              -- 各端关卡一致
    scoreCap    = function() return 999 end,   -- 上限校验（与 down100 对称放宽到 999）

    locked      = false,

    --==== 生命周期 ====--

    -- setup：建画布元素（角色 + 平台对象池）、用统一种子一次性生成关卡布局，但别动（别开循环、别收输入）。
    setup = function(ctx, api)
        local cv = api:Canvas()
        if not cv then return end   -- PlayingScreen 未就绪（纯逻辑单测早期）：静默返回

        -- 画布尺寸（运行期读真实值，无头/未布局时给兜底）。
        local W = cv:GetWidth();  if not W or W <= 0 then W = 760 end
        local H = cv:GetHeight(); if not H or H <= 0 then H = 460 end

        -- 本局状态全挂在一张表上（self 局部表，自包含；teardown 清理用）。
        local G = {}
        G.cv = cv
        G.W, G.H = W, H

        --==== 调参（与 down100 对称，方向相反）====--
        G.charSize   = 18           -- 角色方块边长
        G.pltW       = 78           -- 平台宽（缺口靠平台只占一段宽度实现）
        G.pltH       = 10           -- 平台高
        G.gapY       = 70           -- 相邻平台层垂直间距
        G.gravity    = 560          -- 重力加速度（像素/秒^2，向下为负 vy）
        G.jumpVel    = 430          -- 落到平台时的向上弹跳初速度
        G.moveSpeed  = 300          -- 左右移动速度（像素/秒）
        G.scrollY    = H * 0.55     -- 角色超过此高度则世界向下滚（等效相机上移、角色保持视野内）

        --==== 用统一种子一次性生成平台序列（各端一致，§4）====--
        -- worldY：以「世界坐标」记平台高度（越大越高）；平台沿世界系固定，靠 G.camY 投影到画布。
        -- 每层平台的水平位置 px 随机（留出左右边距），相当于「缺口/落脚点」位置变化。
        -- 约束：相邻两层 px 偏移 ≤ reachX，保证一次弹跳的滞空时间内左右移动够得着下一层（关卡总是可通）。
        -- ⚠️ WoW 沙箱无 math.randomseed；用框架确定性随机 api:Random（各端 matchId+round 一致）。
        G.platforms = {}            -- { worldY=, px=, tier=, tex= }
        local layers = 200          -- 预生成足量层（30s 一般爬不满）
        local minPx, maxPx = 8, W - G.pltW - 8
        if maxPx < minPx then maxPx = minPx end
        local reachX = 130          -- 相邻层水平最大偏移（滞空时间 × moveSpeed 内可达）
        local prevPx = math.floor((minPx + maxPx) / 2)   -- 第一层居中（角色开局站这）
        for i = 1, layers do
            local lo = math.max(minPx, prevPx - reachX)
            local hi = math.min(maxPx, prevPx + reachX)
            local px = (i == 1) and prevPx or api:Random(math.floor(lo), math.floor(hi))
            G.platforms[i] = { worldY = i * G.gapY, px = px, tier = i }
            prevPx = px
        end

        --==== 角色（纯色方块）====--
        local ch = cv:CreateTexture(nil, "OVERLAY")
        ch:SetColorTexture(0.30, 0.85, 1.0, 1.0)   -- 青蓝方块
        ch:SetSize(G.charSize, G.charSize)
        G.charTex = ch

        --==== 平台纹理对象池（复用，OnUpdate 只改位置/显隐，§8）====--
        -- 画布一屏最多显示 ceil(H/gapY)+2 层，池子开够即可。
        G.pool = {}
        local poolN = math.ceil(H / G.gapY) + 3
        for i = 1, poolN do
            local t = cv:CreateTexture(nil, "ARTWORK")
            t:SetColorTexture(0.55, 0.45, 0.30, 1.0)   -- 土黄平台
            t:SetSize(G.pltW, G.pltH)
            t:Hide()
            G.pool[i] = t
        end

        --==== 初始姿态：角色站在第一层平台上，相机从底部起 ====--
        G.camY = 0                                  -- 世界系相机偏移（越大代表爬越高）
        local p1 = G.platforms[1]
        G.charX = p1.px + (G.pltW - G.charSize) / 2  -- 画布系 x（左下原点）
        G.charWorldY = p1.worldY + G.pltH            -- 角色脚底所在世界高度
        G.vy = 0
        G.maxTier = 1                                -- 已登上的最高层（计分依据）
        G.held = { left = false, right = false }

        api.G = G   -- 挂到 api 供 start/stop/teardown 共享（仅本局，框架每局重建 api）
    end,

    -- start："GO!"：申请键盘 + 开 OnUpdate 循环（dt 驱动，不依赖帧率）。围观者不绑输入不跑逻辑。
    start = function(ctx, api)
        if api:IsSpectator() then return end   -- 围观者只看（框架渲染别人的实况分），不收输入不计分
        local G = api.G
        if not G or not G.cv then return end

        -- 键盘：框架托管 propagate/ESC/归还，只给回调记 held。LEFT/A 左、RIGHT/D 右。
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

        -- 投影：世界高度 worldY → 画布系 y（左下为原点，向上为正）。
        local function projY(worldY) return worldY - G.camY end

        -- 主循环（dt 驱动）：移动 → 重力/弹跳 → 相机跟随 → 计分 → 重绘。
        G.cv:SetScript("OnUpdate", function(_, dt)
            dt = dt or 0
            if dt <= 0 then return end
            if dt > 0.1 then dt = 0.1 end   -- 卡顿封顶，防穿模

            local W, H = G.W, G.H
            local cs = G.charSize

            -- 1) 左右移动（held + dt，不依赖帧率），clamp 到画布内。
            local dx = 0
            if G.held.left then dx = dx - G.moveSpeed * dt end
            if G.held.right then dx = dx + G.moveSpeed * dt end
            G.charX = G.charX + dx
            if G.charX < 0 then G.charX = 0 end
            if G.charX > W - cs then G.charX = W - cs end

            -- 2) 竖直：重力下拉，记录上一帧脚底世界高度（用于「自上而下穿过平台才算落脚」判定）。
            local prevWorldY = G.charWorldY
            G.vy = G.vy - G.gravity * dt
            G.charWorldY = G.charWorldY + G.vy * dt

            -- 3) 落脚判定：仅当下落中（vy<=0）、且本帧脚底从平台上方穿到下方、x 在平台范围内 → 弹跳。
            if G.vy <= 0 then
                for i = 1, #G.platforms do
                    local p = G.platforms[i]
                    local top = p.worldY + G.pltH           -- 平台上表面世界高度
                    -- 只看可能相交的层（早退优化）：平台太高就跳过后续（platforms 按 worldY 升序）。
                    if top > prevWorldY + 1 then break end
                    if prevWorldY >= top - 1 and G.charWorldY <= top then
                        -- x 重叠判定（角色与平台水平有交集）
                        if G.charX + cs > p.px and G.charX < p.px + G.pltW then
                            G.charWorldY = top
                            G.vy = G.jumpVel              -- 自动向上弹
                            if p.tier > G.maxTier then G.maxTier = p.tier end
                            break
                        end
                    end
                end
            end

            -- 4) 防掉出世界底：clamp 到第一层平台高度并原地重新弹起（无死亡惩罚）。
            local floorY = G.platforms[1].worldY + G.pltH
            if G.charWorldY < floorY then
                G.charWorldY = floorY
                G.vy = G.jumpVel
            end

            -- 5) 相机跟随：角色在画布内高度超过 scrollY 阈值则世界下滚（camY 增大），角色保持视野内。
            local chCanvasY = G.charWorldY - G.camY
            if chCanvasY > G.scrollY then
                G.camY = G.charWorldY - G.scrollY
            end

            -- 6) 计分：当前最高层 - 1（站第一层算 0 层，往上每登一层 +1），上报。
            api:SetScore(G.maxTier - 1)

            -- 7) 重绘：角色 + 可见平台（对象池只显示画布范围内的层）。
            local ch = G.charTex
            ch:ClearAllPoints()
            ch:SetPoint("BOTTOMLEFT", G.cv, "BOTTOMLEFT", G.charX, projY(G.charWorldY))
            ch:Show()

            -- 找出当前可见的平台层区间，复用池子绘制。
            local poolIdx = 1
            for i = 1, #G.platforms do
                local p = G.platforms[i]
                local y = projY(p.worldY)
                if y > -G.pltH and y < H + G.pltH then
                    local t = G.pool[poolIdx]
                    if not t then break end             -- 池子用尽（理论不会，可见层 ≤ poolN）
                    t:ClearAllPoints()
                    t:SetPoint("BOTTOMLEFT", G.cv, "BOTTOMLEFT", p.px, y)
                    t:Show()
                    poolIdx = poolIdx + 1
                elseif y >= H + G.pltH then
                    break                                -- 后续平台更高、全在视野外，早退
                end
            end
            -- 隐藏池中未用到的纹理。
            for j = poolIdx, #G.pool do G.pool[j]:Hide() end
        end)
    end,

    -- stop：时间到 / 主动结束：停循环冻结（分数已在 api 里；键盘框架自动归还）。
    stop = function(ctx, api)
        local G = api.G
        if G and G.cv then G.cv:SetScript("OnUpdate", nil) end
    end,

    -- teardown：关闭 / 热升级：清理一切（停循环、隐藏元素）。幂等。
    teardown = function(ctx, api)
        local G = api.G
        if not G then return end
        if G.cv then G.cv:SetScript("OnUpdate", nil) end
        if G.charTex then G.charTex:Hide() end
        if G.pool then for _, t in ipairs(G.pool) do t:Hide() end end
        api.G = nil
    end,

    -- onTie：被选中加赛——不实现则框架复用 setup+start（GetSeed 因 round 变化自动换关卡），足够。
}
]]

------------------------------------------------------------
-- 从 SOURCE 跑出 def，并把源码挂回 def.code（供 ExportGame 打包分享，§6）
------------------------------------------------------------
local def = assert(loadstring(SOURCE))()
def.code = SOURCE

local GAME_VERSION = def.version   -- 外层引导/日志用，与 SOURCE 内一致

------------------------------------------------------------
-- 注册（核心未就绪则压 pending 队列）—— 与 SpeedClick.lua 同骨架
------------------------------------------------------------
local GL = _G.GameLobby
if GL and GL.RegisterGame then
    GL:RegisterGame(def)                         -- 版本门控自动替换 up100 的 0.0.0 占位
elseif GL and GL._pendingGames then
    table.insert(GL._pendingGames, def)
else
    _G.GameLobby_pendingGames = _G.GameLobby_pendingGames or {}
    table.insert(_G.GameLobby_pendingGames, def)
end
