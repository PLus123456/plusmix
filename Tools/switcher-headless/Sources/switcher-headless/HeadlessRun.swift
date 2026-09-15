import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherAudio
import SwitcherOutputs
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
}

/// 音频输出：空设备（实时假时钟，不出声）或真设备。
enum AudioOutputChoice {
    case null(NullOutputDevice)
    case device(AudioOutputDevice)

    static func make(_ spec: String, mixer: AudioMixer) throws -> AudioOutputChoice {
        switch spec.lowercased() {
        case "null", "none": return .null(NullOutputDevice(mixer: mixer))
        case "default", "": return .device(try AudioOutputDevice(mixer: mixer))
        default:
            guard let info = AudioHAL.device(named: spec) else {
                let names = AudioHAL.devices().filter { $0.outputChannels > 0 }.map(\.name).joined(separator: " / ")
                throw CLIError("找不到音频输出设备「\(spec)」。有：\(names)")
            }
            return .device(try AudioOutputDevice(mixer: mixer, deviceID: info.id))
        }
    }

    func start() throws {
        switch self {
        case .null(let d): try d.start()
        case .device(let d): try d.start()
        }
    }

    func stop() {
        switch self {
        case .null(let d): d.stop()
        case .device(let d): d.stop()
        }
    }

    var summary: String {
        switch self {
        case .null(let d):
            let s = d.stats
            return "空设备：\(s.blocks) 块，跳块 \(s.skippedBlocks)，最晚醒来 \(String(format: "%.3f", s.maxWakeLateMs)) ms"
        case .device(let d):
            let s = d.callbackStats
            return "\(d.info.name)：\(s.callbacks) 次回调，抖动 max \(String(format: "%.3f", s.maxJitterMs)) ms，buffer \(d.actualBlockFrames)"
        }
    }
}

/// 把录制器的编码计数变成 Stats.encoder 的一项：skipped 累计、bitrate 按上次采样以来的窗口算。只在 Stats 采样线程上被调。
final class EncoderStatsSource: @unchecked Sendable {
    private let recorder: Recorder
    private let last = Mutex<(counters: EncoderCounters, at: HostTime)?>(nil)

    init(recorder: Recorder) { self.recorder = recorder }

    func entries() -> [Stats.EncoderEntry] {
        let now = HostClock.now()
        let current = recorder.counters.encoder
        let previous = last.withLock { box -> (counters: EncoderCounters, at: HostTime)? in
            let p = box
            box = (current, now)
            return p
        }
        let window = previous.map { max((now - $0.at).seconds, 1e-3) } ?? 1
        return [current.statsEntry(previous: previous?.counters, windowSeconds: window)]
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
        engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(16, maxNumber))
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

        // 2. 音频：混音器（C 热路径）+ 输出设备；每路带音频的输入挂一个槽位，参数照节目文件。
        let mixer = AudioMixer()
        for (slotIndex, entry) in audioInputs.enumerated() {
            mixer.attach(ring: entry.ring, toSlot: slotIndex)
            mixer.apply(entry.settings, toSlot: slotIndex)
        }
        let audioDevice = try AudioOutputChoice.make(options.audioDevice, mixer: mixer)

