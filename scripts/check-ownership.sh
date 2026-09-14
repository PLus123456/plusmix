#!/bin/bash
# 目录归属检查（make lint 的一部分）：某分支相对 main 是否只改了 docs/OWNERSHIP.md 允许的路径。
#
# 用法：scripts/check-ownership.sh <分支> [--base <基线分支>] [--include-working-tree]
#   --base                 默认 main；检查点分支从 main 开，功能分支也从 main 开，一般不用改
#   --include-working-tree 把当前工作树里未提交、未跟踪的改动也算上（只在该分支已 checkout 时有意义）
#
# 规则来源：docs/OWNERSHIP.md 的表（第 3 列分支、第 4 列路径 token）。token 语义见该文件"表格格式"一节。
# 所有分支另外允许：reports/<分支名>.md（/ 换 -）、reports/issues/、docs/contract-changes/。
#
# 合并提交（检查点会话 G2–G5 把功能分支合进来）：被合进来的内容不算本分支的改动。分支上只要有合并提交，就沿第一父链
# 逐个提交结算：普通提交 = 相对父提交的 diff；合并提交 = 相对"自动合并结果"（git merge-tree --write-tree）的 diff，
# 也就是只剩冲突解决 / 合并时手改的部分（这正是检查点的"胶水"）。同一文件在多个提交里改动的行数相加。
set -uo pipefail
cd "$(dirname "$0")/.."

branch=""; base="main"; include_wt=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --include-working-tree) include_wt=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) branch="$1"; shift ;;
  esac
done
if [ -z "$branch" ]; then echo "用法：$0 <分支> [--base main] [--include-working-tree]" >&2; exit 2; fi

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

if [ "$branch" = "main" ]; then
  green "[check-ownership] main 只有 P0 用（唯一直接在 main 上做的会话），不做归属检查"
  exit 0
fi
if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
  red "[check-ownership] 分支不存在：$branch"; exit 2
fi

# ---- 读表 ----
row=$(grep -F "| \`$branch\` |" docs/OWNERSHIP.md | head -1)
if [ -z "$row" ]; then
  red "[check-ownership] docs/OWNERSHIP.md 里没有分支 $branch 的行。已知分支："
  grep -oE '^\| [A-Z0-9-]+ \| [^|]+ \| `[^`]+` ' docs/OWNERSHIP.md | awk -F'`' '{printf "    %s\n",$2}'
  exit 2
fi
paths_col=$(printf '%s' "$row" | awk -F'|' '{print $5}')
tokens=$(printf '%s' "$paths_col" | grep -o '`[^`]*`' | tr -d '`')

allow=(); deny=(); glue_prefix=(); glue_quota=()
while IFS= read -r t; do
  [ -z "$t" ] && continue
  case "$t" in
    '!'*) deny+=("${t#!}") ;;
    '~'*) spec=${t#\~}; glue_prefix+=("${spec%:*}"); glue_quota+=("${spec##*:}") ;;
    *)    allow+=("$t") ;;
  esac
done <<< "$tokens"
safe_branch=${branch//\//-}
allow+=("reports/${safe_branch}.md" "reports/issues/" "docs/contract-changes/")

match_glob() { # $1=path $2=glob
  local p=$1 g=$2
  case "$g" in
    */) [[ "$p" == "$g"* ]] ;;
    *)  [[ "$p" == $g ]] ;;
  esac
}

# ---- 取改动 ----
mb=$(git merge-base "$base" "$branch") || { red "[check-ownership] 找不到 $base 与 $branch 的 merge-base"; exit 2; }

# 已提交的改动，numstat 三列：增 / 删 / 路径。
# 没有合并提交：一次 diff（merge-base → 分支顶）。有合并提交：沿第一父链逐个提交结算（见文件头注释）。
collect_committed() {
  if [ -z "$(git rev-list --merges --first-parent "$mb..$branch" | head -1)" ]; then
    git diff --numstat --no-renames "$mb" "$branch"
    return
  fi
  local c p1 p2 tree
  for c in $(git rev-list --first-parent --reverse "$mb..$branch"); do
    p1=$(git rev-parse --verify --quiet "$c^1")
    p2=$(git rev-parse --verify --quiet "$c^2" || true)
    if [ -n "$p2" ]; then
      # 自动合并的树；有冲突时 merge-tree 退出 1 但仍写出带冲突标记的树，diff 出来的就是解决冲突的改动
      tree=$(git merge-tree --write-tree "$p1" "$p2" 2>/dev/null | head -1)
      [ -n "$tree" ] || tree=$p1
      git diff --numstat --no-renames "$tree" "$c"
    else
      git diff --numstat --no-renames "$p1" "$c"
    fi
  done
}
merged_note=""
if [ -n "$(git rev-list --merges --first-parent "$mb..$branch" | head -1)" ]; then
  merged_note="（含合并提交：被合入分支的内容不算本分支改动，只算合并时的手改）"
