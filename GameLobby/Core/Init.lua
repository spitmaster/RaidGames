-- Core/Init.lua —— 引导器：三档延迟初始化，最末 flush GL:Init 队列 + 回收 _pendingGames
-- owner: wow-comm-wa-specialist
-- 仿 sample/BiaoGe/Core/DB/Init.lua 的 BG.Init 三档机制（ADDON_LOADED/PLAYER_LOGIN/PLAYER_ENTERING_WORLD）。
-- 加载顺序：本文件 .toc 最末（契约 §10），此时所有模块已把回调排进 GL._initQueue。
--
-- 设计：各模块「不」自己监听这三个事件，统一 GL:Init(fn) 排队（契约 §1）。
--   这里只有一个事件帧负责推进生命周期，flush 时机选在「身份/团队信息均已就绪」之后。

local self = aura_env or {}
local GL = _G.GameLobby

-- 版本门控让位的旧实例不会执行到这里（Bootstrap 已 return）。
-- 但防御：万一 GL 不存在（加载顺序异常），直接退出。
if not GL then return end

-- 已经引导过（同一实例的 Init.lua 不会被加载两次；防御 WA 重复注入）。
if GL._bootstrapped then return end
GL._bootstrapped = true

------------------------------------------------------------
-- 三档延迟 + flush
------------------------------------------------------------

-- flush：按序执行 GL._initQueue，再回收待注册游戏队列。
-- 用一个 flag 保证只跑一次（三档事件谁先满足谁触发）。
local function tryFlush()
    if GL._initDone then return end

    -- 1) 先 flush 各模块的 Init 回调（Comm 注册前缀/监听、Roster/Match/Stats/UI 等就位）。
    GL:_FlushInit()

    -- 2) 回收待注册游戏队列：核心未就绪时 RegisterGame 压入的 def 现在统一注册。
    --    （配合聚合串「核心与游戏子 aura 先后不保证」的场景，SPEC §5 / 决策 D16。）
    --    GameRegistry 提供 GL:RegisterGame；它就绪后这里把 pending 倒出来。
    if GL._pendingGames and GL.RegisterGame then
        local pending = GL._pendingGames
        GL._pendingGames = {}   -- 先清空，避免 RegisterGame 内部再压入造成重复
        for _, def in ipairs(pending) do
            local ok, err = pcall(GL.RegisterGame, GL, def)
            if not ok then geterrorhandler()(err) end
        end
    end

    GL:Emit("LOG", "sys", (GL.L and GL.L["游戏大厅已就绪"]) or "游戏大厅已就绪")
end

-- 事件帧：ADDON_LOADED（本插件加载完）→ PLAYER_LOGIN → PLAYER_ENTERING_WORLD。
-- 任一档满足「核心数据就绪」即可 flush；这里选 PLAYER_LOGIN 之后（身份信息已可用），
-- 并在 PLAYER_ENTERING_WORLD 做状态恢复广播（晚加入/reload，SPEC §6）。
local frame = CreateFrame("Frame")
GL._initFrame = frame
GL._eventFrame = GL._eventFrame or frame   -- 供热升级统一注销

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUi)
    if event == "PLAYER_LOGIN" then
        -- 身份/团队 API 此时可用，flush 各模块初始化。
        tryFlush()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 进世界/reload：先确保已 flush（万一 LOGIN 没触发，例如某些 WA 注入时机）。
        tryFlush()

        -- 状态恢复（SPEC §6）：广播 GetState，在场者 WHISPER 回 State，
        -- 晚加入者据回复补建进行中的比赛 UI。具体收发由 Match 的 handler 处理；
        -- 这里只负责在合适时机触发一次询问。延迟 1.5 秒，等团队信息稳定。
        if GL.Comm and GL.Comm.Broadcast and GL.Roster then
            C_Timer.After(1.5, function()
                if GL.Roster:GetChannel() then
                    GL.Comm:Broadcast("GetState")
                end
            end)
        end
    end
end)

-- 登记卸载钩子：热升级让位时停掉本帧。
GL:_RegisterTeardown(function()
    if frame then
        frame:UnregisterAllEvents()
        frame:SetScript("OnEvent", nil)
    end
end)
