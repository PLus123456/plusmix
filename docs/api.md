# 本地 API（v1）

> 由 `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` 生成，不要手改；
> 命令表来自 `SwitcherContracts.Command`（CONTRACTS.md §2.6、§8）与 `CommandCatalog`（Packages/SwitcherControl）。
> 设计方案 §9.2：这是官方接口，Stream Deck 插件、MIDI 映射、Companion 模块都对着它写。

默认监听 `127.0.0.1:8765`（headless：`--api`，`--api-listen 0.0.0.0:8765` 可改）。
所有时间戳都是 host time（`mach_absolute_time` 的原始 tick 数，UInt64），换算纳秒用 `hello` / `state` 里的 `timebase`：ns = ticks × numer / denom。
鉴权默认关；配了 token 后每个请求带 `Authorization: Bearer <token>`（WebSocket 也可用 `?token=<token>`），否则 401。

## HTTP

### GET /api/v1/state

全量状态。键名与 Swift `Codable` 一致（`MixerState` 的字段原样）。

```json
{
  "version": "0.1.0",
  "now": 123456789,
  "timebase": {"numer": 125, "denom": 3},
  "clock": {"t0": 123000000, "frameDuration": {"numerator": 1, "denominator": 60}},
  "sequence": 42,
  "tick": 3600,
  "tickTime": 123456000,
  "publishedAt": 123455900,
  "state": { "format": {...}, "inputs": [...], "program": 1, "preview": 2, "transition": {...}, "ftb": {...}, "overlays": [...], "audio": {...}, "outputs": [...] },
  "tally": {"1": {"program": true, "preview": false}, "2": {"program": false, "preview": true}},
  "stats": { "ts": ..., "tick": ..., "render_ms": ..., "missed_render": ..., "jitter_ms": ..., "per_input": {...}, "encoder": [...], "audio": {...}, "rss_mb": ..., "cpu_pct": ..., "gpu_pct": ... }
}
```

- `clock` 在引擎没起时钟时为 `null`；`stats` 在还没采到第一行时为 `null`；`publishedAt` 是状态机发布这个快照的时刻。
- `tally`：每路已配置输入的 `{program, preview}`，由快照推导（`MixerState.tally(ofInput:)`），全系统只算这一处。
- `stats` 就是 stats.jsonl 的最近一行（测试标准 §7 的字段），UI / API / 测试三方同一份（铁律 4）。

### POST /api/v1/command

请求体 `{"command": <Command>}`（也接受直接放 `<Command>`）。应答 `200`：

```json
{"sequence": 43, "appliedTick": 3601, "applied": true, "issuedAt": 123456100, "appliedTickTime": 123456700}
```

- `sequence`：总线分配的全局序号，严格递增、无空洞。
- `appliedTick`：命令生效的拍（切换永远落在拍点边界）；`appliedTickTime` 是该拍的理想时刻（引擎没起时钟时为 null）。
- `applied`：状态是否真的变了。`false` = 状态机按规则忽略了它（转场进行中再发 fade、FTB 目标已相同、mute 已是该值……），状态原样，仍是 200。
- `issuedAt`：命令进总线的时刻（服务端 host time）。
- 结构性非法（引用不存在的输入 / 输出、通道越界、负时长、JSON 解析失败）→ `400 {"error": "<理由>"}`。

批量：请求体 `{"commands": [<Command>, …]}`，按顺序执行、sequence 连续（例如 `setPreview` + `cut` 一次发）。应答 `200 {"receipts": [...]}`；
第 `index` 条被拒时 `400 {"error": "<理由>", "index": 1, "receipts": [前面已生效的回执]}`。空数组 400。

### GET /api/v1/commands

命令目录（下表的机器可读版）：`{"commands": [{"kind": "cut", "group": "切换", "summary": "...", "parameters": {...}, "example": {"cut": {}}}, ...]}`。

