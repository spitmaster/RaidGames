-- Core/UI/Widgets/SectionLabel.lua —— 区段标题（11px 字距 + 渐隐横线 + 可挂多段右侧 extra）
-- owner: wow-ui-developer
-- 单一职责（SRP）：渲染一行"标题文字 + 右侧渐隐横线"，可挂若干右侧补充段（人数/就绪等）。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

function W.SectionLabel(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(22)

    local fs = W.Text(f, "display", theme.font.sectionLabel, "textDim")
    fs:SetPoint("LEFT", f, "LEFT", 4, 0)
    fs:SetText(text or "")
    f._label = fs

    -- 右侧渐隐横线（divider 实 → 透明）
    local line = W.Solid(f, "divider", 0.8, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 10, 0)
    line:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    W.SetVGradient(line, {theme:RGB("divider")}, {theme:RGB("divider", 0)})
    f._line = line

    -- 右侧 extra 段（人数 "10 人"、就绪 "✓ 9/9" 等）
    f._extra = {}
    function f:AddExtra(txt, token, kind)
        local e = W.Text(self, kind or "mono", theme.font.small, token or "text")
        e:SetText(txt)
        local anchor = #self._extra > 0 and self._extra[#self._extra] or fs
        e:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
        table.insert(self._extra, e)
        line:ClearAllPoints()
        line:SetPoint("LEFT", e, "RIGHT", 10, 0)
        line:SetPoint("RIGHT", self, "RIGHT", -4, 0)
        return e
    end

    function f:SetLabel(txt) fs:SetText(txt) end
    return f
end
