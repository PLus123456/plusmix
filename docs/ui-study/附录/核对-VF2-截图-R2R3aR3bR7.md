> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# VF2 截图结论核对（R2 / R3a / R3b / R7）

核对方式：逐张用 Read 看原图（/Users/plus/plusmix/vmix-28-guide/figures/）。字小的地方用 $SP/tools/crop 裁剪放大，裁图放在 $SP/vf2/，文件名是"图号-部位"。像素级比较的做法是：对同一区域裁图，再比 md5。只读，仓库没动。
判定：✅ 与图一致 / ⚠️ 部分不一致 / ❌ 与图不符 / ❓ 图上看不清（本批没有 ❓）。

## 1. 菜单项清单

| 图号 | 报告与编号 | 报告写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 060 | R3a A1、C-M16、D-G10 | Open ▾：最近文件只显示文件名（毕业典礼.vmixZip、last.vmix）/ 分隔线 / Clear；没有勾，也没有灰项 | ✅ | 完全一致（vf2/060-menu.png） |
| 061 | R3a A1、C-M17 | Save As ▾ 只有 Save As Bundle | ✅ | 一致 |
| 062 | R3a A1 | Fullscreen ▾ 只有 Display 1 ▸ | ✅ | 一致 |
| 063 | R3a A1、C-M15、D-G14–16 | Output（✓，默认）/ Preview / MultiView / MultiView2 / Replay / Mix1 / Input1 / Input2，无分隔线，"子菜单是单选" | ⚠️ | 8 项、顺序、无分隔线都对。但图上只有 Output 一个勾，看不出是单选还是可以多选，也看不出是不是"默认"，要标推测 |
| 064 | R3a A4 | 22 项效果（无图标、无子菜单、中间不分隔）+ 分隔线 + 粗体 Duration Milliseconds + 500；当前效果不打勾 | ✅ | 22 项逐项核过，名称和顺序都对；左侧勾选栏全空；数值 500（vf2/064-top.png、064-bot.png） |
| 065 | R3a A4 | 同上，1000 | ✅ | 22 项同序，1000 |
| 066 | R3a A4 | 同上，1000 | ✅ | 22 项同序，1000 |
| 067 | R3a A4 | 同上，1000 | ✅ | 22 项同序，1000 |
| 068 | R3a A2、C-M13 | Input Settings（粗体）/ 分隔线 / Output（✓） | ✅ | 一致（"即默认项"见 §5.2） |
| 119 | R3b A3 | Output 2 ▸ / Output 3 ▸ / Output 4 ▸ / SRT（这张图上没有 ▸）/ Output / NDI / SRT Settings / External Output Settings；无分隔、无勾 | ✅ | 一致（vf2/119-menu.png） |
| 123 | R3b A3、F | 悬停 SRT 后出现 ▸，子菜单是 1–4 (Disabled)，全灰 | ✅ | 一致；子菜单的方向见 §2 |
| 123 | R7 A3、C-M17 | "参考的 SRT 输出放在 Settings › Outputs / NDI / SRT（图 123）" | ⚠️ | 图 123 不是设置页，是底栏 External 齿轮菜单：里面有"SRT ▸"（1–4 Disabled）和一项"Output / NDI / SRT Settings"。Settings › Outputs / NDI / SRT 页是图 004，页面上看不到任何 SRT 字段 |
| 133 | R3b A3、R7 A1、R7 C-M02 | 只有 Start All Streams 一项，下面一条横线 | ✅ | 一致（vf2/133-menu.png） |
| 142 | R3b A4、R3a A4 旁证 | 1 / 2 / 3 / 4 / Stinger 1–4，共 8 项 | ✅ | 一致 |
| 143 | R3b A4 | Fullscreen / PictureInPicture | ✅ | 一致 |
| 145 | R3b A4、D-G02 | 19 项，末项 Cut | ✅ | 19 项。前 18 项和转场菜单前 18 项（Fade 到 RollerDoor）同名同序，第 19 项是 Cut，没有 Stinger。截这张图时 Type 已经切到 PictureInPicture |
| 146 | R3b A5 | 9 项，每项带图标；无分隔、无勾、无灰项 | ✅ | 一致（vf2/146-menu.png） |
| 148 | R3b A5 | Excel/CSV / Google Sheets / JSON / RSS / Text / XML / ZoomChat ─ Import / Export / Remove All | ✅ | 一致 |
| 031 | R2 A3、F、D-G06 | 9 项，无分隔；末项 SRT (Rendezvous) | ✅ | 一致。字体是等宽的，按字宽数出末项共 16 个字符，确实是"Rendezvous"（vf2/031-menu.png） |
| 125 | R7 A3 | 23 项，默认 Custom RTMP Server，不分组、无分隔线 | ✅ | 23 项同名同序（vf2/125-a.png、125-b.png） |
| 002 | R3a A1、C-M21（旁证） | Settings ▾ 下有 16 项 | ✅ | 16 项；菜单右半截超出了主窗口（见 §2） |
| 084 | R3a A4 旁证、C-M07、E2 | 函数表里有 SetTransitionEffect1–4、SetTransitionDuration1–4、QuickPlay、FadeToBlack、SetFader、CutDirect；由此"可见四个按钮……都能单独改、单独触发" | ⚠️ | 这些名字都在。但可见范围里没有"执行第 n 个转场"这类函数：列表带滚动条，Stinger4 以下没截到。"单独触发"没有图证（vf2/084-bottom.png） |

