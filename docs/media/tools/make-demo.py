#!/usr/bin/env python3
"""Create original static demo inputs and a real PlusMix show; no camera/network needed."""
import copy
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / ".build/readme-media/demo"
OUT.mkdir(parents=True, exist_ok=True)
RENDER = ROOT / "docs/media/tools/render-svg.swift"
CACHE = ROOT / ".build/readme-media/ModuleCache"


def render(name, body):
    source = OUT / f"{name}.svg"
    source.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" '
        'viewBox="0 0 1280 720">' + body + '</svg>\n', encoding="utf-8"
    )
    subprocess.run(["swift", "-module-cache-path", str(CACHE), str(RENDER),
                    str(source), str(source.with_suffix(".png"))], check=True)


for number, label, accent in [(1, "主画面", "#FF867B"), (2, "第二视角", "#6EE7B7"), (3, "演示文稿", "#9EAEFF")]:
    render(f"source-{number}", f'''
      <rect width="1280" height="720" fill="#15222C"/>
      <path d="M720 0H1280V720H900L660 400Z" fill="{accent}"/>
      <circle cx="1120" cy="180" r="240" fill="none" stroke="#15222C" stroke-opacity=".18" stroke-width="72"/>
      <path d="M840 720L1280 280M960 720L1280 400" stroke="#15222C" stroke-opacity=".2" stroke-width="3"/>
      <g fill="#F5F9FA" font-family="Helvetica Neue, sans-serif">
        <text x="76" y="90" font-size="23" letter-spacing="4">PLUSMIX / DEMO SOURCE</text>
        <text x="62" y="370" font-size="236" font-weight="700" letter-spacing="-14">0{number}</text>
        <text x="78" y="450" font-size="46" font-family="PingFang SC, sans-serif" font-weight="600">{label}</text>
        <text x="78" y="643" font-size="22" fill="#AEBBC4" font-family="PingFang SC, sans-serif">原创静态演示素材</text>
      </g>
      <path d="M1040 455v110m-55-55h110" stroke="#15222C" stroke-width="22" stroke-linecap="round"/>
    ''')

render("lower-third", '''
  <rect x="64" y="548" width="1152" height="118" rx="12" fill="#0D171F" fill-opacity=".94"/>
  <rect x="64" y="548" width="8" height="118" rx="4" fill="#6EE7B7"/>
  <text x="104" y="598" fill="#F5F9FA" font-size="34" font-family="PingFang SC, sans-serif" font-weight="600">PlusMix 现场演示</text>
  <text x="104" y="640" fill="#B4C4CE" font-size="24" font-family="PingFang SC, sans-serif">多机位切换 · 字幕叠加</text>
  <text x="1014" y="619" fill="#6EE7B7" font-size="24" font-family="Helvetica Neue, sans-serif" letter-spacing="3">DEMO</text>
''')

show = json.loads((ROOT / "Samples/event/event.switcher.json").read_text())
template = copy.deepcopy(show["inputs"][0])
show["inputs"] = []
for n, name in [(1, "主画面 · 演示图"), (2, "第二视角 · 演示图"), (3, "演示文稿"), (4, "标题字幕")]:
    item = copy.deepcopy(template)
    item.update(number=n, name=name, source={"image": {"path": f"source-{n}.png" if n < 4 else "lower-third.png"}})
    item["settings"]["audio"]["muted"] = True
    show["inputs"].append(item)
show["name"] = "README 演示"
show["outputs"] = []
show["mixer"]["format"] = {"width": 1280, "height": 720, "frameRate": {"numerator": 30, "denominator": 1}}
show["mixer"]["transition"]["durationTicks"] = 30
show["mixer"]["ftb"]["durationTicks"] = 24
show["mixer"]["overlays"][0]["input"] = 4
show["mixer"]["overlays"][0]["animation"]["durationTicks"] = 18
show["layout"] = {"mixerPanelVisible": False, "mainWindowFrame": "{{80, 80}, {1280, 760}}"}
(OUT / "readme.switcher.json").write_text(json.dumps(show, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(OUT / "readme.switcher.json")
