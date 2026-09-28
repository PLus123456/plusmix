> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# VF4 截图结论核对（R1 / R4 / R6）

核对人：VF4（截图侧）。
方法：
- 逐张用 Read 看原图 figures/fig-NNN.png（文件扩展名是 png，内容其实是 JPEG）。
- 小字用 sips 裁剪放大，裁图放在 $SP/vf4/。
- 按钮是否发灰、底色有没有变，用 sips 转 BMP 后读像素比较：取框内最暗像素的亮度，0 = 纯黑。

范围：
- R1（图 001–022）、R4（图 068–083、100–103）、R6（图 104–123）的 A 节，以及 C / D 节"参考行为"列里引到的图。
- 旁证图 063、134、149 也看了。

判定：✅ 与图一致 / ⚠️ 部分不一致 / ❌ 与图不符 / ❓ 看不清。"附注"表示结论没错，但有该补进正式文档的内容。

总体：
- 三份报告的菜单清单、字段、数值几乎全部对得上。
- 真正与图不符的有 2 处，都在 R6：外部菜单齿轮的"按下态"；SRT 的 listener。
- 部分不一致 6 处，其余问题集中在"推测写成事实"和"默认值口径"两类。

---

## 1. 菜单 / 列表清单

| 图号 | 报告与编号 | 报告写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 002 | R1 A1 | Settings ▾ 菜单 16 项，Display → About，顺序与设置窗左侧导航一致 | ✅ | 16 项名称、顺序逐一对上，与图 003 导航同序 |
| 002 | R1 A1 | 无分隔线；行距均匀 22 px；无勾、灰项、▸；左侧图标栏空；左缘对齐 Settings 按钮；向下展开；右半截被切 | ✅ | Display 行 y≈69、About 行 y≈399，(399−69)/15 = 22 px；无分隔线；菜单左缘 x≈1505，正是 Settings 按钮左缘；"Outputs / NDI /"和"External Output"的末尾被截图右缘切掉 |
| 002 | R1 A1、F | "?"变蓝是悬停态 | ✅ 附注 | "?"底色 RGB(59,93,132)，图 001 常态是 (56,64,71)；指针尖端落在标题栏和工具条交界处，悬停的解释成立。报告没写的一点：菜单打开时，Settings 分体按钮（主体 + ▾）整体变成浅蓝灰 (61,70,87)，这是"菜单打开态"，和 External 齿轮的表现不同（见 §3） |
| 068 | R4 A1 #3 | PGM 齿轮菜单："Input Settings"（粗体）/ 分隔线 / ✓"Output" | ✅ | 一致。菜单向下开，右缘对齐齿轮（报告没写方向）。"粗体即默认项"是按 Windows 惯例推断的，见 §4 |
| 074 | R4 A3 | Presets 小箭头菜单：Open / Save / Clear / 分隔线 / Reset | ✅ | 一致；菜单从 Presets 主按钮左缘向下展开 |
| 076 | R4 A3 | "+"菜单：Gaussian Blur / LUT / Alpha Mask，无分隔线 | ✅ | 一致；菜单从"+"按钮左缘向下展开 |
| 078 | R4 A3 | 层下拉：Main（选中）+ 1–10，共 11 项 | ✅ | 一致，没有滚动条 |
| 080 | R4 A3 | 每层输入下拉：None（选中）、1 Blank；只列其他输入，不含自己 | ✅ 附注 | 列表确实只有 None 和 1 Blank，本窗是 2 号，没有"2 Blank"。但整个节目只有 2 路输入，"排除自己"是从这一个例子推出的规则，是否还排除别的看不出。写进文档时注明"从 2 路输入的样本看" |
| 082 | R4 A3 | 触发事件 17 项（逐项列名） | ✅ | 17 项名称、顺序逐一对上；无分隔线；列表没有滚动条，是完整清单 |
| 083 | R4 A3 | "Select Function"小窗：分类 All … Replay（Transition 绿底）；右上搜索框；Fade 高亮 | ✅ | 一致。Replay 只露出半行；"搜索框"是列表上方一个没有标签的文本框，这是推断，但合理 |
| 102 | R4 A3 | PTZ Device Type 10 项 | ✅ | 10 项名称、顺序一致，没有滚动条 |
| 107 | R6 A2 | Driver 列表 AcousticaARA … DeHum2，有滚动条，在对话框底边截断 | ✅ | 能看到的 9 项一致，右侧有竖滚动条；截图下缘就是对话框下缘 |
| 118 | R6 A3 | Output 下拉：Output 1（选中）/ 2 / 3 / 4 | ✅ 附注 | 4 项一致。但 118 是在**页签 2** 下展开的（页签 2 绿底、左边有 ☐ Enabled），A3 那句"中间下拉 Output 1 ▾（图 111）。展开后（图 118）"读起来像是页签 1。页签 1 的下拉没展开过，两套来源表相同是推断 |
| 119 | R6 A4 | 一级菜单：Output 2▸ / Output 3▸ / Output 4▸ / SRT / Output / NDI / SRT Settings / External Output Settings；无分隔线、无勾；没有 Output 1 | ✅ | 一致。菜单项用单数"Output / NDI / SRT Settings"，设置页名用复数"Outputs / NDI / SRT"，R6 两处都照原样写了，没写错 |
| 120 | R6 A4 | Output 2▸：✓Output / Preview / MultiView / MultiView2 / Replay / Mix1 / Input1 / Input2 | ✅ | 一致 |
| 121 | R6 A4 | Output 3▸ 截断在 Input1 | ✅ | Input1 是最后一个完整项，下面只露出半行上沿（像 Input2），读不出 |
| 122 | R6 A4 | Output 4▸ 截断在 Mix1 | ✅ | 同上，Mix1 下面的半行读不出 |
| 123 | R6 A4 | SRT▸：1 (Disabled) … 4 (Disabled) 全灰；没悬停时 SRT 右侧没有 ▸ | ✅ | 一致；119–122 里 SRT 行都没有 ▸，123 悬停时才出现 |
| 063 | R6 A4（旁证） | 外部菜单的来源表与 Fullscreen ▸ Display 1 ▸ 是同一张 | ✅ | 063 的 Display 1▸ 也是 ✓Output / Preview / MultiView / MultiView2 / Replay / Mix1 / Input1 / Input2，名称和顺序都相同 |
| 134 | R6-M11（旁证） | 多路录制窗有自己的 Start | ✅ | 右上有一个大按钮"Start"；表里列出 Output 1–4 |
| 149 | R4 A1 #4（旁证） | 触发器汇总窗多一列 Source Input，底部有"Go To Input Settings" | ✅ | 一致（表是空的，按钮是灰的） |

