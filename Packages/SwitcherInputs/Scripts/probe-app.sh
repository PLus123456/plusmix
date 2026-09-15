#!/bin/bash
# 把 switcher-input-probe 包成 .app 跑（TCC 用）。
#
# 为什么：摄像头 / 屏幕录制权限按"责任进程"归属。从 Claude 的 Bash、脚本、`swift run` 直接起的命令行工具，责任进程是启动它的程序
# （Claude 桌面端的 claude-code 辅助程序），它的 Info.plist 没有 NSCameraUsageDescription，系统连提示都不弹就拒了
# （AVCaptureDevice.requestAccess 立刻回 false、状态仍是 notDetermined）。用 `open` 起一个 .app，它自己就是责任进程，
# Info.plist 里带用途说明，系统会正常弹"允许访问摄像头"；子进程继承责任归属，所以 .app 只是一个稳定的启动器（build 一次，
# 之后不重编——ad-hoc 签名的 cdhash 变了 TCC 就当成新程序，屏幕录制那种在系统设置里手动打的开关会失效），真正的探针可以随便重编。
#
# 用法：Scripts/probe-app.sh <探针参数...>
#   Scripts/probe-app.sh devices
#   Scripts/probe-app.sh run --input camera:0 --input file:Tests/Fixtures/pattern.mov --seconds 10
#   Scripts/probe-app.sh hotplug --camera <uniqueID> --cycles 20
#   Scripts/probe-app.sh permission --camera 0 --seconds 60
# 环境变量：PROBE_CONFIG=debug|release（默认 release）；PROBE_LOG=日志路径（默认 .build/probe-app/last.log）
set -euo pipefail
cd "$(dirname "$0")/.."
PKG=$(pwd)
CONFIG=${PROBE_CONFIG:-release}
APP_DIR="$PKG/.build/probe-app"
APP="$APP_DIR/SwitcherInputProbe.app"
LOG=${PROBE_LOG:-$APP_DIR/last.log}
mkdir -p "$APP_DIR"

echo "== swift build -c $CONFIG（switcher-input-probe）" >&2
swift build -c "$CONFIG" --product switcher-input-probe >&2
PROBE="$(swift build -c "$CONFIG" --show-bin-path)/switcher-input-probe"

# 启动器：只在没有时编一次（稳定的 cdhash 让 TCC 记住授权）
LAUNCHER_SRC="$APP_DIR/launcher.swift"
if [ ! -x "$APP/Contents/MacOS/SwitcherInputProbe" ]; then
  echo "== 首次：建 $APP" >&2
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.switcher.input-probe</string>
  <key>CFBundleName</key><string>SwitcherInputProbe</string>
  <key>CFBundleExecutable</key><string>SwitcherInputProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Switcher 输入探针需要摄像头来测量采集延迟与热插拔。</string>
  <key>NSMicrophoneUsageDescription</key><string>Switcher 输入探针需要麦克风来测试设备自带的音频。</string>
  <key>NSAudioCaptureUsageDescription</key><string>Switcher 输入探针需要系统音频来测试屏幕采集的音频。</string>
</dict>
</plist>
PLIST
  cat > "$LAUNCHER_SRC" <<'SWIFT'
// SwitcherInputProbe.app 的启动器：把参数原样交给探针二进制，stdout / stderr 落到日志文件，退出码原样返回。
// `open -W -n SwitcherInputProbe.app --args --probe <探针路径> --log <日志> -- <探针参数...>`
import Foundation
var args = Array(CommandLine.arguments.dropFirst())
var probe = ""; var log = "/tmp/switcher-input-probe.log"; var rest: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--probe" { probe = args.removeFirst() }
    else if a == "--log" { log = args.removeFirst() }
    else if a == "--" { rest = args; break }
}
FileManager.default.createFile(atPath: log, contents: nil)
let handle = FileHandle(forWritingAtPath: log)!
let p = Process()
p.executableURL = URL(fileURLWithPath: probe)
p.arguments = rest
p.standardOutput = handle
p.standardError = handle
do { try p.run() } catch { handle.write(Data("启动器：起不来 \(probe)：\(error)\n".utf8)); exit(3) }
p.waitUntilExit()
handle.write(Data("__PROBE_EXIT__ \(p.terminationStatus)\n".utf8))
exit(p.terminationStatus)
SWIFT
  swiftc -O -o "$APP/Contents/MacOS/SwitcherInputProbe" "$LAUNCHER_SRC" >&2
  codesign --force --sign - "$APP" >&2
fi

: > "$LOG"
echo "== open $APP（日志 $LOG）" >&2
echo "   若系统弹出摄像头 / 麦克风授权提示，请点允许；屏幕录制要在 系统设置 › 隐私与安全性 › 屏幕录制与系统录音 里打开 SwitcherInputProbe。" >&2
open -W -n -a "$APP" --args --probe "$PROBE" --log "$LOG" -- "$@" &
OPEN_PID=$!
tail -n +1 -f "$LOG" &
TAIL_PID=$!
wait "$OPEN_PID" || true
sleep 0.3
kill "$TAIL_PID" 2>/dev/null || true
code=$(sed -n 's/^__PROBE_EXIT__ //p' "$LOG" | tail -1)
exit "${code:-1}"
