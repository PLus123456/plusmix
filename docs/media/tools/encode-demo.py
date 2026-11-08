#!/usr/bin/env python3
"""Add explanatory captions outside real window captures; export compact README GIFs."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / ".build/readme-media"
MEDIA = ROOT / "docs/media"

DEMOS = {
    "switching": ("从预览，到播出", [
        (0, 2.9, "选择 PVW，播出画面保持不变"),
        (2.9, 5.3, "Cut：立即切换两路画面"),
        (5.3, 8.9, "Fade：1 秒淡入淡出"),
        (8.9, 12, "Wipe：从左向右擦除"),
    ]),
    "overlays": ("字幕与画中画，独立控制", [
        (0, 3.5, "Overlay 1：字幕从下方滑入"),
        (3.5, 6.5, "Overlay 2：淡入画中画"),
        (6.5, 9.1, "单独收起字幕，保留画中画"),
        (9.1, 12, "收起画中画，回到干净的节目画面"),
    ]),
}


def caption(name, title, index, text):
    dots = ''.join(f'<circle cx="{854 + n * 23}" cy="687" r="4" fill="{"#6EE7B7" if n == index else "#3D4C58"}"/>' for n in range(4))
    svg = OUT / f"{name}-caption-{index}.svg"
    svg.write_text(f'''<svg xmlns="http://www.w3.org/2000/svg" width="960" height="720" viewBox="0 0 960 720">
      <rect width="960" height="86" fill="#101820"/>
      <rect y="656" width="960" height="64" fill="#101820"/>
      <g font-family="PingFang SC, Helvetica Neue, sans-serif">
        <text x="28" y="27" font-size="12" letter-spacing="2.5" fill="#6EE7B7">PLUSMIX / 工作流程</text>
        <text x="27" y="63" font-size="26" font-weight="600" fill="#F4F8FA">{title}</text>
        <text x="932" y="48" text-anchor="end" font-size="13" fill="#A7B9C6">真实 App · 原创演示素材</text>
        <circle cx="41" cy="687" r="15" fill="#6EE7B7"/>
        <text x="41" y="693" text-anchor="middle" font-size="17" font-weight="600" fill="#101820">{index + 1}</text>
        <text x="72" y="694" font-size="19" fill="#F4F8FA">{text}</text>
      </g>
      {dots}
      <path d="M0 85.5H960M0 656.5H960" stroke="#34414D"/>
    </svg>''', encoding="utf-8")
    png = svg.with_suffix(".png")
    subprocess.run(["swift", "-module-cache-path", str(OUT / "ModuleCache"),
                    str(MEDIA / "tools/render-svg.swift"), str(svg), str(png)], check=True)
    return png


for name, (title, chapters) in DEMOS.items():
    inputs = ["-i", str(OUT / f"{name}.mov")]
    filters = ["[0:v]fps=12,scale=960:570:flags=lanczos,pad=960:720:0:86:color=0x101820,setsar=1[v0]"]
    for index, (start, end, text) in enumerate(chapters):
        inputs += ["-i", str(caption(name, title, index, text))]
        filters.append(f"[v{index}][{index+1}:v]overlay=0:0:enable='gte(t,{start})*lt(t,{end})'[v{index+1}]")
    filters += ["[v4]split[a][b]", "[a]palettegen=max_colors=192:stats_mode=diff[p]",
                "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"]
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs,
                    "-filter_complex", ";".join(filters), "-t", "12", "-loop", "0",
                    str(MEDIA / f"demo-{name}.gif")], check=True)
    print(f"{name}: {(MEDIA / f'demo-{name}.gif').stat().st_size / 1024:.0f} KiB")

subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(OUT / "poster.png"),
                "-vf", "scale=1280:760:flags=lanczos", "-frames:v", "1", str(MEDIA / "demo-poster.png")], check=True)