## 2. 页面字段与默认值

| 图号 | 报告与编号 | 报告写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 003 | R1 A3 #1 | Theme（名字读不清）；Preview 橙、Output 绿；Master Frame Rate = NTSC 59.94p；Output Size = 2560x1440；Output Aspect Ratio = Widescreen（字灰）；Fullscreen 1 选中；Display = 2；Position ☐ + 4 个灰框；Hide Cursor ☐ / On Top ☐ / Minimise ☐（灰）；Input Size = 208x156 | ✅ | 全部对上（主题名见 §4a） |
| 004 | R1 A3 #2 | 表头 Source / Overlays / Description；Fullscreen ①② 来源 Output；Output ①–④ 来源 Output，NDI ① On、②–④ Off，每行一个齿轮，叠加 All On ▾；说明 ① Record / Stream / External，②–④ External 2/3/4；Additional NDI 两行都是 Off；MultiView 1/2、5 个布局块、Customise Layout | ✅ | 全部对上。来源下拉里的"Output"是灰字，这个界面的下拉值普遍偏灰，不能据此判断禁用 |
| 005 | R1 A3 #3 | ☑"Display confirmation for Record, External, Stream and MultiCorder buttons"；☐ Input Close 确认 | ✅ | 一致：录制 / 外部 / 推流 / 多路录制确认这一项默认勾上 |
| 005 | R1 A3 #3 | Transition Display 六项全勾；QuickPlay / FTB / Overlay / T-Bar 字灰，另两项字黑；"Transitions 2-"标签被下一个勾选框压住 | ✅ | 一致 |
| 005 | R1 A3 #3 | QuickPlay Transition = Fade，Duration = 500 Milliseconds；Fade To Black = 500 Milliseconds | ✅ | 一致 |
| 005 | R1 A3 #3 | 启动类 6 项、媒体类 3 项、VISCA、T-Bar 触发、自家控制台（标签截断）、Plug And Play、Save Data Sources 的勾选状态 | ✅ | 逐项对上 |
| 009–012 | R1 A3 #7 | 4 个分页，第 1 项只在第 1 页勾；Use Streaming / Display Settings 都勾；Frame Rate 两列都是 NTSC 59.94p（右列灰）；Output Size 1280x720（灰）/ 2560x1440（灰）；Device / Port / Audio Device / Audio Channels = Master / Alpha 全灰；Audio Delay = 0 + 说明 | ✅ | 全部对上；四张图只差分页和第一项勾选 |
| 013 | R1 A3 #8 | 7 个勾选；Default Input Audio Delay = 0 ms；Gap Handling = Drop；PFL ☐、Meters Pre-Fader ☐；Voice Shortcuts：Enabled ☐、SystemMicrophone、Confidence 90 %、Test | ✅ | 全部对上；页上确实没有采样率和缓冲设置 |
| 014 | R1 A3 #9 | Master / Headphones = 系统默认播放设备 + 1 + 2；A–G = None + 1 + 2；Default Bus = Master；☐ Always show all Bus buttons | ✅ | 全部对上 |
| 015 | R1 A3 #10 | ☑ Enabled、Port 8088；网址（超链接）+ 提示；☐ Telestrator；Video Source = Output 2；H264 2mbps；☑ Hardware Encoder；admin / 密码空；免登录 5 项全勾 + 滚动条；☑ 本机免登录；☐ 增强安全；☐ LAN only；TCP API ☑ Enabled、☐ LAN only | ✅ | 全部对上 |
| 016 | R1 A3 #11 | 网页 tally 地址（只读）；Tally Lights LLC / metaSETZ 说明；Radio-Far ☐；Arduino 表 1–6 行为 2/3 … 12/13，7 行起 0/0；三个按钮 | ✅ | 全部对上；第 11 行被截 |
| 021 | R1 A3 #16 | 版本、注册码框、Version / Expiry / 7680x4320 / 1000 / 1000 / Features；☐ 启动时检查更新；Change Registration Key；三个链接；NDI® 商标声明一行；Send Support Report | ✅ 附注 | 全部对上：三个链接分别是许可协议、隐私政策、开源许可，NDI® 注册商标声明在左下单独一行。补一点：**"Send Support Report"的字是灰的**（最暗像素 93，旁边的 Change Registration Key 是 0），截图时可能不可用，报告没提 |
| 022 | R1 A2 | 标题"<产品名> Advanced Settings"；问号图标；是(Y) / 否(N) | ✅ | 一致 |
| 069 | R4 A3 General | 页头 Blank + 灰色 Change；Name；Aspect Ratio = Source；Category 7 色；Deinterlace Blend ☐ / Sharpen ☐（灰）/ Mirror ☐（灰）/ Flatten Layers ☐；mix audio ☑ / Play ☑ / Restart ☐ / Pause ☑；Mouse Click Action = Preview；只读 Widescreen / 32x32 / 59.94p / None；Audio Settings、Create Virtual Input | ✅ | 全部对上。Sharpen、Mirror 的字（40 / 64）和同一列的 Deinterlace Blend、Flatten Layers（0）对比明显，确实是禁用 |
| 069 | R4 A2 | 每路一个独立窗口，标题 Input: <编号> <名字>，**有最小化 / 最大化 / 关闭** | ⚠️ | 标题对，但**最小化按钮是灰的**（最暗像素 194；最大化和关闭都接近纯黑），输入设置窗不能最小化。对照：音频设置窗（104）灰的是最大化，R6 写对了 |
| 070 | R4 A3 | 没有亮度 / 对比度 / 色相 / Gamma；R/G/B 为 0、滑块居中；Saturation 0 在约 1/5 处；Auto White Balance、Reset（灰）；Black 0 / White 255；Auto（灰）、0-255、16-235；Alpha 255；两个勾选；滑杆左边有数值框 | ✅ | 核实过：页上没有 Brightness / Contrast / Hue / Gamma。Saturation 滑块实测在轨道约 21 % 处 |
| 071 | R4 A3 | Colour Key ☐ + 空色块 + 吸管 + 调色板；色度键框整个灰掉；右侧 R/G/B"都在 0"；亮度键框可用，Luma Key（0），Key/Fill Input = None | ✅ 附注 | 控件和灰态一致。"都在 0"和"Luma Key（0）"只是滑块在最左：这一页的滑杆**没有数值框**，图上看不到数值 |
| 072 / 073 | R4 A3、F | Display 不是菜单：点一下，文字变成"Display: Colour Bars"，三组变成 R/G/B 竖条，数值不变 | ✅ 附注 | 核实过：Display 按钮没有 ▾（旁边的 Presets 有）。073 里指针停在按钮上，没有任何弹出层；按钮文字变了，三组变成竖条，数值 0/0/0、0/0/0、1/1/1 不变。只看到 Wheels→Bars 这一次，能不能切回、有没有第三种状态看不出（报告 F 已注明） |
| 072 | R4 A3 | ON（绿）、Display 宽按钮、Presets 分体（字灰）；Lift / Gamma / Gain 各有色轮 + 竖条 + 复位图标 + 三个数；Hue、Sat 各带复位；Basic Auto Correct | ✅ | 一致 |
| 077 | R4 A3 | 层下拉 Main + Copy + Paste；左列 Zoom / Zoom X / Zoom Y / Pan X / Pan Y / Rotate 每行"滑杆 + 数值框 + Reset"，Rotate 带 Z 按钮，下面有 90 按钮；右列 Crop 0 / 0 / 2560 / 1440 + Reset All | ✅ | 一致。右列 Crop 四行只有数值框，**没有**单独的 Reset；A 节没说有，这里没错，C 表的问题见本节 R4-M11 那行 |
| 079 | R4 A3 | 10 行（编号 / 全勾 / None / Edit 灰）；版式库 6 个 + 滚动条；Import / Export / Add / Remove | ✅ | 6 个版式的描述逐一对上 |
| 081 | R4 A3 | 7 列表头；▲▼；编辑行 OnCompletion / Fade / Preview / 500 / 0；第二行 Mix = 1；右侧竖排 Add / Edit / Delete；没有 Value 框；没有实时画面 | ✅ | 一致 |
| 100 | R4 A3 | Arduino：COM Port = None、Tally Number = 1、Status = Disabled（蓝字）；Other Tally Lights 一句说明；没有画面区 | ✅ | 一致 |
| 101 | R4 A3 | Device Type = None；Connect、3×3 方向键、Zoom ± 和竖滑杆、Speed、Tally ☐ 整块灰；缩略图勾选可用 | ✅ | 一致 |
| 103 | R4 A3 | Delay（灰）：0 frames + Apply（灰）；Filters 空列表 + Properties（灰） | ✅ | 控件一致（"视频延迟"这个说法是推断，见 §4b） |
| 104 | R6 A2 | 最小化 / 最大化（灰）/ 关闭；5 个页签；表头 Post，刻度 1 3 6 9 12 18 24 36 90，底部 -Inf -Inf dBFS；Format 48000 Hz 16 Bit 2 Channels；Gain 在最左、0 dB，带 Reset；AGC ☐；Close | ✅ | 全部对上（实测最大化是灰的，最小化是黑的） |
| 105 / 106 | R6 A2 | 白色空列表 + ▲▼ + "+ −" + Show Editor；Add Plugin 对话框：Driver 空、Plugin 灰、OK / Cancel | ✅ | 一致 |
| 108 | R6 A2 | ☐ Enable EQ、Reset；10 段 31/62/125/250/500/1k/2k/4k/8k/16k；+12db … 0db … -12db；全部为 0 | ✅ | 频点、范围、默认位置全对 |
| 109 | R6 A2 | ☐ Enable Compressor；Ratio 在最左，1:1，带 Reset；Threshold 约 80 % 处，−18 dB，带 Reset；只有这两个参数 | ✅ | 一致（Threshold 滑块实测在轨道约 81 %） |
| 110 | R6 A2 | ☐ Enable Noise Gate；Threshold 在最左，−100 dB，带 Reset；只有阈值 | ✅ | 一致 |
| 111 | R6 A3 | 页签 1 / 2；Output 1 ▾；6 种格式，MP4 选中；WAV File Record；MP4 页各字段与值 | ✅ | 全部对上（路径里的竞品名问题见 §5 末尾） |
| 112–116 | R6 A3 | AVI / WMV / WMV Streaming / FFMPEG / 私有 AVI 各页字段 | ✅ | 逐页对上：WMV 用 FPS 文本框代替 Frame Rate 下拉；WMV Streaming 顶部是 HTTP Port 8080，没有 New File，也没有 Browse |
| 117 | R6 A3 | 选页签 2 会多一个 ☐ Enabled（默认不勾），页签 1 没有；页签 2 也是 MP4 / Output 1 / capture.mp4 | ✅ | 一致：111（页签 1）顶部没有 Enabled，117 / 118（页签 2）有 |
| 111 / 117 | R6 A3 | 默认格式是 MP4 | ✅ | 两个页签都是 MP4 选中（"默认"怎么写见 §4c） |
| 070 / 077 | R4-M11（C 表参考行为） | "每根滑杆都配数值框和单独的 Reset；位置页还有 Copy / Paste / Reset All（070、077）；调色每组有复位图标（072）" | ⚠️ | 070 的滑杆有数值框，但**没有单独的 Reset**：R/G/B + Saturation 共用一个 Reset，黑白拉伸用 Auto / 0-255 / 16-235，Alpha 没有复位。077 右列 Crop 四根**没有 Reset**。071 的滑杆连数值框都没有。072 每组有复位图标 ✅。建议改成"位置页左列每行有数值框 + Reset，其他页多为整组复位" |
| 104–110 | R6-M03（C 表参考行为） | "每页顶部一个 Enable 勾选 + 参数 + 每项 Reset" | ⚠️ | 只有 EQ / Compressor / Noise Gate 三页顶部有 Enable，General（只有 AGC 勾选）和 Plugins 都没有。EQ 只有一个整页 Reset，10 段没有各自的 Reset；Compressor 和 Noise Gate 才是每个参数一个 Reset |
| 004 | R1-G08（D 表） | "一键把全部输入发 NDI" | ⚠️ | 标签是"Cameras / Calls / Audio Inputs"，只包括摄像机、通话、音频输入三类，不是全部输入 |

