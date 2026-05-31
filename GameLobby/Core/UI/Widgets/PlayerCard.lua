-- Core/UI/Widgets/PlayerCard.lua —— 玩家卡（左 3px 职业色边 + 圆形首字头像 + 名字 + 状态 ✓/○/★/计数）
-- owner: wow-ui-developer
-- 单一职责（SRP）：渲染一个参赛者条目；对外只暴露 :SetData(p) + 右键推送菜单。
-- p 形参：{ name, classFile, isSelf, isLeader, ready, spectator, count, showCount, pushTarget }
--   pushTarget：可作 WHISPER 目标的全名（由 Lobby:RefreshPlayers 传 m.nameNorm，带 -realm）。
--
-- 右键交互（SPEC 功能 9b / §6 P2P 推送）：右键卡片 → EasyMenu 列「当前可推送的游戏」，
-- 点击 → GL.Push:SendGame(pushTarget, gameId)。UI 只采集「目标 + gameId」，不碰分片/协议。
-- 自己的卡不弹推送项。无可推送游戏给一条 disabled 提示。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

-- 共享的隐藏 UIDropDownMenu 容器（EasyMenu 必需，全局只建一个，照 GameTile 范式）
local _pcDropdown

------------------------------------------------------------
-- 枚举「当前可推送的游戏」（与 GameImport:ExportGame 的可导出判定一致）
------------------------------------------------------------
-- 条件：已注册、有非空 def.code、非 locked（占位/未上线无 code）。
-- 返回 { {id=, name=}, ... }，按注册顺序。纯查询，不发消息。
local function ListPushableGames()
    local out = {}
    if not (GL.Games and GL.Games.List) then return out end
    local ok, list = pcall(function() return GL.Games:List() end)
    if not ok or type(list) ~= "table" then return out end
    for _, def in ipairs(list) do
        if type(def) == "table" and not def.locked
            and type(def.code) == "string" and def.code ~= "" then
            out[#out + 1] = { id = def.id, name = def.name or def.id }
        end
    end
    return out
end

------------------------------------------------------------
-- 构建右键菜单表（抽成纯函数，便于无头测试断言不抛错）
------------------------------------------------------------
-- 入参：name（展示用玩家名）、target（WHISPER 全名）、isSelf。
-- 返回 EasyMenu 菜单数组。自己的卡：不列推送项（仅标题 + 取消）。
local function BuildPushMenu(name, target, isSelf)
    local menu = {
        { text = name or "玩家", isTitle = true, notCheckable = true },
    }
    if not isSelf then
        local games = ListPushableGames()
        if #games == 0 then
            menu[#menu + 1] = {
                text = "暂无可推送的游戏", notCheckable = true, disabled = true,
            }
        else
            for _, gdef in ipairs(games) do
                local gid, gname = gdef.id, gdef.name
                menu[#menu + 1] = {
                    text = "推送：" .. tostring(gname),
                    notCheckable = true,
                    func = function()
                        local GL2 = _G.GameLobby
                        if not (GL2 and GL2.Push and GL2.Push.SendGame) then
                            if GL2 and GL2.UI and GL2.UI.Log then
                                GL2.UI:Log("warn", "推送模块尚未就绪")
                            end
                            return
                        end
                        -- 业务零写入：只采集「目标 + gameId」，分片/协议交给 Push。
                        -- pcall 返回 (pcallOk, ok, msg)：pcallOk=Push 没抛错，ok=Push 自己的成功标志。
                        local pcallOk, ok, msg = pcall(function()
                            return GL2.Push:SendGame(target, gid)
                        end)
                        -- ok=true：已发出握手（进度/成功/失败后端已走 LOG 事件，UI 不必额外订阅）。
                        -- ok=false 或 pcall 出错：把可读原因走日志条。
                        if not pcallOk then
                            if GL2.UI and GL2.UI.Log then GL2.UI:Log("warn", "推送出错：" .. tostring(ok)) end
                        elseif ok == false then
                            if GL2.UI and GL2.UI.Log then GL2.UI:Log("warn", tostring(msg or "推送失败")) end
                        end
                    end,
                }
            end
        end
    end
    menu[#menu + 1] = { text = "取消", notCheckable = true, func = function() end }
    return menu
end

-- 暴露到 W 供测试/复用（纯函数，不依赖实例）。
W.BuildPlayerPushMenu = BuildPushMenu

function W.PlayerCard(parent)
    -- Button（而非 Frame）以接收点击：右键弹推送菜单。无左键行为，故只注册右键，
    -- 不引入任何左键副作用；尺寸/锚点仍由 Lobby:RefreshPlayers 在网格里设置，不受影响。
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(32)
    c:RegisterForClicks("RightButtonUp")
    W.PanelBG(c, "panel2"); W.MetalBorder(c, "thin")

    -- 左 3px 职业色边
    local classBar = W.Solid(c, nil, 1, "ARTWORK")
    classBar:SetWidth(3)
    classBar:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    classBar:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
    c._classBar = classBar

    -- is-self 金底渐变
    local selfBG = W.Solid(c, "accent", 0.0, "BACKGROUND", 1)
    selfBG:SetAllPoints(c)
    W.SetVGradient(selfBG, {theme:RGB("accent", 0.12)}, {theme:RGB("accent", 0)})
    c._selfBG = selfBG

    -- 圆形头像（GLOW 圆贴图 + ADD 黑底融掉 + 染职业色）
    local port = c:CreateTexture(nil, "ARTWORK")
    port:SetTexture(W.GLOW); port:SetBlendMode("ADD")
    port:SetSize(22, 22); port:SetPoint("LEFT", c, "LEFT", 8, 0)
    c._port = port

    local initial = W.Text(c, "display", 10, nil)
    initial:SetTextColor(0.1, 0.07, 0.03, 0.8)
    initial:SetPoint("CENTER", port, "CENTER", 0, 0)
    c._initial = initial

    -- 名字（职业色，左对齐，溢出截断）
    local name = W.Text(c, "ui", theme.font.body, "text")
    name:SetPoint("LEFT", port, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", c, "RIGHT", -22, 0)
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    c._name = name

    -- 状态（右侧）
    local status = W.Text(c, "mono", 10, "textMute")
    status:SetPoint("RIGHT", c, "RIGHT", -6, 0)
    c._status = status

    function c:SetData(p)
        p = p or {}
        -- 右键推送所需：目标全名（WHISPER target）+ 展示名 + 是否自己。
        -- pushTarget 由 Lobby:RefreshPlayers 传 m.nameNorm（带 -realm）；缺省回退展示名。
        self._pushTarget = p.pushTarget or p.name
        self._displayName = p.name
        self._isSelf = p.isSelf and true or false
        local r, g, b = theme:ClassColor(p.classFile)
        self._classBar:SetVertexColor(r, g, b, 1)
        self._port:SetVertexColor(r, g, b, 1)
        self._name:SetText(p.name or "?")
        self._name:SetTextColor(r, g, b)
        self._initial:SetText((p.name or "?"):sub(1, 3))    -- 中文 UTF-8 3 字节取首字
        self._selfBG:SetAlpha(p.isSelf and 1 or 0)
        -- is-self 边色换 accent-deep（设计 .player.is-self border-color: accent-deep）
        for _, ring in ipairs(self._borders or {}) do
            for _, e in pairs(ring) do
                e:SetVertexColor(theme:RGB(p.isSelf and "accentDeep" or "frameDark"))
            end
        end
        if p.showCount then
            self._status:SetText(tostring(p.count or 0))
            self._status:SetTextColor(theme:RGB("accentGlow"))
        elseif p.isLeader then
            self._status:SetText(W.ICON.leader)
            self._status:SetTextColor(theme:RGB("accent"))
        elseif p.spectator then
            self._status:SetText("观")
            self._status:SetTextColor(theme:RGB("textMute"))
        elseif p.ready then
            self._status:SetText(W.ICON.ready)
            self._status:SetTextColor(theme:RGB("success"))
        else
            self._status:SetText(W.ICON.waiting)
            self._status:SetTextColor(theme:RGB("textMute"))
        end
    end

    ------------------------------------------------------------
    -- 右键 → 推送游戏：EasyMenu 下拉（照 GameTile 范式：共享隐藏 dropdown + cursor 锚点）
    ------------------------------------------------------------
    function c:ShowContextMenu()
        if not _pcDropdown then
            _pcDropdown = CreateFrame("Frame", "GameLobbyPlayerDropdown", UIParent, "UIDropDownMenuTemplate")
        end
        if not EasyMenu then return end
        local menu = BuildPushMenu(self._displayName, self._pushTarget, self._isSelf)
        EasyMenu(menu, _pcDropdown, "cursor", 0, 0, "MENU")
    end

    -- 点击分发：只处理右键（弹推送菜单）。卡片本无左键行为，不新增。
    c:SetScript("OnClick", function(s, button)
        if button == "RightButton" then s:ShowContextMenu() end
    end)
    return c
end
