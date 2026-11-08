#!/usr/bin/env python3
"""Export the single SVG source to the README PNG and every macOS AppIcon size."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
MEDIA = ROOT / "docs/media"
CATALOG = ROOT / "App/Resources/Assets.xcassets"
ICONS = CATALOG / "AppIcon.appiconset"
ICONS.mkdir(parents=True, exist_ok=True)
CACHE = ROOT / ".build/readme-media/ModuleCache"


def render(path, pixels):
    subprocess.run(["swift", "-module-cache-path", str(CACHE),
                    str(MEDIA / "tools/render-svg.swift"), str(MEDIA / "plusmix-icon.svg"),
                    str(path), str(pixels)], check=True)


render(MEDIA / "plusmix-icon.png", 512)
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        render(ICONS / name, size * scale)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
info = {"author": "xcode", "version": 1}
(CATALOG / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
(ICONS / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