## 3. 弹出方向

| 图号 | 报告与编号 | 报告写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 119 | R6 A4、R6-M13 | External 齿轮菜单向上弹，底边贴底栏上沿，左边对齐齿轮左边 | ✅ | 菜单下缘 y≈970，正是底栏上沿；菜单左缘 x≈407，正是齿轮按钮左缘 |
| 120–123 | R6 A4 | 子菜单向右展开，顶边对齐悬停的那一行，往下长，盖过底栏和状态行、伸出窗口 | ✅ | Output 2 / 3 / 4 / SRT 行的顶边在 y≈838 / 860 / 882 / 903，对应子菜单的顶边相同。120 的子菜单下缘约 1015，已经盖住状态行（状态行从 y≈1000 开始）。121、122 被截图下缘（即窗口下缘）切断。123 只有 4 项，没被切断，盖住了底栏的 Stream / MultiCorder 按钮 |
| 119 | R6 A4 | "菜单开着时齿轮是按下的高亮态（图 119）" | ❌ | 119 里指针正停在齿轮上，齿轮底色 (57,83,109) 是**悬停态**。120–123 里菜单同样开着，指针已移到菜单项上，齿轮底色 (42,47,57) 和图 001 的常态逐像素相同。参考里没有"菜单打开时齿轮保持按下"这种状态。（对照：Settings ▾ 菜单打开时，Settings 按钮整体变成浅蓝灰，见图 002） |
| 002 | R1 A1 | Settings ▾ 菜单左缘对齐 Settings 按钮，向下展开 | ✅ | 见 §1 |
| 068 / 074 / 076 | R4（报告没写方向，这里补充） | — | 补充 | PGM 齿轮菜单向下开，右缘对齐齿轮。Presets 和"+"菜单向下开，左缘对齐按钮。窗口上半部的菜单都往下开，截到的往上开的只有底栏 External 这一个。底栏 Add Input 和 Stream 的分体箭头画的是 ▴（图 001），推测也往上开，但没截到 |