## 2. 弹出方向

| 图号 | 弹出物 | 报告写的 | 判定 | 图上实际（坐标是原图像素） |
|---|---|---|---|---|
| 119 | External 齿轮菜单 | R3b A3、C-M01：左缘和齿轮对齐，向上开，贴着底栏上沿 | ✅ | 菜单左缘 x≈406，等于齿轮按钮左缘；菜单下缘 y≈970，等于按钮上缘；整块在窗口内 |
| 133 | Stream ▴ | R3b A3、C-M01、R7 A1：右缘和 ▴ 对齐，向上开 | ✅ | 菜单 x≈510–682，右缘等于 ▴ 右缘（≈683）；下缘贴着按钮上沿；在窗口内 |
| 146 | ≡ 工具菜单 | R3b A5、C-M01：向上开，在按钮左上方 | ✅ | 菜单右缘 x≈1477，等于 ≡ 按钮左缘，所以整块落在按钮左上方，和按钮水平方向不重叠；下缘贴着底栏上沿；盖住调音台 Master 条的底部（耳机、旋钮那一行）；在窗口内 |
| 064–067 | 转场 ▾ | 任务要求核对；R3a 没写方向 | ✅ | 向下开。菜单上缘 y≈182，紧贴 Fade 按钮下缘（≈181）；左缘和按钮左缘对齐（≈758）；一直伸到 y≈720，盖住 PGM 监视器左边一截。065–067 的形态相同，每张依次下移 41 px |

补充（报告里没写，不计入判定）：
- 123：SRT ▸ 的子菜单从 SRT 项向右开，往下一直伸到 y≈993，压住底栏的 Stream 和 MultiCorder 按钮（仍在窗口内）。所以"底栏弹出物都在底栏上方"只对一级菜单成立。R3b-M01 打算做一个"一律朝上"的帮助函数，子菜单要另外考虑。
- 060 / 061 / 062：顶部的 ▾ 菜单都向下开，左缘对齐主体按钮的左缘，而不是对齐小箭头。
- 068：PGM 齿轮菜单向下开，右缘对齐齿轮，也就是对齐标题条右缘。
- 002（他区）：Settings ▾ 向下开，左缘对齐 Settings 主体；右半截超出了主窗口，截图里"Outputs / NDI /"和"External Output"的尾巴被裁掉了。可见顶部菜单并不保证落在窗口内。
- 建议 R3a 在 A4 补一句"转场 ▾ 向下开，左缘对齐按钮"，C 附 2 做菜单时按这个方向来。

## 3. 默认值

