# 会话报告：界面对照调研（UIA，分支 claude/vmix-28-guide-menu-ui-c83cd1）

用户 2026-09-28 直接指派，没有 prompt 文件。原话要点：用户在另一台电脑上按竞品 28 版逐项截图并做了索引（/Users/plus/plusmix/vmix-28-guide/）；先研究好菜单逻辑、看怎么改，再看还有哪些功能没加上；另外做目视检查——中间那块丑、没对齐，下边有个按钮的菜单超出边框——都要记录在案；可以多派 agent。基线 c836cce，只写文档、不改代码。

## 1. 做了什么

- **调研**（18 个 agent）：
  - 8 个按截图章节分区对照（R1–R7，其中主界面分 R3a / R3b）：157 张图逐张读，小字裁剪放大；每区同时读我们对应的代码。
  - 1 个不看截图，拿我们自己的 v1 规格和界面稿核对实现（R8）。
  - 1 个做目视检查：在临时拷贝里加巡检脚本，把 App 真跑起来截图、量尺寸，并做了改法原型。
  - 5 个逐条核对前面的结论（代码 2、截图 2、动作目录 1），共 401 条。
  - 3 个汇总：改动总表、功能缺口、待拍板。
  - 本会话自己复核了关键缺陷，写正文和问题单。
- **产出**（全在 docs/ui-study/，入口是 README.md）：
  - 01 菜单逻辑：6 条总规则、为什么差这么多（W2-B 留给 W3-E 的一批入口没进 W3-E 的 prompt）、逐区改法、菜单栏重排。
  - 01a 改动总表：130 条统一改动，其中 P0 8 条；另有有意保留的差异 30 行、报告间分歧 28 处、契约提案候选 12 个。
  - 02 功能缺口：缺陷 63 条；v1 缺口 14 条；建议补进规格的 55 条；后续方案已有章节的 22 组；不做的 38 行；动作目录对照。
  - 03 目视检查：两处点名问题的根因、量化、改法与原型截图，外加 32 条其它目视问题。
  - 04 待拍板：68 条待定问题。
  - 05 落地拆分：先止血、再改骨架、契约批了再做的三波工作包。
  - 附录：9 份区域原始报告、5 份核对记录、目视检查原始记录与弹出物几何。
  - img：17 张我们 App 的改前 / 原型截图。
- **问题单**：reports/issues/UIA-*.md 共 14 张，按归属会话归并。
- **归属表**：docs/OWNERSHIP.md 加了本会话一行，只登记 docs/ui-study/ 与本文件那一行本身，同 W1-A3 / W3-C2 / W4-D 先例，检查点合并时请复核。

## 2. 测试 ID

本会话不改代码，没有测试标准里的测试 ID。做过的检查：

| 检查 | 结果 |
|---|---|
| `python3 docs/tools/check-links.py docs/ui-study`（make lint 的 check-links） | 通过：23 个 Markdown 的相对链接与锚点都能解析 |
| `make lint BRANCH=claude/vmix-28-guide-menu-ui-c83cd1`（提交后跑） | 全部通过：禁词、版本号 0.1.0 一致、Package.swift 约束、依赖方向（8 个包）、归属（56 个改动文件都在允许范围内）、check-links（全仓 143 个 Markdown）、check-rt-symbols |
| 目视检查实测：转场列可见左沿 | 改前 6 种（8 / 14 / 23–28 / 91 / 103）；原型全部 8…141 |
| 目视检查实测：转场列最小高 | 改前 483 pt，大于 1100×700 时能分到的 476；原型 409 |
| 目视检查实测："外部输出"菜单伸出窗口下沿 | 改前 25 pt（4 种窗口位置），子菜单 228 pt；原型朝上且拍平后在窗口内 |
| 目视检查实测："叠加…"弹出层 | 改前伸出 318 pt（1100×700），内容 320×320 装 400×640 的表单；原型 426×666，在窗口内 |
| 核对 | 401 条：326 属实 / 一致，67 改措辞，7 与图不符（都是截图细节），代码结论 0 条不符 |

## 3. 没做的和原因

- **没改任何代码**。用户要的是先研究、看怎么改；改法已在临时拷贝里做过原型并实测。正式实现应由 App 会话照 03 / 05 重写：巡检脚本要放开 private、要改 bundle id，不适合入库。
- **没写契约提案、没写 prompt 文件**。铁律 1 规定提案要用户先点头；续做 prompt 一般由检查点写（OWNERSHIP 补充规则 6）。候选和写法见 05 §3、§5。
- **竞品截图没入库**。按设计方案 §0，竞品截图属于作品；文中按图号引用用户本机的文件。建议把 vmix-28-guide/ 加进 .gitignore 或挪出仓库目录，.gitignore 归 P0 / 检查点，本会话没动。
- **目视检查没覆盖的**：总线效果 sheet、NDI 真实发现结果、授权后的摄像头 / 屏幕页、录制 / 推流 / 外部显示的运行态、2× 屏截图（03 §4）。