### GET /api/v1/log?limit=256

最近走过总线的命令（诊断用）：`{"entries": [{"sequence", "issuedAt", "source": "ui|hotkey|midi|api|script", "command", "appliedTick", "applied", "appliedAt"}, ...]}`，
按 sequence 升序，最多 256 条；`appliedAt − issuedAt` 是总线 + 状态机的处理耗时。

### GET /api/v1/tally

给外部 tally / 面板轮询的小应答：`{"sequence", "tick", "program", "preview", "tally": {"1": {"program": true, "preview": false}, ...}}`。
与 `state` 里的 `tally` 同一份推导，只是没有整个 MixerState。

## WebSocket /api/v1/events

连接后依次收到 `hello`、当前 `snapshot`、最近一行 `stats`（如有）；之后每次状态变化推一条 `snapshot`（每拍最多一条，同一拍内多条命令只发最终状态），每秒一条 `stats`。
推送形态选的是 **整快照 + 版本号**（`sequence` / `tick`），不是 JSON Patch：快照几 KB、本机回环带宽不是问题，而整快照幂等、丢一条也能自愈，客户端不用维护补丁状态机；tally 和 PGM / PVW 只关心最新值。

```json
{"type": "hello", "version": "0.1.0", "now": 123456789, "timebase": {"numer": 125, "denom": 3}, "clock": {...}}
{"type": "snapshot", "sequence": 43, "tick": 3601, "tickTime": 123456700, "publishedAt": 123456120, "sentAt": 123456150, "state": {...}, "tally": {"1": {"program": true, "preview": false}}}
{"type": "stats", "stats": {...}}
```

- `tickTime`：该快照生效那一拍的理想时刻；`publishedAt`：状态机发布这个快照的时刻；`sentAt`：服务端序列化这条消息的时刻。
  C2 的三种口径：`收到时刻 − tickTime`（状态变化的拍点 → 客户端）、`收到时刻 − publishedAt`（状态机发布 → 客户端）、`收到时刻 − sentAt`（纯传输）。
- 客户端也可以在这条连接上发命令：`{"id": 7, "command": <Command>}` → `{"type": "receipt", "id": 7, "sequence": 44, "appliedTick": 3602, "applied": true, "issuedAt": ..., "appliedTickTime": ...}`；出错 `{"type": "error", "id": 7, "error": "<理由>"}`。`id` 原样带回，可省略。
- 批量：`{"id": 8, "commands": [<Command>, …]}` → `{"type": "receipts", "id": 8, "receipts": [...]}`；第 `index` 条被拒时同一条消息里带 `"error"` 和 `"index"`（前面的已生效）。

## 命令

JSON 形态由 Swift 合成的 `Codable` 决定：`{"<case>": {<参数>}}`，无参数的是 `{"cut": {}}`。

### 切换

#### `cut`

PGM 与 PVW 原子对调，无中间态；转场进行中发 Cut 立即完成对调。

```json
{
  "cut" : {

  }
}
```

#### `fade`

选 Fade 并立即开始 auto 转场（= setTransition(fade, d) + autoTransition）。

| 参数 | 含义 |
|---|---|
| `durationTicks` | 时长（拍）；0 等于 Cut |

```json
{
  "fade" : {
    "durationTicks" : 30
  }
}
```

#### `setTransition`

选下一次转场的类型和时长，不开始；T-bar 用的也是它选的类型。

| 参数 | 含义 |
|---|---|
| `type` | cut / fade / wipe / zoom / stinger |
| `durationTicks` | 时长（拍） |

```json
{
  "setTransition" : {
    "durationTicks" : 20,
    "type" : "wipe"
  }
}
```

#### `setTransitionParams`

改 Wipe / Stinger 参数（两组整体替换），下一次转场起生效；转场进行中（含 T-bar 推到一半）被拒。