| 图号 | 报告与编号 | 报告写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 023 / 024 | R2 A2、C-M05、R3b A3 | Input Select 打开时选中第一项 Video | ✅ | 023 是刚点完 Add Input 的样子：光标还停在按钮上，按钮有悬停高亮，Video 是绿底。不过只观察到这一次，看不出是"每次都回到 Video"还是"记住上次选的" |
| 024 | R2 A3 | Video contains Alpha Channel、Video is Interlaced 两个复选默认不勾 | ✅ | 一致 |
| 023–047 | R2 A2、C-M08、F | "26 张截图里 Number 全部显示 1" | ⚠️（轻） | Number 框只出现在 023–047 这 25 张里（图 001 上没有这个框），25 张都是 1 |
| 141 | R3b A4、C-M09 | Number 1 / Type Fullscreen / Effect Fade / Effect Duration 500 Milliseconds / Duration 0（Milliseconds）/ Stinger Input None（灰）/ Stinger Cut Point 0 / Alpha 255 | ✅ | 全部一致（vf2/141-fields.png） |
| 124 | R7 A2、M07 | Quality 摘要 "H264 720p 2.5mbps AAC 128kbps"；Use Hardware Encoder 已勾 | ✅ | 一致 |
| 124 对比 128–131 | R7 A2、F | Application 的"FFMPEG"：第 1 路是灰字，第 2–5 路是黑字 | ❌ | 五张图里 Application 框同一区域的裁图 md5 完全相同，字色没有差别：都是灰色衬线字，属于 §5.1 说的字体规律。第 2–5 路变灰的是 Quality 框和 Use Hardware Encoder（vf2/124-app.png、128-app.png） |
| 127 | R7 A5、M08 | Video Bit Rates 2500；1280×720；Audio 128；Baseline / 3.1 / Low Latency HQ / Original；Keyframe Frequency "2 seconds"；Stream Delay 0；Threads 4；Network Buffer 20；三个 CBR 复选都不勾 | ✅ | 全部一致 |
| 128–131 | R7 A2、M09 | Use Stream 1 Quality 默认勾上；Quality 下拉和硬件编码变灰；Destination 是 None；没有 Start n | ✅ | 一致。四张图的 Quality、硬件编码、Application 三块区域像素完全相同 |
| 134 | R7 A7、M14 | Output 1–4 默认都不勾；Show unsupported inputs 不勾 | ✅ | 一致 |
| 134 | R7 A7 | "vMix AVI（默认选中，绿）" | ⚠️ | 图上 vMix AVI 确实是绿底。但索引"按什么"一栏写的是"齿轮 → vMix AVI"，不排除截图前点过这个页签。另外，135–138 选中别的页签时，vMix AVI 的字一直是粗体（vf2/134-tabs.png 到 138-tabs.png），像是"当前生效格式"的标记，报告没提到 |
| 064–067 | R3a A4、C-M02、C 附 2 | "出厂默认 Fade 500 / Merge 1000 / Wipe 1000 / Fly 1000" | ⚠️ | 图上只看得到截图当时的值，是不是出厂值看不出，应写成"截图时的值" |
| 069 | R3b A1、A2（旁证） | Category 七个色块，深灰默认选中；Mouse Click Action = Preview | ✅ | 一致 |
| 125 | R7 A3 | Destination 默认 Custom RTMP Server | ✅ | 一致 |

## 4. 主界面图 001