## 4. 推测与事实

### 4a 图上其实能看出来，报告却标了"推测 / 看不清"

1. R1 F（图 003）：主题名写成"像 Charcoal8 或 Charcoal18"。
   - 放大后，值框里是 9 个字形（C h a r c o a l 8），"Charcoal18"需要 10 个，所以应是 **Charcoal8**。
   - 价值不高，正式文档里仍可只写"深色主题"。
2. R4 F（图 081）：写"Add / Edit / Delete 看不出是不是灰的"。
   - 这三个按钮的字最暗像素在 45–54，和图 017 / 018 里灰掉的 Add（59 / 43）是同一档。
   - 同样字体、可用的按钮（图 069 的 Audio Settings）是 0。
   - 所以可以写成"表是空的时候，这三个按钮是灰的"。
3. R6 F（图 111 / 117 / 118）：写"Profile: 和 Audio: 标签浅灰，看不出是禁用还是样式"。
   - "看不出"这个结论对，可以补一条旁证：同一页的"Filename:"（47）和"Size:"（25）标签也偏灰，而 Filename 明显能编辑。
   - 图 003 同理："Display:"和"Position:"标签偏灰，Display 下拉却显然可用。
   - 结论：这个界面里灰色标签是样式，不代表禁用。判断禁用要看控件本身（底色、箭头、值）是不是灰的。R1 里按"字灰"推测"跟随 / 禁用"的几处（003 的 Output Aspect Ratio、Minimise）也照这个标准复核一遍。

