#!/usr/bin/env python3
"""Record real UI transitions using an isolated App instance and its local API.

Requires a built Debug PlusMix.app and Screen Recording access for the invoking terminal.
The test-host environment uses separate preferences, null audio and a random loopback port.
Only the child process started here is controlled/captured/stopped. No stream or recording
output in the mixer is enabled; ScreenCaptureKit saves this window to .build/ only.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / ".build/readme-media"
APP = ROOT / ".build/DerivedData/Build/Products/Debug/PlusMix.app/Contents/MacOS/PlusMix"
RECORDER = OUT / "record-window"
OUT.mkdir(parents=True, exist_ok=True)
subprocess.run(["swiftc", "-module-cache-path", str(OUT / "ModuleCache"),
                str(ROOT / "docs/media/tools/record-window.swift"), "-o", str(RECORDER)], check=True)
log = []
port = None


def api(path, command=None):
    body = None if command is None else json.dumps({"command": command}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/api/v1/{path}", data=body,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def send(command):
    receipt = api("command", command)
    log.append({"command": command, "receipt": receipt})
    return receipt


def check_state(program, preview, overlays=()):
    snapshot = api("state")
    state = snapshot["state"]
    assert (state["program"], state["preview"]) == (program, preview), state
    assert state["transition"]["progress"] == 0, state["transition"]
    for index in range(4):
        assert state["overlays"][index]["on"] == (index + 1 in overlays)
        assert state["overlays"][index]["animProgress"] == (1 if index + 1 in overlays else 0), state["overlays"]
    log.append({"verified": {"program": program, "preview": preview, "overlays": list(overlays)},
                "overlayState": state["overlays"], "stats": snapshot["stats"]})


def reset():
    for channel in (1, 2):
        send({"overlay": {"channel": channel, "on": False}})
    send({"setProgram": {"input": 1}})
    send({"setPreview": {"input": 2}})
    send({"setTransition": {"type": "fade", "durationTicks": 30}})
    time.sleep(0.8)
    check_state(1, 2)


def record(name, events, seconds=12):
    movie = OUT / f"{name}.mov"
    ready = movie.with_suffix(".mov.ready")
    movie.unlink(missing_ok=True)
    ready.unlink(missing_ok=True)
    recording = subprocess.Popen([str(RECORDER), str(app.pid), str(movie), str(seconds)])
    try:
        deadline = time.monotonic() + 15
        while not ready.exists():
            if recording.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("Window recorder did not start")
            time.sleep(0.02)
        start = time.monotonic()
        for at, commands, expected in events:
            time.sleep(max(0, start + at - time.monotonic()))
            for command in commands:
                receipt = send(command)
                assert receipt["applied"], (command, receipt)
            if expected is not None:
                time.sleep(1.15)  # Wait for the longest 1 s transition to finish.
                check_state(*expected)
        assert recording.wait(timeout=seconds + 10) == 0
    finally:
        if recording.poll() is None:
            recording.terminate()
            recording.wait(timeout=5)


with (OUT / "capture-app.log").open("w") as app_log:
    app = subprocess.Popen([str(APP), "--show", str(OUT / "demo/readme.switcher.json"),
                            "--audio-device", "null", "--api-listen", "127.0.0.1:0", "--api-token", "",
                            "--stats", str(OUT / "capture-stats.jsonl")],
                           env={**os.environ, "XCTestConfigurationFilePath": "readme-demo"},
                           stdout=app_log, stderr=app_log)
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if app.poll() is not None:
                raise RuntimeError("PlusMix exited before the API started; see capture-app.log")
            sockets = subprocess.run(["lsof", "-a", "-p", str(app.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                                     capture_output=True, text=True).stdout
            ports = re.findall(r"^n(?:localhost|127\.0\.0\.1):(\d+)$", sockets, re.M)
            if ports:
                port = int(ports[0])
                try:
                    snapshot = api("state")
                    if snapshot.get("stats") and all(snapshot["stats"]["per_input"][str(i)]["fps"] > 0 for i in range(1, 5)):
                        break
                except (OSError, KeyError):
                    pass
            time.sleep(0.1)
        else:
            raise RuntimeError("PlusMix demo inputs did not become ready")
        reset()
        subprocess.run([str(RECORDER), str(app.pid), str(OUT / "poster.png")], check=True)
        record("switching", [
            (0.9, [{"setPreview": {"input": 3}}], (1, 3)),
            (2.9, [{"cut": {}}], (3, 1)),
            (4.3, [{"setPreview": {"input": 2}}], None),
            (5.3, [{"fade": {"durationTicks": 30}}], (2, 3)),
            (7.5, [{"setPreview": {"input": 1}}], None),
            (8.9, [{"setTransition": {"type": "wipe", "durationTicks": 30}}, {"autoTransition": {}}], (1, 2)),
        ])
        reset()
        send({"setOverlay": {"channel": 2, "rect": {"x": 0.63, "y": 0.06, "width": 0.32, "height": 0.32},
                             "animation": {"kind": "fade", "durationTicks": 18}}})
        record("overlays", [
            (0.9, [{"overlay": {"channel": 1, "on": True, "input": 4}}], (1, 2, (1,))),
            (3.5, [{"overlay": {"channel": 2, "on": True, "input": 3}}], (1, 2, (1, 2))),
            (6.5, [{"overlay": {"channel": 1, "on": False}}], (1, 2, (2,))),
            (9.1, [{"overlay": {"channel": 2, "on": False}}], (1, 2)),
        ])
        print("Verified: PVW selection, Cut, Fade, Wipe, independent overlays 1 / 2", flush=True)
    finally:
        (OUT / "capture-log.json").write_text(json.dumps(log, ensure_ascii=False, indent=2) + "\n")
        if app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
