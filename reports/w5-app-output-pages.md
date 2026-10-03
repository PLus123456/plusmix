# W5-I 输出设置页 —— 报告（prompt 95，分支 w5-app-output-pages）

worktree `.claude/worktrees/w5-app-output-pages-95c271`，桌面端分支 `claude/w5-app-output-pages-95c271`，本地别名 `w5-app-output-pages`（同一提交，`make lint BRANCH=w5-app-output-pages` 用）。
**基线 = main 190fe32（G6 合入后），没有叠在 92 / 93 上**：prompt 写"从 G6 合入后的 main 开"；本会话开工时试过把分支快进到 93 的头（8a13a21，含 92）好拿到 92 的外部显示菜单，
被权限拦下（"改共享资源"），就按 prompt 留在 main 上。92 / 93 / 94 / 96 都在同一片 App 文件上，G7 合并时的接口对不上见 §5 第 1 条。只动了 App/（外加本报告与一张问题单）。

提交：c22a6a9 红灯轮（测试）→ 619132d 实现 → 1cfc783 / 37f8580 两处小修 → 本报告。

## 1. 做了什么

### 1.1 每条交付落在哪

| 交付 | 落点 | 说明 |
|---|---|---|
| 0 输出总览（F8） | `OutputPagesModel.overviewRows` / `openDetail`，`OutputOverviewPage` | 设置窗侧栏第一页（`Tab.overview`，`Tab.allCases.first`）。每个输出一行：种类 / 名字 / 来源 / 开·关 / 状态（录制、推流、NDI、外部显示、虚拟摄像头各用本页同一套文字，读 Stats.encoder / Stats.display）+"详情 ›"；点整行或按钮 = 切到它的页并滚到那一节（`focusedOutput` + ScrollViewReader）。跟录制 1 的 ISO 路跳 ISO 页，自己定格式的录制路跳录制页。 |
| 0 名字框（F9） | `OutputSectionHeader` | 录制 / 推流 / 外部显示 / 多画面 / 虚拟摄像头每一节标题行："推流 1  输出 5 …… 名字 [   ]"，回车或离开输入框 = renameOutput（NDI 页原来就有）。 |
| 1 推流页（L3 / L5–L10 / L12） | `StreamPage` / `StreamDestinationSection` / `StreamAuthSheet`，`OutputPagesModel` 推流一节，`OutputPresets.swift`，`StreamAddress.swift`，`App/Resources/StreamServices.json` | 段名"推流 k"（推流自己的序号）、副标题"输出 n"、名字框；段首"开始 / 停止"开关（开 = startStream，没有地址不让开；关 = 先确认再 stopStream，与底栏同一问、偏好设置里关掉就不问）+ 状态行"推流中 · 5.9 Mb/s · 丢 3 帧 · 重连 1 次"（Stats.encoder 按 output 对号；起不来写原因，W5-B 的重试 / 停用保留）；页顶"全部开始 / 全部停止"（停也先问一次）；"服务"下拉（§1.3）；"质量"下拉（1080p / 720p 两档 + 自定义，§1.2）；"编码详情…"展开区（编码器、分辨率、码率、关键帧按秒"2 s（= 120 帧）"、音频码率、重试间隔最长）；第 2 个起"与推流 1 相同"（勾着时质量和编码详情灰掉）；"鉴权…"（§1.5）；页底"合计上行约 n Mb/s（m 个目的地）"+ 一句"各自编码、各占一份上行"。在推的路：服务 / 地址 / 密钥 / 鉴权 / 质量 / 编码详情 / 删除都锁着，悬停提示"正在推流：停止后可改"（L12 补提示；锁本身是 87 的）。添加目的地一节也有"服务"下拉（固定入口直接填地址框），地址空时不让加（同原来）。 |
| 2 录制页（K4 / K6–K8 / K10、V-15） | `RecordPage` / `RecordOutputSection`，`OutputPagesModel` 录制一节，`RecordDefaults`，`OutputLinkage` | 页顶：录着时"正在录制：改动从下一次开录起生效"（K6，87 的）、在录的路停了才跟的提示、"按底栏「录制」会一起录 n 路：录制、录制 2、ISO 1"（K7）。"文件（全部录制路共用）"一节：目录（中间截断、完整路径在悬停提示里，V-15）+"选择…"、文件名模板、示例、文件格式单选（87）、片段间隔——改的是录制 1 的，其余录制路跟（§1.6）。下面是**录制输出列表**：每一路"录制 k · 输出 n · 名字框"、"参与录制"开关、来源下拉（只列 PGM / 各路输入）、自己的编码（编码器、分辨率、码率、关键帧、音频）、状态、"删除这一路"（在录时灰掉）；最后"添加录制输出"。新建的录制输出（加的路、底栏没有录制输出时加的那一路、空节目自带的那一路）码率按节目格式（K8 / Q30）。 |
| 3 ISO 页（K9 / K10） | `ISOPage`，`OutputPagesModel.isoRows` / `setISORow` / `isoFormatLine` | 页顶"格式 H.264 · 18 Mb/s · .mov（同录制 1）[更改格式…]"+"目录 …（中间截断）[更改目录…]"。表：行 = PGM（录制 1）+ 每路输入，列 = 录（勾选框）/ 名称 / 状态 / 丢帧 / 目录（读 Stats.encoder；时长等 022 / 101）。PGM 行取消 = 录制 1 不参与 = 只录 ISO；输入行勾 / 取消 = 加 / 删这路的 ISO 录制（同原来）；录着的行锁住。纯音频 / 图片输入默认收起，"显示全部输入（另有 … 路）"展开（已经有 ISO 路的照列）。页底磁盘估算照旧。 |
| 4 外部显示页（M2 / M5）、多画面格子（M7） | `ExternalDisplayPage` / `ExternalOutputSection`，`ExternalDisplayRouting`；`MultiviewPage` / `MultiviewCellRow` | 外部显示页最上面"每块屏送什么"：每块屏一个单选（关闭 / PGM / PVW / 多画面 / 各输入），**读写的就是快照里的外部显示输出，规则与 92 的菜单逐条相同**（每块屏的"那一路" = 开着的优先、否则编号最小；选源 = 那一路换源并打开、同屏别的开着的路关掉；没有那一路 = addOutput"显示器 · 源"；关闭 = 只关不删）。下面每一路的细项（名字框、开关、显示器、来源、退回主屏、状态、删除）照旧。原来的"打开外部显示"一节由每屏单选代替（`addExternalDisplay` 模型接口留着，老用例在用）。多画面页：预设 / 安全框 / 电平表照旧；"格子"一节没有自定义格子时给"从当前预设转成自定义"（`MultiviewLayout.placements` 抄出当前预设每格的位置）和"添加格子"；有自定义格子时逐格：来源（PGM / PVW / 各输入，多画面不能套自己）+ x / y / 宽 / 高（0–1，钳到画面内）+ 删除，末尾"添加格子 / 清掉自定义格子"。 |
| 底栏 | `BottomBarView.recordPressed`（改 6 行） | 只起参与录制的路；一路都不参与时提示"没有参与录制的路…"。没有录制输出时加的那一路按节目格式给码率。 |

