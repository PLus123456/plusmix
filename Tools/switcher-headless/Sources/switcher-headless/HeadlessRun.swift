import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherAudio
import SwitcherAudioIntegration
import SwitcherOutputs
import SwitcherControl
import SwitcherTestKit

/// run 子命令的参数。
struct RunOptions: Sendable {
    var showURL: URL
    var scriptURL: URL?
    var durationSeconds: Double
    var statsURL: URL?
    var recordURL: URL?
    var preview: Bool
    var audioDevice: String
    var leadMs: Double
    var gpuStats: Bool
    /// 合成源帧的提前量（ms）：第 k 帧的 pts = 拍点 − 提前量，nil = 半个节目帧。见 HeadlessSession.run 第 1 步的注释。
    var inputLeadMs: Double?
    /// 录制封口的看门狗（秒）。
    var stopTimeoutSeconds: Double = 60
    /// --api：本地 API 的配置；nil = 不起。
    var api: APIServerConfiguration? = nil
    /// W2-E A4：另起 N 个录制器（PGM 视频 + 前 N 路带音频输入各自的 ISO 音轨），文件名 <record 去掉扩展名>.iso<编号>.mov。
    var isoAudio: Int = 0
}

/// 音频输出：--audio-device null|default|<名字> → 集成层（W2-E AudioEngine）的设备选择。空设备 = W1-D 假时钟，不出声，gate 用。
enum AudioOutputChoice {
    static func output(_ spec: String) throws -> AudioEngineConfiguration.Output {
        switch spec.lowercased() {
        case "null", "none": return .null
        case "default", "": return .systemDefault
        default:
            guard AudioHAL.device(named: spec) != nil else {
                let names = AudioHAL.devices().filter { $0.outputChannels > 0 }.map(\.name).joined(separator: " / ")
                throw CLIError("找不到音频输出设备「\(spec)」。有：\(names)")
            }
            return .device(name: spec)
        }
    }
}

/// 把录制器的计数变成 Stats.encoder 的项（每个录制器一项，顺序 = 传入顺序：PGM 录制器在前、ISO 录制器在后）：
/// skipped / frames / dropped / disk_free_mb / state 按提案 001 / 002 由 `RecorderCounters.statsEntry` 填，bitrate 按上次采样以来的窗口算。
/// 只在 Stats 采样线程上被调。
final class EncoderStatsSource: @unchecked Sendable {
    private let recorders: [Recorder]
    private let last = Mutex<[(counters: RecorderCounters, at: HostTime)?]>([])

    init(recorders: [Recorder]) {
        self.recorders = recorders
        last.withLock { $0 = Array(repeating: nil, count: recorders.count) }
    }

    func entries() -> [Stats.EncoderEntry] {
        let now = HostClock.now()
        let current = recorders.map(\.counters)
        let previous = last.withLock { box -> [(counters: RecorderCounters, at: HostTime)?] in
            let p = box
            box = current.map { ($0, now) }
            return p
        }
        return current.enumerated().map { i, c in
            let window = previous[i].map { max((now - $0.at).seconds, 1e-3) } ?? 1
            return c.statsEntry(previous: previous[i]?.counters, windowSeconds: window, state: recorders[i].state.statsName)
        }
    }
}

/// 一次 headless 运行：节目文件 → 引擎 + 渲染器 + 合成源 + 混音 + 录制 + Stats，跑到 --duration 或 Ctrl-C，然后按顺序收尾。
final class HeadlessSession: @unchecked Sendable {
    let options: RunOptions
    let show: Show
    let initialState: MixerState
    let scenario: Scenario?
    let format: ProgramFormat
    let renderer: MetalRenderer
    let stateMachine: StateMachine
    let engine: Engine
    /// 本次要跑的拍数（第 0 拍到第 totalTicks − 1 拍）。
    let totalTicks: Int64
    /// --api：命令总线 + 状态推送 + HTTP/WS 服务（W2-C）。总线是 UI / 快捷键 / MIDI / API 的统一入口；headless 里只有 API 一个来源。
    let commandBus: CommandBus
    let stateFeed: StateFeed
    let apiServer: APIServer?

    private let stopRequests = Atomic<Int>(0)
    private(set) var exitCode: Int32 = 0

