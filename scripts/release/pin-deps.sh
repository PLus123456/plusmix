#!/bin/bash
# 依赖钉版本（prompt 71 第 6 条；issues W3C2-g5-swift-collections-1.7-dyld-crash、W3E2-w1-testkit-frameprobe-unpinned-deps-swift-runtime）。
#
# 背景：swift-collections 1.7.0 用了 Swift 6.4 运行时的 _swift_initBorrow，macOS 26.6.2 及更早的 libswiftCore 没有、也不向后部署，
# 解到它的 App / frameprobe 一起就 dyld 崩；本产品最低系统是 macOS 15，所以入库的解析结果全部钉在 1.6.0 那一套。
# 入库的文件：Packages/{SwitcherControl,SwitcherOutputs,SwitcherTestKit}/Package.resolved、Tools/{switcher-headless,frameprobe}/Package.resolved、
# scripts/xcode-workspace-Package.resolved（make gen 拷进 Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved）。
#
# 用法：
#   pin-deps.sh check [--root DIR]        所有入库文件 + 工作区文件（若存在）对同一依赖钉同一版本 / 提交；受限依赖不超上限（下面 MAX_ALLOWED）。退出 1 = 不一致
#   pin-deps.sh list  [--root DIR]        列出每个依赖的版本与出现在哪些文件
#   pin-deps.sh sync  [--root DIR]        把模板拷进工作区（同 make gen 的那一步）
#   pin-deps.sh upgrade <identity> <version> <revision> [--root DIR]
#                                         把所有文件里这个依赖改成给定版本 / 提交（升依赖的正式路径；改完 make clean && make build && make test，
#                                         再在 macOS 15 / 26 各起一次 App 与 frameprobe，docs/release/dependencies.md）
#   pin-deps.sh verify-runtime <mach-o>...  二进制不引用只有更新的 Swift 运行时才有的符号（DENYLIST）。退出 1 = 引用了
# 发布构建（scripts/release/archive.sh）先跑 check，再用 xcodebuild -onlyUsePackageVersionsFromResolvedFile。
set -uo pipefail

# 受限依赖：identity → 允许的最高版本（含）。超过它 = 需要比最低系统更新的 Swift 运行时。
MAX_ALLOWED="swift-collections=1.6.99"
# 只有 Swift 6.4 及以后的运行时才导出的符号（macOS 27 起）；二进制引用它们就起不来 macOS 26.6.2 / 15。
DENYLIST="_swift_initBorrow"

cd "$(dirname "$0")/../.."
root=$PWD
cmd=${1:-}; [ $# -gt 0 ] && shift
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

template="scripts/xcode-workspace-Package.resolved"
workspace="Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
tracked=(Packages/SwitcherControl/Package.resolved Packages/SwitcherOutputs/Package.resolved Packages/SwitcherTestKit/Package.resolved
         Tools/switcher-headless/Package.resolved Tools/frameprobe/Package.resolved)

resolved_files() { # 在 root 下存在的那些
  local f
  for f in "$template" "${tracked[@]}" "$workspace"; do [ -f "$root/$f" ] && printf '%s\n' "$f"; done
}

case "$cmd" in
  check|list)
    files=$(resolved_files)
    [ -n "$files" ] || { red "[pin-deps] $root 下没有任何 Package.resolved"; exit 2; }
    PIN_FILES="$files" python3 - "$root" "$cmd" "$template" "$workspace" "$MAX_ALLOWED" <<'PY'
import json, sys, os
root, cmd, template, workspace, max_allowed = sys.argv[1:6]
files = [l.strip() for l in os.environ["PIN_FILES"].splitlines() if l.strip()]
limits = {}
for item in max_allowed.split():
    k, v = item.split("=", 1); limits[k] = tuple(int(x) for x in v.split("."))
pins = {}   # identity -> {(version, revision): [files]}
per_file = {}
for f in files:
    d = json.load(open(os.path.join(root, f)))
    per_file[f] = {}
    for p in d["pins"]:
        st = p["state"]; key = (st.get("version") or st.get("branch") or "?", st.get("revision", "?"))
        pins.setdefault(p["identity"], {}).setdefault(key, []).append(f)
        per_file[f][p["identity"]] = key
