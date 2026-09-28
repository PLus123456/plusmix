# check-ownership.sh 不认 reports/w1-core-3-run.md（prompt 81 让 gate4 运行报告改成这个名字）

归属会话 / 分支：G5 检查点（docs/OWNERSHIP.md 与 scripts/check-ownership.sh 都不在 w1-core-3 的目录里），S3
发现于：W1-B3 / w1-core-3，2026-09-28

## 现象

prompt 81 第 3 条："`scripts/gate4.sh --minutes 10 --label w1b3` 跑一次……运行报告改名 reports/w1-core-3-run.md"；会话指派信里 OWNERSHIP 行的描述也写着
"外加 reports/w1-core-3.md 与 reports/w1-core-3-run.md"。但 docs/OWNERSHIP.md 的 `w1-core-3` 行只列了四个目录，`scripts/check-ownership.sh` 的通用规则只放行
`reports/<分支名>.md`，于是 `make lint BRANCH=w1-core-3` 的 check-ownership 对 `reports/w1-core-3-run.md` 报越界（其余 lint 项全绿）。

## 建议

G5 合并时在 docs/OWNERSHIP.md 的 `w1-core-3` 行加上 `reports/w1-core-3-run.md`（或把通用规则改成放行 `reports/<分支名>-run.md`），一行改动。
W1-B3 按 prompt 保留了这个文件名，没有绕过检查。