### 1.2 新建默认值（Q30，契约默认值不动）

- 录制（`RecordDefaults`）：视频码率 1080p30 10、1080p60 18、1440p60 32、2160p30 36 Mb/s（59.94 / 29.97 按 60 / 30 档）；其余按 0.15 bit / 像素 / 帧取整到 Mb/s、至少 4（720p60 → 8、1080p50 → 16）；H.264，关键帧沿用契约默认 120 帧；AAC 256k；.mov、"停止后转 .mp4"默认关（不动）。
- 推流（`StreamQualityTier`）：两档 + 自定义——**1080p**：1920×1080，节目 ≥ 48 fps 6 Mb/s、否则 4.5 Mb/s，AAC 160k；**720p**：1280×720，3 Mb/s，AAC 128k（L7 的例子）。两档都是 H.264、关键帧 2 s 按节目帧率换帧数（60 → 120、30 → 60、59.94 → 120）。新目的地 = 不高于节目的最大一档（封顶 1080p、不放大：4K 节目 → 1080p 档，720p 节目 → 720p 档）；第 2 个起抄推流 1 的编码并勾"与推流 1 相同"。档位判定看实际尺寸（宽高 nil = 节目尺寸）、码率、关键帧、音频，一项对不上就显示"自定义"。
- 合计上行 = 全部目的地的视频 + 音频码率之和（每个目的地各起一路编码）。

### 1.3 推流服务预设表（Q31 (a)）—— JSON 的结构