fi
changes=$(collect_committed)
if [ "$include_wt" = 1 ]; then
  # 未提交的改动：工作树相对分支顶（只在该分支已 checkout 时有意义）；未跟踪文件按行数全算新增
  changes+=$'\n'$(git diff --numstat --no-renames "$branch")
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$(wc -l < "$f" | tr -d ' ')
    changes+=$'\n'"$n	0	$f"
  done < <(git ls-files --others --exclude-standard)
fi
# 同一路径多条记录（多个提交、已提交 + 未提交）按增 / 删分别相加；二进制的 "-" 算 0
changes=$(printf '%s\n' "$changes" | sed '/^$/d' | awk -F'\t' '
  { a=$1; d=$2; if (a=="-") a=0; if (d=="-") d=0; add[$3]+=a; del[$3]+=d }
  END { for (p in add) printf "%d\t%d\t%s\n", add[p], del[p], p }' | sort -k3)
if [ -z "$changes" ]; then
  green "[check-ownership] $branch 相对 $base 没有改动$merged_note"; exit 0
fi

# ---- 逐文件判定 ----
violations=(); glue_lines=(); glue_keys=(); glue_files=()
while IFS=$'\t' read -r added deleted path; do
  [ -z "$path" ] && continue
  [ "$added" = "-" ] && added=0; [ "$deleted" = "-" ] && deleted=0
  lines=$((added + deleted))
  denied=0
  for d in "${deny[@]:-}"; do [ -n "$d" ] && match_glob "$path" "$d" && denied=1; done
  if [ "$denied" = 1 ]; then violations+=("$path（明确排除）"); continue; fi
  ok=0
  for a in "${allow[@]}"; do match_glob "$path" "$a" && { ok=1; break; }; done
  [ "$ok" = 1 ] && continue
  # 胶水额度
  matched_glue=0
  for i in "${!glue_prefix[@]}"; do
    gp=${glue_prefix[$i]}
    if [[ "$gp" == *'*' ]]; then
      pre=${gp%\*}
      if [[ "$path" == "$pre"* ]]; then
        rest=${path#"$pre"}; key="$pre${rest%%/*}"; matched_glue=1
      fi
    else
      if [[ "$path" == "$gp"* ]]; then key="$gp"; matched_glue=1; fi
    fi
    if [ "$matched_glue" = 1 ]; then
      found=0
      for j in "${!glue_keys[@]}"; do
        if [ "${glue_keys[$j]}" = "$key" ]; then glue_lines[$j]=$((glue_lines[$j] + lines)); glue_files[$j]+=" $path(+$added/-$deleted)"; found=1; fi
      done
      if [ "$found" = 0 ]; then glue_keys+=("$key"); glue_lines+=("$lines"); glue_files+=(" $path(+$added/-$deleted)"); fi
      break
    fi
  done
  [ "$matched_glue" = 1 ] && continue
  violations+=("$path")
done <<< "$changes"

# 胶水额度结算
for j in "${!glue_keys[@]}"; do
  key=${glue_keys[$j]}
  quota=0
  for i in "${!glue_prefix[@]}"; do
    gp=${glue_prefix[$i]}
    [[ "$key" == "${gp%\*}"* ]] && quota=${glue_quota[$i]}
  done
  if [ "${glue_lines[$j]}" -gt "$quota" ]; then
    violations+=("$key 的胶水改动 ${glue_lines[$j]} 行 > 额度 $quota 行：${glue_files[$j]}（写 reports/issues/ 退回原会话）")
  else
    yellow "[check-ownership] 胶水：$key ${glue_lines[$j]}/$quota 行 —${glue_files[$j]}"
  fi
done

total=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
if [ "${#violations[@]}" -gt 0 ]; then
  red "[check-ownership] $branch 越界（相对 $base，共 $total 个改动文件）。允许：${allow[*]}"
  for v in "${violations[@]}"; do printf '    %s\n' "$v"; done
  exit 1
fi
green "[check-ownership] $branch 的 $total 个改动文件都在允许范围内$merged_note"
