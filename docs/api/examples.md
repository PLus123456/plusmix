# API 示例

下面的命令都对着一个在跑的 PlusMix（App 默认已开 API）或无界面引擎。没有设备也能试：另开一个终端跑示例节目并开 API：

```bash
swift build -c release --package-path Tools/switcher-headless && Tools/switcher-headless/.build/release/switcher-headless run --show Samples/event/event.switcher.json --duration 600 --audio-device null --api
```

## 1. curl

看状态（PGM / PVW / tally / 最近一行统计）：

```bash
curl -s http://127.0.0.1:8765/api/v1/state | python3 -m json.tool | head -40
```

只要 tally：

```bash
curl -s http://127.0.0.1:8765/api/v1/tally
```

Cut：

```bash
curl -s -X POST http://127.0.0.1:8765/api/v1/command -H 'Content-Type: application/json' -d '{"command": {"cut": {}}}'
```

选 3 号到 PVW 再 Fade 30 拍（批量，同一次请求顺序执行）：

```bash
curl -s -X POST http://127.0.0.1:8765/api/v1/command -H 'Content-Type: application/json' -d '{"commands": [{"setPreview": {"input": 3}}, {"fade": {"durationTicks": 30}}]}'
```

转场进行中发这一批：`setPreview` 被拒（回执 `applied = false`），`fade` 也被忽略，3 号上不了 PGM；换成 `[setPreview, cut]` 时 `cut` 会把正在进行的那次做完，PGM 落在原来那次的目标上、不是 3 号——看每条回执的 `applied`（[§4](#4-时序上要知道的)）。

执行转场槽 2（= 界面上点"转场 2"、⌥2；之后 T-bar / 回车也用它）：

```bash
curl -s -X POST http://127.0.0.1:8765/api/v1/command -H 'Content-Type: application/json' -d '{"command": {"useTransitionSlot": {"slot": 2, "start": true}}}'
```

打开叠加通道 1 并换成 6 号输入：

```bash
curl -s -X POST http://127.0.0.1:8765/api/v1/command -H 'Content-Type: application/json' -d '{"command": {"overlay": {"channel": 1, "on": true, "input": 6}}}'
```

开始 / 停止 1 号录制输出：

```bash
curl -s -X POST http://127.0.0.1:8765/api/v1/command -d '{"startRecord": {"output": 1}}'
```

```bash
curl -s -X POST http://127.0.0.1:8765/api/v1/command -d '{"stopRecord": {"output": 1}}'
```

设了 token 时加一个头：`-H 'Authorization: Bearer <token>'`。命令目录（每条命令的参数与样例）：

```bash
curl -s http://127.0.0.1:8765/api/v1/commands | python3 -c 'import json,sys; [print(c["kind"], "—", c["summary"]) for c in json.load(sys.stdin)["commands"]]'
```

最近走过总线的命令（谁在什么时候切的）：

```bash
curl -s 'http://127.0.0.1:8765/api/v1/log?limit=20' | python3 -m json.tool
```

## 2. Python

[examples/switcher_client.py](examples/switcher_client.py) 只用标准库（HTTP 用 `urllib`，WebSocket 自带最小实现）：

```bash
python3 docs/api/examples/switcher_client.py state
```

```bash
python3 docs/api/examples/switcher_client.py preview 2 && python3 docs/api/examples/switcher_client.py cut
```

```bash
python3 docs/api/examples/switcher_client.py cmd '{"fade": {"durationTicks": 30}}'
```

订阅 WebSocket，打印每次 tally 变化和"收到 − 拍点"的推送延迟（同一台 Mac 上用 `mach_absolute_time` 与服务端同一个钟；命令在下一拍生效、快照常常早于那一拍到达，所以看到负几毫秒是正常的，测试标准 C2 判的是 ≤ 50 ms）：

```bash
python3 docs/api/examples/switcher_client.py watch
```

在自己的脚本里用：

```python
import json, urllib.request

def command(cmd, base="http://127.0.0.1:8765"):
    req = urllib.request.Request(base + "/api/v1/command", data=json.dumps({"command": cmd}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as r:
        return json.load(r)          # {"sequence", "appliedTick", "applied", ...}

print(command({"setPreview": {"input": 2}}))
print(command({"cut": {}}))
```

C 系列测试用的完整客户端（记录快照、按计划发命令、算 C1–C4）在 [scripts/apitest/apitest.py](../../scripts/apitest/apitest.py)。

## 3. Companion

[Bitfocus Companion](https://bitfocus.io/companion) 不需要专门的模块就能对着本地 API 用——用它自带的两个通用模块：

**发命令：Generic: HTTP 模块。** Connections 里加 "Generic: HTTP"（Base URL 填 `http://127.0.0.1:8765`），按钮动作选 **POST**：

| 字段 | 值 |
|---|---|
| URL | `/api/v1/command` |
| Body | `{"command": {"cut": {}}}`（任何一条 [命令](../api.md) 的 JSON） |
| Content type | `application/json` |
| Header（设了 token 时） | `Authorization: Bearer <token>` |

常用按钮：

| 按钮 | Body |
|---|---|
| PVW 选 n | `{"command": {"setPreview": {"input": 1}}}` |
| 直切 PGM n | `{"command": {"setProgram": {"input": 1}}}` |
| Cut / Auto | `{"command": {"cut": {}}}` / `{"command": {"autoTransition": {}}}` |
| Fade 0.5 s（60 fps） | `{"command": {"fade": {"durationTicks": 30}}}` |
| 选 + 切一次完成 | `{"commands": [{"setPreview": {"input": 3}}, {"cut": {}}]}`（转场进行中 `setPreview` 被拒、`cut` 只把正在进行的那次做完，看回执） |
| 执行转场 1–4 | `{"command": {"useTransitionSlot": {"slot": 2, "start": true}}}` |
| 叠加 1 开 / 关 | `{"command": {"overlay": {"channel": 1, "on": true, "input": null}}}` / `"on": false` |
| 叠加 1 关掉并清空输入 | `{"command": {"overlay": {"channel": 1, "on": false, "input": 0}}}`（`input: 0` = 清空、`null` = 不换；清空的那一拍画面就没有、不走退出动画——要淡出就先单发 `"on": false`，等动画走完再清） |
| FTB | `{"command": {"ftb": {"on": true}}}` |
| 录制 / 推流 | `{"command": {"startRecord": {"output": 1}}}` … |

**反馈（按钮颜色 = tally）：Generic: WebSocket 模块。** Connections 里加 "Generic: WebSocket"，URL `ws://127.0.0.1:8765/api/v1/events`，
勾 "Use JSON"，把收到消息的 JSON 路径映射成变量：`$.state.program` → `pgm`、`$.state.preview` → `pvw`、`$.tally.1.program` → `tally_1_pgm` ……
然后在按钮上用 "variable value" 反馈：`pgm` 等于 `1` 时红、`pvw` 等于 `1` 时绿。快照每拍最多一条、每条都是整状态，丢一条也不会错。
这条连接同样能发命令（`{"id": 1, "command": {"cut": {}}}`），所以只用 WebSocket 模块也行。

用现成的第三方面板配置（不改 Companion 里的连接类型）走 [兼容层](vmix-compat.md)；为原生 API 写一个正式 Companion 模块的骨架在 [docs/integrations/companion.md §2](../integrations/companion.md#2-走原生-api-的-companion-模块骨架本期只写文档)。

## 4. 时序上要知道的

- 命令在**下一拍**生效（回执里的 `appliedTick`），从发出到画面变化 ≤ 1 拍 + 网络往返（C1）。
- 收到 `applied = false` 不用重发：状态机是有意忽略的（例如转场进行中再发转场；**转场进行中的 `setPreview` / `setProgram` 也会被拒**，PVW / PGM 不变）。批量 `[setPreview(n), cut]` 在转场中发：前一条被拒，`cut` 把正在进行的那次转场做完，PGM 落在原来那次的目标上、不是 n。
- 想在精确的拍点切换：先读 `state.tick`，算好目标拍，提前一点发；或者用场景脚本（`switcher-headless --script`，[scenarios/README.md](../../scenarios/README.md)）。
- 状态推送是整快照；客户端只保存最新一条即可，重连后第一条就是当前状态。