| 参数 | 含义 |
|---|---|
| `wipe` | {direction: leftToRight / rightToLeft / topToBottom / bottomToTop / diagonal, softness: 软边宽占画面的比例 0–1，超出钳住} |
| `stinger` | {input: 作 stinger 的输入编号（带 alpha 的文件 / 图片），不写 = 未设置；cutAtTick: 第几拍换底，≥ 0，≥ 时长 = 完成时换} |

```json
{
  "setTransitionParams" : {
    "stinger" : {
      "cutAtTick" : 12,
      "input" : 4
    },
    "wipe" : {
      "direction" : "topToBottom",
      "softness" : 0.2
    }
  }
}
```

#### `autoTransition`

按已选的类型 / 时长开始 auto 转场；进行中再发则忽略。

```json
{
  "autoTransition" : {

  }
}
```

#### `setPreview`

把 PVW 换成该输入；转场进行中（含 T-bar 推到一半）被拒（applied = false）。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号；0 = 黑场 |

```json
{
  "setPreview" : {
    "input" : 2
  }
}
```

#### `setProgram`

直接把 PGM 换成该输入（硬切），PVW 不变；转场进行中被拒（applied = false）。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号；0 = 黑场 |

```json
{
  "setProgram" : {
    "input" : 3
  }
}
```

#### `tbar`

推杆位置 0–1；到 1 提交（对调并回到 0）。

| 参数 | 含义 |
|---|---|
| `progress` | 0–1 |

```json
{
  "tbar" : {
    "progress" : 0.5
  }
}
```

#### `ftb`

渐黑开 / 关（显式目标，脚本可重放）；时长用状态里的 ftb.durationTicks（改它走 setFTBDuration）。

| 参数 | 含义 |
|---|---|
| `on` | true = 黑 |

```json
{
  "ftb" : {
    "on" : true
  }
}
```

#### `setTransitionSlot`

改转场槽 1–4 之一的配置（效果 + 时长 + Wipe / Stinger 参数整体替换），转场进行中也收；改的是当前槽且空闲时当前那组同时按槽重拷，进行中的那一次按开始时的参数走完再重拷；相同配置 applied = false。

| 参数 | 含义 |
|---|---|
| `slot` | 1–4 |
| `config` | {type: cut / fade / wipe / zoom / stinger, durationTicks: 时长（拍，≥ 0），wipe: {direction, softness 0–1}, stinger: {input 或不写, cutAtTick ≥ 0}} |

```json
{
  "setTransitionSlot" : {
    "config" : {
      "durationTicks" : 60,
      "stinger" : {
        "cutAtTick" : 0
      },
      "type" : "wipe",
      "wipe" : {
        "direction" : "topToBottom",
        "softness" : 0.2
      }
    },
    "slot" : 2
  }
}
```

#### `useTransitionSlot`

选中转场槽 1–4（把槽拷进当前那组、currentSlot = slot）；start = true 同时开始 auto 转场、一拍内原子完成（cut / 时长 0 = 立即对调，Stinger 槽没选输入照常开始）；start = false 只选中给 T-bar / 回车用。转场进行中被拒（applied = false）。

| 参数 | 含义 |
|---|---|
| `slot` | 1–4 |
| `start` | true = 选中并开始；false = 只选中 |

```json
{
  "useTransitionSlot" : {
    "slot" : 2,
    "start" : true
  }
}
```

#### `setFTBDuration`

改 FTB 淡入 / 淡出黑的时长（拍）；渐变进行中电平从当前值按新时长继续走、不跳变；相同值 applied = false；不跟随转场时长。

| 参数 | 含义 |
|---|---|
| `ticks` | 时长（拍，≥ 0） |

```json
{
  "setFTBDuration" : {
    "ticks" : 15
  }
}
```

### 叠加

#### `overlay`

开关叠加通道 1–4；input 非 null 时同时换该通道用的输入。

