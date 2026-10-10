# 崩溃诊断与诊断包（prompt 71 交付 3；后续方案 §8.1 最小版）

## 崩溃诊断（MetricKit）

- `App/Sources/Release/CrashDiagnostics.swift`：App 一起来（非测试宿主）就 `MXMetricManager.shared.add(subscriber)`；系统在**下次启动**交付上次的崩溃 / 卡死 / CPU / 磁盘异常负载，
  启动时也把 `pastDiagnosticPayloads` 收一遍（按结束时间去重）。
- 落盘：`~/Library/Application Support/PlusMix/Diagnostics/<crash|hang|cpu|disk|diagnostic>-yyyyMMdd-HHmmss.json`（`MXDiagnosticPayload.jsonRepresentation()` 原样，
  含调用栈的 `callStackTree`，未符号化），只留最近 100 份。**不上传任何东西**（后续方案要求"用户同意后上传"，本期只做落盘 + 同意后导出）。
- 符号化：负载里有 `binaryUUID` / `offsetIntoBinaryTextSegment`，配 xcarchive 里的 dSYM（`.build/release/<版本>/PlusMix.xcarchive/dSYMs/`）用 `atos -o PlusMix.app.dSYM/Contents/Resources/DWARF/PlusMix -l <加载地址> <地址>`；
  发布时把 xcarchive（含 dSYM）存好，GitHub Release 草稿里附 release-report.md，dSYM 在 runner 的 artifact 里。
- 系统自己的崩溃报告 `~/Library/Logs/DiagnosticReports/PlusMix*.ips`（前缀 = 可执行名 = PRODUCT_NAME） 也会被诊断包收进 crashes/（最近 20 份）。
- 帮助 → 打开诊断文件夹 直接看目录。

## 诊断包（帮助 → 导出诊断包…；设置 › 更新与诊断 里也有按钮）

1. 对话框说明内容，用户选"包含崩溃诊断与日志"或"只导出设置与统计"——这就是同意；取消就什么都不写。
2. 存储面板选位置（默认 `PlusMix-诊断-yyyyMMdd-HHmm.zip`；zip 里的顶层目录 `PlusMix-diagnostics-<时间>/`）。
3. 主线程收集（`DiagnosticBundle.build`），后台线程写文件与 `log show`，完成后 Finder 里选中 zip。

zip 里（`DiagnosticBundle.write`）：

| 文件 | 内容 | 去掉了什么 |
|---|---|---|
| README.txt | 目录说明（用户语言） | — |
| system.txt | 版本 / 构建号 / bundle id / 签名摘要 / Sparkle 源、macOS、机型、芯片、内存、GPU、显示器、节目格式、输入 / 输出列表、扩展状态、最近一条提示、诊断目录 | — |
| settings.txt | AppSettings 的每个键 | `apiToken` 只写 set / not set |
| stats-latest.jsonl | 导出时最近一秒的 `Stats.jsonLine()`（与 stats.jsonl 同一套字段，铁律 4） | — |
| stats.jsonl | `--stats` 开着时正在写的整份 | — |
| show.switcher.json | 当前节目（`Show.save()` 后过 `ShowRedaction`） | `streamKey` 等键的值 → `<redacted>`；url 查询串里 passphrase / key / token / password / secret / streamid / auth / user / pass / pwd 的值 → `<redacted>`；主机 / 端口 / 路径保留 |
| config/ | hotkeys.json、midi.json（存在的那些） | — |
| crashes/ | MetricKit 负载 + 系统崩溃报告 + INDEX.txt | 只在同意时有内容；负载里有二进制路径与调用栈，无节目内容 |
| log.txt | `log show --last 120m --style compact --info --predicate 'process == "PlusMix" OR process == "com.plusmix.switcher.camera-extension"'`（App 进程名 = 可执行名 = PRODUCT_NAME；扩展进程名 = 它的 bundle id） | 只在同意时有；可能含文件路径与设备名（对话框里说了） |

`ShowRedaction` 在 JSON 层做、不依赖 Show 的字段名（新加的密钥字段只要名字含 key / token / password 之类就会被盖掉——见 `secretKeys`；不含的话在这里加）。
测试：App/Tests/ReleaseTests.swift R7（整包扫描无密钥）、R8（去密钥规则）、R9（落盘 / 列表 / prune）。

## 没做的（后续方案 §8.1 剩下的）

- 上传 / 遥测：默认关，本期没有任何网络上报；以后做要先有隐私声明与开关。
- 自己的符号化：需要把 dSYM 随发布归档保存并写 atos 脚本，等有第一份真崩溃再做。
