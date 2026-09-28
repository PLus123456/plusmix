#!/bin/bash
# 装 GitHub Actions self-hosted runner（prompt 71 交付 4；docs/release/ci.md）。这台 Mac 或以后的 mini 都用它。
# 用法：ci-runner-setup.sh --url https://github.com/<owner>/<repo> --token <注册 token> [--dir ~/actions-runner] [--name <名字>] [--labels switcher,macOS,ARM64]
#       ci-runner-setup.sh --uninstall [--dir ~/actions-runner]
# 注册 token 在仓库 Settings → Actions → Runners → New self-hosted runner（一小时有效）。
# 装完是一个 LaunchAgent（svc.sh），跑在当前用户的登录会话里——App 的 xcodebuild test 与虚拟摄像头 / 显示类用例需要窗口服务器，不能装成 LaunchDaemon。
# 机器上另外要：Xcode + xcodegen + ffmpeg + mediamtx（brew）、NDI SDK（/Library/NDI SDK for Apple）、自动登录 + 不休眠（工作流里包了 caffeinate，但屏幕保护 / 锁屏会挡 TCC 弹窗），
# 摄像头 / 屏幕录制 TCC 给 Terminal 或 runner 进程一次；perf-baseline 的 powermetrics 要免密码 sudo（脚本末尾打印 sudoers 一行）。
set -uo pipefail
url=""; token=""; dir="$HOME/actions-runner"; name="$(scutil --get ComputerName 2>/dev/null || hostname)"; labels="switcher,macOS,ARM64"; uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url=$2; shift 2 ;;
    --token) token=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --labels) labels=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
if [ "$uninstall" = 1 ]; then
  [ -d "$dir" ] || { echo "没有 $dir"; exit 0; }
  cd "$dir" && { ./svc.sh stop 2>/dev/null; ./svc.sh uninstall 2>/dev/null; [ -n "$token" ] && ./config.sh remove --token "$token"; }
  echo "已停用 runner（目录 $dir 保留；要彻底删就 rm -rf 它）"; exit 0
fi
[ -n "$url" ] && [ -n "$token" ] || { echo "用法：ci-runner-setup.sh --url https://github.com/<owner>/<repo> --token <token>（GitHub 仓库 Settings → Actions → Runners → New self-hosted runner）" >&2; exit 2; }
[ "$(uname -m)" = arm64 ] || { echo "只支持 Apple Silicon（osx-arm64 的 runner）" >&2; exit 1; }
mkdir -p "$dir" && cd "$dir"
if [ ! -x ./config.sh ]; then
  ver=$(curl -sS -m 20 https://api.github.com/repos/actions/runner/releases/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))") || { echo "取不到 runner 最新版本号" >&2; exit 1; }
  tar="actions-runner-osx-arm64-$ver.tar.gz"
  echo "下载 runner $ver …"
  curl -sS -L -o "$tar" "https://github.com/actions/runner/releases/download/v$ver/$tar" || exit 1
  tar xzf "$tar" && rm -f "$tar"
fi
./config.sh --unattended --url "$url" --token "$token" --name "$name" --labels "$labels" --work _work --replace || exit 1
./svc.sh install && ./svc.sh start
echo
echo "runner 已装成 LaunchAgent（$(ls "$HOME"/Library/LaunchAgents/actions.runner.* 2>/dev/null | head -1)），标签：$labels"
echo "接下来（人工，docs/release/ci.md）："
echo "  1. 系统设置 → 用户与群组 → 自动登录 = 本用户；节能 → 防止自动进入睡眠；锁定屏幕 → 屏幕保护 / 关闭显示器 = 永不（否则 TCC 弹窗看不到）"
echo "  2. 第一次跑 CI 时给 runner 进程摄像头 / 麦克风 / 屏幕录制授权（系统设置 → 隐私与安全性）"
echo "  3. perf-baseline 的 powermetrics 要免密码 sudo：sudo visudo -f /etc/sudoers.d/switcher-ci，写一行："
echo "       $(whoami) ALL=(root) NOPASSWD: /usr/bin/powermetrics"
echo "  4. 装 NDI SDK（/Library/NDI SDK for Apple）、brew install xcodegen ffmpeg mediamtx；Xcode 打开一次接受许可（sudo xcodebuild -license accept）"
