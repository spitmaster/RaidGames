# 从 Chrome dino 雪碧图 crop 所需精灵 → 打成一张 POT 图集 atlas（TGA 32位不压缩）。
# 输出：GameLobby/Media/dino/atlas.tga + sample/dino/atlas_preview.png + 打印每个精灵 {x,y,w,h}。
#
# 已知排错点（无头环境无法验证 WoW 显示）：
#   - 若真机里贴图上下颠倒：把存图前的 atlas 先 ImageOps.flip(atlas) 再 save（TGA 原点位）。
#   - 必须 POT（2 的幂）尺寸、32 位、不压缩，否则旧客户端可能黑屏/不显示。
import os
from PIL import Image, ImageOps

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, "dino.png")
# atlas 落地到插件 Media（纯插件路线，每个用户都有此文件）
MEDIA = os.path.normpath(os.path.join(HERE, "..", "..", "GameLobby", "Media", "dino"))
os.makedirs(MEDIA, exist_ok=True)
ATLAS_TGA = os.path.join(MEDIA, "atlas.tga")
PREVIEW = os.path.join(HERE, "atlas_preview.png")

im = Image.open(SRC).convert("RGBA")
px = im.load()
W, H = im.size


def tight(box):
    """收紧 bbox 到该 box 内 alpha>16 像素的最小矩形 (x0,y0,x1,y1)。"""
    x0, y0, x1, y1 = box
    minx, miny, maxx, maxy = x1, y1, x0, y0
    found = False
    for y in range(y0, y1):
        for x in range(x0, x1):
            if px[x, y][3] > 16:
                found = True
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if not found:
        return box
    return (minx, miny, maxx + 1, maxy + 1)


def col_segments(x0, x1, y0, y1, min_gap=2):
    """在 [x0,x1) 区间内按空列分隔出连续内容列段，返回 [(cx0,cx1), ...]（cx1 含右界+1）。"""
    fill = []
    for x in range(x0, x1):
        c = 0
        for y in range(y0, y1):
            if px[x, y][3] > 16:
                c += 1
        fill.append(c)
    segs = []
    i = 0
    n = x1 - x0
    while i < n:
        if fill[i] > 0:
            s = i
            gap = 0
            while i < n:
                if fill[i] > 0:
                    gap = 0
                else:
                    gap += 1
                    if gap >= min_gap:
                        break
                i += 1
            e = i - gap
            segs.append((x0 + s, x0 + e + 1))
        else:
            i += 1
    return segs


sprites = {}  # name -> tight box (x0,y0,x1,y1) in source


def add(name, box):
    t = tight(box)
    sprites[name] = t
    return t


# ---- 恐龙 6 帧（88px 步距，精灵带 y2..96）：挑 run1/run2/jump/dead ----
TREX_X0, STEP = 1678, 88
# trex_2=跑左腿前, trex_3=跑右腿前, trex_0=站立(jump用), trex_5=撞死
add("run1", (TREX_X0 + 2 * STEP, 2, TREX_X0 + 3 * STEP, 97))
add("run2", (TREX_X0 + 3 * STEP, 2, TREX_X0 + 4 * STEP, 97))
add("jump", (TREX_X0 + 0 * STEP, 2, TREX_X0 + 1 * STEP, 97))
add("dead", (TREX_X0 + 5 * STEP, 2, TREX_X0 + 6 * STEP, 97))

# ---- 蹲 2 帧（118px 步距，矮宽 y36..96）----
DUCK_X0, DSTEP = 2206, 118
add("duck1", (DUCK_X0 + 0 * DSTEP, 2, DUCK_X0 + 1 * DSTEP, 97))
add("duck2", (DUCK_X0 + 1 * DSTEP, 2, DUCK_X0 + 2 * DSTEP, 97))

# ---- 翼龙 2 帧（92px 步距）----
PT_X0, PSTEP = 260, 92
add("fly1", (PT_X0 + 0 * PSTEP, 2, PT_X0 + 1 * PSTEP, 90))
add("fly2", (PT_X0 + 1 * PSTEP, 2, PT_X0 + 2 * PSTEP, 90))

# ---- 云（一朵）：seg_02 x[174,257]，紧 bbox ----
add("cloud", (174, 2, 258, 50))

# ---- 仙人掌：小仙人掌排里相邻的「手臂」彼此重叠 → 列扫描不出干净缝，
#      改用手挑的显式 bbox（按列 ink 直方图：每根的主干列 ink≈64-70）。
#   小单根：主干 456-469 + 两侧手臂列 → x[446,480]（约 34 宽）
#   小双根：两根主干 490-503 / 524-537 → x[480,538]（约 58 宽）
add("cactusS", (446, 2, 480, 101))     # 单根小仙人掌
add("cactusS2", (480, 2, 538, 101))    # 双根小仙人掌

# ---- 大仙人掌：seg_05 x[652,749] 双根（高）；seg_06 里挑一个三根丛生 ----
add("cactusL", (652, 2, 750, 101))      # 双根大仙人掌（约 98 宽）
add("cactusL2", (752, 2, 840, 101))     # 丛生大仙人掌（取前段）

# ---- 打包到 atlas ----
PAD = 2
names = list(sprites.keys())
# 简单行填充：按高度排序，逐行放，行宽到达 atlas 宽换行。
ATLAS_W = 512
# 先按高降序放置（减少空洞）
order = sorted(names, key=lambda n: sprites[n][3] - sprites[n][1], reverse=True)
placed = {}
cx, cy, rowh = PAD, PAD, 0
for n in order:
    x0, y0, x1, y1 = sprites[n]
    w, h = x1 - x0, y1 - y0
    if cx + w + PAD > ATLAS_W:
        cx = PAD
        cy += rowh + PAD
        rowh = 0
    placed[n] = (cx, cy, w, h)
    cx += w + PAD
    if h > rowh:
        rowh = h
needed_h = cy + rowh + PAD


def next_pot(v):
    p = 1
    while p < v:
        p *= 2
    return p


ATLAS_H = next_pot(needed_h)
print("atlas needs HxW: needed_h=%d -> POT H=%d, W=%d" % (needed_h, ATLAS_H, ATLAS_W))

atlas = Image.new("RGBA", (ATLAS_W, ATLAS_H), (0, 0, 0, 0))
for n in order:
    x0, y0, x1, y1 = sprites[n]
    crop = im.crop((x0, y0, x1, y1))
    ax, ay, w, h = placed[n]
    atlas.paste(crop, (ax, ay))

# 保存 TGA：32 位带 alpha、不压缩（Pillow 默认 TGA 即不压缩 RGBA）
atlas.save(ATLAS_TGA)
# 预览 PNG（给人看，深底叠一层方便辨认）
prev = Image.new("RGBA", (ATLAS_W, ATLAS_H), (28, 28, 32, 255))
prev.alpha_composite(atlas)
prev.save(PREVIEW)

# 回读校验
chk = Image.open(ATLAS_TGA)
print("ATLAS saved:", ATLAS_TGA)
print("  reopened size=%s mode=%s" % (chk.size, chk.mode))
print("  POT? W=%d (%s) H=%d (%s)" % (
    ATLAS_W, "yes" if ATLAS_W == next_pot(ATLAS_W) else "NO",
    ATLAS_H, "yes" if ATLAS_H == next_pot(ATLAS_H) else "NO"))

print("\n-- LUA coords (x,y,w,h in atlas %dx%d) --" % (ATLAS_W, ATLAS_H))
for n in sorted(placed.keys()):
    ax, ay, w, h = placed[n]
    print('  %-9s = {%4d,%4d,%4d,%4d},' % (n, ax, ay, w, h))
