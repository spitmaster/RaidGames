-- Core/UI/Widgets/RankRow.lua —— 榜行（live / final 两种规格）
-- owner: wow-ui-developer
-- 单一职责（SRP）：渲染一行排名（rank + 职业色名 + 分数 + 可选 CPS / 进度条）。
-- 实例 API：
--   :SetRow({ rank, name, classFile, score, cps, isSelf, maxScore })
--
-- kind 区分：
--   "live"  ：高 28，分数右对齐，底部 2px 进度条（cps 不显示）
--   "final" ：高 34，分数右对齐，左侧 CPS，rank=1 用 |T 图标 + 传说色

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
local W = GL.UI and GL.UI.Widgets
if not W then return end
local theme = GL.UI.theme

function W.RankRow(parent, kind)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(kind == "final" and 34 or 28)
    W.PanelBG(r, "panel2"); W.MetalBorder(r, "thin")

    local classBar = W.Solid(r, nil, 1, "ARTWORK")
    classBar:SetWidth(3)
    classBar:SetPoint("TOPLEFT"); classBar:SetPoint("BOTTOMLEFT")
    r._classBar = classBar

    local selfBG = W.Solid(r, "accent", 0, "BACKGROUND", 1)
    selfBG:SetAllPoints(r)
    W.SetVGradient(selfBG, {theme:RGB("accent", 0.15)}, {theme:RGB("accent", 0)})
    r._selfBG = selfBG

    local rank = W.Text(r, "display", kind == "final" and 16 or 13, "textMute")
    rank:SetPoint("LEFT", r, "LEFT", 8, 0)
    rank:SetWidth(24); rank:SetJustifyH("CENTER")
    r._rank = rank

    local name = W.Text(r, "ui", kind == "final" and 13 or theme.font.body, "text")
    name:SetPoint("LEFT", rank, "RIGHT", 6, 0)
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    r._name = name

    local score = W.Text(r, "mono", kind == "final" and 16 or theme.font.mono, "accentGlow")
    score:SetPoint("RIGHT", r, "RIGHT", -10, 0)
    r._score = score

    if kind == "final" then
        local cps = W.Text(r, "mono", theme.font.small, "textMute")
        cps:SetPoint("RIGHT", score, "LEFT", -12, 0)
        r._cps = cps
    else
        local bar = W.Solid(r, "accent", 0.5, "OVERLAY")
        bar:SetHeight(2); bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 3, 0)
        r._bar = bar
    end

    function r:SetRow(d)
        d = d or {}
        local cr, cg, cb = theme:ClassColor(d.classFile)
        self._classBar:SetVertexColor(cr, cg, cb)
        self._name:SetText(d.name or "?")
        self._name:SetTextColor(cr, cg, cb)
        self._selfBG:SetAlpha(d.isSelf and 1 or 0)
        self._score:SetText(tostring(d.score or 0))

        -- 名次：final 第 1 名用 |T 图标；其余配色 1/2/3
        local rk = d.rank or 0
        if kind == "final" and rk == 1 then
            self._rank:SetText(W.ICON.leader); self._rank:SetTextColor(theme:Rarity("legendary"))
        else
            self._rank:SetText(tostring(rk))
            if rk == 1 then
                self._rank:SetTextColor(theme:Rarity("legendary"))
            elseif kind == "final" and rk == 2 then
                self._rank:SetTextColor(0.77, 0.77, 0.77)
            elseif kind == "final" and rk == 3 then
                self._rank:SetTextColor(0.79, 0.48, 0.24)
            else
                self._rank:SetTextColor(theme:RGB("textMute"))
            end
        end

        -- rank-1 行底描边换传说橙
        if rk == 1 then
            local lr, lg, lb = theme:Rarity("legendary")
            for _, ring in ipairs(self._borders or {}) do
                for _, e in pairs(ring) do e:SetVertexColor(lr, lg, lb, 0.8) end
            end
        else
            for _, ring in ipairs(self._borders or {}) do
                for _, e in pairs(ring) do e:SetVertexColor(theme:RGB("frameDark")) end
            end
        end

        if self._cps then self._cps:SetText("CPS " .. string.format("%.1f", d.cps or 0)) end
        if self._bar and d.maxScore and d.maxScore > 0 then
            local w = (self:GetWidth() - 6) * (math.min(d.score or 0, d.maxScore) / d.maxScore)
            self._bar:SetWidth(math.max(0.1, w))
            self._bar:SetVertexColor(cr, cg, cb, 0.5)
        end
    end
    return r
end
