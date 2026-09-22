#!/bin/bash
# 只用已有产物重出 reports/G4-run-<label>.md 并拼 reports/G4.md（改了 G4-notes.md 或跑完 gate4-ndi / gate4-matrix 之后用；不跑、不解码）。
# 用法：scripts/gate4-report.sh [--label 10min] [--out-dir .build/gate4/<label>] [--baseline baselines/g3-m5max.json]
#   <out-dir>/note.txt 若存在，作为该次运行的说明附在报告里（gate4.sh 跑完可以手写一份）。
set -uo pipefail
cd "$(dirname "$0")/.."
label=10min; out_dir=""; baseline=baselines/g3-m5max.json
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
[ -n "$out_dir" ] || out_dir=".build/gate4/$label"
blank=$(python3 - scenarios/g4.json <<'PY'
import json, sys
sc = json.load(open(sys.argv[1])); windows = []; pending = None
for e in sc["events"]:
    if e["tick"] < 7200: continue
    c = e["command"]
    if "fade" in c: windows.append((e["tick"] + 1, e["tick"] + c["fade"]["durationTicks"]))
    elif "setTransition" in c: pending = c["setTransition"]["durationTicks"]
    elif "autoTransition" in c and pending is not None: windows.append((e["tick"] + 1, e["tick"] + pending)); pending = None
print(",".join(f"{a}-{b}" for a, b in windows))
PY
)
note_args=()
[ -s "$out_dir/note.txt" ] && note_args=(--extra-note "$(cat "$out_dir/note.txt")")
python3 scripts/gate3-report.py --checkpoint G4 --out-dir "$out_dir" --label "$label" --minutes 10 --show scenarios/g4-show.json --script scenarios/g4.json \
  --baseline "$baseline" --blank-ticks "$blank" --run-report "reports/G4-run-$label.md" --notes reports/G4-notes.md --report reports/G4.md ${note_args[@]+"${note_args[@]}"}