### 4b 推测写成了事实（没标"推测"）

| 报告与编号 | 写成事实的说法 | 图上能证明到哪一步 | 建议 |
|---|---|---|---|
| R1 A3 #3 | Transition Display"控制中间转场列显示哪些元素" | 六个标签和图 001 中间列的元素一一对应（Quick Play、Fade/Merge/Wipe/Fly、FTB、1–4、T-Bar、时钟），但没演示取消勾选后的效果 | 加上"（推测，依据图 001 中间列）" |
| R1-M01 | "点主体开设置窗" | A1 自己标了推测；点主体的结果没截到 | C 表也标推测 |
| R1-M04 | 设置窗"切页不丢改动" | 没演示 | 删掉或标推测 |
| R1-M14 | 快捷键"时长用毫秒" | Duration 列只有"300"，没有单位；毫秒是从 Options 页 QuickPlay 的"Milliseconds"类推的 | 标推测 |
| R1-M19 | External 页第 1 项就是"自家虚拟摄像头" | 标签只写"<产品名> Video / Streaming"；B2 表标了"推测对应"，C 表没标 | 标推测 |
| R1-G02 | Minimise = "主窗口最小化时的行为" | 这个勾选框的字是灰的，含义没有任何提示 | 改成"Minimise（含义不明）" |
| R4 A1 #5、R4-M04、R4-M07 前半、R4-M08 | General 页的 Audio Settings 按钮"另开一个音频设置窗"；"调音台里的齿轮打开的是这一路的音频设置窗"；"音频 EQ / 压缩在音频设置窗里" | 调音台截图里只有 Master 条，截到的也只有 Master 的音频设置窗（104–110）。某一路输入的音频设置窗、Audio Settings 按钮点下去的结果都没截到。R6-M04 把同一件事标成了"推测"，两份报告口径不一 | 统一标"推测（按 Master 同类窗类推）" |
| R4-M07 后半 | "换来源是页头的按钮（069 Change）" | A3 标了"推测是换来源"，C 表没标 | 标推测 |
| R4 A2、R4-M09、R4-G01 | 设置窗下半部"是本路的实时画面"，可以"边调边看" | 本路输入是 Blank，画面区全黑，看不出是不是实时画面；唯一旁证是 PTZ 页"Always show thumbnail in input preview"这句 | 标推测。M09 / G01 是 P1 建议的依据，更要写清楚 |
| R4 A2、R4-M21 | "每路一个独立窗口" | 只截到 2 号这一个窗口；标题带编号只能说明窗口按输入命名 | 标推测 |
| R4 A3 Advanced、R4-M20、R4-G25 | Delay 是"按帧计的**视频**延迟"，"要点 Apply 才生效" | 页上只有"Delay"、"0 frames"和一个灰的"Apply"。单位 frames 能支持"按帧"，"视频"和"点 Apply 才生效"是推断 | 标推测 |
| R4 A1 #3 | "Input Settings（粗体，即默认项）" | 粗体能看到；"默认项"是 Windows 惯例 | 小问题，加"（Windows 惯例）" |
| R4 A3 Tally 旁证 | 图 016 页上有"一类 USB tally 灯"和"一类无线 tally 灯" | 页上写的是"plugged in"和"Radio-Far"，"USB"和"无线"都是推断 | 小问题 |
| R4-M19 | 云台页 Tally 勾选 = "机身 tally 灯" | F 节标了推测，C 表没标 | 小问题 |
| R4-G11 | Create Virtual Input = "同源副本输入（同一个来源，各自一套设置）" | 只有这个按钮，点下去的行为没截到 | 标推测 |
| R6 A5 | "**Output 1–4 是四条输出通道**：每条选一个源，可带或不带叠加，可开 NDI / SRT。录制、外部设备、外部菜单的 Output 2–4 都指向这些通道" | 004 能证明每条通道有 Source、NDI、叠加、说明四列；118 录制的来源是 Output 1–4；120–122 外部菜单按 Output 2–4 选源。但有两点没有直接图证：一是 **SRT 和 Output n 的对应关系**（123 只写了"1–4 (Disabled)"）；二是 **009–012 的外部设备取哪条通道**（页上没有来源项，只能靠 004 说明列"External 2/3/4"推出来） | 加粗的结论改标推测，SRT 那半句单独标推测 |
| R6 A5 | 013 的 Solo Mode / Meters Pre-Fader"对应 Master 条的监听，以及音频设置窗表头的 Post" | 两处都在图上，但它们之间的对应关系没演示 | 标推测 |
| R6-M01 | 音频设置窗是"非模态"的 | A2 标了推测，C 表没标 | 标推测 |
| R6-M02 | 页签里勾上 Enable"就作用到声音上" | Enable 一个都没勾，没演示 | 小问题 |
| R6-M05 | General 页的 Gain"和推子分开" | Gain 0 dB 在最左，Master 推子在顶部附近，看得出不是同一个刻度；但是否联动没演示 | 小问题，标推测 |
| R6-M07、R6-M11 | Record 主体按钮"负责起停"，"只起停录制 1 / 2" | A3 自己写了"截图没演示" | C 表标推测 |
| R6-M14 | 外部菜单子项是"单选"，"换来源 = 这一路换画面" | 只看到一个 ✓，没演示换源 | 标推测 |
| R6-M19 | "通道的来源在一处改，所有挂着的输出跟着变" | 没演示 | 标推测 |
| R6-G11 | 录制的音频来源可选"Master / 某条总线" | "Master ▾"下拉没展开过 | 标推测 |
| R6-G16 | H.264 档次有"Baseline / Main / High" | Profile 下拉没展开过，只看到 H264Baseline | 标推测 |
| R6-G25、R6-M18 | External 指"采集卡 SDI / HDMI 输出" | 页上是 External Renderer / Device / Port / Alpha Channel，"SDI / HDMI"是推断 | 小问题 |
| R6-G27 | External 第 1 项是"虚拟视频设备" | A5 标了推测，D 表没标 | 标推测 |
| **R6-G26** | SRT"含被拉流（listener）" | ❌ **图上没有任何依据**。SRT 只出现在 004 的页名、005 的"Start SRT Output"、119 / 123 的"SRT ▸ 1–4 (Disabled)"，哪里都没有 caller / listener 字样 | 从"参考"列删掉，或注明"来自截图以外的资料" |

