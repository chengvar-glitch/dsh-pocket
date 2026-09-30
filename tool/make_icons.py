#!/usr/bin/env python3
"""从 DSH 官方 favicon.svg 生成各平台 App 图标。

为什么不用 cairosvg / rsvg-convert / inkscape：
  本机是 Ubuntu，没装这些工具，系统 pip 又被 PEP 668 挡住，装 venv 还缺
  python3-venv。但系统自带 pycairo，而 DSH 的 logo 恰好是"单条 flat path"，
  所以这里自己解析 SVG 的 path data 并用 pycairo 填充 —— 零新依赖、零 sudo。

输入 : assets/brand/dsh-logo-black.svg（深色鲸鱼，透明底）
       assets/brand/dsh-logo-white.svg（浅色鲸鱼，用于深色底）
输出 : Android mipmap 各密度、macOS AppIcon.appiconset、Linux 图标、assets/brand/logo.png

用法:
    python3 tool/make_icons.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import cairo

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "assets" / "brand"
BLACK_SVG = BRAND / "dsh-logo-black.svg"
WHITE_SVG = BRAND / "dsh-logo-white.svg"

# 官方 viewBox 是 "0 0 50 50"
VIEWBOX = 50.0

# 注：这里曾经硬编码过 INK_TOP/INK_BOTTOM 来"手动居中"，但那只做对了一半
# （缩放由宽度决定，纵向却只平移了顶部）。现在改成 ink_bounds() 实测墨迹
# 包围盒再对齐中心，所以不再需要这两个常量。

TOKEN_RE = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?")


def parse_path(d: str):
    """把 SVG path data 解析成 pycairo 能吃的绝对坐标命令流。

    只支持本 logo 实际用到的命令（M m L l H h V v C c S s Z z 以及 A a 的退化处理），
    够用即可；遇到不支持的命令直接报错，避免静默画错。
    """
    tokens = TOKEN_RE.findall(d)
    i = 0
    cmd = None
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    # 三次贝塞尔的前一个控制点（用于 S/s 的隐含反射）
    last_c2 = None
    out = []

    def num() -> float:
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    def is_cmd(t: str) -> bool:
        return len(t) == 1 and t.isalpha()

    while i < len(tokens):
        if is_cmd(tokens[i]):
            cmd = tokens[i]
            i += 1
            if cmd in "Zz":
                out.append(("close",))
                cur = start
                last_c2 = None
                continue
        if cmd is None:
            raise ValueError("path 以数字开头，缺少命令")

        rel = cmd.islower()
        c = cmd.upper()

        if c == "M":
            x, y = num(), num()
            if rel:
                x, y = cur[0] + x, cur[1] + y
            out.append(("move", x, y))
            cur = start = (x, y)
            last_c2 = None
            cmd = "l" if rel else "L"  # 后续隐式坐标按 lineto 处理
        elif c == "L":
            x, y = num(), num()
            if rel:
                x, y = cur[0] + x, cur[1] + y
            out.append(("line", x, y))
            cur = (x, y)
            last_c2 = None
        elif c == "H":
            x = num()
            if rel:
                x = cur[0] + x
            out.append(("line", x, cur[1]))
            cur = (x, cur[1])
            last_c2 = None
        elif c == "V":
            y = num()
            if rel:
                y = cur[1] + y
            out.append(("line", cur[0], y))
            cur = (cur[0], y)
            last_c2 = None
        elif c == "C":
            x1, y1, x2, y2, x, y = (num() for _ in range(6))
            if rel:
                x1, y1 = cur[0] + x1, cur[1] + y1
                x2, y2 = cur[0] + x2, cur[1] + y2
                x, y = cur[0] + x, cur[1] + y
            out.append(("curve", x1, y1, x2, y2, x, y))
            last_c2 = (x2, y2)
            cur = (x, y)
        elif c == "S":
            x2, y2, x, y = (num() for _ in range(4))
            if rel:
                x2, y2 = cur[0] + x2, cur[1] + y2
                x, y = cur[0] + x, cur[1] + y
            if last_c2 is None:
                x1, y1 = cur
            else:
                x1, y1 = 2 * cur[0] - last_c2[0], 2 * cur[1] - last_c2[1]
            out.append(("curve", x1, y1, x2, y2, x, y))
            last_c2 = (x2, y2)
            cur = (x, y)
        elif c == "A":
            # 本 logo 不含弧线命令；真遇到就明确报错，别静默画错
            raise NotImplementedError("path 含 A/a 弧线命令，本脚本未实现")
        else:
            raise NotImplementedError(f"未支持的 SVG 命令：{cmd}")

    return out


_INK_BOUNDS_CACHE = {}


def ink_bounds(svg: Path):
    """返回 logo 在 viewBox 坐标系下的真实墨迹包围盒 (x0, y0, x1, y1)。

    用 cairo 把路径填充到一张大位图上再取 alpha 包围盒 —— 而不是拿贝塞尔
    控制点当边界：控制点是凸包，比真实墨迹大一圈（实测 x 方向差 0.47、
    y 方向差 0.28），拿它居中会引入肉眼可见的偏移。

    结果按 viewBox 标度归一化后返回。每个 SVG 只测一次（结果有缓存）——
    2000×2000 的逐像素扫描不便宜，而整个脚本会渲染 23 张图。
    """
    cached = _INK_BOUNDS_CACHE.get(svg)
    if cached is not None:
        return cached

    cmds = parse_path(re.search(r'\sd="([^"]+)"', svg.read_text()).group(1))

    probe = 2000
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, probe, probe)
    ctx = cairo.Context(surf)
    ctx.scale(probe / VIEWBOX, probe / VIEWBOX)
    ctx.set_source_rgba(0, 0, 0, 1)
    _trace_path(ctx, cmds)
    ctx.fill()
    surf.flush()

    buf = surf.get_data()
    stride = surf.get_stride()
    minx, miny, maxx, maxy = probe, probe, -1, -1
    for y in range(probe):
        row = y * stride
        for x in range(probe):
            if buf[row + x * 4 + 3] > 8:
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
    if maxx < 0:
        raise RuntimeError(f"{svg.name} 渲染后是空的，检查 path")

    k = VIEWBOX / probe
    result = (minx * k, miny * k, (maxx + 1) * k, (maxy + 1) * k)
    _INK_BOUNDS_CACHE[svg] = result
    return result


def _trace_path(ctx, cmds) -> None:
    """把解析出来的命令逐条喂给 cairo。"""
    for c in cmds:
        if c[0] == "move":
            ctx.move_to(c[1], c[2])
        elif c[0] == "line":
            ctx.line_to(c[1], c[2])
        elif c[0] == "curve":
            ctx.curve_to(c[1], c[2], c[3], c[4], c[5], c[6])
        elif c[0] == "close":
            ctx.close_path()


def draw_logo(ctx, size: float, svg: Path, color, scale_logo: float = 0.82,
              bounds=None):
    """在 size×size 的画布上画 logo，**按墨迹包围盒**居中。

    这个函数以前只做了纵向的一半工作：缩放系数由宽度决定（sx 通常小于 sy），
    但纵向上只平移了 -INK_TOP，没有补上"墨迹缩放后比画布矮"的那部分，
    于是整体偏高。512px 的 App 内 logo 实测偏上约 63px（画布高度的 12%），
    小图标上就是肉眼可见的不居中。

    现在改成显式地把墨迹包围盒映射到画布中央：
      1. 用墨迹的 w/h 算缩放，保证墨迹完整落在 scale_logo 指定的占比内
      2. 把墨迹中心对齐到画布中心
    """
    if bounds is None:
        bounds = ink_bounds(svg)
    x0, y0, x1, y1 = bounds
    ink_w, ink_h = x1 - x0, y1 - y0

    # 墨迹要占到画布的 scale_logo，横纵都满足 → 取更小的那个缩放
    target = size * scale_logo
    s = min(target / ink_w, target / ink_h)

    ctx.save()
    # 先缩放到原点，再把墨迹中心挪到画布中心
    ctx.translate(size / 2, size / 2)
    ctx.scale(s, s)
    ctx.translate(-(x0 + ink_w / 2), -(y0 + ink_h / 2))
    ctx.set_source_rgba(*color)
    _trace_path(ctx, parse_path(re.search(r'\sd="([^"]+)"', svg.read_text()).group(1)))
    ctx.fill()
    ctx.restore()


def render(svg: Path, out: Path, size: int, *, bg=None, logo_color=(0, 0, 0),
           scale_logo: float = 0.82, radius_ratio: float = 0.0):
    """渲染一张 size×size 的 PNG。bg=None 表示透明背景。"""
    out.parent.mkdir(parents=True, exist_ok=True)
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    ctx = cairo.Context(surf)
    ctx.set_antialias(cairo.ANTIALIAS_BEST)

    if bg is not None:
        r = size * radius_ratio
        if r > 0:
            # 圆角矩形背景（Android 自适应图标用）
            x, y, w, h = 0.0, 0.0, float(size), float(size)
            ctx.new_sub_path()
            ctx.arc(x + w - r, y + r, r, -3.14159265 / 2, 0)
            ctx.arc(x + w - r, y + h - r, r, 0, 3.14159265 / 2)
            ctx.arc(x + r, y + h - r, r, 3.14159265 / 2, 3.14159265)
            ctx.arc(x + r, y + r, r, 3.14159265, 3 * 3.14159265 / 2)
            ctx.close_path()
            ctx.set_source_rgba(*bg)
            ctx.fill()
        else:
            ctx.set_source_rgba(*bg)
            ctx.paint()

    draw_logo(ctx, float(size), svg, logo_color, scale_logo)
    surf.write_to_png(str(out))
    return out


# ---- 各平台规格 ----
ANDROID_MIPMAPS = {
    "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
}
# macOS AppIcon 的文件名必须与 flutter create 生成的 Contents.json 逐字一致。
# 注意它复用了同一张图（16@2x 与 32@1x 都叫 app_icon_32.png、512@2x 叫
# app_icon_1024.png），所以这里按"文件名 → 像素数"来生成，而不是按 (尺寸,scale) 推。
MACOS_ICON_FILES = {
    "app_icon_16.png": 16,
    "app_icon_32.png": 32,
    "app_icon_64.png": 64,
    "app_icon_128.png": 128,
    "app_icon_256.png": 256,
    "app_icon_512.png": 512,
    "app_icon_1024.png": 1024,
}

BRAND_BG = (0.0, 0.0, 0.0, 1.0)          # 纯黑底，配白色鲸鱼
WHITE = (1.0, 1.0, 1.0, 1.0)
GRAY_BG = (0.961, 0.961, 0.969, 1.0)     # 浅灰底，配黑色鲸鱼


def main() -> int:
    for p in (BLACK_SVG, WHITE_SVG):
        if not p.exists():
            print(f"缺少源文件：{p}", file=sys.stderr)
            return 1

    made = []

    # 1) Android：传统方形图标（黑底白鲸）+ 自适应图标前景/背景
    for name, px in ANDROID_MIPMAPS.items():
        d = ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{name}"
        made.append(render(WHITE_SVG, d / "ic_launcher.png", px,
                           bg=BRAND_BG, logo_color=WHITE, scale_logo=0.62))
        # 自适应图标：108dp 画布，安全区只有内 66dp，logo 要更小
        made.append(render(WHITE_SVG, d / "ic_launcher_foreground.png", int(px * 108 / 48),
                           bg=None, logo_color=WHITE, scale_logo=0.42))

    # 自适应图标背景色（纯色即可）
    (ROOT / "android" / "app" / "src" / "main" / "res" / "values" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <color name="ic_launcher_background">#000000</color>\n'
        '</resources>\n'
    )

    # 2) macOS AppIcon.appiconset（文件名对齐 Contents.json）
    mdir = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    mdir.mkdir(parents=True, exist_ok=True)
    for fname, px in MACOS_ICON_FILES.items():
        made.append(render(WHITE_SVG, mdir / fname, px,
                           bg=BRAND_BG, logo_color=WHITE, scale_logo=0.68,
                           radius_ratio=0.22))

    # 3) Linux 桌面图标（flutter create 用的是 png）
    for px in (48, 128, 256, 512):
        made.append(render(BLACK_SVG, ROOT / "linux" / f"icon_{px}.png", px,
                           bg=GRAY_BG, logo_color=(0, 0, 0), scale_logo=0.72))

    # 4) App 内使用的 logo（透明底，深浅两版都留）
    made.append(render(WHITE_SVG, BRAND / "logo_white.png", 512, bg=None,
                       logo_color=WHITE, scale_logo=0.9))
    made.append(render(BLACK_SVG, BRAND / "logo_black.png", 512, bg=None,
                       logo_color=(0, 0, 0), scale_logo=0.9))

    for m in made:
        print("生成", m.relative_to(ROOT), f"{m.stat().st_size}B")
    print(f"\n共 {len(made)} 个文件。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