| 区域 | 报告与编号 | 判定 | 图上实际 |
|---|---|---|---|
| 顶部工具条 | R3a A1 | ✅ | 左组：Preset（没有边框的标签）｜New｜Open ▾｜Save｜Save As ▾｜Last。中间（x≈800–915，在转场列正上方）：Fullscreen ▾。右组：Pause Inputs｜Basic｜Settings ▾｜?。带小箭头的分体按钮正好是 Open、Save As、Fullscreen、Settings 这四个，箭头都朝下 ▾（vf2/001-top-*.png） |
| 粗体字 | R3a A1、F | ✅（可以升级，见 §5.1） | Save As、Pause Inputs、Quick Play 的字确实偏粗 |
| PVW 标题条 | R3a A2、C-M12 | ✅ | 橙底，"2"编号块 + Blank；右端从左到右是红绿蓝三竖条、双层套叠矩形、齿轮（vf2/001-pvw-icons.png） |
| PGM 标题条 | R3a A2 | ✅ | 绿底"1 Blank"，右端只有一个齿轮 |
| 转场列 | R3a A3 | ✅ | 从上到下：Quick Play / Cut / Fade ▾ / Merge ▾ / Wipe ▾ / Fly ▾ / FTB / 1 2 3 4 / 横向 T-bar / 时钟。带 ▾ 的只有四个转场按钮 |
| T-bar | R3a A3 | ✅ | 横放。灰色竖把手停在最左，把手中部有一条和把手等宽的蓝带；右边是白描边、黑芯的轨道 |
| 时钟 | R3a A3、B5 | ✅ | 白框黑底，上行 19:03:45，下行 07:03 下午 |
| 输入条 | R3b A1 | ✅ | 从左到右：灰色空格 / 红底"视觉s" / 绿底"开场视频s" / 橙 / 紫 / 浅蓝 / 深蓝 / 放大镜。右端是绿底带喇叭的"Audio Mixer"。调音台左上角有图钉；调音台只占卡片区右侧 |
| 输入卡片 | R3b A2 | ✅ | 标题条 1 绿、2 橙。第一行：Close｜Quick Play｜Cut｜Loop｜空格。第二行：1｜2｜3｜4｜Audio｜显示器图标｜齿轮。字的亮度分三档：Quick Play 最亮（带空格，属于字体规律）；Close、Cut、1–4 中等；Loop、Audio 最暗，像是禁用，报告的说法成立 |
| 底栏 | R3b A3、R2 A1、R7 A1 | ✅ | 左组：Add Input ▴（分体，没有齿轮）｜⚙ Record｜⚙ External｜⚙ Stream ▴（分体）｜⚙ MultiCorder｜⚙ PlayList。右组：Overlay｜≡｜红黄绿柱状图｜四宫格｜相机｜锁（灰色开锁，到图 157 变成金色合锁）。每个齿轮都是主按钮左边一个独立的小方块；两个 ▴ 都朝上 |
| 底栏 ▴ | R7 A1 | ⚠️ | 报告写"只有 Stream 带 ▴"，但 Add Input 也带 ▴。应改成"带齿轮的几个按钮里只有 Stream 带 ▴" |
| 状态栏 | R3b A10、C-M25 | ✅ | 独立一行：1440p59.94（绿字）｜EX｜FPS: 60｜Render Time: 3 ms｜GPU Mem: 0 %｜CPU vMix: 3 %｜Total: 40 %。报告说图 023 的 FPS 是 85、图 146 的 CPU 6 % / Total 42 %，也都对 |
| 标题栏 | R3a C-M20 | ✅ | "vMix Pro - 28.0.0.42 x64"：产品名 + 版本号 + 架构，没有节目名 |

## 5. 推测与事实

### 5.1 标了推测或说"看不出"，其实图上能坐实或推翻

先说一条贯穿整套截图的规律，下表好几条都靠它回答：在同一种控件字体里，**文字不含空格就渲染成灰色衬线字，含空格就是黑色等宽字**；主界面按钮上则是**含空格的字显得粗、亮**。下面的证据全部逐条对过：
- 024 最近列表 8 条：2 条黑字都含空格（"…Practice Ultra Ver.…"、"Z:\25 KCL 学习资料\…copy.mp4"），6 条灰字都不含。
- 035 最近列表 25 条：末 4 条是黑字，路径都含空格（"Plus's Pictures(London)"、"Plus Chen"）；前 21 条是灰字，都不含（vf2/035-tail.png）。
- 125 目的地 23 项：6 项黑字，加上高亮的 Custom RTMP Server，全都含空格；16 项灰字，全都不含。
- 142："1"到"4"是灰字，"Stinger 1–4"是黑字。151："Stream / SRT""Audio Input""Instant Replay""Web Browser""Video Call"是黑字，其余单个词都是灰字。
- 027：标签"Input:""Resolution:"是灰字，"Frame Rate:""Video Format:""Audio Device:"等是黑字；取值"2560x1440""Default"是灰字，"NTSC 59.94p""Built In Audio"是黑字。
- 030："URL""Buffer""milliseconds"是灰字，"Stream Type""Low Latency Mode"是黑字。038："Colour"和"Transparent"是灰字，其中 Colour 是当前**选中**的那个单选项；"Colour Bars"是黑字。069（他区）："Sharpen""Mirror""Category"也是灰字。
- 041 / 056 / 059：MultiView、Legacy、All、Recent 四个页签是灰字，GT 开头的八个是黑字。在 056 里 MultiView 已被选中，在 059 里已经"加载完成"，这四个仍是灰字。
- 028："PsF""FEIM"是灰字，但它们的复选框和另外三个外观完全一样（vf2/028-checks.png）。
- 主界面按钮：Save As、Pause Inputs、Quick Play、Add Input、Audio Mixer 都含空格，都偏粗；New、Open、Save、Last、Fullscreen、Basic、Settings、Cut、Fade、Merge、Wipe、Fly、FTB、Record、External、Stream、MultiCorder、PlayList、Overlay 都不含空格，都不粗。唯一例外是"Preset"，它是标签，不是按钮。右键菜单用的是另一种字体，不受这条规律影响：068 的"Input Settings"是真粗体，119 的"Output 2"等并不粗。

