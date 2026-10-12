# W5-O（prompt 112）改了的 App 行为：手册 / 兼容层文档里对应的警告与绕法可以删了

归属会话 / 分支：W4-C3（prompt 109，`w4-docs-3`）
发现于：W5-O（prompt 112，分支 `w5-app-followups`）——每做完一项在这里补一条；做法与用例见 reports/w5-app-followups.md §1 / §2
严重级：S3（文档与实现对不上：手册还在警告已经修掉的行为）

每条：改了什么（提交号）→ 手册里哪几处要改（路径:行号按 main 22ff4d9）。

## 1. 外部显示 Esc 只关不删；设置页按钮改名"删除这一路"（S2，提交 03f4d25）

- 现在：外部显示窗口里按 Esc = 这一路 `enabled = false`（窗口收起，显示器 / 来源配置留着），与路由菜单里这块屏的"关闭"同一条命令；再点源按原配置开回来。
  设置 › 外部显示 每路底下的按钮从"关闭这路 / Close"改成 **"删除这一路 / Remove This Output"**（做的仍是删，与录制页同字、与路由菜单"删除 n …"同口径，都不问）；只关用这一节顶上的"启用"开关。
- 手册：`docs/user/输出.md:165`（"最后是'关闭这路'按钮——它删掉这一路和它的设置……"→ 按钮名改"删除这一路"，警告可删）、`docs/user/输出.md:169`（"在外部显示窗口里按 Esc 也是删掉这一路"→ 改回"Esc 关闭这一路（配置留着）"）；
  英文 `docs/user/en/outputs.md:168`、`:173` 同。G4 / G7 清单写的"Esc 关闭窗口"现在对了（清单归检查点，不用改）。

## 2. 设置页只写自己改的键，启动参数不再被存成本机设置（S2，提交 03f4d25）

- 现在：常规 / 音频设备 / 远程控制 / 高级 页（以及 Tally 页）改一项只写那一项的键；`--no-api` / `--api-listen` / `--api-token` / `--audio-device` / `--record-min-free-mb` /
  `--record-fallback` / `--tally-port` 带进来的值只管这一次运行、不再顺手存下。监听地址 host:port 是一个键：只改了一半（例如远程控制页只换"仅本机 / 允许局域网"）时另一半按本机存的。
  导入设置 / 恢复默认照旧（它们本来就不看启动参数）。
- 手册：`docs/user/设置.md:113` 那句加粗的警告（"但这次运行里在设置窗改了……也会一起存下——带着启动参数跑的时候别改这几页"）删掉，改成"启动参数只管这一次运行，设置窗里改的项照常存"；
  英文 `docs/user/en/settings.md:113` 同。若别处写了 `defaults delete com.plusmix.switcher <键>` 这个绕法（KNOWN_ISSUES 那行的绕法列），手册里也一并删。

## 7. 兼容层 X51：31 个上游真有的函数名回 501（提交 18d5b45）

- 现在：ActivatorRefresh、AudioChannelMatrixApplyPreset、AudioMixerShowHide、StreamingSetKey / URL / Username / Password、ChangeCountdown、SuspendCountdown、ResumeRender、
  AutoPause / AutoPlay / AutoPlayFirst / AutoPlayNext / AutoRestart 一族 12 个、ColourCorrectionAuto / Reset、MoveMultiViewOverlay、NDISelectSourceByName / ByIndex、
  NDIStartRecording / NDIStopRecording、OpenPreset、LastPreset 回 `501 NotImplemented: …`（精确名字，没加前缀族：NDIAnything 这类编出来的名字照旧 400）。
- 文档：`docs/integrations/vmix-compat.md:132` 那句"注意：另有 31 个……现在也被当成'不认识'返回 400，按上面的定义应返回 501"删掉；覆盖表若按"已知未实现 = 501"列数，31 个归进 501 那一栏（169 → 200）。
