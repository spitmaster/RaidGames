-- Core/Bootstrap.lua —— 建立 _G.GameLobby（GL）：双环境同体 + 版本门控幂等 + 事件总线
-- owner: wow-comm-wa-specialist
-- 契约 §0/§1/§2；范式照 sample/BiaoGe/Core/Module/AuctionWA.lua:23-49 与 Core/DB/Init.lua。
--
-- 不变量 #1（同体）：本文件是整个核心唯一一个「无条件运行」的引导文件，
--   插件经 .toc 加载、WA 经 aura 自身加载时机都会跑到这里。
--   每个 .lua 文件首行 `local self = aura_env or {}`——aura_env 存在=跑在 WA 里，nil=跑在插件里。

local self = aura_env or {}

-- 本核心整体版本号（字符串 "x.y.z"）。游戏各自有独立版本（见 GameRegistry）。
local CORE_VERSION = "0.1.0"

-- "0.1.0" → 可比较数值（major*10000 + minor*100 + patch）。
-- 纯函数，WA 版可直接复用；容忍 "v0.1.0" / "0.1" 等写法。
local function GetVerNum(str)
    if type(str) ~= "string" then return 0 end
    local major, minor, patch = string.match(str, "(%d+)%.(%d+)%.?(%d*)")
    if not major then
        -- 退一步：抓第一个 "x.y"
        major, minor = string.match(str, "(%d+)%.(%d+)")
        patch = "0"
    end
    if not major then return 0 end
    return (tonumber(major) or 0) * 10000 + (tonumber(minor) or 0) * 100 + (tonumber(patch) or 0)
end

------------------------------------------------------------
-- 版本门控（高版本胜；旧版让位时卸载旧实例）
------------------------------------------------------------

local existing = _G.GameLobby

if existing then
    local existingVer = GetVerNum(existing.version)
    local newVer = GetVerNum(CORE_VERSION)
    if newVer <= existingVer then
        -- 已有同等或更高版本核心在场（插件 + WA 同装时常见）——本实例让位。
        return
    end
    -- 本实例更高版本：卸载旧实例后接管。
    -- 1) 隐藏旧实例创建的所有顶层框架（UI 层把框架登记到 GL._frames）。
    if existing._frames then
        for _, frame in pairs(existing._frames) do
            if type(frame) == "table" and frame.Hide then
                pcall(frame.Hide, frame)
            end
        end
    end
    -- 2) 注销旧实例的事件帧。
    if existing._eventFrame and existing._eventFrame.UnregisterAllEvents then
        pcall(existing._eventFrame.UnregisterAllEvents, existing._eventFrame)
    end
    -- 3) 调用各模块自报的卸载钩子（模块可在 GL._teardownHooks 里登记）。
    if existing._teardownHooks then
        for _, fn in ipairs(existing._teardownHooks) do
            pcall(fn)
        end
    end
    -- 4) wipe 旧实例桌面，让其被 GC；新实例完全重建。
    wipe(existing)
end

------------------------------------------------------------
-- 建立 / 接管 GL
------------------------------------------------------------

local GL = existing or {}
_G.GameLobby = GL

GL.version = CORE_VERSION
GL.GetVerNum = GetVerNum
GL.isWA = (aura_env ~= nil)         -- 本实例是否跑在 WeakAuras 里
GL.auraEnv = self                   -- 跑在 WA 时即 aura_env，跑在插件时为空表

-- 旧实例让位时要清理的资源登记位（重建后从空开始）。
GL._frames = {}                     -- UI 层把顶层框架 tinsert 进来，供热升级时 Hide
GL._teardownHooks = {}              -- 模块自报卸载钩子，供热升级时调用
GL._pendingGames = {}               -- 待注册游戏队列（核心未就绪时 RegisterGame 压这里，引导后回收）

------------------------------------------------------------
-- 本地化表 L —— 缺 key 回落 key 自身（中文文案集中放这）
------------------------------------------------------------

GL.L = setmetatable({}, {
    __index = function(_, key)
        return tostring(key)
    end,
})

------------------------------------------------------------
-- 初始化队列 GL:Init(fn) —— 各模块排队，核心就绪后由 Init.lua 按序 flush
-- （仿 BiaoGe BG.Init）。模块不自己监听 ADDON_LOADED/PLAYER_LOGIN 等事件。
------------------------------------------------------------

GL._initQueue = {}
GL._initDone = false

function GL:Init(fn)
    if type(fn) ~= "function" then return end
    if self._initDone then
        -- 已经 flush 过（晚到的模块，如导入的 WA 游戏）：立即执行。
        local ok, err = pcall(fn)
        if not ok then geterrorhandler()(err) end
        return
    end
    table.insert(self._initQueue, fn)
end

-- 由 Init.lua 在三档延迟的最末调用：按序执行排队的初始化回调。
function GL:_FlushInit()
    if self._initDone then return end
    self._initDone = true
    for _, fn in ipairs(self._initQueue) do
        local ok, err = pcall(fn)
        if not ok then geterrorhandler()(err) end
    end
    wipe(self._initQueue)
end

------------------------------------------------------------
-- 事件总线 GL:On / :Off / :Emit（契约 §2）—— 模块间唯一解耦通道
------------------------------------------------------------

GL._listeners = {}                  -- [event] = { fn1, fn2, ... }

function GL:On(event, fn)
    if type(event) ~= "string" or type(fn) ~= "function" then return end
    local list = self._listeners[event]
    if not list then
        list = {}
        self._listeners[event] = list
    end
    -- 去重：同一 fn 不重复订阅同一事件
    for _, existingFn in ipairs(list) do
        if existingFn == fn then return end
    end
    table.insert(list, fn)
end

function GL:Off(event, fn)
    local list = self._listeners[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then
            table.remove(list, i)
        end
    end
    if #list == 0 then
        self._listeners[event] = nil
    end
end

function GL:Emit(event, ...)
    local list = self._listeners[event]
    if not list then return end
    -- 拷贝一份再遍历：允许 handler 内部 On/Off（修改原表不影响本轮）。
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    for i = 1, #snapshot do
        local ok, err = pcall(snapshot[i], ...)
        if not ok then geterrorhandler()(err) end
    end
end

------------------------------------------------------------
-- 轻量工具（供全核心复用）
------------------------------------------------------------

-- hex 颜色 → 0-1 RGB（UI 层主题令牌会大量用；放这里全核心可取）
function GL.HexToRGB(hex)
    if type(hex) ~= "string" then return 1, 1, 1 end
    hex = hex:gsub("#", "")
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255
end

-- 便捷：把一个顶层框架登记到热升级清理清单
function GL:_RegisterFrame(frame)
    table.insert(self._frames, frame)
    return frame
end

-- 便捷：登记卸载钩子（热升级让位时调用）
function GL:_RegisterTeardown(fn)
    if type(fn) == "function" then
        table.insert(self._teardownHooks, fn)
    end
end