| 参数 | 含义 |
|---|---|
| `channel` | 1–4 |
| `on` | 开 / 关 |
| `input` | 输入编号或 null（不换） |

```json
{
  "overlay" : {
    "channel" : 1,
    "input" : 4,
    "on" : true
  }
}
```

#### `setOverlay`

改叠加通道的位置尺寸与进出动画。

| 参数 | 含义 |
|---|---|
| `channel` | 1–4 |
| `rect` | {x, y, width, height} 都是 0–1 比例 |
| `animation` | {kind: cut/fade/slide/zoom, durationTicks} |

```json
{
  "setOverlay" : {
    "animation" : {
      "durationTicks" : 15,
      "kind" : "fade"
    },
    "channel" : 2,
    "rect" : {
      "height" : 0.5,
      "width" : 0.5,
      "x" : 0.5,
      "y" : 0.5
    }
  }
}
```

#### `setOverlayDecoration`

改叠加通道的装饰：画中画边框、锚点、是否在 PVW 里预览。

| 参数 | 含义 |
|---|---|
| `channel` | 1–4 |
| `border` | {width: 占节目高的比例（渲染器钳到 0–0.1）, color: {red, green, blue}} 或 null（不画） |
| `anchor` | topLeft / top / topRight / left / center / right / bottomLeft / bottom / bottomRight；缩放动画绕它缩 |
| `previewOn` | true = 这一路也画进 PVW |

```json
{
  "setOverlayDecoration" : {
    "anchor" : "bottomRight",
    "border" : {
      "color" : {
        "blue" : 255,
        "green" : 255,
        "red" : 255
      },
      "width" : 0.006
    },
    "channel" : 1,
    "previewOn" : true
  }
}
```

### 音频

#### `audioGain`

某路输入的增益（dB，−96…+24，超出钳住）。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `dB` | 增益 |

```json
{
  "audioGain" : {
    "dB" : -6,
    "input" : 1
  }
}
```

#### `mute`

某路输入静音开 / 关。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `on` | true = 静音 |

```json
{
  "mute" : {
    "input" : 1,
    "on" : true
  }
}
```

#### `busGain`

总线增益（dB）。

| 参数 | 含义 |
|---|---|
| `bus` | 0 = master, 1 = busA, 2 = busB, 3 = headphones |
| `dB` | 增益 |

```json
{
  "busGain" : {
    "bus" : 0,
    "dB" : -3
  }
}
```

#### `busMute`

总线静音开 / 关。

| 参数 | 含义 |
|---|---|
| `bus` | 0–3，同 busGain |
| `on` | true = 静音 |

```json
{
  "busMute" : {
    "bus" : 1,
    "on" : true
  }
}
```

#### `setAFV`

音频跟随视频开 / 关。

| 参数 | 含义 |
|---|---|
| `on` | 开 / 关 |

```json
{
  "setAFV" : {
    "on" : true
  }
}
```

#### `setMonitorMode`

耳机监听方式：AFL（推子后）/ PFL（推子前）。

| 参数 | 含义 |
|---|---|
| `mode` | afl / pfl |

```json
{
  "setMonitorMode" : {
    "mode" : "pfl"
  }
}
```

#### `setMonitorSource`

耳机 / 监听总线上听哪条总线（master / busA / busB）；headphones 自己无效被拒；独听仍优先；与现状相同的值 applied = false。

| 参数 | 含义 |
|---|---|
| `bus` | 0 = master, 1 = busA, 2 = busB（3 = headphones 无效） |

```json
{
  "setMonitorSource" : {
    "bus" : 1
  }
}
```

#### `setBusEffects`

整体替换一条总线的效果链；链顺序 = 处理顺序，enabled = false 的格旁路。

| 参数 | 含义 |
|---|---|
| `bus` | 0 = master, 1 = busA, 2 = busB, 3 = headphones |
| `effects` | [{id, enabled, params}]：id 与参数键见 CONTRACTS.md §2.4 |

