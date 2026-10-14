#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""按 src/hud.lua 的真实常量渲染界面示意图。

这不是实机截图 —— 而是把 hud.lua 里的 LAYOUT 参数、颜色、文字格式逐项
照搬出来渲染，用来核对"面板在屏幕哪个位置、多大、各状态显示什么"。

几何部分（位置/尺寸）是像素级精确的，因为公式就是从代码里抄的；
字体渲染是近似的，因为游戏用的是 core/performance_hud/debug，本机没有。

用法：
    python tools/render_mockup.py
"""
from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "mockup.png")

# ---------------------------------------------------------------------------
# 逐项照搬 src/hud.lua 的 LAYOUT
# ---------------------------------------------------------------------------
LAYOUT = {
    "right_margin": 0.012,
    "below_objectives": 0.28,
    "width": 172,
    "height": 40,
    "text_inset_x": 10,
    "text_inset_y": 7,
    "text_size": 26,
    "reference_height": 1080,
}

GREEN = (90, 220, 155)
ORANGE = (255, 180, 70)
RED = (235, 90, 80)

FONT_CANDIDATES = [
    "C:/Windows/Fonts/consola.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
]
# 中文标注用；游戏里的倒计时字体是 core/performance_hud/debug（本机没有）。
CJK_CANDIDATES = [
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/msyh.ttf",
    "C:/Windows/Fonts/simhei.ttf",
]


def _first_existing(paths):
    for path in paths:
        if os.path.isfile(path):
            return path
    return None


def load_font(size: int):
    path = _first_existing(FONT_CANDIDATES)
    if path:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def load_cjk(size: int):
    path = _first_existing(CJK_CANDIDATES)
    if path:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return load_font(size)


def presentation(status: str, seconds: int):
    """照搬 hud.lua 的 presentation()。返回 (文字, 颜色) 或 (None, None)。"""
    if status == "READY":
        return "READY", GREEN
    if status == "COOLDOWN":
        if seconds > 120:
            colour = GREEN
        elif seconds >= 60:
            colour = ORANGE
        else:
            colour = RED
        return "%02d:%02d" % (seconds // 60, seconds % 60), colour
    return None, None


def geometry(screen_w: int, screen_h: int):
    """照搬 hud.lua 的坐标计算。y 自下而上，所以这里要翻转回来。"""
    scale = screen_h / LAYOUT["reference_height"]
    panel_w = LAYOUT["width"] * scale
    panel_h = LAYOUT["height"] * scale
    x = screen_w - panel_w - screen_w * LAYOUT["right_margin"]
    # 游戏里的 y 从底部量、且指向面板下边缘；换算成图像坐标（从顶量）：
    y_gui = screen_h * (1 - LAYOUT["below_objectives"]) - panel_h
    y_image = screen_h - y_gui - panel_h
    return scale, panel_w, panel_h, x, y_image


def draw_sky(draw, width, height, tint):
    """给一个暗色的、类似游戏画面的背景，方便看清文字位置。"""
    for row in range(height):
        ratio = row / height
        draw.line(
            [(0, row), (width, row)],
            fill=(int(tint[0] * (1 - ratio * 0.5)) + 10,
                  int(tint[1] * (1 - ratio * 0.5)) + 12,
                  int(tint[2] * (1 - ratio * 0.5)) + 16),
        )


def main() -> int:
    screen_w, screen_h = 1920, 1080
    scale, panel_w, panel_h, panel_x, panel_y = geometry(screen_w, screen_h)

    print("screen      = %dx%d" % (screen_w, screen_h))
    print("scale       = %.3f" % scale)
    print("panel       = %.0f x %.0f" % (panel_w, panel_h))
    print("panel at    = %.0f, %.0f  (图像坐标，左上角)" % (panel_x, panel_y))
    print("right edge  = %.0f  (距屏幕右边 %.0f px)"
          % (panel_x + panel_w, screen_w - panel_x - panel_w))

    cases = [
        ("冷却中，剩余 4:12 —— 绿色", "COOLDOWN", 252),
        ("冷却中，剩余 1:34 —— 转为橙色", "COOLDOWN", 94),
        ("冷却中，剩余 0:41 —— 转为红色", "COOLDOWN", 41),
        ("冷却清零 —— 显示 READY", "READY", 0),
    ]

    row_h = 270
    img = Image.new("RGB", (screen_w, row_h * len(cases)), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    font_panel = load_font(max(10, int(LAYOUT["text_size"] * scale)))
    font_note = load_cjk(19)
    font_small = load_cjk(15)

    for index, (label, status, seconds) in enumerate(cases):
        top = index * row_h
        draw_sky(draw, screen_w, row_h, (26, 32, 38))

        # 顶部参考线 + 右上角"原生任务面板"示意，用来交代面板相对位置
        draw.line([(0, top + 2), (screen_w, top + 2)], fill=(60, 70, 78))
        box = (screen_w - 360, top + int(row_h * 0.08),
               screen_w - 40, top + int(row_h * 0.08) + 56)
        draw.rectangle(box, fill=(16, 20, 24), outline=(48, 58, 66))
        draw.text((box[0] + 12, box[1] + 18), "原生任务面板（示意）",
                  font=font_small, fill=(105, 120, 130))

        text, colour = presentation(status, seconds)
        if text is not None:
            # 面板 y 是相对屏幕顶部的绝对位置，这里必须再按行偏移。
            tx = panel_x + LAYOUT["text_inset_x"] * scale
            ty = top + panel_y + LAYOUT["text_inset_y"] * scale
            draw.text((tx, ty), text, font=font_panel, fill=colour)
            # 面板自身的可见范围参考框（实机没有背景板，这里只是示意位置）
            draw.rectangle(
                [panel_x, top + panel_y, panel_x + panel_w, top + panel_y + panel_h],
                outline=(70, 84, 94))
        else:
            label += "   ← 面板隐藏"

        draw.text((28, top + 22), label, font=font_note, fill=(160, 176, 186))
        draw.text((28, top + 48),
                  "面板右边缘距屏幕右边 %.0f px，垂直位于距顶 %.0f%% 处"
                  % (screen_w - panel_x - panel_w, LAYOUT["below_objectives"] * 100),
                  font=font_small, fill=(96, 110, 120))

    img.save(OUT)
    print("\n已写出 %s" % OUT)
    print("注意：这是按代码常量渲染的示意图，不是实机截图。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