| 报告与编号 | 报告写的 | 判定 | 图上实际 / 应怎么写 |
|---|---|---|---|
| R2 F（024、035） | 最近列表里的灰字"推测灰 = 文件或盘当前不在" | ❌ | 灰字、黑字和路径里有没有空格一一对应，是字体渲染造成的，和文件在不在无关 |
| R2 F（027）、A3 Camera 行 | "Input:""Resolution:"两个标签是灰的，"推测是禁用态" | ❌ | 同一条字体规律，不能据此说禁用。真正禁用的是 Audio Input、Audio Format 两个灰底下拉框 |
| R2 F（030） | "URL""Buffer"是灰字，"看不出是不是禁用" | ⚠️ | 其实看得出：是字体规律，不是禁用 |
| R2 F（038） | "Colour""Transparent"偏灰，"看不出是不是禁用" | ⚠️ | 其实看得出：被选中的 Colour 也是灰字，所以灰不等于禁用 |
| R2 F（041） | 四个页签是灰字，"推测在懒加载" | ❌ | 056（MultiView 已选中）和 059（已加载完成）里它们仍是灰字；这是字体规律，不是加载状态 |
| R2 A3 NDI 行、D-G05、D-G23、F（028） | "PsF""FEIM"是灰的 / "截图里是灰的" | ⚠️ | 字是灰的，这是字体规律；复选框本身和另外三个外观相同。只能写"字是灰的"，不能暗示不可用 |
| R3b F（151） | 列表里有黑粗、有灰细，"推测是字体渲染差异" | ✅ | 能坐实，"推测"二字可以去掉 |
| R7 F（125、126） | 灰字"推测是字体回退" | ✅ | 能坐实：黑字的 7 项全含空格，灰字的 16 项全不含。R7 A7 FFMPEG 页写的"MPEG-2（灰字）"也是这条规律，不代表禁用 |
| R3a F、A1、A3 | Quick Play、Save As、Pause Inputs 偏粗，"推测只是字体渲染或强调" | ✅ | 能坐实是字体渲染（Add Input、Audio Mixer 也一样粗），"或强调"可以删掉。R3b A2 说"Quick Play 字比别的亮"，原因相同 |
| R7 A5、F | Video Bit Rates 2500，"单位推测 kb/s" | ✅ | 能坐实：124 的摘要写着"2.5mbps … AAC 128kbps"，和 127 的 2500、128 对得上 |
| R7 A7、F | MP4 页的 Video Bit Rate 8"推测 Mb/s"，Audio 384"推测 kb/s" | ✅ | 有旁证：图 111 录制的 MP4 页是同样的 8 和 384，旁边明确写着"Mbps""Kbps" |
| R3b A1 | 输入条最左的灰色空格"推测 = 全部 / 未分类" | ⚠️ | 报告自己说输入条七格和 069 的七个 Category 色块一一对应，而第一块深灰是默认选中的。照这个对应，灰格就是"默认的深灰分类"，和"全部"这个说法对不上。两种说法要二选一（倾向"未分类"，仍标推测） |
| R3a A2 | "Output 是右监视器显示哪路混合的单选，只有一路混合时就只有这一项"（推测） | ⚠️ | 063 的全屏源里已经有"Mix1"，可 068 的菜单里只有 Output，这和"只有一路混合"的前提对不上。应改成"Mix1 存在却没出现在这个菜单里，原因看不出（可能没启用）" |

### 5.2 推测写成了事实，或者事实写错

