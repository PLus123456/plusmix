#!/bin/bash
# 包依赖方向检查（make lint 的一部分）。设计方案 §11 / 落地方案 §2 规定的唯一合法方向：
#
#     SwitcherContracts ← SwitcherCore ← {Inputs, Audio, Outputs, Control} ← TestKit ← Tools / App
#
# 用 `swift package dump-package` 读每个 Package.swift 的真实依赖（不用正则猜），按层级编号检查：
#   层 1 SwitcherCore（包内：SwitcherContracts 层 0；SwitcherEngine、SwitcherRender 层 1，互不依赖，只见 Contracts）
#   层 2 SwitcherInputs / SwitcherAudio / SwitcherOutputs / SwitcherControl（同层之间不许互相依赖）
#   层 3 SwitcherTestKit
#   层 4 Tools/*（App 由 project.yml 描述，处于同一层，它只能依赖不能被依赖）
# 规则：一个包 / target 只能依赖层号比自己小的 Switcher 包；第三方包不管。
# 包内传递依赖也算（Contracts → 某 C 辅助 target → Engine 同样会被拦）。
# 测试 target 按它测的模块算层级（SwitcherEngineTests 视同 SwitcherEngine）。
set -uo pipefail
cd "$(dirname "$0")/.."

manifests=(Packages/*/Package.swift Tools/*/Package.swift)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 8 个包的 dump 并行跑（串行要 12 秒）
pids=()
for m in "${manifests[@]}"; do
  dir=$(dirname "$m")
  name=$(basename "$dir")
  ( swift package --package-path "$dir" dump-package > "$tmp/$name.json" 2> "$tmp/$name.err" ) &
  pids+=($!)
done
fail=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    m=${manifests[$i]}; name=$(basename "$(dirname "$m")")
    printf '\033[31m[check-deps] %s：dump-package 失败\033[0m\n' "$m"
    sed 's/^/    /' "$tmp/$name.err"
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1

python3 - "$tmp" <<'PY'
import json, os, sys, glob

tmp = sys.argv[1]
PACKAGE_RANK = {
    "SwitcherCore": 1,
    "SwitcherInputs": 2, "SwitcherAudio": 2, "SwitcherOutputs": 2, "SwitcherControl": 2,
    "SwitcherTestKit": 3,
}
CORE_TARGET_RANK = {"SwitcherContracts": 0, "SwitcherEngine": 1, "SwitcherRender": 1}
TOOL_RANK = 4

pkgs = {}  # name -> dump json
for f in sorted(glob.glob(os.path.join(tmp, "*.json"))):
    with open(f) as fh:
        d = json.load(fh)
    pkgs[os.path.basename(f)[:-5]] = d

def rank_of_package(name):
    return PACKAGE_RANK.get(name, TOOL_RANK)

# 产品名 -> 所属包（用于 byName 解析）
product_owner = {}
for pname, d in pkgs.items():
    for p in d.get("products", []):
        product_owner[p["name"]] = pname
# 包身份（小写）-> 包名
identity_to_pkg = {p.lower(): p for p in pkgs}

def base_target(name):
    # SwitcherEngineTests -> SwitcherEngine
    return name[:-5] if name.endswith("Tests") else name

violations = []

for pname, d in pkgs.items():
    prank = rank_of_package(pname)
    targets = {t["name"]: t for t in d.get("targets", [])}

    # (a) 包级 dependencies：路径依赖
    for dep in d.get("dependencies", []):
        for kind, entries in dep.items():
            for e in entries:
                path = e.get("path") or ""
                ident = (e.get("identity") or os.path.basename(path)).lower()
                target_pkg = identity_to_pkg.get(ident)
                if target_pkg is None:
                    continue  # 第三方
                if rank_of_package(target_pkg) >= prank:
                    violations.append(f"{pname}/Package.swift 声明依赖包 {target_pkg}（层 {rank_of_package(target_pkg)} ≥ 自身层 {prank}）")

    # (b) target 级依赖：解析成 (同包 target) 或 (其他包的产品)
    intra = {}          # target -> set(同包 target)
    for tname, t in targets.items():
        intra[tname] = set()
        for dep in t.get("dependencies", []):
            for kind, val in dep.items():
                depname = val[0]
                if kind == "target" or (kind == "byName" and depname in targets):
                    intra[tname].add(depname)
                    continue
                if kind == "product":
                    ident = (val[1] or "").lower()
                    owner = identity_to_pkg.get(ident) or product_owner.get(depname)
                elif kind == "byName":
                    owner = product_owner.get(depname)
                else:
                    owner = None
                if owner is None or owner == pname:
                    continue  # 第三方
                if rank_of_package(owner) >= prank:
                    violations.append(f"{pname} 的 target {tname} 依赖 {owner} 的产品 {depname}（层 {rank_of_package(owner)} ≥ 自身层 {prank}）")

    # (c) 包内传递闭包（目前只有 SwitcherCore 有分层要求）
    if pname == "SwitcherCore":
        def closure(start):
            seen, stack = set(), list(intra.get(start, ()))
            while stack:
                x = stack.pop()
                if x in seen:
                    continue
                seen.add(x)
                stack.extend(intra.get(x, ()))
            return seen
        for tname in targets:
            base = base_target(tname)
            if base not in CORE_TARGET_RANK:
                continue
            for dep in closure(tname):
                if dep == base:
                    continue  # 测试 target 依赖自己测的模块
                dep_base = base_target(dep)
                if dep_base in CORE_TARGET_RANK and CORE_TARGET_RANK[dep_base] >= CORE_TARGET_RANK[base]:
                    violations.append(f"SwitcherCore 内 {tname} 依赖 {dep}（传递）：{dep_base} 层 {CORE_TARGET_RANK[dep_base]} ≥ {base} 层 {CORE_TARGET_RANK[base]}；Engine / Render 只许依赖 Contracts")

if violations:
    print("\033[31m[check-deps] 发现反向依赖：\033[0m")
    for v in sorted(set(violations)):
        print("    " + v)
    sys.exit(1)
print(f"\033[32m[check-deps] 依赖方向正确（检查了 {len(pkgs)} 个包：{', '.join(sorted(pkgs))}）\033[0m")
PY
