#!/usr/bin/env python3
"""生成 Samples/ 下的三个节目文件（W4-C）。

    python3 Samples/tools/make-shows.py            # 写 Samples/{church,classroom,event}/*.switcher.json

为什么用脚本而不是手写 JSON：Show 的 Codable 是 Swift 合成的，InputSettings / OutputSettings 里没有默认值的键一个都不能缺
（缺了 App / headless 打开直接报"缺字段"）。脚本把这些样板集中在几个函数里，改一处就够；文件本身仍按 Swift `Show.fileEncoder`
的形态写（键排序、两格缩进），用 App "另存为"再存一遍 diff 只会有空白差异。

字段含义见 docs/CONTRACTS.md §2.4 / §2.5 / §2.8；JSON 形态与 docs/api.md 里 loadShow 的例子一致。
素材图（assets/*.png）由 Samples/tools/make-assets.swift 生成。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------- 样板 ----------

def frame_rate(fps):
    return {"numerator": 60000, "denominator": 1001} if fps == 59.94 else {"numerator": int(fps), "denominator": 1}


def input_settings(*, afv=True, gain_db=0.0, muted=False, master=True, delay_ms=0):
    """一路输入的全部设置（所有键都要在）。"""
    return {
        "audio": {
            "afv": afv,
            "delayMs": delay_ms,
            "gainDb": gain_db,
            "muted": muted,
            "pan": 0,
            "routing": {"busA": False, "busB": False, "headphones": False, "master": master},
            "solo": False,
        },
        "crop": {"bottom": 0, "left": 0, "right": 0, "top": 0},
        "effects": [],
        "keyer": {
            "enabled": False,
            "keyColor": {"blue": 0, "green": 255, "red": 0},
            "softness": 0.1,
            "spillSuppression": 0.5,
            "tolerance": 0.3,
        },
        "transform": {"flipHorizontal": False, "flipVertical": False, "offsetX": 0, "offsetY": 0, "rotationDegrees": 0, "scale": 1},
    }


def synthetic(number, name, *, fps=60, level=128, seed=None, audio=False, settings=None):
    """合成测试源：灰底 + 噪声（噪声让编码器有真实负载；纯灰底压不出设定码率）。"""
    return {
        "number": number,
        "name": name,
        "source": {
            "synthetic": {
                "settings": {
                    "audio": audio,
                    "audioDriftPpm": 0,
                    "background": {"noise": {"amplitude": 24, "level": level, "seed": seed if seed is not None else number}},
                    "clockDriftPpm": 0,
                    "dropEveryN": 0,
                    "frameRate": frame_rate(fps),
                    "height": 1080,
                    "jitterMs": 0,
                    "width": 1920,
                }
            }
        },
        "settings": settings or input_settings(),
    }


def image(number, name, path):
    """图片输入（PNG 带 alpha，路径相对节目文件所在目录）。"""
    return {"number": number, "name": name, "source": {"image": {"path": path}}, "settings": input_settings(master=False)}


def overlay(*, input_number=None, on=False, rect=None, kind="cut", ticks=0, slide_from=None, border=None, anchor="center", preview_on=False):
    o = {
        "anchor": anchor,
        "animProgress": 0,
        "animation": {"durationTicks": ticks, "kind": kind},
        "on": on,
        "previewOn": preview_on,
        "rect": rect or {"height": 1, "width": 1, "x": 0, "y": 0},
    }
    if slide_from:
        o["animation"]["slideFrom"] = slide_from
    if input_number is not None:
        o["input"] = input_number
    if border:
        o["border"] = border
    return o


def audio_state(*, afv=True):
    return {
        "afv": afv,
        "alignmentFrames": 2048,
        "buses": [{"bus": b, "effects": [], "gainDb": 0, "muted": False} for b in range(4)],
        "monitorMode": "afl",
        "monitorPoint": "preDelayLine",
    }


def mixer(*, fps, program, preview, transition_ticks, overlays, wipe_softness=0.0):
    return {
        "format": {"frameRate": frame_rate(fps), "height": 1080, "width": 1920},
        "ftb": {"durationTicks": transition_ticks, "level": 0, "on": False},
        "overlays": overlays,
        "preview": preview,
        "program": program,
        "transition": {
            "durationTicks": transition_ticks,
            "progress": 0,
            "source": "auto",
            "stinger": {"cutAtTick": 0},
            "type": "fade",
            "wipe": {"direction": "leftToRight", "softness": wipe_softness},
        },
    }


def video(codec="h264", mbps=8, keyframe=60):
    return {"bitrateBps": int(mbps * 1_000_000), "codec": codec, "keyframeIntervalFrames": keyframe}


AUDIO_AAC = {"bitrateBps": 160000, "codec": "aac"}


def record_output(number, name, directory, *, source=None, mbps=8, keyframe=60, pattern="{show}-{date}-{time}"):
    """录制输出。directory 是相对路径：App 里挂在 ~/Movies/Switcher/ 下，headless 相对当前目录。"""
    return {
        "enabled": False,
        "kind": "record",
        "name": name,
        "number": number,
        "settings": {
            "audio": dict(AUDIO_AAC),
            "extra": {},
            "record": {"container": "mov", "directory": directory, "fileNamePattern": pattern, "fragmentIntervalSeconds": 1, "remuxToMP4": False},
            "source": source or {"program": {}},
            "video": video(mbps=mbps, keyframe=keyframe),
        },
    }


def iso_output(number, input_number, directory, *, mbps=8, keyframe=60):
    """ISO 分路 = kind record、source = 该输入；文件名模板带 {output} 免得同一秒同名。"""
    return record_output(number, f"ISO {input_number}", directory, source={"input": {"number": input_number}}, mbps=mbps, keyframe=keyframe,
                         pattern="{show}-{date}-{time}-{output}")


def stream_output(number, name, url, key, *, mbps=4.5, keyframe=60):
    return {
        "enabled": False,
        "kind": "stream",
        "name": name,
        "number": number,
        "settings": {
            "audio": dict(AUDIO_AAC),
            "extra": {},
            "source": {"program": {}},
            "stream": {"reconnectMaxSeconds": 30, "streamKey": key, "url": url},
            "video": video(mbps=mbps, keyframe=keyframe),
        },
    }


def multiview_output(number, name, *, preset="pgmPvw+grid", safe_area=True, meters=True):
    return {
        "enabled": False,
        "kind": "multiview",
        "name": name,
        "number": number,
        "settings": {"extra": {}, "multiview": {"custom": [], "meters": meters, "preset": preset, "safeArea": safe_area}, "source": {"multiview": {}}},
    }


def ndi_output(number, name, *, source=None, groups=None):
    extra = {"ndi.groups": groups} if groups else {}
    return {"enabled": False, "kind": "ndi", "name": name, "number": number, "settings": {"extra": extra, "source": source or {"program": {}}}}


def show(name, *, inputs, mixer_settings, audio, outputs):
    return {"audio": audio, "inputs": inputs, "layout": {}, "mixer": mixer_settings, "name": name, "outputs": outputs, "schemaVersion": 1}


# ---------- 三个样例 ----------

def church():
    """教会：3 机位 + 调音台 + 歌词字幕 / 台标（图片）+ 直播 + 录制。1080p30（直播常用）。"""
    fps = 30
    desk = input_settings(afv=False)   # 调音台不跟随视频：不管 PGM 在哪一路，声音一直在
    inputs = [
        synthetic(1, "机位 1 · 讲台（合成源，换成你的摄像头）", fps=fps, level=96),
        synthetic(2, "机位 2 · 全景（合成源）", fps=fps, level=128),
        synthetic(3, "机位 3 · 侧面（合成源）", fps=fps, level=160),
        synthetic(4, "调音台（合成源带音频，换成你的音频接口）", fps=fps, level=64, audio=True, settings=desk),
        image(5, "歌词字幕", "assets/lyrics.png"),
        image(6, "台标", "assets/logo.png"),
    ]
    overlays = [
        overlay(input_number=5, kind="slide", ticks=8, slide_from="bottom", anchor="bottom"),     # 叠加 1：歌词，从底边滑入 8 拍（0.27 s）
        overlay(input_number=6, kind="fade", ticks=6, anchor="topRight"),                        # 叠加 2：台标，淡入 6 拍
        overlay(),
        overlay(),
    ]
    outputs = [
        record_output(1, "节目录制", "教会", mbps=8, keyframe=60),
        stream_output(2, "直播（先本地 MediaMTX 试）", "rtmp://127.0.0.1:1935/s1", "", mbps=4.5, keyframe=60),   # 本机 scripts/mediamtx.yml 的 s1 路径；换平台时填地址 + 密钥
    ]
    return show("教会直播示例", inputs=inputs, mixer_settings=mixer(fps=fps, program=2, preview=1, transition_ticks=15, overlays=overlays),
                audio=audio_state(afv=True), outputs=outputs)


def classroom():
    """教室：屏幕 + 摄像头画中画 + 课程标题 + 录制。1080p30。"""
    fps = 30
    teacher = input_settings(afv=False, gain_db=0)   # 老师话筒（跟摄像头一路进来）一直开着，切到屏幕时声音不断
    inputs = [
        synthetic(1, "屏幕 · 课件（合成源，换成屏幕 / 窗口输入）", fps=fps, level=192),
        synthetic(2, "摄像头 · 老师（合成源带音频，换成你的摄像头）", fps=fps, level=96, audio=True, settings=teacher),
        image(3, "课程标题", "assets/title.png"),
    ]
    pip = {"height": 0.28, "width": 0.28, "x": 0.70, "y": 0.68}
    overlays = [
        overlay(input_number=2, on=True, rect=pip, kind="zoom", ticks=10, anchor="bottomRight",
                border={"color": {"blue": 255, "green": 255, "red": 255}, "width": 0.006}),  # 叠加 1：老师画中画（右下，带白边），打开节目就在
        overlay(input_number=3, kind="slide", ticks=8, slide_from="bottom", anchor="bottom"),  # 叠加 2：课程标题
        overlay(),
        overlay(),
    ]
    outputs = [record_output(1, "课程录制", "教室", mbps=8, keyframe=60)]
    return show("教室录课示例", inputs=inputs, mixer_settings=mixer(fps=fps, program=1, preview=2, transition_ticks=15, overlays=overlays),
                audio=audio_state(afv=True), outputs=outputs)


def event():
    """活动：4 机位 + 调音台 + 标题字幕 + 多画面 + PGM 录制 + 4 路 ISO + NDI（关着）。1080p60。"""
    fps = 60
    desk = input_settings(afv=False)
    inputs = [
        synthetic(1, "机位 1 · 主席台（合成源）", fps=fps, level=80),
        synthetic(2, "机位 2 · 观众（合成源）", fps=fps, level=112),
        synthetic(3, "机位 3 · 游机（合成源）", fps=fps, level=144),
        synthetic(4, "机位 4 · 大屏翻拍（合成源）", fps=fps, level=176),
        synthetic(5, "调音台（合成源带音频）", fps=fps, level=64, audio=True, settings=desk),
        image(6, "标题字幕", "assets/title.png"),
    ]
    overlays = [
        overlay(input_number=6, kind="slide", ticks=15, slide_from="bottom", anchor="bottom"),
        overlay(),
        overlay(),
        overlay(),
    ]
    outputs = [
        record_output(1, "节目录制", "活动", mbps=12, keyframe=120),
        iso_output(2, 1, "活动", mbps=12, keyframe=120),
        iso_output(3, 2, "活动", mbps=12, keyframe=120),
        iso_output(4, 3, "活动", mbps=12, keyframe=120),
        iso_output(5, 4, "活动", mbps=12, keyframe=120),
        multiview_output(6, "多画面", preset="pgmPvw+grid", safe_area=True, meters=True),
        ndi_output(7, "节目 NDI"),
    ]
    return show("活动多机位示例", inputs=inputs,
                mixer_settings=mixer(fps=fps, program=1, preview=2, transition_ticks=30, overlays=overlays, wipe_softness=0.1),
                audio=audio_state(afv=True), outputs=outputs)


SHOWS = {"church": church, "classroom": classroom, "event": event}


def main(argv):
    only = set(argv[1:]) or set(SHOWS)
    for key, make in SHOWS.items():
        if key not in only:
            continue
        path = os.path.join(ROOT, key, f"{key}.switcher.json")
        data = make()
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        print(f"写入 {os.path.relpath(path, os.getcwd())}：{len(data['inputs'])} 路输入，{len(data['outputs'])} 个输出")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
