# docs/CONTRACTS.md 里五处"137 落地后生效、现在 API 还是原文"要翻成现在时（137 已随 G13 合入）

归属会话 / 分支：下一个契约会话（128 P5-6 `p5-contracts-6`，或任何先动 `docs/CONTRACTS.md` 的契约会话）
发现于：G13（prompt 140，分支 `g13`）合入 136 `p5-contracts-8` → 137 `w2-control-6` 时，2026-11-07
严重级：S3（文档口径过期，代码行为已对；不影响任何用例）

## 现象

P5-8（136）写 CONTRACTS.md 时 API 打码还没落地，按 prompt 136 把往返规则写成"137 落地后生效，现在 API 还是原文"（reports/p5-contracts-8.md §4 第 2 条、reports/w2-control-6.md §3 第 1 条都提过"G13 合入时翻成现在时"）。
137 已随 G13 合入（合并提交 faec8e0），这几句现在不对了：

| 行（g13 d5c3c9b） | 现在的字样 | 改成 |
|---|---|---|
| 42（标题下的变更记录 P5-8 那条） | "……第 ② 步 API 打码归 137 W2-C6……" | 补一句"137 W2-C6 2026-11-07 落地（G13 合入）：API 状态 / WS 快照 / 命令日志打码、`?secrets=1` 要 token" |
| 216（§2.5 `StreamSettings` 行） | "对外（API 状态 / 命令日志）怎么打码与往返见 §2.11（提案 035，137 落地后生效）" | "……见 §2.11（提案 035，137 已落地）" |
| 374（§2.11 正文标题） | "——137 W2-C6 落地后生效，现在 API 给的还是原文" | "——137 W2-C6 2026-11-07 落地（G13 合入）" |
| 400（§3 速查） | "（提案 035；137 落地后生效，现在 API 还是原文）" | "（提案 035，137 已落地）" |
| §2.11 往返那句 | "`setOutputSettings` 收到打码值 = 保留原值" | **若用户批 137 报告 §4 第 1 条**（换地址 + 标记密钥 → 400，比提案字面严一档），补"换地址时密钥要给原文（标记 → 400）"；提案 035 文末也补同一句。不批就不用改、137 要删 a99ff8f 那段判断与用例 |

## 为什么 G13 不顺手改

`docs/CONTRACTS.md` 不在 G13 的目录（docs/OWNERSHIP.md G13 行；G4 行当年带着它，G12 / G13 没有），check-ownership 会红；契约文字按流程归契约会话。

## 顺带（同一会话可以一起做）

- `Packages/SwitcherCore/Package.swift` 的 `SwitcherContractsTests` testTarget 没加 `exclude: ["Fixtures"]`：136 的金样让 SwiftPM 的"unhandled files"告警从 8 个文件变 9 个（reports/p5-contracts-8.md §3 第 4 条）；夹具都按 `#filePath` 读、不走 Bundle.module，加 exclude 即可。
- App 三处注释"推流包的 StreamURLRedaction"（`App/Sources/Release/ShowRedaction.swift:2 / :11`、`App/Sources/Settings/StreamAddress.swift:9`）G13 按 App 胶水额度改成"契约的"（reports/G13.md §4.3）。

## 处理结果

（契约会话填）
