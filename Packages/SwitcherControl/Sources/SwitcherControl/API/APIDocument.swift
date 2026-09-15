import Foundation
import SwitcherContracts

// docs/api.md 的生成器（switcher-apidoc 可执行文件调它；CommandCatalogTests 保证仓库里那份与生成结果一致）。

/// API 文档（Markdown）。
public enum APIDocument {
    public static func markdown() -> String {
        var out = """
        # 本地 API（v1）

        > 由 `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` 生成，不要手改；
        > 命令表来自 `SwitcherContracts.Command`（CONTRACTS.md §2.6、§8）与 `CommandCatalog`（Packages/SwitcherControl）。
        > 设计方案 §9.2：这是官方接口，Stream Deck 插件、MIDI 映射、Companion 模块都对着它写。

        默认监听 `127.0.0.1:\(APIServerConfiguration.defaultPort)`（headless：`--api`，`--api-listen 0.0.0.0:\(APIServerConfiguration.defaultPort)` 可改）。
        所有时间戳都是 host time（`mach_absolute_time` 的原始 tick 数，UInt64），换算纳秒用 `hello` / `state` 里的 `timebase`：ns = ticks × numer / denom。
        鉴权默认关；配了 token 后每个请求带 `Authorization: Bearer <token>`（WebSocket 也可用 `?token=<token>`），否则 401。

        ## HTTP

        ### GET /api/v1/state

        全量状态。键名与 Swift `Codable` 一致（`MixerState` 的字段原样）。

        ```json
        {
          "version": "\(SwitcherVersion.current)",
          "now": 123456789,
          "timebase": {"numer": 125, "denom": 3},
          "clock": {"t0": 123000000, "frameDuration": {"numerator": 1, "denominator": 60}},
          "sequence": 42,
          "tick": 3600,
          "tickTime": 123456000,
          "state": { "format": {...}, "inputs": [...], "program": 1, "preview": 2, "transition": {...}, "ftb": {...}, "overlays": [...], "audio": {...}, "outputs": [...] },
          "tally": {"1": {"program": true, "preview": false}, "2": {"program": false, "preview": true}},
          "stats": { "ts": ..., "tick": ..., "render_ms": ..., "missed_render": ..., "jitter_ms": ..., "per_input": {...}, "encoder": [...], "audio": {...}, "rss_mb": ..., "cpu_pct": ..., "gpu_pct": ... }
        }
        ```

        - `clock` 在引擎没起时钟时为 `null`；`stats` 在还没采到第一行时为 `null`。
        - `tally`：每路已配置输入的 `{program, preview}`，由快照推导（`MixerState.tally(ofInput:)`），全系统只算这一处。
        - `stats` 就是 stats.jsonl 的最近一行（测试标准 §7 的字段），UI / API / 测试三方同一份（铁律 4）。

        ### POST /api/v1/command

        请求体 `{"command": <Command>}`（也接受直接放 `<Command>`）。应答 `200`：

        ```json
        {"sequence": 43, "appliedTick": 3601, "issuedAt": 123456100, "appliedTickTime": 123456700}
        ```

        - `sequence`：总线分配的全局序号，严格递增、无空洞。
        - `appliedTick`：命令生效的拍（切换永远落在拍点边界）；`appliedTickTime` 是该拍的理想时刻（引擎没起时钟时省略）。
        - 结构性非法（引用不存在的输入 / 输出、通道越界、负时长、JSON 解析失败）→ `400 {"error": "<理由>"}`；
          语义上的忽略（转场进行中再发 fade 等）仍返回 200，状态不变。

        ### GET /api/v1/commands

        命令目录（下表的机器可读版）：`[{"kind": "cut", "group": "切换", "summary": "...", "example": {"cut": {}}}, ...]`。

        ## WebSocket /api/v1/events

        连接后依次收到 `hello`、当前 `snapshot`、最近一行 `stats`（如有）；之后每次状态变化推一条 `snapshot`（每拍最多一条，同一拍内多条命令只发最终状态），每秒一条 `stats`。
        推送形态选的是 **整快照 + 版本号**（`sequence` / `tick`），不是 JSON Patch：快照几 KB、本机回环带宽不是问题，而整快照幂等、丢一条也能自愈，客户端不用维护补丁状态机；tally 和 PGM / PVW 只关心最新值。

        ```json
        {"type": "hello", "version": "\(SwitcherVersion.current)", "now": 123456789, "timebase": {"numer": 125, "denom": 3}, "clock": {...}}
        {"type": "snapshot", "sequence": 43, "tick": 3601, "tickTime": 123456700, "sentAt": 123456150, "state": {...}, "tally": {"1": {"program": true, "preview": false}}}
        {"type": "stats", "stats": {...}}
        ```

        - `tickTime`：该快照生效那一拍的理想时刻；`sentAt`：服务端序列化这条消息的时刻。C2 的两种口径：`收到时刻 − tickTime`（状态变化的拍点 → 客户端）、`收到时刻 − sentAt`（纯传输）。
        - 客户端也可以在这条连接上发命令：`{"id": 7, "command": <Command>}` → `{"type": "receipt", "id": 7, "sequence": 44, "appliedTick": 3602, "issuedAt": ..., "appliedTickTime": ...}`；出错 `{"type": "error", "id": 7, "error": "<理由>"}`。`id` 原样带回，可省略。

        ## 命令

        JSON 形态由 Swift 合成的 `Codable` 决定：`{"<case>": {<参数>}}`，无参数的是 `{"cut": {}}`。

        """
        var group = ""
        for doc in CommandCatalog.entries {
            if doc.group != group {
                group = doc.group
                out += "\n### \(group)\n"
            }
            out += "\n#### `\(doc.kind.rawValue)`\n\n\(doc.summary)\n"
            if !doc.parameters.isEmpty {
                out += "\n| 参数 | 含义 |\n|---|---|\n"
                for p in doc.parameters { out += "| `\(p.name)` | \(p.note) |\n" }
            }
            let sample = (try? APIJSON.string(doc.example, pretty: true)) ?? "{}"
            out += "\n```json\n\(sample)\n```\n"
        }
        return out
    }
}