    init(options: RunOptions) throws {
        self.options = options
        show = try ShowStore().load(from: options.showURL)
        let state = show.makeState()
        try state.validate()
        initialState = state
        scenario = try options.scriptURL.map { try ScenarioRunner.load(from: $0) }
        format = state.format
        let fps = format.frameRate.framesPerSecond.doubleValue
        var ticks = Int64((options.durationSeconds * fps).rounded())
        if let sc = scenario, Int64(sc.durationTicks) < ticks {
            print("场景只有 \(sc.durationTicks) 拍，短于 --duration 的 \(ticks) 拍，按场景长度跑")
            ticks = Int64(sc.durationTicks)
        }
        guard ticks >= 1 else { throw CLIError("拍数为 0：--duration 太短或场景 durationTicks 为 0") }
        totalTicks = ticks
        renderer = try MetalRenderer()
        stateMachine = StateMachine(initialState: state)
        let maxNumber = state.inputs.map(\.number).max() ?? 1
        let engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(16, maxNumber))
        self.engine = engine
        let bus = CommandBus(stateMachine: stateMachine)
        let feed = StateFeed(stateMachine: stateMachine) { engine.clock?.spec }
        commandBus = bus
        stateFeed = feed
        apiServer = options.api.map { APIServer(bus: bus, feed: feed, configuration: $0) }
    }

    /// 第一次：请求干净停止；第二次：立即退出。
    func requestStop(signal: Int32) {
        let n = stopRequests.add(1, ordering: .acquiringAndReleasing).newValue
        if n >= 2 {
            FileHandle.standardError.write(Data("再次收到信号 \(signal)，立即退出\n".utf8))
            exit(130)
        }
        FileHandle.standardError.write(Data("收到信号 \(signal)：停时钟、排空渲染器、封口录制文件……（再按一次立即退出）\n".utf8))
    }

    private var stopRequested: Bool { stopRequests.load(ordering: .acquiring) > 0 }

    func run() async throws {
        let t0 = HostClock.now() + HostDuration(milliseconds: options.leadMs)
        let spec = TickClockSpec(t0: t0, frameRate: format.frameRate)
        let lastTick = Tick(totalTicks - 1)

        // 1. 输入：只接合成源（G2 / M0）。每路自己的帧槽（W1-B）+ 像素池（W1-A）；带音频的路另起一个独立的合成音频源写进 C 环（W1-D）。
        //    时间线：视频第 k 帧的 pts = 节目拍点 − 提前量（默认半个节目帧，8.3 ms @60）。提前量模拟真设备"帧在它该被合成的拍之前到达"：
        //    没有它，pts 恰好落在拍点上的帧到达时刻与拍点只差唤醒 + 画帧的几十微秒到几毫秒，带 ±3 ms 抖动的那路每帧都在赌"先到还是拍先到"，
        //    一半重复一半丢（冒烟跑实测 50%），量到的是拍点竞态而不是引擎的挑帧规则。音频（click）不带提前量，t0 = 节目第 0 拍，
        //    这样闪光帧在第 60k 拍合成、click 在 t0 + k s，录制文件里两者同刻（A2 = 0 才是对的）。
        let programFrameSeconds = format.frameDuration.doubleValue
        let inputLeadMs = options.inputLeadMs ?? programFrameSeconds * 500
        let videoT0 = t0 - HostDuration(milliseconds: inputLeadMs)
        var inputs: [SyntheticVideoInput] = []
        var audioInputs: [(number: Int, ring: CAudioRing, settings: InputAudioSettings, source: SyntheticAudioInput)] = []
        for cfg in initialState.inputs {
            guard case .synthetic(let settings) = cfg.source else {
                throw CLIError("G2 只接合成源：输入 \(cfg.number)「\(cfg.name)」是 \(cfg.kind)")
            }
            let slot = LockFreeFrameSlot(capacity: 3)
            let timeline = SyntheticTimeline(t0: videoT0, frameRate: settings.frameRate)
            let input = try SyntheticVideoInput(number: cfg.number, name: cfg.name, settings: settings, videoSlot: slot,
                                                audioRing: nil, timeline: timeline, seed: UInt64(cfg.number))
            engine.registerInput(number: cfg.number, slot: slot)
            inputs.append(input)
            if settings.audio {
                let ring = CAudioRing(channelCount: 2)
                let source = SyntheticAudioInput(number: cfg.number, name: "\(cfg.name) 音频", frameRate: format.frameRate,
                                                 driftPpm: settings.audioDriftPpm, audioRing: ring,
                                                 timeline: SyntheticTimeline(t0: t0, frameRate: format.frameRate))
                audioInputs.append((cfg.number, ring, cfg.settings.audio, source))
            }
        }

        // 2. 音频：W2-E 的 AudioEngine（混音器 + 设备 + 对齐延迟 + AFV + 消费者泵 + 真设备 host 时钟重采样）；
        //    每路带音频的输入把环注册进去，每路参数（增益 / 路由 / 静音…）由它从状态机快照 diff 出来，不用在这里 apply。
        var audioConfig = AudioEngineConfiguration()
        audioConfig.output = try AudioOutputChoice.output(options.audioDevice)
        // SW_AUDIO_SILENT=1：真设备也不出声（Master 不映射到设备通道，仍照常处理、照常送录制器）——长跑 / 真设备 A2 用
        if ProcessInfo.processInfo.environment["SW_AUDIO_SILENT"] == "1" { audioConfig.outputChannelMap = BusChannelMap(master: nil) }
        let audioEngine = try AudioEngine(stateMachine: stateMachine, configuration: audioConfig)
        for entry in audioInputs {
            var hints = AudioInputHints()
            hints.producerBlockFrames = entry.source.blockFrames
            try audioEngine.registerInput(number: entry.number, ring: entry.ring, hints: hints)
        }

        // 3. 录制：Recorder 是 PGM 帧的消费者（有界队列 + 自己的编码线程）；Master 块由 AudioEngine 的消费者泵喂给它
        //    （块 PTS = 块首 − 对齐延迟 = 内容采集时刻，与视频拍点同一时基；G2 自建泵没扣混音器年龄，A2 −18 ms 就是这么来的）。
        var recorder: Recorder?
        var recorderAudioToken: AudioConsumerToken?
        var isoRecorders: [(Recorder, AudioConsumerToken)] = []
        if let url = options.recordURL {
            let outputSettings = show.outputs.first { $0.kind == .record }?.settings
            let cfg = Recorder.Configuration(url: url, format: format,
                                             video: outputSettings?.video ?? VideoEncodeSettings(),
                                             audio: audioInputs.isEmpty ? nil : (outputSettings?.audio ?? AudioEncodeSettings()),
                                             audioChannels: 2,
                                             fragmentIntervalSeconds: outputSettings?.record?.fragmentIntervalSeconds ?? 1,
                                             remuxToMP4: outputSettings?.record?.remuxToMP4 ?? false,
                                             name: "record")
            let rec = Recorder(configuration: cfg)
            engine.addConsumer(rec)
            if !audioInputs.isEmpty { recorderAudioToken = try audioEngine.addConsumer(rec, source: .master) }
            recorder = rec
            // A4：ISO 音轨录制器（视频仍是 PGM——每路视频 ISO 是 W3-C 的事）
            guard options.isoAudio <= audioInputs.count else {
                throw CLIError("--iso-audio \(options.isoAudio) 超过带音频的输入数 \(audioInputs.count)")
            }
            for k in 0..<options.isoAudio {
                let number = audioInputs[k].number
                let isoURL = url.deletingPathExtension().appendingPathExtension("iso\(number).mov")
                var isoCfg = cfg
                isoCfg.url = isoURL
                isoCfg.name = "iso\(number)"
                let iso = Recorder(configuration: isoCfg)
                engine.addConsumer(iso)
                isoRecorders.append((iso, try audioEngine.addConsumer(iso, source: .input(number: number))))
            }
        }

        // 4. Stats：引擎每秒组一行（铁律 4，只有这一份）——StatsPublisher 是唯一的采样线程，写文件（--stats）和 API 推送（--api）
        //    都是它的消费者，拿到的是同一行；编码 / 音频 / GPU 三个来源灌给引擎。
        var writer: StatsWriter?
        var gpu: GPUUtilization?
        var statsPublisher: StatsPublisher?
        if options.statsURL != nil || apiServer != nil {
            if let rec = recorder {
                let source = EncoderStatsSource(recorders: [rec] + isoRecorders.map(\.0))
                engine.encoderStatsProvider = { source.entries() }
            }
            engine.audioStatsProvider = { audioEngine.audioCounters }
            if options.gpuStats, let g = GPUUtilization() {
                gpu = g
                engine.gpuPercentProvider = { g.deviceUtilizationPercent() }
            }
            let publisher = StatsPublisher(engine: engine, interval: 1)
            if let url = options.statsURL {
                let w = try StatsWriter(url: url, append: false)
                publisher.addConsumer { w.submit($0) }
                writer = w
            }
            if apiServer != nil {
                let feed = stateFeed
                publisher.addConsumer { feed.publish(stats: $0) }
            }
            statsPublisher = publisher
        }

        // 4b. API（W2-C）：先于引擎起，让客户端在第 0 拍前就能连上。
        if let server = apiServer {
            await stateFeed.start()
            try await server.start()
        }

        // 5. 场景：全部预排程到状态机，按拍应用（跳过的拍也逐拍走，命令不会漏）。
        if let sc = scenario {
            for e in sc.sortedEvents { await stateMachine.schedule(e.command, at: e.tick) }
        }

        // 6. 起：音频引擎（设备 + 控制线程 + 泵）→ 视频输入（到 t0 才出第一帧）→ 音频输入 → 录制（起点 = 第 0 拍；尽量晚起，
        //    它的入口环只存 256 块 ≈ 1.4 s，起点之前的块留在里面等第一个压缩视频样本到了才会被丢掉）→ 引擎（start 里 prepare 渲染器，lead 要盖住它）
        try await audioEngine.start(clock: spec)
        for input in inputs { try input.start() }
        for entry in audioInputs { try entry.source.start() }
        if let rec = recorder { try rec.start(at: RecordingStart(clock: spec, tick: .zero)) }
        for (iso, _) in isoRecorders { try iso.start(at: RecordingStart(clock: spec, tick: .zero)) }
        if stopRequested {
            await apiServer?.stop()
            await stateFeed.stop()
            await shutdownEarly(inputs: inputs, audioInputs: audioInputs.map(\.source), recorder: recorder, audioEngine: audioEngine, writer: writer)
            return
        }
        try await engine.start(t0: t0, firstTick: .zero, lastTick: lastTick)
        let leadLeft = (t0 - HostClock.now()).milliseconds
        try statsPublisher?.start()
        guard let clock = engine.clock else { throw CLIError("引擎没有时钟") }
        print("""
            switcher-headless \(SwitcherVersion.current)
              节目：\(show.name)（\(options.showURL.path)）\(format.width)×\(format.height)@\(format.frameRate)，\(inputs.count) 路合成源，\(audioInputs.count) 路音频
              场景：\(options.scriptURL?.path ?? "无")（\(scenario?.events.count ?? 0) 个事件）
              时长：\(totalTicks) 拍（\(String(format: "%.1f", options.durationSeconds)) s）  t0 距现在 \(String(format: "%.0f", leadLeft)) ms\(leadLeft < 0 ? "  ⚠️ 起晚了，开头会跳拍" : "")  合成源提前量 \(String(format: "%.2f", inputLeadMs)) ms
              音频：\(options.audioDevice)（对齐延迟 \(String(format: "%.2f", audioEngine.alignmentDuration.milliseconds)) ms，消费者流\(audioEngine.resamplesToHostClock ? "重采样到 host 时钟" : "不重采样")）  录制：\(options.recordURL?.path ?? "无")\(isoRecorders.isEmpty ? "" : "（+ \(isoRecorders.count) 路 ISO 音轨）")  stats：\(options.statsURL?.path ?? "无")  GPU 占用：\(gpu == nil ? "不可用" : "IOKit")
              API：\(apiServer.flatMap(\.baseURL).map { "\($0.absoluteString)/api/v1（WS /api/v1/events）\(options.api?.token == nil ? "" : "，token 鉴权开")" } ?? "关")
              时钟实时策略：\(clock.isRealtime ? "已生效" : "⚠️ 未生效（V3 会超）")
            """)

        // 7. 等：跑完 totalTicks 拍（派发 + 跳过 = 总拍数），或收到信号。
        //    平时 100 ms 看一次；最后 30 拍改 2 ms，这样最后一拍派完后 ≤ 2 ms 就能停视频源——否则 60 fps 的源在这 100 ms 里再推 5–6 帧，
        //    3 格候选表挤掉 2–3 帧记成 dropped，stats 最后一行的 V4 精确核算会多出 1–2 帧设计外（G3 第一次跑 8 号输入就是这样）。
        while !(clock.ticksDispatched + clock.ticksSkipped >= UInt64(totalTicks)) && !stopRequested {
            let remaining = Int64(totalTicks) - Int64(clock.ticksDispatched + clock.ticksSkipped)
            try? await Task.sleep(for: remaining > 30 ? .milliseconds(100) : .milliseconds(2))
        }
        let interrupted = stopRequested

        // 7b. 先停 API（不再收命令、关掉 WS），推送源等引擎停了再停（最后几拍的快照还要推）
        await apiServer?.stop()

        // 8. 停。跑满的情况：时钟已派完最后一拍、不会再挑帧，先停视频源再停引擎——反过来的话引擎排空在途帧的那几十毫秒里视频源还在 push，
        //    满槽挤掉的帧会被记成 dropped，stats 最后一行的 V4 精确核算每路多出 2–3 帧（W1-B 报告 §4 第 13 条）。
        //    中断的情况：时钟还在跑，先停引擎（否则末尾几拍每路多 1–2 次 reuse），视频源紧接着停。
        //    然后录制封口（边界 = 最后一拍 + 1：音频恰好裁到最后一帧末尾，再多 writer 会因为音频超前于已结束的视频拒收而死等；
        //    封口期间音频源、泵、设备都还在跑）→ 泵 → 音频设备 → 音频源 → stats 关文件
        if interrupted {
            await engine.stop()
            for input in inputs { input.stop() }
        } else {
            for input in inputs { input.stop() }
            await engine.stop()
        }
        let boundary = Tick((engine.counters.lastTick?.rawValue ?? -1) + 1)
        var recordResult: RecordingResult?
        if let rec = recorder {
            // 边界之后的音频块不再送录制器：块 PTS = 块首 − 对齐延迟，含边界的块要等 对齐延迟 + 一块 + 泵周期 才到，等够再摘消费者。
            // 否则录制器封口期间还在收块，它的漂移硬校正会对"边界之后"的块补静音（W1-E 的 drainAudio 先查漂移后查 stopTime），
            // 每次补的静音随墙钟增长，appendPCM 每 4096 帧等 200 ms 超时——W2-E 的 45 s 冒烟跑封口卡了 3 分钟
            // （问题单 reports/issues/W2E-w1-outputs-recorder-drift-check-before-stop.md；W1-E 修好后可以先 stop 再摘）。
            if let token = recorderAudioToken {
                let boundaryTime = spec.time(of: boundary)
                let deadline = boundaryTime + audioEngine.alignmentDuration + audioEngine.blockDuration * 2 + HostDuration(milliseconds: 6)
                let wait = deadline - HostClock.now()
                if wait.ticks > 0 { try? await Task.sleep(for: .nanoseconds(Int(wait.nanoseconds))) }
                audioEngine.removeConsumer(token)
                recorderAudioToken = nil
                for (_, t) in isoRecorders { audioEngine.removeConsumer(t) }
            }
            let before = rec.counters
            let result = await stopRecorder(rec, atTick: boundary, timeoutSeconds: options.stopTimeoutSeconds)
            switch result {
            case .success(let r)?: recordResult = r
            case .failure(let e)?:
                FileHandle.standardError.write(Data("录制封口失败：\(e)\n".utf8))
                exitCode = 1
            case nil:
                let now = rec.counters
                FileHandle.standardError.write(Data("""
                    录制封口超过 \(options.stopTimeoutSeconds) s 没有完成（状态 \(rec.state)），放弃等待，文件可能不完整。
                      封口前：视频 \(before.videoFrames) 帧，音频 \(before.audioFrames) 样本，音频块丢 \(before.audioBlocksDropped)，漂移 \(String(format: "%.3f", before.audioDrift.milliseconds)) ms，硬校正 \(before.audioCorrections)
                      现在：视频 \(now.videoFrames) 帧，音频 \(now.audioFrames) 样本，音频块丢 \(now.audioBlocksDropped)，漂移 \(String(format: "%.3f", now.audioDrift.milliseconds)) ms，硬校正 \(now.audioCorrections)；编码 \(now.encoder.encoded) / skipped \(now.encoder.skipped)

                    """.utf8))
                exitCode = 1
            }
        }
        for (iso, _) in isoRecorders {
            switch await stopRecorder(iso, atTick: boundary, timeoutSeconds: options.stopTimeoutSeconds) {
            case .success(let r)?: print("  ISO：\(r.url.lastPathComponent) 视频 \(r.videoFrames) 帧 / 音频 \(r.audioFrames) 样本 / 音频漂移 \(String(format: "%.3f", iso.counters.audioDrift.milliseconds)) ms 硬校正 \(iso.counters.audioCorrections)")
            case .failure(let e)?: print("  ISO 封口失败：\(e)")
            case nil: print("  ISO 封口超时")
            }
        }
        let audioStatus = audioEngine.status
        await audioEngine.stop()
        for entry in audioInputs { entry.source.stop() }
        statsPublisher?.stop()   // 先停采样再关文件；最后一行是停机前那一秒的
        writer?.close()
        await stateFeed.stop()

        // 9. 汇总（stdout；数字来源都是各对象的计数器，正式指标以 stats.jsonl / frameprobe 为准）
        printSummary(clock: clock, inputs: inputs, audioInputs: audioInputs.map { (number: $0.number, source: $0.source) }, audioStatus: audioStatus,
                     recorder: recorder, recordResult: recordResult, writer: writer, interrupted: interrupted)
    }

    /// 录制封口，带看门狗：nil = 超时。
    private func stopRecorder(_ rec: Recorder, atTick tick: Tick, timeoutSeconds: Double) async -> Result<RecordingResult, any Error>? {
        await withTaskGroup(of: Result<RecordingResult, any Error>?.self) { group in
            group.addTask {
                await withCheckedContinuation { c in rec.stop(atTick: tick) { c.resume(returning: $0) } }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func shutdownEarly(inputs: [SyntheticVideoInput], audioInputs: [SyntheticAudioInput], recorder: Recorder?,
                               audioEngine: AudioEngine, writer: StatsWriter?) async {
        if let rec = recorder {
            _ = await stopRecorder(rec, atTick: .zero, timeoutSeconds: 10)
        }
        await audioEngine.stop()
        for a in audioInputs { a.stop() }
        for input in inputs { input.stop() }
        writer?.close()
        print("引擎启动前收到信号，已收尾退出")
        exitCode = 130
    }

    private func printSummary(clock: ProgramClock, inputs: [SyntheticVideoInput], audioInputs: [(number: Int, source: SyntheticAudioInput)],
                              audioStatus a: AudioEngineStatus, recorder: Recorder?,
                              recordResult: RecordingResult?, writer: StatsWriter?, interrupted: Bool) {
        let c = engine.counters
        func ms(_ d: HostDuration?) -> String { d.map { String(format: "%.3f", $0.milliseconds) } ?? "—" }
        var lines: [String] = []
        lines.append("结束：\(interrupted ? "信号中断" : "跑满") \(c.ticksDispatched + c.ticksSkipped) / \(totalTicks) 拍")
        lines.append("  引擎：派发 \(c.ticksDispatched) 拍，跳拍 \(c.ticksSkipped)，渲染器 skipped \(c.renderSkipped)（missed_render = \(c.missedRender)），提交 \(c.framesSubmitted)，完成 \(c.framesCompleted)，派发给消费者 \(c.framesDispatched)，快照等待 \(c.snapshotWaits) / 过期 \(c.snapshotStale)，慢消费者调用 \(c.slowConsumeCalls)")
        lines.append("  时钟：唤醒抖动 p99 \(ms(clock.jitter.percentile(0.99))) ms，max \(ms(clock.jitter.allTimeMax)) ms（\(clock.jitter.sampleCount) 拍）；渲染 V1 平均 \(String(format: "%.3f", c.averageRenderMs)) ms")
        for input in inputs {
            let k = input.counters
            let s = input.videoSlot?.stats
            var pacing = ""
            if let ps = engine.pacingStats(forInput: input.number) {
                pacing = "；到达余量 \(String(format: "%.2f", ps.margin.milliseconds)) ms（窗口最大到达延迟 \(String(format: "%.2f", ps.windowMaxLatency.milliseconds)) ms，迟到 \(ps.lateFrames)，抬 \(ps.raises) / 降 \(ps.decreases)）"
            }
            lines.append("  输入 \(input.number)：生成 \(k.generated)，设定丢 \(k.droppedByDesign)，池不够 \(k.poolStarved)，迟到 \(k.late)，唤醒 max \(String(format: "%.3f", Double(k.wakeLatencyMaxNs) / 1e6)) ms；帧槽 pushed \(s?.pushed ?? 0) consumed \(s?.consumed ?? 0) reused \(s?.reused ?? 0) dropped \(s?.dropped ?? 0)" + pacing)
        }
        lines.append("  音频：\(a.blocksRendered) 块，dropouts \(a.counters.dropouts)，underruns \(a.counters.underruns)，不连续 \(a.discontinuities)，实时违规 \(a.realtimeViolations)，队列丢块 \(a.tapDrops)；设备 \(a.device.kind) \(a.device.name)：\(a.device.callbacks) 块，最晚醒 / 抖动 \(String(format: "%.3f", a.device.maxJitterMs)) ms；对齐延迟 \(String(format: "%.2f", a.alignmentMs)) ms")
        for i in a.inputs {
            lines.append("  音频输入 \(i.number)：槽位 \(i.slot)，年龄 \(String(format: "%.0f", i.ageSetpointFrames)) 帧，对齐延迟 \(i.alignmentDelayFrames) 帧，补不齐 \(i.residualFrames)，比率 \(String(format: "%+.1f", i.ratioPpm)) ppm，欠载块 \(i.underrunBlocks)，重就绪 \(i.reprimes)，AFV \(String(format: "%.2f", i.afvGain))")
        }
        for c in a.consumers {
            lines.append("  音频消费者 \(c.source) → \(c.consumers)：\(c.blocks) 块 / \(c.frames) 帧，tap 丢 \(c.tapDropped)" + (c.devicePpm.map { String(format: "，设备 %+.2f ppm，重采样比 %.7f，挨饿 %d", $0, c.resampleRatio ?? 1, c.resamplerStarved) } ?? ""))
        }
        for entry in audioInputs {
            let k = entry.source.counters
            lines.append("  音频源 \(entry.number)：写 \(k.blocksWritten) 块 / \(k.framesWritten) 帧，拒 \(k.framesRejected)，迟到 \(k.late)")
        }
        if let rec = recorder {
            let k = rec.counters
            if let r = recordResult {
                lines.append("  录制：\(r.url.path)  视频 \(r.videoFrames) 帧 / 音频 \(r.audioFrames) 样本 / \(String(format: "%.3f", r.durationSeconds)) s / \(r.videoBytes / 1024) KB；编码 skipped \(r.encoder.skipped)，被 writer 拒 \(k.videoFramesRejected)，音频块丢 \(k.audioBlocksDropped)，音频漂移 \(String(format: "%.3f", k.audioDrift.milliseconds)) ms，硬校正 \(k.audioCorrections)，停止拍 \(r.stopTick)")
            } else {
                lines.append("  录制：状态 \(rec.state)，视频 \(k.videoFrames) 帧，编码 skipped \(k.encoder.skipped)")
            }
        }
        if let w = writer {
            lines.append("  stats：\(w.url.path) 写 \(w.writtenLines) 行，丢 \(w.droppedLines)，清洗 \(w.sanitizedLines)")
        }
        if apiServer != nil {
            let b = commandBus.counters, f = stateFeed.counters
            lines.append("  API：命令 \(b.applied) 条应用（其中 \(b.ignored) 条被 reducer 忽略）/ \(b.rejected) 条拒绝 / \(b.queued) 条排过队；推送快照 \(f.snapshots) 条、stats \(f.stats) 条、唤醒 \(f.wakeups) 次")
        }
        print(lines.joined(separator: "\n"))
    }
}