```json
{
  "setBusEffects" : {
    "bus" : 0,
    "effects" : [
      {
        "enabled" : true,
        "id" : "peakLimiter",
        "params" : {
          "attackSeconds" : 0.012,
          "decaySeconds" : 0.024,
          "preGainDb" : 0
        }
      }
    ]
  }
}
```

#### `setInputAudio`

一路的独听 / AFV 参与 / 总线路由，三个参数都可选，不写 = 不动；全不写或全与现状相同 applied = false（替代按快照改一位再 setInputSettings 整体写回）。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `solo` | true / false，或不写 |
| `afv` | true = 参与 AFV 门控，false = 不跟随视频，或不写 |
| `routing` | {master, busA, busB, headphones} 整体替换，或不写 |

```json
{
  "setInputAudio" : {
    "input" : 1,
    "routing" : {
      "busA" : true,
      "busB" : false,
      "headphones" : false,
      "master" : true
    },
    "solo" : true
  }
}
```

### 输出

#### `startRecord`

开始录制（output 必须是 record 类型的输出）。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |

```json
{
  "startRecord" : {
    "output" : 1
  }
}
```

#### `stopRecord`

停止录制。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |

```json
{
  "stopRecord" : {
    "output" : 1
  }
}
```

#### `startStream`

开始推流（output 必须是 stream 类型的输出，url / key 在它的设置里）。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |

```json
{
  "startStream" : {
    "output" : 2
  }
}
```

#### `stopStream`

停止推流。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |

```json
{
  "stopStream" : {
    "output" : 2
  }
}
```

#### `setOutputEnabled`

非录制 / 推流输出（NDI / 外部显示 / 虚拟摄像头 / 多画面）的目标开关；record / stream 被拒。多画面的开关 = 要不要把多画面送给下游（NDI 之类），布局与它无关。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |
| `on` | true = 应该在跑 |

```json
{
  "setOutputEnabled" : {
    "on" : true,
    "output" : 3
  }
}
```

#### `renameOutput`

改一个输出的显示名。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |
| `name` | 新名字 |

```json
{
  "renameOutput" : {
    "name" : "大屏",
    "output" : 3
  }
}
```

### 输入表

#### `setInputSettings`

整体替换一路输入的设置（裁切 / 变换 / 音频 / 效果 / 抠像），超范围的值钳住。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `settings` | InputSettings 整体 |

```json
{
  "setInputSettings" : {
    "input" : 1,
    "settings" : {
      "audio" : {
        "afv" : true,
        "delayMs" : 40,
        "gainDb" : -3,
        "muted" : false,
        "pan" : 0,
        "routing" : {
          "busA" : false,
          "busB" : false,
          "headphones" : false,
          "master" : true
        },
        "solo" : false
      },
      "crop" : {
        "bottom" : 0,
        "left" : 0,
        "right" : 0,
        "top" : 0
      },
      "effects" : [

      ],
      "keyer" : {
        "enabled" : false,
        "keyColor" : {
          "blue" : 0,
          "green" : 255,
          "red" : 0
        },
        "softness" : 0.1,
        "spillSuppression" : 0.5,
        "tolerance" : 0.3
      },
      "playback" : {
        "paused" : false,
        "restartOnProgram" : false
      },
      "transform" : {
        "flipHorizontal" : false,
        "flipVertical" : false,
        "offsetX" : 0,
        "offsetY" : 0,
        "rotationDegrees" : 0,
        "scale" : 1
      }
    }
  }
}
```

#### `renameInput`

改一路输入的显示名。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `name` | 新名字 |

```json
{
  "renameInput" : {
    "input" : 1,
    "name" : "主机位"
  }
}
```

#### `addInput`

加一路输入；编号已存在则拒绝。

| 参数 | 含义 |
|---|---|
| `config` | InputConfig：number, name, source, settings |