## 4. 对契约的疑问

1. **转场槽 + FTB 时长**（01a 第 5 节 #1、#2，04 Q01、Q08）：TransitionState 加 slots / currentSlot，加 setTransitionSlot / useTransitionSlot，再加一条设 FTB 时长的命令。这是 P0 改版的前提。
2. **转场进行中 setPreview / setProgram 不拦**（04 Q66）：现在转场中改 PVW / PGM 会把正在切的画面换掉。要不要拒收、还是延后生效，是状态机语义，定了要写进 docs/CONTRACTS.md。
3. **文件播放控制命令**（#3，04 Q11）：FileInput 早就有 pause / resume / seek，但契约里没有对应命令。
4. **推流统计字段**（#5，04 Q13）：uptime、disconnects、last_error。按铁律 4 应该进 Stats，而不是让 UI 自己推算。
5. **RecordSettings.container 与 InputSettings.effects 的口径**（#6、#7，04 Q10、Q12）：前一个选 .mp4 没有效果，后一个被 App 拿来装音频效果。
6. 其余候选（输入分类、效果键表、trim、输出通道、整机 CPU、暂停全部输入）见 01a 第 5 节，多数建议先不提。

## 5. 下一个会话需要知道的坑

- **竞品截图里的"默认"只是截图时的值**：那台机器被改过（分类起过名、加过快捷键）。灰字也不代表禁用：中文 Windows 上不含空格的文字会渲染成灰色衬线字。
- **NSButton 是翻转坐标**（isFlipped == true，已写探针确认）：
  - `popUp(at: NSPoint(x: 0, y: bounds.height), in: button)` 是从按钮**下沿**往下弹；
  - NSPopover 在按钮上用 `.maxY` 也是**下沿**，要朝上得用 `.minY`；
  - 菜单朝上的写法：`y: -menu.size.height + 1`；
  - 子菜单仍会往下伸，底栏的菜单别用子菜单。
- **`NSStackView.alignment = .width` 无效**：读回来是 0，等于没有横向对齐。转场列没对齐的主因就是这个。
- **NSPopover 装 NSHostingView 不设 preferredContentSize，会被压成 320×320**，SwiftUI 表单四边被裁。对照：转场"参数…"用 NSHostingController + preferredContentSize，尺寸是对的。
- **想让 App 在隔离环境里跑起来截图**：
  - 环境变量 `XCTestConfigurationFilePath=/dev/null` 让 App 进测试宿主模式：独立 defaults、空节目、不恢复上次节目、退出不自动保存、API 端口 0。
  - bundle id 要另改（窗口位置存在标准 defaults 里），CameraExtension 的 bundle id 要一起改，否则过不了嵌入校验。
  - 直接执行二进制（不要 open），截屏权限才跟着 Claude。
  - 只截自己的窗口（`screencapture -l <windowNumber>`），别截整屏。
  - NSMenu.popUp 是模态的：用 `.common` 模式的 Timer 截图后再 `cancelTracking()`。
- **巡检的副作用**：
  - 打开"添加输入 › NDI"页时，NDI 源发现会触发 macOS 防火墙的"接受传入连接"询问，本次留在屏幕上等用户处理，后几轮关掉了自动发现。
  - 系统里多了 `~/Library/Preferences/com.plusmix.switcher.uitour.plist`，LaunchServices 也登记了草稿区那份临时构建。都无害，可以删掉 / 注销。
  - 草稿区的临时拷贝和截图不入库。
- **lint 的漏洞**：scripts/lint-rules.sh 把 `VMixCompat` 当允许的 token，结果它进了界面文案（Localizable.strings:648），lint 没拦住（X62）。建议 lint 扫 .strings 时不放行这个 token（规则归 P0 / 检查点）。
- **交接落空的模式**：W2-B 写"留给 W3-E"的一批入口，W3-E 的 prompt 没列，就一直没人做（01 §2）。以后检查点写续做 prompt 时，建议对一遍上一轮报告里的"留给 xx"清单。
- **分区报告之间有撞号和口径不一**：两份报告都把契约提案写成 020；对 T-bar 竖放出处的说法也不一致（竖放是 W2-B 的实现选择，不在落地方案 §7 表里）。以 01a / 04 为准。