| 报告与编号 | 报告写的 | 判定 | 图上实际 / 应怎么写 |
|---|---|---|---|
| R2 A2 | "图 024–047 每张鼠标都停在左栏的某一项上" | ❌ | 024 上没有光标；029 的光标在"Local Desktop Capture"页签上；031 的光标在窗口顶部靠右，Stream Type 下拉的右上方 |
| R2 A2、C-M07 | "独立的模态窗口" | ⚠️ | 图上只看得到标题栏和 ×，是不是模态看不出，要标推测 |
| R2 A3 Web Browser 行、C-M15、D-G06 | "最近地址列表"；网页、网络流这几页"都有'最近用过'列表"；"最近地址" | ⚠️ | 043 和 030 的列表都是空的，看不出是不是"最近用过"。030 那一行 A3 自己标了推测，M15、G06 和 Web Browser 行却没标 |
| R2 C-M24 | "音频输入页只有设备和格式（格式是灰的）" | ⚠️ | 040 上还有"Mute in Headphones"复选框，同一份报告的 A3 和 M17 都写了，这里漏了 |
| R2 C-M22 | "截图范围内没有'换来源'的入口（推测要删掉重加）" | ⚠️ | 图 069（他区）输入设置顶部名字条的右端有一个"Change"按钮（灰色，没演示），很可能就是换来源的入口。"要删掉重加"不宜当结论（vf2/069-change.png） |
| R2 C-M13 | "一打开就持续搜索" | ⚠️（轻） | 只有一张图，看到转圈，"持续"看不出来 |
| R3a A3、A4、C-M02 | "按钮上的字 = 当前效果名" | ⚠️ | 截图里没有演示改效果，按钮上的字会不会跟着变看不出。"四个菜单一样、按钮字不一样"只能算旁证，要标推测 |
| R3a A4、A1、C-M03 | 转场菜单是"效果单选列表"；063"子菜单是单选"；C-M03"点主体执行" | ⚠️ | 转场菜单里一个勾都没有，063 也只有一个勾，是不是单选看不出。主体单击的效果 A3 自己标了推测，到 C-M03 写成了事实 |
| R3a C-M04 | "在菜单里键入毫秒" | ⚠️ | A4 和 F 标的是"推测可以键入"，C 节写成了事实 |
| R3a C-M15 | "勾 = 这块屏全屏时显示什么" | ⚠️ | A1、F 标了推测，C 节没标 |
| R3a A2、C-M13 | "Input Settings（粗体，即默认项）" | ⚠️ | 粗体是真的；"默认项"在 F 里标了推测，A2 和 C 节没标 |
| R3a A2、C-M12、E9 | "PVW 齿轮直接打开 PVW 那一路的输入设置" | ⚠️ | 索引对图 069 只写了"预监框右上角齿轮 / 素材卡片右下角齿轮 → General 页"，没说中间有没有菜单；而同款的 PGM 齿轮是先弹菜单的（068）。"直接打开"是推断 |
| R3b A4 | "最小化 / 最大化是灰的" | ❌ | 只有最大化是灰的；最小化按钮"—"是黑色，和 124、139 这些能最小化的窗口一样（vf2/141-title.png、139-title.png） |
| R3b A4、A3 表、C-M07 | "独立模态窗" | ⚠️ | 看不出是不是模态，要标推测 |
| R3b A3 | "统一模式：……右边 ▴ = 向上弹的快捷菜单" | ⚠️（轻） | 只有 Stream 的 ▴ 截到了菜单，Add Input 的 ▴ 没截到 |
| R3b C-M11 | "按分类筛卡片" | ⚠️ | A1 标了推测，C 节写成了事实 |
| R3b D-G26 | "推流'全部开始'及单路起停快捷项（图 133）" | ⚠️（轻） | 图 133 只有 Start All Streams 一项，"单路起停"是推测 |
| R7 A2；A4、C-M10 | 推流设置窗"非模态"；Advanced 是"模态对话框" | ⚠️ | 两者都看不出，要标推测 |
| R7 A7 | "整窗一份格式，切页签 = 所有通道换格式" | ⚠️ | 没有演示。而且 vMix AVI 在 135–138 里始终是粗体，"正在看的页签（绿底）"和"实际生效的格式（粗体）"可能是两回事 |
| R7 A7 | "本机两路 Blank 没进表——被当成不支持的输入藏起来了" | ⚠️ | 唯一的依据是"Show unsupported inputs"没勾，要标推测 |
| R7 A8 | "（切换台层面按顺序把输入切上去）" | ⚠️（轻） | 播放逻辑没有演示，要标推测 |

## 6. 抽查（每份报告 5 条；抽查中发现的问题已并入 §5）

