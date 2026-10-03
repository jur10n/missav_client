#!/usr/bin/env python3
"""生成扩展图标：深色圆角方块 + 品红播放三角，与 popup 配色一致。"""
from PIL import Image, ImageDraw
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "icons"
BG = (20, 22, 26, 255)      # #14161a
FG = (229, 68, 109, 255)    # #e5446d


def rounded_rect(draw, size, radius, color):
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=color)


def make(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded_rect(d, size, max(2, size // 5), BG)
    # 播放三角，占约 55% 高度，稍微右移保持视觉居中
    h = size * 0.56
    x0 = size * 0.34
    y0 = (size - h) / 2
    pts = [(x0, y0), (x0, y0 + h), (x0 + h * 0.78, size / 2)]
    d.polygon(pts, fill=FG)
    return img


for s in (16, 48, 128):
    make(s).save(ROOT / f"icon{s}.png")
    print(f"icon{s}.png")