        // 3. 录制：Recorder 是 PGM 帧的消费者（有界队列 + 自己的编码线程）；Master 块经泵线程喂给它。
        var recorder: Recorder?
        var pump: AudioPump?
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
            if !audioInputs.isEmpty {
                guard let tap = mixer.addTap(source: .bus(.master)) else { throw CLIError("混音器消费者队列已满") }
                pump = AudioPump(tap: tap, consumer: rec)
            }
            recorder = rec
        }

        // 4. Stats：引擎每秒组一行（铁律 4，只有这一份），编码 / 音频 / GPU 三个来源从这里灌。
        var writer: StatsWriter?
        var gpu: GPUUtilization?
        if let url = options.statsURL {
            let w = try StatsWriter(url: url, append: false)
            if let rec = recorder {
                let source = EncoderStatsSource(recorder: rec)
                engine.encoderStatsProvider = { source.entries() }
            }
            engine.audioStatsProvider = { mixer.audioCounters }
            if options.gpuStats, let g = GPUUtilization() {
                gpu = g
                engine.gpuPercentProvider = { g.deviceUtilizationPercent() }
            }
            writer = w
        }

        // 5. 场景：全部预排程到状态机，按拍应用（跳过的拍也逐拍走，命令不会漏）。
        if let sc = scenario {
            for e in sc.sortedEvents { await stateMachine.schedule(e.command, at: e.tick) }
        }

        // 6. 起：音频设备 → 视频输入（到 t0 才出第一帧）→ 音频输入 → 录制（起点 = 第 0 拍；尽量晚起，
        //    它的入口环只存 256 块 ≈ 1.4 s，起点之前的块留在里面等第一个压缩视频样本到了才会被丢掉）→ 泵 → 引擎（start 里 prepare 渲染器，lead 要盖住它）
        try audioDevice.start()
        for input in inputs { try input.start() }
        for entry in audioInputs { try entry.source.start() }
        if let rec = recorder { try rec.start(at: RecordingStart(clock: spec, tick: .zero)) }
        pump?.start()
        if stopRequested {
            shutdownEarly(inputs: inputs, audioInputs: audioInputs.map(\.source), recorder: recorder, pump: pump, audioDevice: audioDevice, writer: writer)
            return
        }
        try await engine.start(t0: t0, firstTick: .zero, lastTick: lastTick)
        let leadLeft = (t0 - HostClock.now()).milliseconds
        writer?.startSampling(every: 1) { [engine] in engine.makeStats() }
        guard let clock = engine.clock else { throw CLIError("引擎没有时钟") }
        print("""
            switcher-headless \(SwitcherVersion.current)
              节目：\(show.name)（\(options.showURL.path)）\(format.width)×\(format.height)@\(format.frameRate)，\(inputs.count) 路合成源，\(audioInputs.count) 路音频
              场景：\(options.scriptURL?.path ?? "无")（\(scenario?.events.count ?? 0) 个事件）
              时长：\(totalTicks) 拍（\(String(format: "%.1f", options.durationSeconds)) s）  t0 距现在 \(String(format: "%.0f", leadLeft)) ms\(leadLeft < 0 ? "  ⚠️ 起晚了，开头会跳拍" : "")  合成源提前量 \(String(format: "%.2f", inputLeadMs)) ms
              音频：\(options.audioDevice)  录制：\(options.recordURL?.path ?? "无")  stats：\(options.statsURL?.path ?? "无")  GPU 占用：\(gpu == nil ? "不可用" : "IOKit")
              时钟实时策略：\(clock.isRealtime ? "已生效" : "⚠️ 未生效（V3 会超）")
            """)

        // 7. 等：跑完 totalTicks 拍（派发 + 跳过 = 总拍数），或收到信号。
        while !(clock.ticksDispatched + clock.ticksSkipped >= UInt64(totalTicks)) && !stopRequested {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let interrupted = stopRequested

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
        pump?.stop()
        audioDevice.stop()
        for entry in audioInputs { entry.source.stop() }
        writer?.close()

        // 9. 汇总（stdout；数字来源都是各对象的计数器，正式指标以 stats.jsonl / frameprobe 为准）
        printSummary(clock: clock, inputs: inputs, audioInputs: audioInputs.map { (number: $0.number, source: $0.source) }, mixer: mixer,
                     audioDevice: audioDevice, pump: pump, recorder: recorder, recordResult: recordResult, writer: writer, interrupted: interrupted)
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

    private func shutdownEarly(inputs: [SyntheticVideoInput], audioInputs: [SyntheticAudioInput], recorder: Recorder?, pump: AudioPump?,
                               audioDevice: AudioOutputChoice, writer: StatsWriter?) {
        if let rec = recorder {
            let done = DispatchSemaphore(value: 0)
            rec.stop(atTick: .zero) { _ in done.signal() }
            _ = done.wait(timeout: .now() + 10)
        }
        pump?.stop()
        audioDevice.stop()
        for a in audioInputs { a.stop() }
        for input in inputs { input.stop() }
        writer?.close()
        print("引擎启动前收到信号，已收尾退出")
        exitCode = 130
    }

    private func printSummary(clock: ProgramClock, inputs: [SyntheticVideoInput], audioInputs: [(number: Int, source: SyntheticAudioInput)],
                              mixer: AudioMixer, audioDevice: AudioOutputChoice, pump: AudioPump?, recorder: Recorder?,
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
        let a = mixer.stats
        lines.append("  音频：\(a.blocksRendered) 块，dropouts \(a.dropouts)，underruns \(a.underruns)，实时违规 \(a.rtViolations)，队列丢块 \(a.tapDrops)，最长一块 \(String(format: "%.3f", HostDuration(ticks: Int64(a.maxBlockTicks)).milliseconds)) ms；\(audioDevice.summary)" + (pump.map { "；泵搬块 \($0.moved)" } ?? ""))
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
        print(lines.joined(separator: "\n"))
    }
}