`App/Resources/StreamServices.json`（随 App 发布；改表不用改代码），`StreamServiceCatalog` 读主 bundle，读不到退回两个自定义：

```json
{ "version": 1, "checked": "2026-10-03", "note": "…",
  "services": [
    { "id": "youtube",            // 稳定 id（只在窗口开着时记"刚选过哪个"，不进节目）
      "kind": "fixed",            // custom = 自定义，不填地址；perSession = 每场发地址 + 推流码，不填地址；fixed = 入口固定，选中即填 url
      "schemes": ["rtmp", "rtmps"],
      "url": "rtmp://a.rtmp.youtube.com/live2",          // 只有 fixed 有
      "match": ["rtmp://a.rtmp.youtube.com/", "…"],       // 认地址用的片段（可缺；perSession 给了也认，如哔哩哔哩 bilivideo.com/live-bvc）
      "backupURL": "rtmp://b.rtmp.youtube.com/live2?backup=1",   // 可缺
      "name": { "zh-Hans": "YouTube", "en": "YouTube" },
      "hint": { "zh-Hans": "推流码在…", "en": "…" } }     // 一句"推流码 / 地址去哪拿"，两种语言
  ] }
```

顺序 = 下拉顺序：自定义（RTMP / RTMPS）、自定义（SRT）、微信视频号、抖音、哔哩哔哩、快手、YouTube、Facebook、Twitch。**节目里只存完整地址**（`StreamSettings.url`），不存服务 id；重开窗口按地址认服务（固定入口按 match，其次按协议落到自定义；每场发地址的平台认不出来时显示自定义）。选服务：固定入口 = 地址填成入口（推流码不动，可改）；自定义 / 每场发的平台 = 不填，当前地址是别家固定入口（或协议对不上的自定义）就清空让用户贴。SRT 自定义的说明里写清 streamid / passphrase / latency 怎么写、字符限制。

### 1.4 入口地址核对记录（2026-10-03）

| 服务 | 写进表的 | 依据 | 核对结论 |
|---|---|---|---|
| YouTube | `rtmp://a.rtmp.youtube.com/live2`；说明里给 `rtmps://a.rtmps.youtube.com/live2` 与备用 `rtmp://b.rtmp.youtube.com/live2?backup=1` | YouTube Live Streaming API `liveStreams` 资源有 `cdn.ingestionInfo.ingestionAddress / backupIngestionAddress / rtmpsIngestionAddress / rtmpsBackupIngestionAddress` 四个字段（developers.google.com/youtube/v3/live/docs/liveStreams），但文档不给示例值；具体地址与第三方资料（Haivision KB "troubleshooting youtube streams"、livereacting / upstream 的说明）一致 | 官方页面没有直接写出地址，**地址本身来自第三方资料的一致说法**；YouTube 工作室串流设置里显示的就是这几个，用户以那里为准（说明里写了） |
| Facebook | `rtmps://live-api-s.facebook.com:443/rtmp/`，`schemes` 只有 rtmps | Meta 开发者博客 2019-04-16"Live video uploads RTMPS"：2019-05-01 起只收 RTMPS（官方）；地址本身见 Wowza 支持文章"Facebook Live Workaround with RTMPS"等 | RTMPS 要求是官方的；**入口地址官方是每场经 Graph API `secure_stream_url` 给的**，固定地址来自第三方资料，说明里写了"页面上显示的服务器地址和这里不同时以页面为准" |
| Twitch | `rtmp://ingest.global-contribute.live-video.net/app` | Twitch 官方入口表 ingest.twitch.tv/ingests 的 "Default"（priority 0）条目 `rtmp://ingest.global-contribute.live-video.net/app/{stream_key}`；dev.twitch.tv/docs/video-broadcast 给的格式 `rtmp://<ingest-server>/app/<stream-key>` | **官方核对过**；旧的 `rtmp://live.twitch.tv/app` 也在 match 里（认老节目） |
| 微信视频号 | 不填（perSession） | 第三方说明：视频号助手网页 channels.weixin.qq.com › 直播管理 › 推流配置 里有推流地址与推流密钥 | 每场不同，只写去哪拿 |
| 哔哩哔哩 | 不填（perSession），match `bilivideo.com/live-bvc` | 搜索到的推流服务器 `rtmp://live-push.bilivideo.com/live-bvc/`；开播设置里给"服务器地址 + 串流密钥"，密钥每次开播变 | 服务器地址看起来固定，但没找到官方文档，**不填、只用来认**；说明写"直播中心 › 我的直播间 › 开播设置" |
| 抖音 / 快手 | 不填（perSession） | 没找到官方的第三方推流文档（搜索只有平台外的教程） | 说明写成"开播前在平台直播后台取推流地址和推流码；第三方推流可能要先开通权限"，**没有核对到官方原文**，用户如有准确路径请改 JSON |

