#!/usr/bin/env python3
"""生成插件用的 PNG 图标（只用标准库：zlib + struct）。运行一次，产物提交进仓库：
  imgs/plugin/icon(.png / @2x)           256 / 512：插件图标
  imgs/plugin/category-icon(.png / @2x)  28 / 56：分类图标
  imgs/keys/default(.png / @2x)          72 / 144：按钮默认底图（运行时会被 SVG 盖掉）
  imgs/actions/<name>/icon(.png / @2x)   20 / 40：动作列表里的小图标（每种一个颜色 / 形状）
颜色按设计方案：PGM 红、PVW 绿。"""
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "com.plusmix.switcher.sdPlugin", "imgs")


def png(path, w, h, pixel):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel(x, y, w, h))

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def rounded(fill, radius_frac=0.2, inset=0.0, ring=None):
    """圆角方块；ring = (颜色, 环宽比例) 画一个空心环。"""
    def pixel(x, y, w, h):
        r = w * radius_frac
        i = w * inset
        px, py = x + 0.5, y + 0.5
        left, top, right, bottom = i, i, w - i, h - i
        if px < left or py < top or px > right or py > bottom:
            return (0, 0, 0, 0)
        cx = min(max(px, left + r), right - r)
        cy = min(max(py, top + r), bottom - r)
        d2 = (px - cx) ** 2 + (py - cy) ** 2
        if d2 > r * r:
            return (0, 0, 0, 0)
        if ring:
            color, width = ring
            inner = w * inset + w * width
            if inner < px < w - inner and inner < py < h - inner:
                return fill + (255,)
            return color + (255,)
        return fill + (255,)
    return pixel


def two_tone(left, right):
    """左右两色（cut：左绿右红）。"""
    def pixel(x, y, w, h):
        base = rounded(left)(x, y, w, h)
        if base[3] == 0:
            return base
        return (right if x >= w / 2 else left) + (255,)
    return pixel


def dot(bg, fg):
    """底色 + 中心圆点（record / ftb）。"""
    def pixel(x, y, w, h):
        base = rounded(bg)(x, y, w, h)
        if base[3] == 0:
            return base
        cx, cy, r = w / 2, h / 2, w * 0.22
        return (fg + (255,)) if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r else base
    return pixel


RED, GREEN, AMBER, BLUE, GREY, DARK, WHITE = (214, 40, 40), (42, 157, 59), (224, 159, 31), (31, 111, 224), (90, 90, 90), (43, 43, 43), (255, 255, 255)

ACTIONS = {
    "cut": two_tone(GREEN, RED),
    "auto": two_tone(GREEN, AMBER),
    "slot": rounded(DARK, ring=(BLUE, 0.18)),
    "preview": rounded(GREEN),
    "program": rounded(RED),
    "tally": rounded(DARK, ring=(RED, 0.18)),
    "overlay": rounded(AMBER),
    "record": dot(DARK, RED),
    "stream": rounded(BLUE),
    "ftb": dot(GREY, (0, 0, 0)),
}


def main():
    for size, suffix in ((256, ""), (512, "@2x")):
        png(os.path.join(ROOT, "plugin", "icon%s.png" % suffix), size, size, two_tone(GREEN, RED))
    for size, suffix in ((28, ""), (56, "@2x")):
        png(os.path.join(ROOT, "plugin", "category-icon%s.png" % suffix), size, size, two_tone(GREEN, RED))
    for size, suffix in ((72, ""), (144, "@2x")):
        png(os.path.join(ROOT, "keys", "default%s.png" % suffix), size, size, rounded(DARK, radius_frac=0.15))
    for name, pixel in ACTIONS.items():
        for size, suffix in ((20, ""), (40, "@2x")):
            png(os.path.join(ROOT, "actions", name, "icon%s.png" % suffix), size, size, pixel)
    print("icons written under", os.path.normpath(ROOT))


if __name__ == "__main__":
    main()