### 4c 全局问题：报告里的"默认"其实是"截图时的值"

- 这台机器的设置被用户改过，证据有：
  - 图 001 的输入分类被命名成中文；
  - 图 017 有两条用户自己加的快捷键；
  - 015 / 016 显示的是本机局域网地址；
  - 008 的录制目录在用户文档下。
- 所以下面这些地方的"默认"只能说明"截图时是这个值"，不能当出厂默认值写进正式文档：
  - R1 A3 的标题"默认值按截图"；
  - R1-M06"默认勾"、R1-M21 FTB 500 ms；
  - R4 A3 各页；
  - R6-M12"录制默认：MP4、H.264 Baseline、8 Mbps …"。
- 尤其是 R6-M12、R1-M06、R1-M21 这几条会直接拿来和我们的默认值比较。
- 建议正式文档统一写"截图时"。

## 5. 索引与图不符

| 图号 | 来源 | 索引写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 013 | R1 F | "音频采样率、缓冲和控制设置" | 报告说法成立 | 页上没有采样率和缓冲。实际内容是：自动混音、电平表显示、FTB 含音频、默认输入延迟、断音处理、独听模式、语音快捷键 |
| 070 | R4 F | "显示亮度、对比度、饱和度等基础画面调整" | 报告说法成立 | 没有亮度和对比度。实际是 RGB、饱和度、黑白拉伸、Alpha、预乘、601→709 |
| 073 | R4 F | 页面列"Colour Correction → Display 菜单"；描述"切换颜色校正的显示/辅助视图" | 报告说法成立（附注） | 不是菜单，没有弹出层，也没有示波器之类的辅助视图；"切换显示"这半句是对的。R4 F 转述索引原文时写成"切换显示 / 辅助视图"，有小改动 |
| 107 | R6 F | "展开可用音频插件驱动列表" | 报告说法成立 | 条目是具体的插件名，不像驱动（标签叫 Driver，索引照抄了标签） |
| 117 | VF4 新发现 | 页面列"Recording Setup → 输出 2" | ⚠️ | 实际点的是录制配置的页签"2"，来源下拉仍是"Output 1"。同一个对话框里"Output 2"是一个来源选项，索引这样叫会撞名。"会出现什么"列写的"第 2 路录制配置"是对的 |
| 020 | VF4 新发现 | "性能与状态告警设置" | ⚠️ | 页上只有三种提醒：音量过低、FTB 开着、没在录制，没有性能告警。GPU / CPU 告警开关在 Performance 页（图 006） |
| 021 | VF4 新发现 | "查看版本、许可证与系统信息" | ⚠️（小） | 页上有版本、授权信息、功能列表、三个链接、商标声明，没有系统信息（显卡等信息在图 006） |
| 119 | VF4 新发现 | "展开 Output 2/3/4、SRT 1–4 及外部输出设置入口" | ⚠️（小） | 一级菜单里只有"SRT"，1–4 在子菜单里（图 123）。设置入口有两个："Output / NDI / SRT Settings"和"External Output Settings" |
| 118 | VF4 新发现 | "录制设置顶部 Output 1 下拉框" | ⚠️（小） | 是在页签 2 下展开的，索引没说明是第 2 套 |

