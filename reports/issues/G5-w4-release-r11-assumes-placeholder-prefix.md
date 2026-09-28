# G5 → W4-B：`test-r11-set-bundle-id.sh` 第 10 行写死"当前 App 前缀是 com.example"，bundle id 切成 com.plusmix 之后 R11 必红

归属会话 / 分支：W4-B / `w4-release`（`scripts/release/tests/test-r11-set-bundle-id.sh`；scripts/ 不在 G5 归属里，检查点不改）
发现于：G5（release/0.1，2026-09-28）用户定 bundle id 前缀 com.plusmix 后跑 `scripts/release/set-bundle-id.sh com.plusmix`，再 `make release-test`
现象：R11 22 项断言 21 过、1 红——`assert_contains "$cur" "com.example" "--check 报出当前 App 前缀 com.example"`。
`--check` 现在报的是 `App / 扩展 bundle id 前缀：com.plusmix（…）`，两边一致；其余断言（在副本上切到 io.example-domain、旧前缀一处不剩、目录改名、UUID、仓库本体校验和不变）全过，脚本本身没问题。
`make release-test` 因此 PASS 9 / FAIL 1，退出 2。
复现步骤：`make release-test`（或 `scripts/release/tests/run.sh test-r11-set-bundle-id`）
严重级：S3（只影响发布脚本自检的一条断言；产品与脚本行为都对）
建议修法（一行）：第 10 行别写死占位前缀，从 project.yml 读当前 `bundleIdPrefix`（`sed -n 's/^ *bundleIdPrefix: *\([^ ]*\).*/\1/p' project.yml`）再 `assert_contains "$cur" "$prefix"`；第 11 行 Stream Deck 那条同理读 manifest 的 UUID 前缀。这样切换前后都绿。