```json
{
  "addInput" : {
    "config" : {
      "name" : "机位 5",
      "number" : 5,
      "settings" : {
        "audio" : {
          "afv" : true,
          "delayMs" : 0,
          "gainDb" : 0,
          "muted" : false,
          "pan" : 0,
          "routing" : {
            "busA" : false,
            "busB" : false,
            "headphones" : false,
            "master" : true
          },
          "solo" : false
        },
        "crop" : {
          "bottom" : 0,
          "left" : 0,
          "right" : 0,
          "top" : 0
        },
        "effects" : [

        ],
        "keyer" : {
          "enabled" : false,
          "keyColor" : {
            "blue" : 0,
            "green" : 255,
            "red" : 0
          },
          "softness" : 0.1,
          "spillSuppression" : 0.5,
          "tolerance" : 0.3
        },
        "playback" : {
          "paused" : false,
          "restartOnProgram" : false
        },
        "transform" : {
          "flipHorizontal" : false,
          "flipVertical" : false,
          "offsetX" : 0,
          "offsetY" : 0,
          "rotationDegrees" : 0,
          "scale" : 1
        }
      },
      "source" : {
        "synthetic" : {
          "settings" : {
            "audio" : true,
            "audioDriftPpm" : 0,
            "background" : {
              "gray" : {
                "level" : 128
              }
            },
            "clockDriftPpm" : 0,
            "dropEveryN" : 0,
            "frameRate" : {
              "denominator" : 1,
              "numerator" : 60
            },
            "height" : 1080,
            "jitterMs" : 0,
            "width" : 1920
          }
        }
      }
    }
  }
}
```

#### `removeInput`

删一路输入；它若在 PGM / PVW / 叠加 / Stinger 上，那些位置变成 0 / null。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |

```json
{
  "removeInput" : {
    "input" : 5
  }
}
```

#### `setInputSource`

换一路输入的来源（文件路径 / 播完动作 / 屏幕目标 / 帧率 / NDI 源名与带宽 / DeckLink 接口……）；编号、名字、设置、PGM / PVW / 叠加引用全部保留。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `source` | InputSource；kind 由它推出 |

```json
{
  "setInputSource" : {
    "input" : 1,
    "source" : {
      "ndi" : {
        "bandwidth" : "lowest",
        "jitterBufferFrames" : 2,
        "sourceName" : "MAC (Cam 1)"
      }
    }
  }
}
```

#### `setPlayback`

文件输入播放 / 暂停（paused = true 画面停在当前帧、每拍重推）；不是文件输入被拒；相同值 applied = false。

| 参数 | 含义 |
|---|---|
| `input` | 文件输入编号 |
| `paused` | true = 暂停，false = 播放 |

```json
{
  "setPlayback" : {
    "input" : 3,
    "paused" : true
  }
}
```

#### `seekPlayback`

文件输入定位到第 seconds 秒（0 = 从头播）：状态里记一次定位请求 (seekTick, seekSeconds)，组装方交给文件输入执行，首帧晚 1–2 拍；不是文件输入 / 负数被拒；同一拍同一位置再发 applied = false。"切上 PGM 时从头播"是每路的 settings.playback.restartOnProgram（走 setInputSettings）。

| 参数 | 含义 |
|---|---|
| `input` | 文件输入编号 |
| `seconds` | 秒，≥ 0 |

```json
{
  "seekPlayback" : {
    "input" : 3,
    "seconds" : 0
  }
}
```

#### `setInputColor`

改一路的分类颜色（Finder 标签那六种），不写 = 清掉分类；相同值 applied = false。分类的名字在 Show.layout 里，不走命令。

| 参数 | 含义 |
|---|---|
| `input` | 输入编号 |
| `color` | red / orange / yellow / green / blue / purple，或不写 = 无分类 |

```json
{
  "setInputColor" : {
    "color" : "red",
    "input" : 1
  }
}
```

### 输出表