bad = []
if cmd == "list":
    for ident in sorted(pins):
        for (ver, rev), fs in sorted(pins[ident].items()):
            print(f"{ident:34s} {ver:12s} {rev[:10]}  {len(fs)} 个文件" + ("" if len(pins[ident]) == 1 else "  ← 不一致"))
for ident, variants in sorted(pins.items()):
    if len(variants) > 1:
        desc = "；".join(f"{v}@{r[:10]} 在 {', '.join(fs)}" for (v, r), fs in sorted(variants.items()))
        bad.append(f"{ident} 钉了不同版本：{desc}")
    for (ver, rev) in variants:
        if ident in limits and ver != "?":
            try: vt = tuple(int(x) for x in ver.split(".")[:3])
            except ValueError: vt = None
            if vt and vt > limits[ident]:
                bad.append(f"{ident} {ver} 超过允许的上限 {'.'.join(map(str, limits[ident]))}（需要比最低系统更新的 Swift 运行时，见文件头注释）")
# 工作区文件（若存在）必须与模板同一套 pin
if workspace in per_file and template in per_file:
    if per_file[workspace] != per_file[template]:
        diff = sorted(set(per_file[workspace].items()) ^ set(per_file[template].items()))
        bad.append(f"工作区 {workspace} 与模板 {template} 不一致（xcodebuild 改了它？跑 pin-deps.sh sync）：{diff[:6]}")
if bad:
    for b in bad: print("\033[31m[pin-deps] " + b + "\033[0m")
    sys.exit(1)
if cmd == "check":
    print(f"\033[32m[pin-deps] {len(files)} 份 Package.resolved 对 {len(pins)} 个依赖钉法一致；受限依赖在上限内（{max_allowed}）\033[0m")
PY
    ;;
  sync)
    [ -f "$root/$template" ] || { red "[pin-deps] 没有模板 $template"; exit 2; }
    mkdir -p "$root/$(dirname "$workspace")"
    cp "$root/$template" "$root/$workspace"
    green "[pin-deps] 已把 $template 拷到 $workspace"
    ;;
  upgrade)
    [ ${#args[@]} -ge 3 ] || { red "用法：pin-deps.sh upgrade <identity> <version> <revision> [--root DIR]"; exit 2; }
    ident=${args[0]}; ver=${args[1]}; rev=${args[2]}
    printf '%s' "$rev" | grep -qE '^[0-9a-f]{40}$' || { red "[pin-deps] revision 要是 40 位十六进制提交号：$rev"; exit 2; }
    changed=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if python3 - "$root/$f" "$ident" "$ver" "$rev" <<'PY'
import json, sys
p, ident, ver, rev = sys.argv[1:5]
d = json.load(open(p)); hit = False
for pin in d["pins"]:
    if pin["identity"] == ident:
        pin["state"]["version"] = ver; pin["state"]["revision"] = rev; hit = True
if hit:
    with open(p, "w") as fh: json.dump(d, fh, indent=2); fh.write("\n")
sys.exit(0 if hit else 3)
PY
      then echo "  改了 $f"; changed=$((changed + 1)); fi
    done <<< "$(resolved_files)"
    [ "$changed" -gt 0 ] || { red "[pin-deps] 没有任何文件钉了 $ident"; exit 1; }
    green "[pin-deps] $ident → $ver@${rev:0:10}，改了 $changed 个文件。接下来：make clean && make gen build test；macOS 15 / 26 各起一次 App 与 frameprobe（docs/release/dependencies.md）"
    ;;
  verify-runtime)
    [ ${#args[@]} -ge 1 ] || { red "用法：pin-deps.sh verify-runtime <mach-o>..."; exit 2; }
    status=0
    for bin in "${args[@]}"; do
      [ -f "$bin" ] || { red "[pin-deps] 不是文件：$bin"; status=1; continue; }
      undefined=$(nm -arch arm64 -u "$bin" 2>/dev/null || nm -u "$bin" 2>/dev/null)
      hits=""
      for sym in $DENYLIST; do printf '%s\n' "$undefined" | grep -qx "$sym" && hits="$hits $sym"; done
      if [ -n "$hits" ]; then red "[pin-deps] $bin 引用了只有更新的 Swift 运行时才有的符号：$hits（依赖没钉住？pin-deps.sh check）"; status=1
      else green "[pin-deps] $bin：不引用 $DENYLIST"; fi
    done
    exit $status
    ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
