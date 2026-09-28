# Samples/ —— 示例节目文件

三个能直接打开的 Show（节目文件，`*.switcher.json`），画面全部用引擎内置的合成测试源，字幕 / 台标是随附的 PNG，
所以在任何一台 Mac 上打开都能跑，不需要摄像头、采集卡或网络。把合成源换成真设备的办法在 [§3](#3-换成你的设备)。

| 目录 | 场景 | 输入 | 叠加通道 | 输出 | 节目格式 |
|---|---|---|---|---|---|
| [church/](church/church.switcher.json) | 教会：3 机位 + 调音台 + 歌词字幕 + 直播 | 1–3 机位、4 调音台（带音频、不跟随视频）、5 歌词字幕（图）、6 台标（图） | 1 = 歌词（从底边滑入）、2 = 台标（淡入） | 1 节目录制、2 直播（RTMP，默认指向本机测试服务器） | 1080p30 |
| [classroom/](classroom/classroom.switcher.json) | 教室：屏幕 + 摄像头画中画 + 录制 | 1 屏幕课件、2 老师摄像头（带音频、不跟随视频）、3 课程标题（图） | 1 = 老师画中画（右下、白边，打开就在）、2 = 课程标题 | 1 课程录制 | 1080p30 |
| [event/](event/event.switcher.json) | 活动：4 机位 + 多画面 + ISO 分路 | 1–4 机位、5 调音台（带音频）、6 标题字幕（图） | 1 = 标题字幕 | 1 节目录制、2–5 四路 ISO、6 多画面（安全框 + 电平表）、7 NDI 发送（关着） | 1080p60 |

每个样例里 PGM / PVW 已经选好，转场默认 Fade（教会 / 教室 15 拍 = 0.5 s，活动 30 拍 = 0.5 s），FTB 同样时长。
录制 / 推流输出打开节目时一律是停着的（App 不会替你开录，只有你按按钮、快捷键或 API 才起），多画面 / NDI 输出的开关按文件里写的来。

## 1. 打开

**App**：节目 › 打开…（⌘O），选 `Samples/<目录>/<名字>.switcher.json`。或者用启动参数：

```bash
make gen build-app && open .build/DerivedData/Build/Products/Debug/PlusMix.app --args --show "$PWD/Samples/event/event.switcher.json"
```

**无界面引擎**（跑 30 秒，每秒一行统计写到 stats.jsonl）：

```bash
swift build -c release --package-path Tools/switcher-headless
Tools/switcher-headless/.build/release/switcher-headless run --show Samples/event/event.switcher.json --duration 30 --audio-device null --stats /tmp/event-stats.jsonl
```

`--audio-device default` 会从系统默认输出出声（调音台那一路是 1 kHz 正弦 −20 dBFS，每秒一个 click）。

## 2. 相对路径

图片输入的 `path`（`assets/lyrics.png` 之类）**相对节目文件所在目录**，录制目录（`教会` / `教室` / `活动`）**相对默认录制目录** `~/Movies/PlusMix/`（无界面引擎里相对当前目录）。
"另存为"到别的地方时把 `assets/` 一起搬走。

App 修好前的临时办法（[问题单](../reports/issues/W4C-app-relative-media-paths.md)）：App 现在把图片路径按进程工作目录解析，从菜单打开样例时字幕 / 台标那两路会显示"图片不存在：assets/…"，
其余照跑。要看到字幕，从样例目录里起 App：

```bash
cd Samples/church && ../../.build/DerivedData/Build/Products/Debug/PlusMix.app/Contents/MacOS/PlusMix --show church.switcher.json
```

## 3. 换成你的设备

两条路都保留编号、名字、设置和 PGM / PVW / 叠加引用：

- App：选中缩略图 → 输入 › 输入设置…（或缩略图右键"设置…"）→ 左栏"来源" → 选设备 → "应用来源"。这一路会按新来源重建，画面断一下。
- 改文件：把该路的 `source` 换成下面任一形态（字段含义见 [用户手册 · 输入](../docs/user/输入.md)）。

```json
{"camera": {"uniqueID": "<AVCaptureDevice.uniqueID，添加输入面板里能看到>"}}
{"screen": {"target": {"display": {"id": 1}}, "frameRate": null, "captureAudio": false}}
{"decklink": {"deviceID": "", "connection": "sdi"}}
{"ndi": {"sourceName": "机器名 (源名)", "bandwidth": "highest", "jitterBufferFrames": 1}}
{"audio": {"deviceUID": ""}}
{"file": {"path": "素材/开场.mov", "endAction": "loop", "rate": 1}}
{"image": {"path": "assets/lyrics.png"}}
```

`deviceUID` 空串 = 跟随系统默认输入；`deviceID` 空串 = 第一台有输入的 DeckLink 卡；屏幕的 `display.id` 是 CGDirectDisplayID（主屏通常是 1），添加输入面板会替你填。

## 4. 直播先在本机试

教会样例的直播目的地是 `rtmp://127.0.0.1:1935/live`、密钥 `church`。另开一个终端起本地服务器，再在 App 里按"推流"（或无界面引擎里把该输出的 `enabled` 改成 true）：

```bash
mediamtx scripts/mediamtx.yml
```

```bash
ffplay rtmp://127.0.0.1:1935/live/church
```

换成平台时只改地址和密钥（`rtmp://` / `rtmps://` / `srt://` 都行，协议由地址决定），其他不动。

## 5. 重新生成

节目文件由 [tools/make-shows.py](tools/make-shows.py) 生成（样板字段集中在几个函数里，改一处就够），图片由 [tools/make-assets.swift](tools/make-assets.swift) 画（只用系统框架）：

```bash
python3 Samples/tools/make-shows.py
```

```bash
swift Samples/tools/make-assets.swift
```

自己的字幕 / 台标：任何 1920×1080、带 alpha 的 PNG 覆盖同名文件即可，节目文件不用改。字幕条放在下三分之一、台标放右上角是为了避开合成源顶部的测试图案（换成真摄像头就没有这个顾虑）。