| 报告 | 条目 | 判定 | 依据 |
|---|---|---|---|
| R2 | A3 Video Delay：Output / 2560x1440 / vMix Video Codec / 20 s，估算"1198.804 frames, 20 seconds @ 59.94018 FPS (8429 MB)" | ✅ | 图 034 |
| R2 | A3 Instant Replay：机位 1–8 全是 None；Camera1 / Master；In、Out、Event 三个转场都是 Fade 500；缓冲 1 s | ✅ | 图 032 |
| R2 | A3 Image：最近列表 25 条 | ✅ | 图 035（3 + 18 + 4 = 25） |
| R2 | A3 Local Desktop Capture：Display1 / Display2 / Display2；窗口里有 vMix、vMix 2、vMix 3，长标题截断成"Codex Compute..."；Window Capture Method = Default | ✅ | 图 029 |
| R2 | A3 Video Call：Host a Call；Output 1；Default 720p 1200 Kbps；Master（灰）；复选框文字被截断，后面跟 More Information | ✅ | 图 045 |
| R3a | A1 Open ▾ 无勾无灰；Preset 没有边框 | ✅ | 图 060、001 |
| R3a | A3 时钟两行的格式 | ✅ | 图 001 |
| R3a | A2 PVW 三个图标的顺序 | ✅ | 图 001 |
| R3a | A1 Settings ▾ 共 16 项，含 Shortcuts、Activators、About | ✅ | 图 002 |
| R3a | A4 旁证：图 084 里有 CutDirect / FadeToBlack / QuickPlay / SetFader / SetTransitionDuration1–4 / SetTransitionEffect1–4 / Stinger1–4 | ✅ | 图 084（"单独触发"的问题见 §1） |
| R3b | A6 Overview 的列名和"Fullscreen Dropped: 37224 0 430 (32 ms)"；Refresh / Reset；窗口能最大化 | ✅ | 图 152 |
| R3b | A7 两块瓦片"渐入 / Fade / Preview"和"123 / Fade / 1 Blank"；底部 Web Controller / Edit | ✅ | 图 155 |
| R3b | A8 另存为：默认目录"文档"，文件名"vMix Capture 28 九月 2026 19-38-35.png"，类型 PNG (*.png)；F 说光标停在锁上 | ✅ | 图 156 |
| R3b | A9 锁：图 001 是灰色开锁，图 157 变成金色合锁，界面其他部分没有变化 | ✅ | 图 001、157 |
| R3b | A5 Audio Bus 筛选表：All 到 Zoom、Red 到 Blue、Custom1–6（列表被截断） | ✅ | 图 151 |
| R7 | A4 Advanced：一节 Stream，Username / Password / User Agent FMLE/3.0，OK / Cancel，只有 × | ✅ | 图 126 |
| R7 | A5 Streaming Quality 各项数值，以及单独一节"Settings shared across all streams" | ✅ | 图 127 |
| R7 | A6 Streaming Status：深色文本区（有光标和滚动条）+ View Log Files / Close | ✅ | 图 132 |
| R7 | A7 MP4 页：8 + H264Baseline，硬件编码已勾，Fault Tolerant 不勾，Audio 384；FFMPEG 页 MPEG-2 / .ts / 8M / 384k；AVI、MKV 页是 vMix Video Codec + 齿轮 | ✅ | 图 135–138 |
| R7 | A8 PlayList：New / Delete PlayList；下拉 Default（展开也只有这一项）；Available Inputs 里两个 Blank；> <；▲ ▼；四个复选都不勾；Previous、Next 是灰的 | ✅ | 图 139、140 |

## 7. 统计与需要改的条目清单

§1–§6 共 106 条判定，§2 的"补充"不计。

| 节 | ✅ | ⚠️ | ❌ | ❓ |
|---|---|---|---|---|
| §1 菜单项 | 19 | 3 | 0 | 0 |
| §2 弹出方向 | 4 | 0 | 0 | 0 |
| §3 默认值 | 9 | 3 | 1 | 0 |
| §4 图 001 | 12 | 1 | 0 | 0 |
| §5.1 推测能坐实或推翻 | 5 | 5 | 3 | 0 |
| §5.2 推测写成事实 / 事实写错 | 0 | 19 | 2 | 0 |
| §6 抽查 | 20 | 0 | 0 | 0 |
| 合计 | 69 | 31 | 6 | 0 |

总体结论：必须核的菜单清单全对，包括 22 项转场效果、19 项叠加效果、9 项工具菜单、23 个推流目的地、9 种 Stream Type，弹出方向和图 001 的形态也都对。问题集中在三类：一是把灰字当状态来解读（其实是字体规律），二是"模态 / 默认 / 单选 / 直接打开"这类推断没标推测，三是 3 处事实写错。

### 需要改的条目

