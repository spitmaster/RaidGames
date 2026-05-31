-- Core/UI/Widgets/GameTile.lua —— 游戏格（glyph + 标题 + 描述；选中态金边 + 顶高光，hover 边亮）
-- owner: wow-ui-developer
-- 单一职责（SRP）：呈现一个游戏 def，并处理选中/hover/锁定的视觉态 + 右键导出菜单。
-- 业务（点击如何切游戏 / 哪个游戏被选）由调用方通过 :SetOnSelect 注入。
-- 实例 API：
--   :SetGame(def, selected)   渲染 def + 设置选中态
--   :SetSelected(on)          单独切换选中态（不重写 def）
--   :SetOnSelect(fn)          左键点击回调（locked 不触发）
--   :ShowContextMenu()        弹右键菜单（导出字符串）

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

-- 共享的隐藏 UIDropDownMenu 容器（EasyMenu 必需，全局只建一个，避免每格一个）
local _tileDropdown

function W.GameTile(parent)
    local t = CreateFrame("Button", nil, parent)
    -- 设计稿尺寸：内距 14px + glyph 36 + 标题 + 两行描述 + 底部留白 ≈ 120 高（旧 96 太挤，描述贴边）
    t:SetSize(180, 120)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    W.PanelBG(t, "panel2"); W.MetalBorder(t, "thin")

    -- 选中态顶部 1px 内高光 + 顶向下金渐变 tint（设计 .is-selected inset 0 1px 0 + linear-gradient top）
    local selTopGlow = W.Solid(t, "accent", 0, "ARTWORK", 1)
    selTopGlow:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
    selTopGlow:SetPoint("TOPRIGHT", t, "TOPRIGHT", -1, -1)
    selTopGlow:SetHeight(1)
    t._selTopGlow = selTopGlow

    local selTint = W.Solid(t, "accent", 0, "BACKGROUND", 1)
    selTint:SetAllPoints(t)
    W.SetVGradient(selTint, {theme:RGB("accent", 0.12)}, {theme:RGB("accent", 0)})
    t._selTint = selTint

    -- 边缘"发光"近似（沿四边走的 1px 染色描边，hover/selected 时 alpha 渐显 + 色变金）。
    -- WoW 没真 box-shadow；单张径向圆纹理拉成椭圆光团不可接受，所以走沿边描边方案。
    t._edgeRing = W.Ring(t, 1, "accent", 0, "OVERLAY")

    local glyphF = CreateFrame("Frame", nil, t)
    glyphF:SetSize(36, 36); glyphF:SetPoint("TOPLEFT", 14, -14)   -- 设计内距 14px
    W.PanelBG(glyphF, "panelInset"); W.MetalBorder(glyphF, "thin")
    local glyphSelBG = W.Solid(glyphF, "accentDeep", 0, "BACKGROUND", 2)
    glyphSelBG:SetAllPoints(glyphF)
    t._glyphSelBG = glyphSelBG
    local glyph = W.Text(glyphF, "display", 18, "accent"); glyph:SetPoint("CENTER")
    t._glyph = glyph

    local title = W.Text(t, "display", 13, "text")
    title:SetPoint("TOPLEFT", glyphF, "BOTTOMLEFT", 0, -8)
    t._title = title
    local desc = W.Text(t, "ui", theme.font.small, "textMute")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    desc:SetPoint("RIGHT", t, "RIGHT", -12, 0)   -- 收右内距，描述自动换行不顶边
    desc:SetJustifyH("LEFT"); desc:SetJustifyV("TOP")
    desc:SetSpacing(4)                            -- 行距 ≈ 设计 line-height 1.5
    t._desc = desc

    -- 「即将上线」徽标：带描边小药丸（设计 .game-tile-lock：1px divider 边 + panelInset 底 + 2/6 内距）
    local lockChip = CreateFrame("Frame", nil, t)
    lockChip:SetPoint("TOPRIGHT", t, "TOPRIGHT", -10, -10)
    W.PanelBG(lockChip, "panelInset"); W.MetalBorder(lockChip, "thin")
    local lockTxt = W.Text(lockChip, "ui", theme.font.tiny, "textMute")
    lockTxt:SetPoint("CENTER", lockChip, "CENTER", 0, 0)
    lockTxt:SetText("即将上线")
    local lw = lockTxt:GetStringWidth()
    lockChip:SetSize((lw and lw > 0 and lw or 42) + 14, 18)
    lockChip:Hide()
    t._lock = lockChip

    -- def: { id, name, glyph, descLines, locked }
    function t:SetGame(def, selected)
        def = def or {}
        self._gameId = def.id
        self._gameName = def.name
        self._locked = def.locked
        self._glyph:SetText(W.GlyphMarkup(def.glyph, 26))
        self._title:SetText(def.name or "")
        self._desc:SetText(table.concat(def.descLines or {}, "\n"))
        if def.locked then
            -- 占位/未上线：置灰显示「即将上线」徽标。**不调 Disable()**——否则按钮接收不到任何点击，
            -- 右键菜单也弹不出；左键由 OnClick 按 _locked 拦截，右键菜单仍可弹（导出项置灰）。
            self:SetAlpha(0.45); self._lock:Show()
        else
            self:SetAlpha(1); self._lock:Hide()
        end
        self:SetSelected(selected)
    end

    function t:SetSelected(on)
        self._selected = on
        self._selTint:SetAlpha(on and 1 or 0)
        self._selTopGlow:SetAlpha(on and 0.5 or 0)
        self._glyphSelBG:SetAlpha(on and 1 or 0)
        for _, e in pairs(self._edgeRing) do
            e:SetVertexColor(theme:RGB("accent")); e:SetAlpha(on and 0.85 or 0)
        end
        local col = on and "accent" or "frameDark"
        for _, ring in ipairs(self._borders or {}) do
            for _, e in pairs(ring) do e:SetVertexColor(theme:RGB(col)) end
        end
        self._glyph:SetTextColor(theme:RGB(on and "accentGlow" or "accent"))
    end

    function t:SetOnSelect(fn) self._onSelect = fn end

    -- hover 反馈：未选中态下，外缘 1px frameBright 边渐显。选中态由 SetSelected 主导，hover 不覆盖。
    t:SetScript("OnEnter", function(s)
        if s._locked or s._selected then return end
        for _, e in pairs(s._edgeRing) do
            e:SetVertexColor(theme:RGB("frameBright")); e:SetAlpha(0.55)
        end
    end)
    t:SetScript("OnLeave", function(s)
        if s._selected then return end
        for _, e in pairs(s._edgeRing) do e:SetAlpha(0) end
    end)

    ------------------------------------------------------------
    -- 右键 → 导出字符串：EasyMenu 下拉菜单
    -- 菜单项点击 → GL.Import:ExportGame(id) → GL.UI:ShowExport / Log
    ------------------------------------------------------------
    function t:ShowContextMenu()
        if not _tileDropdown then
            _tileDropdown = CreateFrame("Frame", "GameLobbyTileDropdown", UIParent, "UIDropDownMenuTemplate")
        end
        if not EasyMenu then return end
        local id, name, locked = self._gameId, self._gameName, self._locked
        local exportDisabled = locked and true or false
        local menu = {
            { text = name or "游戏", isTitle = true, notCheckable = true },
            {
                text = exportDisabled and "导出字符串（不可导出）" or "导出字符串",
                notCheckable = true, disabled = exportDisabled,
                func = function()
                    local GL2 = _G.GameLobby
                    if not (GL2 and GL2.Import) then
                        if GL2 and GL2.UI then GL2.UI:Log("warn", "导入/导出模块尚未就绪") end
                        return
                    end
                    local ok, strOrNil, reason = pcall(function()
                        return GL2.Import:ExportGame(id)
                    end)
                    local str, why
                    if ok then str, why = strOrNil, reason
                    else why = "导出出错：" .. tostring(strOrNil) end
                    if type(str) == "string" then
                        GL2.UI:ShowExport("导出：" .. (name or id or "游戏"), str)
                    else
                        GL2.UI:Log("warn", why or "导出失败")
                    end
                end,
            },
            { text = "取消", notCheckable = true, func = function() end },
        }
        EasyMenu(menu, _tileDropdown, "cursor", 0, 0, "MENU")
    end

    -- 点击分发：左键走选择回调（locked 拦截），右键弹菜单（locked 也允许，仅导出项置灰）
    t:SetScript("OnClick", function(s, button)
        if button == "RightButton" then s:ShowContextMenu()
        else
            if s._locked then return end
            if s._onSelect then s._onSelect(s) end
        end
    end)
    return t
end
