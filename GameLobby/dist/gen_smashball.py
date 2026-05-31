# gen_smashball.py —— 生成狂点钮的实心金圆贴图（GameLobby/Media/smashball.tga）
# 不进游戏（dist/ 被 deploy skill 排除）。生成的 .tga 进 GameLobby/Media/ 随插件部署。
#
# 为什么切图：WoW 3.3.5 矢量 API 画不出"硬边 + 径向渐变"的实心圆。用 PIL/numpy 画一张干净的
# 金圆 TGA 贴上去，才是设计稿那个金属盘。
#
# 抗锯齿：在 4× 画布（1024）逐像素算色，再 LANCZOS 缩到 256 —— 边缘超采样平滑，消除锯齿毛刺。
# TGA：32-bit uncompressed，2 的幂尺寸。径向高光居中（上下对称），规避 WoW TGA origin 颠倒问题。
import numpy as np
from PIL import Image

S = 256
SS = 4           # 超采样倍数
S2 = S * SS
R = 116 * SS     # 圆半径（@1024）
EDGE = 3 * SS    # 亮边宽
GLOW = 14 * SS   # 圆外柔光过渡宽
AA = 1.5 * SS    # 边缘抗锯齿过渡像素（alpha 软化）

def hx(h):
    h = h.lstrip('#')
    return np.array([int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)], dtype=np.float32)

C_GLOW   = hx('ffd98a')   # accentGlow  中心高光
C_BRIGHT = hx('d6a85b')   # frameBright 金属亮
C_DEEP   = hx('8a5a1c')   # accentDeep  暗金
C_DARK   = hx('3a2810')   # 边缘更暗
C_EDGE   = hx('f0c46c')   # accent      亮边环

cx = cy = (S2 - 1) / 2.0
ys, xs = np.ogrid[0:S2, 0:S2]
r = np.hypot(xs - cx, ys - cy).astype(np.float32)   # 到圆心距离
d = np.clip(r / R, 0.0, 1.0)                        # 归一化

# 径向颜色（设计 stops：0%glow 20%bright 65%deep 100%dark），分段线性插值
rgb = np.empty((S2, S2, 3), dtype=np.float32)
def seg(mask, a, b, t):
    for i in range(3):
        rgb[..., i] = np.where(mask, a[i] + (b[i] - a[i]) * t, rgb[..., i])
m1 = d < 0.20
m2 = (d >= 0.20) & (d < 0.65)
m3 = d >= 0.65
seg(m1, C_GLOW,   C_BRIGHT, np.clip(d / 0.20, 0, 1))
seg(m2, C_BRIGHT, C_DEEP,   np.clip((d - 0.20) / 0.45, 0, 1))
seg(m3, C_DEEP,   C_DARK,   np.clip((d - 0.65) / 0.35, 0, 1))

# 亮边环（R-EDGE .. R 之间染 accent，向圆心侧软过渡）
edge_t = np.clip((r - (R - EDGE)) / EDGE, 0, 1)      # 0→实心区, 1→边
edge_band = (r > R - EDGE) & (r <= R)
for i in range(3):
    rgb[..., i] = np.where(edge_band, rgb[..., i] + (C_EDGE[i] - rgb[..., i]) * edge_t, rgb[..., i])

# alpha：圆内实心(255)，边缘 AA 软化，圆外柔光渐隐到 0
alpha = np.zeros((S2, S2), dtype=np.float32)
# 实心圆 + 边缘抗锯齿（r <= R 完全不透明，R..R+AA 线性降到柔光起点）
inside = r <= R
alpha = np.where(inside, 255.0, alpha)
aa_band = (r > R) & (r <= R + AA)
alpha = np.where(aa_band, 255.0 * (1.0 - (r - R) / AA), alpha)
# 柔光：R+AA .. R+GLOW，从 ~120 渐隐到 0（叠在抗锯齿之外做外发光过渡）
glow_band = (r > R) & (r <= R + GLOW)
glow_a = 130.0 * np.clip(1.0 - (r - R) / GLOW, 0, 1) ** 1.5
alpha = np.maximum(alpha, np.where(glow_band, glow_a, 0.0))
# 柔光区颜色用暗金
glow_only = (r > R + AA) & (r <= R + GLOW)
for i in range(3):
    rgb[..., i] = np.where(glow_only, C_DEEP[i], rgb[..., i])

out = np.concatenate([rgb, alpha[..., None]], axis=2).clip(0, 255).astype(np.uint8)
img = Image.fromarray(out, "RGBA").resize((S, S), Image.LANCZOS)
img.save("GameLobby/Media/smashball.tga")
print("wrote GameLobby/Media/smashball.tga", img.size, "(4x supersampled)")