探针：表里固定入口的地址都用推流包 `StreamDestination(settings:)` 解析过（用例 `testPanels_streamPresetFillsURLAndKeepsFullURLInShow` 里逐个跑），协议在各自的 schemes 里。没有真推到这些平台（没有账号，也不该在测试里推公网）。

### 1.5 鉴权（L10，G6 追加按 reports/w5-stream-auth.md §5 第 3 条）

- RTMP / RTMPS："鉴权…"弹一个小表（用户名 / 密码 + 说明 + 清除 / 取消 / 保存），写回地址的 userinfo：`URLComponents` 的 `user` / `password` setter（自动只转义一次，不手拼）；读用推流包 `StreamDestination(settings:).credentials`（地址还不完整时退回 URLComponents）。用户名空 = 去掉整段 userinfo。同样的值再存一次地址不变（不会越转越长）。
- 说明文案写清：这是 Adobe（FMLE 兼容）鉴权，Wowza / Nimble / FMS 与一部分 CDN 入口用；MediaMTX / SRS / nginx-rtmp 这类自建服务器要地址后面的查询串（MediaMTX：`?user=…&pass=…`），填在鉴权框里对它们没用（连接成功、开始推时被拒）。自定义 RTMP 的服务说明里也写了查询串的写法。
- **"写进查询串"的选项没给**（W5-D §3 第 5 条留给本会话 / 用户定）：理由——① 查询串的参数名每家服务器不同（MediaMTX user/pass、SRS 自定义、nginx-rtmp 由 on_publish 回调定），给一个按钮也只能写死 MediaMTX 的名字；② 查询串里的密码会原样出现在地址框里（打码只覆盖 userinfo）。要做的话建议：鉴权表里加"写法：Adobe（user:pass@）/ 查询串（?user=&pass=）"二选一，查询串那种在地址框里也打码——等用户定。
- 地址框打码：`rtmp://user:pass@host/app` 显示成 `rtmp://•••@host/app`；编辑时打码段原样留着 = 存回原来的账号，删掉 = 去掉账号，自己写了 user:pass@ = 用自己写的。鉴权按钮旁一行"鉴权：用户 xxx（密码已设）/ 没有鉴权"。
- SRT：同一个按钮改 passphrase（写进查询串 `passphrase=`，别的查询项按原样 percentEncodedQueryItems 保留）；只收字母数字和 - . _ ~、10–79 个字符（问题单 W5D-w2-stream-srt-passphrase-reserved-chars；libsrt 的长度限制），不合格直接报错不写。

### 1.6 跟随规则（OutputLinkage / OutputLinkageSync）

- 三个 App 层标记放 `OutputSettings.extra`（契约注释："extra 给各输出会话放自己的附加项"，NDI 的 `ndi.groups` / `ndi.conversion` 是先例），节目文件里带着，API / headless 不认、也不受影响：`app.record.armed`（缺 = 参与录制）、`app.record.ownFormat`（录制页里来源改成某路输入的路：自己的格式，不当 ISO 跟）、`app.stream.followFirst`（第 2 个起新建的目的地 = true）。
- 录制 1 = 第一个来源是 PGM 的录制输出（原来的 `ISORoutes.programRecord`）。ISO 路（来源是输入、没标 ownFormat）的**编码**跟录制 1；**文件一节**（目录 / 模板 / 片段 / 文件格式）对全部录制路生效，非录制 1 的模板补 `-{output}`。推流：勾着"与推流 1 相同"的目的地的 video / audio 跟推流 1（地址、密钥、重试间隔不跟）。
- **只在录制 1 / 推流 1 变了的时候跟**（`PanelCoordinator` 每个快照比一次上一个快照）：打开一个各路设置本来就不一样的老节目不会被悄悄改写（`ShowRoundTripTests.testShow_appOpenThenSaveRoundTrip` 的全字段节目里 ISO 是 ProRes、录制 1 是 HEVC，照旧逐字段相等）；同一个快照里跟随的那一路自己也被改了（API 直接改它、loadShow）就不碰它；在录 / 在推的路记下来，停了再跟——"在录的下次起录生效"，页上有提示。勾上"与推流 1 相同"、新建 ISO 路 / 目的地的那一刻由设置页抄一次。不管设置窗开没开都跟（API 改录制 1 也跟）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

