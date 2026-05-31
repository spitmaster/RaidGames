-- Core/UI/Widgets/ScrollList.lua —— 滚动列表容器（战史等长列表用）
-- owner: wow-ui-developer
-- 单一职责（SRP）：用暴雪自带 UIPanelScrollFrameTemplate 包一层，向调用方暴露 child 容器。
-- 调用方在 :GetContent() 上摆控件 + 设置高度，ScrollFrame 自动出滚动条。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end

function W.ScrollList(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(1, 1)
    sf:SetScrollChild(child)
    sf._child = child
    function sf:GetContent() return self._child end
    return sf
end
