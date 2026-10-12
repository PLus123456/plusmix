# 手册还写着"推流密码错了一直按退避重试"：W2-D4 之后鉴权失败第一次就停、状态行有提示

归属会话 / 分支：109 W4-C3（`w4-docs-3`，docs/user 中英手册）；W2-D4（prompt 111，`w2-stream-4`）不碰 docs/，按 prompt 交付 4 写这张单
发现于：W2-D4 实现"推流鉴权失败就停 + 提示"（用户 2026-10-12 定"要，而且要有提示"）之后对手册的核对，2026-10-12

## 现在的行为（w2-stream-4，合入后生效）

- 服务器拒绝鉴权——Adobe 鉴权的密码 / 用户名不对（服务器回 `reason=authfailed` / `nosuchuser`）、服务器要 Adobe 鉴权而地址里没写账号、
  查询串写法（MediaMTX 的 `?user=&pass=`）被拒（publish 回 `NetStream.Publish.Unauthorized`）、服务器要的鉴权方式不支持（`authmod=llnw`）——
  **第一次就停**，不再按退避重试（原来 1、2、4…≤ 30 s 一直试，Adobe 每次 3 个连接）。连不上 / 断线 / 停滞照旧"一直重试"。
- 状态行一句：`推流 n 鉴权失败（用户名或密码不对），已停止：在推流页改对后点底栏「推流」重试`
  （英文：`Stream n authentication failed (wrong user name or password) and stopped: fix it on the Streaming page, then click "Stream" in the bottom bar to retry`）；
  服务器要的鉴权方式不支持时状态行是 `推流 n 不再重连：鉴权失败（服务器要的鉴权方式不支持）：…`（改密码没用，不说"改对"）。
- 底栏推流主体：深红"**推流 · 起不来**"（只开一路时；多路时"推流 · k 路异常"深红），悬停 `推流：起不来 — 推流 n 不再重连：鉴权失败（用户名或密码不对）：<服务器回的原文>`
  + "点一下：重试起不来的路，正常的路不受影响"。改对之后**点底栏主体**才重试（停掉这一路、按新设置起一路）——改地址本身**不会**自动重试这一种
  （"改好地址会自动重试"只对"起不来：没有地址 / 地址不认"那一类）。
- 状态面板：这一路状态"失败"，最后错误 = 推流模块那一句原文；事件 `推流 · 失败：鉴权失败（用户名或密码不对）：…`。
- API / stats.jsonl：`stats.encoder[]` 这一路 `state = "failed"`、`attempt = 0`、`last_error` = 那一句：
  - Adobe 密码错：`鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected [ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=authfailed&opaque=…`
  - Adobe 用户名错：`鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected … ?reason=nosuchuser…`（原来是"鉴权失败：用户名不对（服务器回 nosuchuser）"）
  - 查询串账号错 / 没给（MediaMTX）：`鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed`
  - 服务器要账号、地址里没写：`鉴权失败（服务器要用户名和密码，地址里没写）：NetConnection.Connect.Rejected …`
  - 要 Limelight：`鉴权失败（服务器要的鉴权方式不支持）：服务器要 Limelight（authmod=llnw）`（原来是"鉴权方式不支持：…"）
  原因不再只在系统日志里：状态面板"最后错误"、API 的 `last_error` 都有，文字不带密码。
- 已知限制：地址用"应用 + 密钥"写法（`rtmp://host/live` + 密钥）推 MediaMTX 时，HaishinKit 每次连接先白等 3 s（MediaMTX 不回 releaseStream / FCPublish），
  MediaMTX 鉴权失败又随机等 0–4 s 才回，有一半的概率超过 5 s 的连接超时、那一次按"连接失败"退避，下一次才认出来停下（reports/w2-stream-4.md §5）。
  MediaMTX 惯用的"只写路径、密钥留空"写法第一次就停。

## 手册里要改的地方（docs/user，中英各一份）

| 文件:行 | 现在写的 | 应改成 |
|---|---|---|
| `输出.md:117` / `en/outputs.md:120` | 用户名或密码不对：这一路一直"连接中（第 n 次）"、按退避重试……原因写在系统日志里；"鉴权方式不支持：…" | 第一次就停：底栏深红"推流 · 起不来"、状态行那一句、状态面板最后错误 / 事件；改对后点底栏主体重试（开关仍开着——这一段锁不锁按 112 / App 现状写）；不支持的鉴权方式同样停，文字见上 |
| `输出.md:116` / `en/outputs.md:119` | 填在"鉴权…"里对它们没用：连接会成功、开始推的时候被服务器拒（系统日志里是 `NetStream.Publish.Unauthorized`） | 同上会被拒，**第一次就停**，原因在状态面板 / `last_error`（`鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed`），不只在系统日志 |
| `输出.md:100` / `en/outputs.md:101` | 重连：断线后指数退避自动重连，一直重试不放弃 | 加一句：服务器拒绝鉴权不在此列（第一次就停，见"推流鉴权"） |
| `输出.md:91` / `en/outputs.md:92` | 编码详情里"重试间隔最长 n s（一直重试）" | 照界面原文写；括号后补"鉴权失败除外"或在"重连"一条里说明（界面文案本身要不要改归 App 会话，见下） |
| `故障排查.md:58` / `en/troubleshooting.md:59` | 一直"连接中（第 n 次）"，系统日志里有"鉴权失败（用户名或密码不对）…"——照样按退避一直重试 | 改成"推流 · 起不来（深红）+ 状态行'推流 n 鉴权失败（用户名或密码不对），已停止…'"：改对用户名 / 密码后点底栏主体重试 |
| `故障排查.md:59` / `en/troubleshooting.md:60` | 填了"鉴权…"，连接成功、一开始推就被拒（日志里是 `NetStream.Publish.Unauthorized`） | 同一现象现在是"第一次就停 + 状态行提示"；处理办法不变（改写查询串） |
| `故障排查.md:60` / `en/troubleshooting.md:61` | 系统日志里有"鉴权方式不支持：…" | 文字改为"鉴权失败（服务器要的鉴权方式不支持）：…"，同样第一次就停 |
| `故障排查.md:55` / `en/troubleshooting.md:56` | 重连中……一直重试 | 不变（断线重连）；可加"鉴权失败不重试" |

## 顺带（不归 109，给 App 会话 / 用户定）

- 推流页编码详情的界面文案"重试间隔最长 n s（一直重试）"（W5-B 定的）在鉴权失败时不再成立；要不要加"鉴权失败除外"归 App 会话（112 W5-O 或之后）。
- 底栏这一种写"起不来"而不是"失败"：`OutputButtonSummary.routeState` 先看运行表给的原因（`failureReason` 对停在 failed 的推流对象也返回原因，好让点主体 = 重试），
  所以显示 `output.state.startFailed`；状态面板那边不传原因，显示"失败"。两处不一致，要统一归 App 会话（见 reports/w2-stream-4.md §4）。

严重级：S3（文档与行为不符；不影响推流）
复现：w2-stream-4 合入后，本机 MediaMTX 开鉴权（`MTX_AUTHINTERNALUSERS_*`，见 App `StreamWiringTests.testStream_authFailedStopsWithStatusLineNotice`），
地址写 `rtmp://127.0.0.1:1935/s1?user=pub&pass=错的`，点底栏"推流"。