（全量结果见 §2.2；以下是本会话新增 / 改的用例，单独跑与全量都过）

| 测试 | 内容 | 结果 |
|---|---|---|
| `testPanels_streamPresetFillsURLAndKeepsFullURLInShow` | 预设表 9 项顺序、两种语言名字 / 说明、固定入口能被推流包解析；选 YouTube → 地址 = `rtmp://a.rtmp.youtube.com/live2`、推流码不动；存出来的节目里只有地址带 youtube（出现 1 次）、extra 没有服务键；新模型按地址认回 YouTube；换哔哩哔哩清掉固定入口、贴地址后认得；换自定义 SRT 清空 | 过 |
| `testPanels_streamQualityPresetWritesEncoderFields` | 1080p60 新目的地 = 1920×1080 6 Mb/s 关键帧 120 AAC 160k、显示"2 s（= 120 帧）"；选 720p = 1280×720 3 Mb/s 128k；手改码率 → 自定义；选自定义不改字段、展开详情；按秒改 1 s = 60 帧；30 fps 节目 1080p 档 4.5 Mb/s / 60 帧、下拉文字"1080p · 4.5 Mb/s · 音频 160k"；默认档 720p 节目不放大、4K 封顶 1080p | 过 |
| `testPanels_secondDestinationFollowsFirstUntilDetached` | 第 2 个默认跟、推流 1 不算跟；推流 1 换档 → 推流 2 跟；推流 2 在推时推流 1 再改 → 不动，停了跟上；取消跟随后不再跟、自己改不影响推流 1；再勾上马上抄一次 | 过 |
| `testPanels_isoTableFollowsRecordFormat` | 表 = pgm + 两路输入；勾两路；ISO 1 在录时录制页改 ProRes 422 → ISO 2 跟、ISO 1 不变（0.5 s 后仍 H.264）、页上提示 ISO 1 停了再跟、K6 提示在；ISO 1 停 → 跟上 ProRes；录制页改目录 → 两路 ISO 都跟、模板带 {output}；PGM 行取消 → 底栏录制只起两路 ISO（录制器 = {ISO 1, ISO 2}，PGM 没录） | 过 |
| `testPanels_recordOutputListAddsSecondPGMRecording` | 空节目录制 1 = 18 Mb/s / AAC 256k；来源只列 PGM / 输入；加第二路 = 录制 2、PGM、参与、18 Mb/s、同目录、模板带 {output}；改名、ProRes 422 HQ 不影响录制 1；录制 1 改码率不影响它、改目录它跟；来源改输入 1 后仍在录制页、不跟录制 1；取消参与 → 底栏只起录制 1；删除 | 过 |
| `testPanels_outputOverviewListsEveryOutput` | 7 个输出（录制、推流、NDI、外部显示、虚拟摄像头、多画面、ISO）各一行，种类 / 名字 / 来源 / 开关 / 状态都对、状态有文案；每行跳的页对；NDI 行状态读 Stats.encoder（喂一行 publishing）；点行切页 + focusedOutput | 过 |
| `testPanels_L3_streamPageStartStopStatusLineAndTotalUplink` | 段首开关 / 全部开始只发有地址、没开的；状态行"推流中 · 5.9 Mb/s · 丢 3 帧 · 重连 1 次"；全部停止 / 段首关都先问、答了才发；合计上行"约 12.3 Mb/s（2 个目的地）"；在推的路质量 / 服务 / 鉴权都不改 | 过 |
| `testPanels_L10_streamAuthWritesUserinfoOnceAndMasksAddress` | user `op@x` / pass `p@ss:w rd%` 写回后推流包读回原文、不出现二次转义、重写不变；打码 / 还原三种情况；清除；SRT passphrase 不合格两种被拒、合格的写进且 streamid / latency 原样 | 过 |
| `testPanels_M5_externalPagePerScreenSingleSelect` | 两块屏（注入）；老节目同屏两路 → 那一路 = 编号小的开着的；选 PVW 发的命令 = `ExternalDisplayRouting.pick`（换源 + 关同屏另一路）；关闭只关不删；空屏选输入 1 → addOutput"内建 · 输入 1 …" | 过 |
| `testPanels_M7_multiviewCellEditor` | 格子来源不含多画面；预设转自定义 = 4 格（PVW / PGM / 两路输入）都在画面内；改来源、改位置（钳到 0–1）、加、删、清 | 过 |
| `testPanels_K8_newRecordDefaultsFollowProgramFormat` | 四档按表、59.94 按 60、720p60 = 8 Mb/s、AAC 256k、空节目 18 Mb/s、契约默认仍 6 Mb/s、720p 节目里加的录制 8 Mb/s | 过 |
| `ISOAppTests.testISO_singleEntry_bottomBarOpensSettingsTab_templateCarriesOutput`（改） | 原"编码参数抄 PGM"那条按 K10 新口径改（不是删）：创建时同录制 1 照查；录制 1 之后改 5 Mb/s → ISO 跟；ISO 在录时录制 1 改 7 Mb/s → 不动；停了 → 跟上 7 Mb/s | 过 |