**R2**
- ❌ A2 括号里"图 024–047 每张鼠标都停在左栏的某一项上"：删掉，或改成"多数图的光标停在选中项上（024 没有光标，029 停在页签上，031 在窗口顶部靠右）"。
- ❌ F 关于 024、035 灰字的推测：改成"灰字、黑字是字体渲染造成的：文字不含空格就是灰色衬线字，含空格就是黑色等宽字，和文件在不在无关"。
- ❌ F 027 的"推测禁用"、F 041 的"推测懒加载"：删掉，改用上面同一条规律解释。A3 Camera 行只保留"Audio Input、Audio Format 两个下拉灰底（禁用）"。
- ⚠️ F 030、F 038：写明能看出是字体规律（038 里的 Colour 是选中项）。
- ⚠️ A3 NDI 行、D-G05、D-G23、F 028：改成"PsF、FEIM 的字是灰的（字体规律），复选框能不能用看不出"。
- ⚠️ A2 和 C-M07 的"模态"；A3 Web Browser 行、C-M15、D-G06 里网页、网络流的"最近地址 / 最近用过"：标推测。
- ⚠️ C-M24 补上"Mute in Headphones"；C-M22 提一下图 069 的"Change"按钮，"要删掉重加"改成"未确认"。
- ⚠️（轻）A2 的"26 张"改成"25 张（023–047）"；C-M13 的"持续搜索"改成"进页时在搜索（转圈）"。

**R3a**
- ⚠️ A4、C-M02、C 附 2 的"出厂默认"改成"截图时的值"。
- ⚠️ 下面这些统一标推测：A3、A4、C-M02 的"按钮字 = 当前效果"；A4 的"单选"；A1 的"子菜单是单选""（✓，默认）"；C-M03 的"点主体执行"；C-M04 的"键入毫秒"；C-M15 的"勾 = 全屏时显示什么"；A2、C-M13 的"即默认项"；A2、C-M12、E9 的"PVW 齿轮直接打开"（这一条再注明：PGM 的同款齿轮是先弹菜单的，见图 068）。
- ⚠️ A4 旁证和 C-M07 的"单独触发"：图 084 可见部分只有改效果、改时长的函数，没有"执行第 n 个转场"。
- ⚠️ A2 的推测"只有一路混合时就只有 Output"：对照 063 里的 Mix1 改写。
- 可以升级：F 里关于粗体的推测，改成"带空格的按钮字都偏粗，是字体渲染"。
- 建议补充：A4 写明转场 ▾ 向下开、左缘对齐按钮。

**R3b**
- ❌ A4"最小化 / 最大化是灰的"改成"最大化是灰的，最小化可用"。
- ⚠️ A4、A3 表、C-M07 的"模态"，C-M11 的"按分类筛卡片"，D-G26 的"单路起停快捷项"：标推测。
- ⚠️ A3 的"统一模式：▴ = 快捷菜单"：注明只有 Stream 的 ▴ 截到了菜单。
- ⚠️ A1 灰色空格"全部 / 未分类"的推测和"七格一一对应"的说法打架，要二选一。
- 可以升级：F 里关于图 151 的推测能坐实为字体渲染，"推测"可以去掉。
- 建议补充：A3 和 C-M01 注明 SRT ▸ 子菜单（图 123）会向下伸、压住底栏按钮，"一律朝上"只管一级菜单。

**R7**
- ❌ A2 和 F 的"FFMPEG 第 1 路灰、第 2–5 路黑"：删掉，五张图这块区域像素完全相同。
- ⚠️ A3、C-M17 关于 SRT 位置的图号：改成"External 齿轮 › SRT ▸（图 123，1–4 都是 Disabled），设置入口是同一菜单里的 Output / NDI / SRT Settings；Settings 页见图 004，页面上没看到 SRT 字段"。
- ⚠️ A7"vMix AVI 默认选中"改成"打开时停在 vMix AVI 页（索引写了'→ vMix AVI'）；这个页签在其他页的截图里也保持粗体"。
- ⚠️ 下面这些标推测：A7 的"切页签 = 所有通道换格式"和"Blank 被当成不支持的输入藏起来"；A2 的"非模态"；A4、C-M10 的"模态"；A8 的"按顺序把输入切上去"。
- ⚠️ A1"只有 Stream 带 ▴"改成"带齿轮的几个按钮里只有 Stream 带 ▴（Add Input 也有 ▴）"。
- 可以升级：A5 和 F 的 kb/s 用图 124 的摘要坐实；A7 和 F 的 Mb/s 用图 111 作旁证；F 里图 125 的推测用字体规律坐实。