#### `addOutput`

加一个输出；编号已存在则拒绝。settings.extra 里的旧写法（layout / displayID / fallbackToMain）先搬进正式字段 multiview / display，与读节目文件相同。

| 参数 | 含义 |
|---|---|
| `config` | OutputState：number, kind, name, enabled, settings |

```json
{
  "addOutput" : {
    "config" : {
      "enabled" : false,
      "kind" : "stream",
      "name" : "推流 B",
      "number" : 3,
      "settings" : {
        "audio" : {
          "bitrateBps" : 160000,
          "codec" : "aac"
        },
        "extra" : {

        },
        "source" : {
          "program" : {

          }
        },
        "stream" : {
          "followFirst" : false,
          "reconnectMaxSeconds" : 30,
          "streamKey" : "key",
          "url" : "rtmp://localhost/live"
        },
        "video" : {
          "bitrateBps" : 6000000,
          "codec" : "h264",
          "keyframeIntervalFrames" : 120
        }
      }
    }
  }
}
```

#### `removeOutput`

删一个输出。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |

```json
{
  "removeOutput" : {
    "output" : 3
  }
}
```

#### `setOutputSettings`

整体替换一个输出的设置；extra 里的旧写法同 addOutput 先搬进正式字段。

| 参数 | 含义 |
|---|---|
| `output` | 输出编号 |
| `settings` | OutputSettings 整体 |

```json
{
  "setOutputSettings" : {
    "output" : 1,
    "settings" : {
      "extra" : {

      },
      "record" : {
        "armed" : true,
        "container" : "mov",
        "directory" : "/Volumes/Rec",
        "fileNamePattern" : "{show}-{date}-{time}",
        "fragmentIntervalSeconds" : 1,
        "ownFormat" : false,
        "remuxToMP4" : false
      },
      "source" : {
        "program" : {

        }
      },
      "video" : {
        "bitrateBps" : 12000000,
        "codec" : "hevc",
        "keyframeIntervalFrames" : 120
      }
    }
  }
}
```

### 节目

#### `loadShow`

用节目文件整体替换状态；旧写法按读节目文件同一套规则先搬迁（show.migratingLegacyKeys().makeState()），不合法的节目文件被拒。

| 参数 | 含义 |
|---|---|
| `show` | Show 整体 |