**红灯验证**：实现是在写用例的同一轮里起草的，所以另做了一次反证——把 PanelCoordinator 里的跟随同步和底栏"只起参与录制的路"两处临时改回去重跑：`isoTableFollowsRecordFormat`、`recordOutputListAddsSecondPGMRecording`、`secondDestinationFollowsFirstUntilDetached`、改过的 ISO 用例 4 条红（14 处断言），其余照绿，改回后全绿。

### 2.2 全量

`make test-app`（2026-10-03 23:03 起，等机器连续 60 s 没有别的测试宿主再跑，负载 4.5；先编了 release frameprobe）：**155 条，153 过 / 2 跳 / 0 失败**，290 s
（`xcrun xcresulttool get test-results summary`；main 190fe32 上是 144 条，本分支 +11 条新用例）。两条跳过都是老的 BLOCKED：
`InputWiringTests.testInputs_builtInCameraLiveWithin5sAndPictureShows`（BLOCKED-权限：摄像头没授权）、`VirtualCameraAppTests.testL1_virtualCameraEgress_requiresSignedExtension`（BLOCKED-签名）。
ISO A4（`testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame`）真跑了、过（13 s）。没有一条显示类用例红（屏幕没锁）。

`make lint BRANCH=w5-app-output-pages`：全绿——禁词 / 版本号 / Package.swift、check-deps、`check-ownership`（16 个改动文件都在 App/ 与 reports/ 内）、check-links（167 个 Markdown）、check-rt-symbols。

## 3. 没做的和原因

1. **没叠在 92 / 93 上**（见文首）：外部显示页"与 92 的单选菜单同一份数据"做成了读写同一份快照 + 同一套规则（`ExternalDisplayRouting`，规则逐条照 92 的 `ExternalOutputMenuBuilder`），而不是调 92 的函数；G7 合 92 时两份静态函数并存，建议菜单改调 `ExternalDisplayRouting`（≤ 50 行胶水）。
2. **推流状态面板与时长**（L11 的独立面板、uptime / 断线次数 / 最后错误）：归 101（prompt 写"不做"）；本会话只做推流页每段的状态行（L11"只做面板骨架"的那一部分）。ISO 表没有"时长"列，等 022 / 101。
3. **鉴权"写进查询串"选项**：没给，理由与建议见 §1.5，等用户定。
4. **M5 的"就地送外部显示"**（PVW 标题条 / 格子上的显示器按钮）：归 93 / 94（它们的 prompt 列了 M5 的入口）；本会话做的是同一份数据的设置页。
5. **菜单栏"输出 › 输出总览…"**：没加——93 重排了菜单栏，在 main 上加会和它冲突；设置窗打开默认仍是各自的页（底栏 ⚙ / 菜单项给的 tab），总览在侧栏第一项。建议 G7 或 96（设置体系）顺手加一项。
6. **手册**：docs/user/输出.md 的录制 / ISO / 推流 / 外部显示几段已经和界面不一致，不在本会话目录，写了问题单 reports/issues/W5I-w4-docs-output-pages-manual.md（归 103 W4-C2）。
7. **录制来源 PVW / 多画面的拒收**：界面上不给这种来源（来源下拉只有 PGM / 输入）；从 API / 节目文件写进来的仍照录 PGM，拒收等 023（P5）。
8. 抖音 / 快手（和视频号）的"去哪拿"没核对到官方原文（§1.4），说明写得保守。

