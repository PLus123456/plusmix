# StreamingTests 的端口与输出目录写死、同机多会话并行跑互相踢掉

归属会话 / 分支：推流会话（W2-D 系，`Packages/SwitcherOutputs/Tests/StreamingTests/`：`MediaMTXSupport.swift` 的 `MediaMTXInstance` / `startInstances`、各用例里写死的端口；ThrottleProxyTests 同）
发现于：G6 检查点读 W5-D 报告（reports/w5-stream-auth.md §2、§5 第 10 条）与 W5-E 报告（§2"其它五包"一行）；第五波五个会话 2026-10-01 同机并行时撞上
现象：
- MediaMTX / 代理端口写死（21935…、31935…、31950、41002…），输出目录 `$TMPDIR/switcher-streaming-tests/<用例>` 共用，而 `startInstances` 开头先 `removeItem` 掉它。
- 两个会话同时跑 StreamingTests：后起的 MediaMTX 绑不上端口（`bind/listen 31950: errno 48`）、就绪检查被对方实例的 API 应答、流推进了对方的实例（对方日志 `closing existing publisher`）、录制目录被对方删掉。
- W5-D 全量第 1 遍 45 / 50（E9、RTMP e2e、W2D2-RTMP、E8、ThrottleProxy 五个红全是这个原因）；W5-E 同一时段 Outputs 6 红里 5 个是它；各自单独重跑全过。
- W5-D 自己新加的用例端口不重（21950 / 28950 / 30050、网关 19461–19470），所以全过；App 测试宿主的 `$TMPDIR/switcher-tests/` 与 UserDefaults suite `com.plusmix.switcher.tests` 是同一类问题（reports/w5-app-safety.md §5 第 2 条），归 App 会话。
复现步骤：两个 worktree 同时 `swift test --package-path Packages/SwitcherOutputs --filter StreamingTests`。
严重级：S3（测试工装；不影响产品）。但第五波骨架七路 + P5 会继续并行，检查点合并时每次都要等机器安静才能判 Outputs 红绿。
建议改法：
- 端口按进程号偏移（例如 `basePort + (getpid() % 200) * 10`），或起 MediaMTX 前探一个空闲端口再写进它的配置（`MediaMTXInstance` 已经按配置模板起实例，`extraConfig` 是 W5-D 加的入口）；
- 输出目录带进程号（`SWITCHER_TEST_OUTPUT` 已能改，默认值加 pid 即可），`startInstances` 只删自己的；
- ThrottleProxyTests 的代理端口同样处理。