```json
{
  "loadShow" : {
    "show" : {
      "audio" : {
        "afv" : false,
        "alignmentFrames" : 2048,
        "buses" : [
          {
            "bus" : 0,
            "effects" : [

            ],
            "gainDb" : 0,
            "muted" : false
          },
          {
            "bus" : 1,
            "effects" : [

            ],
            "gainDb" : 0,
            "muted" : false
          },
          {
            "bus" : 2,
            "effects" : [

            ],
            "gainDb" : 0,
            "muted" : false
          },
          {
            "bus" : 3,
            "effects" : [

            ],
            "gainDb" : 0,
            "muted" : false
          }
        ],
        "monitorMode" : "afl",
        "monitorPoint" : "preDelayLine",
        "monitorSource" : 0
      },
      "inputs" : [
        {
          "name" : "机位 1",
          "number" : 1,
          "settings" : {
            "audio" : {
              "afv" : true,
              "delayMs" : 0,
              "gainDb" : 0,
              "muted" : false,
              "pan" : 0,
              "routing" : {
                "busA" : false,
                "busB" : false,
                "headphones" : false,
                "master" : true
              },
              "solo" : false
            },
            "crop" : {
              "bottom" : 0,
              "left" : 0,
              "right" : 0,
              "top" : 0
            },
            "effects" : [

            ],
            "keyer" : {
              "enabled" : false,
              "keyColor" : {
                "blue" : 0,
                "green" : 255,
                "red" : 0
              },
              "softness" : 0.1,
              "spillSuppression" : 0.5,
              "tolerance" : 0.3
            },
            "playback" : {
              "paused" : false,
              "restartOnProgram" : false
            },
            "transform" : {
              "flipHorizontal" : false,
              "flipVertical" : false,
              "offsetX" : 0,
              "offsetY" : 0,
              "rotationDegrees" : 0,
              "scale" : 1
            }
          },
          "source" : {
            "synthetic" : {
              "settings" : {
                "audio" : true,
                "audioDriftPpm" : 0,
                "background" : {
                  "gray" : {
                    "level" : 128
                  }
                },
                "clockDriftPpm" : 0,
                "dropEveryN" : 0,
                "frameRate" : {
                  "denominator" : 1,
                  "numerator" : 60
                },
                "height" : 1080,
                "jitterMs" : 0,
                "width" : 1920
              }
            }
          }
        }
      ],
      "layout" : {

      },
      "mixer" : {
        "format" : {
          "frameRate" : {
            "denominator" : 1,
            "numerator" : 60
          },
          "height" : 1080,
          "width" : 1920
        },
        "ftb" : {
          "durationTicks" : 30,
          "level" : 0,
          "on" : false
        },
        "overlays" : [
          {
            "anchor" : "center",
            "animProgress" : 0,
            "animation" : {
              "durationTicks" : 0,
              "kind" : "cut"
            },
            "on" : false,
            "previewOn" : false,
            "rect" : {
              "height" : 1,
              "width" : 1,
              "x" : 0,
              "y" : 0
            }
          },
          {
            "anchor" : "center",
            "animProgress" : 0,
            "animation" : {
              "durationTicks" : 0,
              "kind" : "cut"
            },
            "on" : false,
            "previewOn" : false,
            "rect" : {
              "height" : 1,
              "width" : 1,
              "x" : 0,
              "y" : 0
            }
          },
          {
            "anchor" : "center",
            "animProgress" : 0,
            "animation" : {
              "durationTicks" : 0,
              "kind" : "cut"
            },
            "on" : false,
            "previewOn" : false,
            "rect" : {
              "height" : 1,
              "width" : 1,
              "x" : 0,
              "y" : 0
            }
          },
          {
            "anchor" : "center",
            "animProgress" : 0,
            "animation" : {
              "durationTicks" : 0,
              "kind" : "cut"
            },
            "on" : false,
            "previewOn" : false,
            "rect" : {
              "height" : 1,
              "width" : 1,
              "x" : 0,
              "y" : 0
            }
          }
        ],
        "preview" : 0,
        "program" : 1,
        "transition" : {
          "currentSlot" : 1,
          "durationTicks" : 30,
          "progress" : 0,
          "slots" : [
            {
              "durationTicks" : 30,
              "stinger" : {
                "cutAtTick" : 0
              },
              "type" : "fade",
              "wipe" : {
                "direction" : "leftToRight",
                "softness" : 0
              }
            },
            {
              "durationTicks" : 60,
              "stinger" : {
                "cutAtTick" : 0
              },
              "type" : "wipe",
              "wipe" : {
                "direction" : "leftToRight",
                "softness" : 0
              }
            },
            {
              "durationTicks" : 60,
              "stinger" : {
                "cutAtTick" : 0
              },
              "type" : "zoom",
              "wipe" : {
                "direction" : "leftToRight",
                "softness" : 0
              }
            },
            {
              "durationTicks" : 60,
              "stinger" : {
                "cutAtTick" : 0
              },
              "type" : "stinger",
              "wipe" : {
                "direction" : "leftToRight",
                "softness" : 0
              }
            }
          ],
          "source" : "auto",
          "stinger" : {
            "cutAtTick" : 0
          },
          "type" : "fade",
          "wipe" : {
            "direction" : "leftToRight",
            "softness" : 0
          }
        }
      },
      "name" : "示例",
      "outputs" : [

      ],
      "schemaVersion" : 1
    }
  }
}
```
