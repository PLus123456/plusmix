# W4D → W3-C / W2-C / W3-D / 契约会话：产品改名 PlusMix 之后，包里还有几处用户看得到的代码名 Switcher（W4-D 的范围不含 Packages/）

发现于：W4-D（prompt 75，分支 w4-rename，2026-09-28）。原则是"只改用户看得到的名字"，但下面这些名字定义在包里（`Packages/*`），
不在 W4-D 的归属内（App/Resources、App/Info.plist、App/Sources、project.yml、CameraExtension/Resources + Info.plist、docs/、README、Samples/README、Tools/streamdeck-plugin/、scripts/release/），
所以没改；文档照实写了现状（并注明是代码名）。改的时候文档要跟着改，列在每条后面。
严重级：S3（都是名字，功能不受影响；但用户在 FaceTime 里看到的是 "Switcher"、在系统设置里看到的是 "PlusMix 虚拟摄像头"，两个名字对不上，0.1.0 发布前最好统一）。

| # | 在哪 | 现在的值 | 用户在哪看到 | 归属 | 改了要跟的文档 / 代码 |
|---|---|---|---|---|---|
| 1 | `Packages/SwitcherOutputs/Sources/VirtualCamera/Shared/VirtualCameraConstants.swift` 第 7 / 9 / 13 / 16 行：`deviceName = "Switcher"`、`deviceModel = "Switcher Virtual Camera"`、`sourceStreamName = "Switcher Program"`、`sinkStreamName = "Switcher Program Sink"` | 代码名 | FaceTime / QuickTime / 浏览器的摄像头列表里叫 "Switcher"；CMIO 的设备型号、流名 | W3-C（VirtualCamera/ + CameraExtension/Sources 共享这份常量） | docs/user/输出.md 第 99 行、docs/user/en/outputs.md 第 110 行、docs/user/故障排查.md 第 62 行、docs/user/en/troubleshooting.md 第 63 行、docs/release/signing.md 第 47 行、docs/release/checklist-first-signed-run.md 第 12 行（都注明了"0.1.0 里设备名仍是代码名"）；VirtualCameraTests / VirtualCameraAppTests 里按名字找设备的断言；CameraExtension/Info.plist 头部注释。**注意**：deviceName 是用户在会议软件里选过的设备名，发布后再改会让用户重选，所以要改就在 0.1.0 之前 |
| 2 | `Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/HotkeyTable.swift` 第 117–123 行 `UserConfig.directory` = `~/Library/Application Support/Switcher`（HotkeyTable.defaultFileURL / MIDIMapTable.defaultFileURL 与两处注释也写着它） | 代码名 | Finder：帮助 → 打开诊断文件夹 打开的就是它下面的 Diagnostics/；hotkeys.json / midi.json / LastSession 都在这里 | W2-C | App 侧跟着它的：`App/Sources/Show/ShowDocuments.swift` `autosaveURL`（故意没改，注释里说明了）、`App/Sources/Release/CrashDiagnostics.swift`（用 `UserConfig.directory`，会自动跟）；文档：docs/user/概念.md 第 90 行、快捷键.md 第 25 / 57 行、en/concepts.md 第 98 行、en/shortcuts.md 第 28 / 60 行、docs/release/diagnostics.md 第 7 行。0.1.0 没发布过不用迁移；发布后再改就要搬旧目录 |
| 3 | `Packages/SwitcherControl/Sources/VMixCompat/VMixCompatConfiguration.swift` 第 28 行 `edition = "Switcher"` | 代码名 | 兼容层 XML `<edition>`（Companion 等面板会显示） | W3-D | docs/api/vmix-compat.md 第 52 行、docs/integrations/vmix-compat.md 第 26 行（都注明了是包内默认值）；VMixCompatTests 里若断言了 edition |
| 4 | `Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift` 第 429 行 `RecordSettings.directory` 的注释"App 相对 `~/Movies/Switcher`" | 注释（App 现在是 `~/Movies/PlusMix`） | 读契约的人 | 下一次契约会话顺手改（不是契约变更，只是注释） | docs/CONTRACTS.md 第 183 行 W4-D 已改并注明 |
| 5 | `Samples/tools/make-shows.py` 第 134 行 docstring "App 里挂在 ~/Movies/Switcher/ 下" | 注释 | 读脚本的人 | W4-C（Samples/ 只有 README 在 W4-D 范围内） | — |

不算问题、有意不改的：模块名 `Switcher*`、`switcher-headless` / `frameprobe`、scheme / 工程名、`SwitcherVersion`、Stats 字段、`.switcher.json` 后缀、bundle id `com.plusmix.switcher`、
Stream Deck 插件的 UUID / 目录名 / npm 包名、App 的 MIDI 锚客户端名与窗口 autosave 名（用户看不到）。

## 只是注释 / 说明文字里的旧产物名（不影响用户，顺手改就行）

`THIRD_PARTY/NDI/SOURCE.md` 第 6 行、`THIRD_PARTY/NDI/NOTICE.md` 第 7 行、`THIRD_PARTY/Sparkle/SOURCE.md` 第 7 行（W4-B）、`CameraExtension/README.md` 第 7 行（G5 / W3-C）、
`Packages/SwitcherOutputs/Sources/VirtualCamera/SystemExtensionInstaller.swift` 第 12 行与 `SwitcherVirtualCamera.swift` 第 4 行（W3-C）里写的 `Switcher.app/…`，现在是 `PlusMix.app/…`。
`docs/checklists/G3.md` / `G4.md` 是历史清单，不改。
