# API：套在 `{"command": …}` 里的命令解不开时，真正的解码错误被吞，一律回"命令 JSON 类型不对：Invalid number of keys found, expected one."

归属会话 / 分支：下一个动 `Packages/SwitcherControl/Sources/SwitcherControl/API/` 的控制层会话（W2-C 续做）
发现于：W4-C5（prompt 135，分支 `w4-docs-5`）的核对 agent 对"帧率写 0 → 400'命令 JSON 无法解析：帧率必须为正'"一句逐字核对时（用一个与 APIModels 结构相同的最小程序实测过）
严重级：S3（错误文案误导，不伤节目；客户端照样拿到 400）

## 现象

docs/api/README.md §3 主推的写法是 `POST /api/v1/command {"command": <Command>}`。命令本身解不开（帧率 0 / 负数、缺键、类型不对……）时：

| 写法 | 回的 400 理由 |
|---|---|
| 裸 `<Command>` | 真正的原因，例如"命令 JSON 无法解析：帧率必须为正" |
| HTTP 批量 `{"commands": [...]}` | 真正的原因（`decodePayload` 看到有 `commands` 键会把解码错误重新抛出来） |
| `{"command": <Command>}`（HTTP） | **"命令 JSON 类型不对：Invalid number of keys found, expected one."** |
| WebSocket 的 `{"command": …}`、`{"id": …, "command": …}`、`{"commands": […]}` | 同上一行 |

原因：`CommandEnvelope.decode`（Packages/SwitcherControl/Sources/SwitcherControl/API/APIModels.swift:267–270）先 `try? decode(CommandRequest.self)`，失败就把**整个请求体**当裸 Command 再解一次；
合成的枚举 Codable 看到唯一的键是 `command`（不是任何 case 名）就报 typeMismatch"Invalid number of keys found, expected one."，原来的错误丢了。
HTTP 批量那条路（同文件 :279–282）已经特判了"有 `commands` 键就把真错误抛出来"，单条的 `command` 键和 WS 的 `WSCommandRequest`（APIServer.swift:226–229）没有。

手册现在照实写了（docs/api/README.md §3 错误表的注意、§6 帧率那一句），告诉客户端用裸命令写法再发一次看原因。

## 建议

- `CommandEnvelope.decode`：请求体是 JSON 对象且有 `command` 键时，直接 `decode(CommandRequest.self)` 并把错误抛出去（同批量那条路的写法）；只有没有 `command` / `commands` 键时才按裸 Command 解。
- WS：`handleWSCommand` 里 `WSCommandRequest` 解码失败而对象里有 `command` / `commands` 键时，同样把真错误报回去（`{"type":"error","id":…,"error":"命令 JSON 无法解析：帧率必须为正"}`）。
- 用例：HTTP `{"command": {"addInput": … 帧率 0 …}}` → 400 理由含"帧率必须为正"；WS 单条 / 批量同；裸写法与 HTTP 批量的现有用例不变。
- 修了告诉文档会话：docs/api/README.md §3 错误表那段"注意"删掉。
