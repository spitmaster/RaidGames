-- Core/UI/Theme.lua —— 铁木 Ironwood 主题令牌（契约 §9，SPEC §4.1）
-- owner: wow-ui-developer
-- 把 styles.css :root 的铁木令牌 hex→0-1 RGB 表，挂到 GL.UI.theme。
-- M1 仅铁木主题；奥术/血色令牌不在此实现（SPEC §4.1 已留存表格，后续里程碑接主题切换时再补）。
-- 代码用「令牌名→RGB」组织颜色，方便日后切主题：换一张 token 表即可。

local self = aura_env or {}
local GL = _G.GameLobby
if not GL then return end
GL.UI = GL.UI or {}

local HexToRGB = GL.HexToRGB

-- 把单个 hex 转成 {r,g,b}（带 .hex 备查）。
local function pack(hex)
    local r, g, b = HexToRGB(hex)
    return { r, g, b, hex = hex }
end

------------------------------------------------------------
-- 铁木 Ironwood 令牌（styles.css :root，含 SPEC §4.1 全部令牌 + 原型补充令牌）
------------------------------------------------------------

local IRONWOOD = {
    bgPage      = pack("#0b0805"),  -- 页面底色
    bgPage2     = pack("#1a120a"),  -- 径向渐变内圈
    frameOuter  = pack("#2a1d0f"),  -- 描边最外暗层
    frameMid    = pack("#6b4a22"),  -- 边框中间色
    frameBright = pack("#d6a85b"),  -- 金属亮边
    frameDark   = pack("#1a1108"),  -- 描边内暗环
    panel       = pack("#1a140c"),  -- 面板底
    panel2      = pack("#0f0b06"),  -- 面板次底
    panelInset  = pack("#0a0703"),  -- 内嵌凹槽底
    divider     = pack("#4a341a"),  -- 分隔线
    text        = pack("#f3e6cb"),  -- 正文
    textDim     = pack("#b89a6a"),  -- 次要文字
    textMute    = pack("#7a6a48"),  -- 弱化文字
    accent      = pack("#f0c46c"),  -- 强调（标题/高亮）
    accentGlow  = pack("#ffd98a"),  -- 强调高光（数字/冠军）
    accentDeep  = pack("#8a5a1c"),  -- 强调暗部（发光阴影）
    danger      = pack("#d85a3a"),  -- 危险/关闭（三主题共用）
    success     = pack("#6abf5e"),  -- 就绪/成功（三主题共用）
}

------------------------------------------------------------
-- 稀有度色（通用 RPG 约定，SPEC §4.1）
------------------------------------------------------------

local RARITY = {
    common    = pack("#bcbcbc"),
    uncommon  = pack("#4ec24c"),
    rare      = pack("#4a8ce8"),
    epic      = pack("#a64ad8"),
    legendary = pack("#ff9b30"),
}

------------------------------------------------------------
-- 职业色（SPEC §4.1，设计稿原型色调；运行时优先用 GetClassColor，见 :ClassColor）
-- key 用 WoW 的 classFile（大写英文），与 Roster 返回的 classFile 对齐。
------------------------------------------------------------

local CLASS = {
    WARRIOR = pack("#c4945a"),
    MAGE    = pack("#66d6ee"),
    PRIEST  = pack("#e6e1d4"),
    ROGUE   = pack("#f0e26a"),
    PALADIN = pack("#f0a4c8"),
    HUNTER  = pack("#a8d96a"),
    WARLOCK = pack("#a884e0"),
    SHAMAN  = pack("#4a8ee6"),
    DRUID   = pack("#ff8a3d"),
    -- WLK 还有 DEATHKNIGHT，设计稿未给色；回落 GetClassColor / 经典红。
    DEATHKNIGHT = pack("#c41f3b"),
}

------------------------------------------------------------
-- 字距 / 字号常量（CSS letter-spacing/font-size → WoW 近似）
-- WoW 字体无法逐字字距（letter-spacing），只能靠「文案里插全角空格」近似（设计稿文案已含）。
-- 这里保留尺寸常量供各组件统一取用。
------------------------------------------------------------

local FONT = {
    titleText   = 22,   -- 标题「游 戏 大 厅」
    titleSub    = 10,   -- 副标题
    countdown   = 110,  -- 倒计时巨大数字（设计 180，WoW 窗体偏小，降级，见报告）
    countdownGo = 72,   -- GO!
    myCount     = 64,   -- 比赛计数大数字
    winnerName  = 34,   -- 冠军名
    statValue   = 26,   -- 统计卡大数字
    smashText   = 26,   -- 狂点钮文案
    btn         = 14,
    btnLg       = 16,
    btnSm       = 11,
    sectionLabel= 11,
    body        = 12,
    mono        = 13,
    small       = 11,
    tiny        = 10,
}

-- WoW 自带字体路径（中文衬线感 → ARKai；数字等宽感 → ARIALN 近似 tabular-nums）
local FONTFILE = {
    display = "Fonts\\ARKai_T.ttf",   -- 标题/按钮：中文楷体，贴近 Cinzel 衬线气质
    ui      = "Fonts\\ARKai_T.ttf",   -- 正文
    mono    = "Fonts\\ARIALN.TTF",    -- 数字/计时/分数（较窄，近似等宽）
}
if not FONTFILE.display then FONTFILE.display = STANDARD_TEXT_FONT end

------------------------------------------------------------
-- 组装 theme，挂 GL.UI.theme
------------------------------------------------------------

local theme = {
    name      = "ironwood",
    nameLabel = "铁木 Ironwood",
    c         = IRONWOOD,
    rarity    = RARITY,
    class     = CLASS,
    font      = FONT,
    fontFile  = FONTFILE,
}

-- 取令牌色：theme:RGB("accent") → r,g,b,a
function theme:RGB(token, alpha)
    local t = self.c[token]
    if not t then return 1, 1, 1, alpha or 1 end
    return t[1], t[2], t[3], alpha or 1
end

-- 稀有度 → r,g,b（key: common/uncommon/rare/epic/legendary）
function theme:Rarity(key)
    local t = self.rarity[key] or self.rarity.common
    return t[1], t[2], t[3]
end

-- 职业色 → r,g,b。优先 WoW 原生 GetClassColor（与游戏内一致），缺则回落设计稿色调。
function theme:ClassColor(classFile)
    if classFile and GetClassColor then
        local r, g, b = GetClassColor(classFile)
        if r then return r, g, b end
    end
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local cc = RAID_CLASS_COLORS[classFile]
        return cc.r, cc.g, cc.b
    end
    local t = self.class[classFile]
    if t then return t[1], t[2], t[3] end
    return self.c.textMute[1], self.c.textMute[2], self.c.textMute[3]   -- 无职业回落弱化色
end

GL.UI.theme = theme