附带两条（不属于索引问题，写正式文档前要处理）：
- R6 A3 的 MP4 那行把录制路径写成 `…\<竞品名>Storage\capture.mp4`，保留了竞品名。这和 R6 开头说的"带竞品名的标签只写私有 …，不照抄"自相矛盾。正式文档改成 `…\capture.mp4`；R1 对图 008 的处理是对的。
- R4 的 B1 和 C 表多处引用了界面稿路径 `docs/spec/ui-mock/<竞品名> for Mac.dc.html`，路径本身带竞品名。`make lint` 只扫 Packages / App / Tools / CameraExtension / project.yml，拦不住这里。写进正式文档时建议只写"界面稿（docs/spec/ui-mock/ 下）第 n 行"。

## 6. 抽查

每份报告的 A 节各抽 5 条以上，都选前面几节没覆盖的条目。

| 图号 | 报告与编号 | 报告写的 | 判定 | 图上实际 |
|---|---|---|---|---|
| 001 | R1 A1 | 工具条左端 Preset 组（New / Open▾ / Save / Save As▾ / Last），中间是 Fullscreen▾；右端依次是 Pause Inputs（粗体）、Basic、Settings + ▾（一个按钮分两段）、? | ✅ | 一致 |
| 006 | R1 A3 #4 | Graphics Adapter 只读框 + ?；Low Latency ☑、High Input Performance ☑（旁注 3GB+）、NDI 缩略图 ☑、禁止系统更新 ☑、GPU/CPU 提醒 ☑；Display Method = Auto | ✅ | 一致 |
| 007 | R1 A3 #5 | 去隔行 Camera / Video Playback = Blend；FFMPEG 文件类型 8 种；DirectShow 三个下拉 = Auto + Properties；☐ 自家去隔行；Blocked Filter List | ✅ 附注 | 内容一致。位置有小出入："☐ 使用自家去隔行"在 MPEG 2 Video 那一行正下方、MPEG Audio 上面，看起来属于 MPEG 2 解码器，报告把它列在三个下拉之后 |
| 017 | R1 A3 #12 | 页签 All / Keyboard / MIDI / Surface / Joystick + Find；表头 Key / Function / Duration / Input；两行用户数据；六个按钮；▲▼ | ✅ | 一致 |
| 020 | R1 A3 #15 | 三节各一个勾选，全不勾；音量低于 −20 dB 持续 5 秒 | ✅ | 一致 |
| 004–021 | R1 A1 | "图 004–021 是在窗口左侧导航里点的，鼠标都停在导航项上" | ⚠️ | 004–009、013–021 的指针在左侧导航项上；**010–012 的指针在顶部 External 2 / 3 / 4 页签上**，切换的是页内分页，不是左侧导航 |
| 068 | R4 A1 #1 | 卡片底行依次是"1 2 3 4" / "Audio" / 显示器图标 / 齿轮，齿轮在最右 | ✅ | 一致；上面一行是 Close / Quick Play / Cut / Loop（灰） |
| 068 | R4 A1 #2、#3 | PVW 标题条右端有 RGB 色条、画框、齿轮；PGM 标题条只有齿轮 | ✅ | 一致 |
| 068 | R4 A2 | tally 显示在卡片标题条上：1 号绿底（PGM）、2 号橙底（PVW） | ✅ 附注 | 一致。另外 PVW / PGM 监视器的标题条本身也是橙 / 绿，并显示当前是哪一路，所以"只在卡片标题条上"这个说法不完整 |
| 069–103 | R4 A2 | 有画面区的页 9 个，没有的 2 个（081、100）；左下常驻 Copy From...；11 个页签的顺序 | ✅ | 逐张核对，一致 |
| 077 | R4 A3 | Crop X2 = 2560、Y2 = 1440，推测按节目像素计 | ✅ | 两个滑块都在最右，数值是 2560 / 1440；本路 Resolution 是 32x32（069），推测合理 |
| 083 | R4 A3 | 选函数不是弹下拉列表，而是另开一个小窗"Select Function"（带关闭按钮） | ✅ | 一致 |
| 001 | R6 A1 | 调音台：左上图钉、蓝色竖条 OUTPUTS；Master 条（绿色标题，齿轮 / i / 绿喇叭，竖推子 + 窄电平表，耳机图标 + 旋钮）；蓝色竖条 INPUTS；绿色 Audio Mixer 开关；状态行"1440p59.94 EX FPS: 60 …" | ✅ | 一致 |
| 104 | R6 A2 | 页签右边常驻一列电平表，刻度不是线性的 | ✅ | 一致，105–110 每一页都有 |
| 113 | R6 A3 | WMV：Bit Rate 800000（文本框）、FPS 59.94、Quality 90、Codec WMV1、音频编码 WMA 9.2 64 kbps 44 kHz stereo CBR | ✅ | 一致 |
| 114 | R6 A3 | WMV Streaming：HTTP Port 8080 代替文件名，没有 New File | ✅ | 一致（也没有 Browse） |
| 115 | R6 A3 | FFMPEG：capture.ts；Codec MPEG-2；Format Transport Stream (.ts)；Video Quality 8M；Audio Quality 384k | ✅ | 一致 |
| 008 | R6 A5 | Filename Format 示例写成"28 九月 2026 - 07-05-35 下午" | ⚠️（小） | 图上示例整行是"Example - 28 九月 2026 - 07-05-35 下午"。开头的"Example"正是 {0} 的位置，恰好支持 R6 自己"{0} = Filename 里的名字"的推测，引用时不该截掉 |

