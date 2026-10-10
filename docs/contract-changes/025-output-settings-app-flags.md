# 025 W5-I 的三个 App 层标记升成正式字段：`RecordSettings.armed` / `RecordSettings.ownFormat` / `StreamSettings.followFirst`

提出会话 / 分支：W5-I（prompt 95，`w5-app-output-pages`；reports/w5-app-output-pages.md §4 第 1 条），G7 检查点转述（reports/G7.md §7.1 第 5 条）；本文件由 G7 按用户 2026-10-10 的裁定写成决策记录
状态：**已批**（用户 2026-10-10："升正式字段"）。契约由 P5（prompt 99）落地；App 侧读写切换与旧键搬迁归 101（W5-N）

## 改什么

现状：三个标记放在 `OutputSettings.extra`（`[String: JSONValue]`，契约注释"各输出会话的附加设置（占位）"，NDI 的 `ndi.groups` / `ndi.conversion` 是先例）里，会进节目文件与 API 全量状态，但 headless / API 不认、没有校验：

| extra 键 | 含义 | 缺键 |
|---|---|---|
| `app.record.armed` | 这一路录制参与"全部录制"（底栏录制主体 / "全部开始"） | true |
| `app.record.ownFormat` | 来源是某路输入的录制（ISO 路）用自己的编码参数、不跟主录制格式 | false（跟主录制格式） |
| `app.stream.followFirst` | 这个推流目的地的编码参数跟第一个目的地 | false（App 对第 2 个起新建的写 true） |

改成正式字段（JSON 键 = 去掉前缀的名字；都可选、缺键给默认；写出总是写全）：

- `RecordSettings.armed: Bool = true`
- `RecordSettings.ownFormat: Bool = false`
- `StreamSettings.followFirst: Bool = false`

`OutputSettings.extra` 保留（NDI 还在用），不再放这三个键。docs/CONTRACTS.md §2.5 的 RecordSettings / StreamSettings 表各加行；`jsonKeys` 快照（若有）更新。

## 为什么

进节目文件与 API 全量状态的东西应有类型与文档；headless / API 的"全部录制"也该认"参与录制"，而 extra 里的键没有校验、headless / API 不认（W5-I §4 第 1 条）。

## 影响谁

- SwitcherContracts：三个字段 + `init(from:)` 的 `decodeIfPresent` 默认 + 测试（缺键默认、往返、老文件照读）。
- App（101）：OutputPagesModel / `OutputLinkage.armedRecords` / 推流页"跟第一个"改读写字段；`Show.load` 后把旧键搬进字段并删键（只搬一次）；W5-I 的用例改读字段。
- headless / API：现在逐路 startRecord，不受影响；"全部录制"要认 armed 的话归控制会话另记。
- VMixCompat：不映射。

## 怎么迁移

不升 schemaVersion：老文件缺键 = 默认；App 在 Show.load 后搬一次 extra 里的三个键（有则写进字段、删键），写回时就没有旧键了。写出总是写全三个字段。

## 落地记录（P5 / prompt 99，2026-10-10）

契约已落地（分支 `p5-contracts`）：`RecordSettings.armed`（缺键 true）/ `RecordSettings.ownFormat`（缺键 false）/ `StreamSettings.followFirst`（缺键 false），显式 `init(from:)` 兜老文件、写出总是写全、`jsonKeys` 钉住；
旧键搬迁做成 `OutputSettings.migratingLegacyAppFlags()` / `Show.migratingLegacyAppFlags()`（有键按原值搬、搬完清键、幂等；键名常量 `RecordSettings.legacyArmedExtraKey` 等），
**不并进 `Show.load` / `migratingLegacyKeys()`**：025 之前的 App 还在读写 extra 键，并进去会让 App 在 101 切换之前丢掉"取消参与"的状态；按本提案"怎么迁移"一节由 App（101）在 Show.load 后调一次并把读写切到字段，之后再并进 `migratingLegacyKeys()`。
用例 `Contracts025Tests`（缺键默认 / 往返 / 写全 / 老场景节目照读 / 搬迁规则）。CONTRACTS.md §2.5 加 RecordSettings / StreamSettings 两行与一段说明。`Show.schemaVersion` 不升。
