# Codex 2026-10-24 网络安全审计的探针与证据（原样归档；G11 2026-10-24 从 `~/.codex/state/plugins/codex-security/scans/plusmix/1f9be64…_20261024T013655Z_99f15va5/artifacts/` 抄来）

来源：reports/codex-network-security-audit-20261024.md（12 条，NS01–NS12 = 报告 Findings 表的 [1]–[12]；修哪张 prompt 见 docs/KNOWN_ISSUES.md 产品缺陷表）。
后缀加 `.txt` 是不让它们被当成源码编译 / 扫禁词。

| 文件 | 是什么 | 条目 | 修复会话 |
|---|---|---|---|
| probe.py.txt + main.swift.txt | 本机探针：`main.swift` 用生产 APIServer + VMixCompatServer 起隔离实例（CPU-only、合成状态、假密钥 scan-canary-only），`probe.py` 发原始 WS 握手（带 `Origin: https://attacker.invalid`）、兼容层 GET、2 MiB 不带换行的 TCP | NS02 / NS05 / NS07 / NS03 | 131 W2-C5（用例照它的握手写） |
| results.txt | 当时的输出：WS 101 + 快照含密钥 + setPreview 生效；兼容层 GET 200 OK Cut；TCP 2 MiB → RSS +4.2 MiB | 同上 | — |
| test-results.txt | 当时跑过的现有套件（都绿、都不断言这些事） | — | — |
| C06-server.py.txt + C06-client.swift.txt | 恶意 RTMP 服务端（握手 + `_result` 第三个 AMF0 值嵌 10 万层单元素严格数组，约 500 KB）与用生产 SwitcherStreaming 连它的客户端 | NS04 | 132 W2-D5（StreamingTests 里照它搭回环假服务端） |
| C06-crash.ips.txt | 客户端 SIGBUS 的崩溃报告（栈保护页；`Reader.value` 反复递归 → `reply` → `exchange` → `probeConnect` → `authorize`） | NS04 | — |

NS01 = 10-22 的 N03（129）、NS06 = 032 已修（G11 回归用例 `Compat032RegressionTests`）、NS08 明文（130 提醒文字 + 手册，TLS 等用户定）、NS09 / NS12 脱敏（132）、NS10 / NS11 Stream Deck（131）。