## 4. 对契约的疑问

1. **三个 App 层标记放在 `OutputSettings.extra`**（`app.record.armed` / `app.record.ownFormat` / `app.stream.followFirst`）：没改契约类型、没改 JSON 字段名，按契约注释"extra 给各输出会话放自己的附加项"、照 NDI 的先例放；但它们会进节目文件、API 的全量状态里也看得到。要不要以后升成正式字段（例如 `RecordSettings.armed`、`StreamSettings.followsOutput`），让 headless / API 的"全部录制"也认"参与录制"——现在 headless 场景文件与 API 的 startRecord 是逐路发的，不受影响。请用户定是否要提案。
2. `RecordSettings.container` 废弃（023 第二节，P5）：本会话照读不写，没碰。
3. Stats.encoder 没有时长 / 断线次数 / 最后错误（022）：状态行只用现有的 state / bitrate / dropped / reconnects。

## 5. 下一个会话需要知道的坑

1. **G7 合 92（w5-app-bottom-bar）时要手接的三处**（92 在同几块代码上改过，自动合并会冲突或悄悄漏）：
   - 底栏录制主体：本分支 `BottomBarView.recordPressed` 起录改成 `OutputLinkage.armedRecords(in:)`（只起参与录制的路，一路都没有时提示）；92 重写了 recordPressed，还加了录制 ▴ 菜单的"全部开始"——**两处都要改成只起参与的路**，否则"PGM 行取消 = 只录 ISO"在 92 的入口上不生效（`testPanels_isoTableFollowsRecordFormat` 走的是 `bottomBar.recordButton.performClick`，合并后看它）。
   - 92 的 `OutputSettingsModel.requestAddDestinationFocus` / `pendingAddDestinationFocus` 挂在旧 `OutputSettingsView` 的"添加目的地"地址框上；这一节现在在 `OutputPagesViews.swift` 的 `StreamPage` 里，`.focused` 要挪过去。
   - 92 的 `ExternalOutputMenuBuilder` 的 outputs(on:) / primaryOutput / autoName / sources / 选源 / 关闭 与本分支 `ExternalDisplayRouting` 规则相同，建议菜单改调它（只留一份）。
2. 两份 Localizable.strings 加了 102 个 `outputSettings.*` 键和 1 个 `bottom.record.noneArmed`（按键序插在原位置），另改了 `outputSettings.iso.hint` / `outputSettings.multiview.customActive` 两个值；与 92–98 冲突时两边都留。
3. **空节目的录制码率从 6 变成 18 Mb/s**（1080p60 的 Q30 默认），AAC 256k：用例里录出来的文件大约是原来的 3 倍；"未保存"判定的基准也用同一个函数，没有变化。
4. **跟随只在录制 1 / 推流 1 变了的时候发生**（不是"每个快照对齐"）：写新用例时，先建 ISO 路 / 第二个目的地，再改录制 1 / 推流 1，才看得到跟随；直接用 API 改 ISO 路自己的设置不会被改回去。设置页关着也跟（PanelCoordinator 持有 `OutputLinkageSync`，换 session 时 reset，第一个快照只当基准）。
5. 推流页"服务"下拉的"刚选过哪个"只记在窗口模型里（`chosenServices`），节目里没有；每场发地址的平台（视频号 / 抖音 / 快手）关窗再开会显示"自定义 RTMP"，这是"节目里只存完整地址"的代价。
6. 地址框显示的是打码后的地址；直接读 `TextField` 的值不是存的地址，测试和别的代码读 `settings.stream.url`。
7. 新 worktree 跑全量前先 `swift build -c release --package-path Tools/frameprobe`，不然 ISO A4 等用例 XCTSkip、看着像全过。`make test-app` 的 -quiet 吞掉用例行，计数用 `xcrun xcresulttool get test-results summary`。几个第五波会话同机跑 App 测试会互相干扰（共用测试宿主的 UserDefaults 与 $TMPDIR/switcher-tests），本会话全量是等机器连续 60 s 没有别的测试宿主才起的。