## 7. 统计与需要改的条目清单

### 统计

逐条判定（§1、§2、§3、§6）：

| 节 | 条数 | ✅（其中附注） | ⚠️ | ❌ | ❓ |
|---|---|---|---|---|---|
| §1 菜单 / 列表 | 21 | 21（3） | 0 | 0 | 0 |
| §2 字段与默认值 | 37 | 33（3） | 4 | 0 | 0 |
| §3 弹出方向 | 4（另有 1 条补充） | 3 | 0 | 1 | 0 |
| §6 抽查 | 18 | 16（2） | 2 | 0 | 0 |
| 合计 | 80 | 73 | 6 | 1 | 0 |

其他几节：
- §4b"推测写成事实"共 28 条：R1 6 条、R4 9 条、R6 13 条。其中 R6-G26（listener）完全没有图证，算 ❌。
- §4a"其实看得出来"3 条。
- §5 索引：报告指出的 013 / 070 / 073 三处（外加 R6 的 107）全部属实；新发现 5 处（117、020、021、119、118）。
- 按报告分，与图不符（❌）：R1 0 处，R4 0 处，R6 2 处。

### 需要改的条目（按优先级）

**必须改（与图不符）**
1. R6 A4：删掉"菜单开着时齿轮是按下的高亮态（图 119）"，改成："图 119 的齿轮发蓝是指针悬停；菜单打开期间齿轮保持常态（图 120–123）"。
2. R6-G26：删掉"含被拉流（listener）"，截图里没有依据。

**应改（部分不一致）**

3. R4 A2：把"有最小化 / 最大化 / 关闭"改成"最小化是灰的（不可用），可以最大化和关闭"。
4. R4-M11 的参考行为列：改成"位置页左列每行有数值框 + Reset；Colour Adjust 是整组 Reset；Crop 没有 Reset；Colour Key 的滑杆没有数值框"。
5. R6-M03 的参考行为列：改成"EQ / Compressor / Noise Gate 三页顶部有 Enable；EQ 只有一个整页 Reset，Compressor 和 Noise Gate 每个参数一个 Reset；General 和 Plugins 没有 Enable"。
6. R1 A1：把"图 004–021 鼠标都停在导航项上"改成"004–009、013–021 停在导航项上；010–012 停在顶部 External 分页上"。
7. R1-G08：把"一键把全部输入发 NDI"改成"摄像机 / 通话 / 音频输入三类一键发 NDI"。
8. R6 A5（图 008）：示例串补回开头的"Example - "。
9. R6 A3（图 118）：注明是在页签 2 下展开的。
10. R6 A3：录制路径去掉竞品名（见 §5 附带）。

**改标"推测"**（明细见 §4b）

11. R4 的三组：
    - 输入的音频设置窗（A1 #5 / M04 / M07 / M08）；
    - 下半部"本路实时画面"（A2 / M09 / G01）；
    - Advanced 页"视频延迟"（A3 / M20 / G25）。
12. R6 的：
    - A5 的"Output 1–4 是通道"结论（特别是 SRT 那半句），以及 013 与 Post 的对应；
    - M14、M19、G11、G16、G27。
13. R1 的：A3 #3、M01、M04、M14、M19、G02。
14. 全局：正式文档里的"默认"一律写成"截图时的值"（§4c）。

**可补（附注）**
15. 021 的 Send Support Report 是灰的；003 主题名是 Charcoal8；081 的 Add / Edit / Delete 是灰的；灰色标签不等于禁用（§4a 第 3 条）。
16. 007 的"使用自家去隔行"在 MPEG 2 Video 那一行下面；080 的"不含自己"只有一个样本；073 只见过一次切换；068 / 074 / 076 的菜单方向（§3 补充）。
17. 索引新发现的 5 处（117、020、021、119、118），交给维护索引的人改。
