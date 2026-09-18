// 输出接线（W2-B2 接缝 5、6）：把 MixerState.outputs 里"应该在跑"（enabled）的录制 / 推流变成活的 Recorder（W1-E）/ StreamOutput（W2-D），
// 跟着快照起停；Stats.encoder 的项也从这里出（与 outputs 里带编码器的输出同序，测试标准 §7）。
//
// 录制的起点 / 终点都是拍（Recorder 的时间基 = 起始拍的拍点），起 / 停都比命令生效的拍晚 `leadTicks` 拍，两头一样长，
// 所以文件时长 = 两条命令生效拍之差（按钮间隔 ± 1 拍）：
// - 起：起始拍 = startRecord 生效拍 + leadTicks（命令生效拍由总线观察者记下；rec.start 建 VT 会话要几十 ms，得赶在起始拍的帧送到之前，
//   否则那几帧被编码器静默丢掉——W1-E 的 VideoEncoder 在 start 完成前不收帧也不计 skipped）；音频块由 AudioEngine 的泵送来，录制器把第一块裁到起点。
// - 停（引擎不停）：边界拍 = stopRecord 生效拍 + leadTicks，先把两扇门关在边界上（FrameGate：tick ≥ 边界的帧不再送；AudioGate：块按 host time
//   裁到边界时刻，跨边界的块截短），等含边界的音频块送到（边界时刻 + 对齐延迟 + 2 块 + 6 ms，且 ≥ 2 帧让边界前的帧都渲染完）→ 摘音频消费者
//   → rec.stop(atTick: 边界) → 完成后摘帧消费者。先摘消费者再 stop 是绕 W1-E 录制器的收尾问题（reports/issues/W2E-w1-outputs-recorder-drift-check-before-stop.md，
//   W1-E2 修好后可改回先 stop）；AudioGate 是因为录制器在 stop 之前收到的块会整块写进去（stopTime 还没定），headless 没有它就多出 2 块 + 6 ms 的音频。
//   两轨都裁在边界拍点，时长同源相等。
// - 推流：StreamOutput 自己有编码器 + 有界队列 + 重连；起 = start() + 挂消费者，停 = 摘消费者 + stopAsync()。
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
import SwitcherStreaming
import SwitcherAudioIntegration
import SwitcherControl

/// 录制器前面的门：关门之后 tick ≥ 边界的帧不再送进去（引擎不停也能精确到拍收口）。GPU 完成线程上调，只有一次原子读。
final class FrameGate: FrameConsumer, @unchecked Sendable {
    let consumer: any FrameConsumer
    private let boundary = Atomic<Int64>(Int64.max)
    init(consumer: any FrameConsumer) { self.consumer = consumer }
    var consumerName: String { consumer.consumerName }
    func consume(_ frame: RenderedFrame) {
        guard frame.tick.rawValue < boundary.load(ordering: .relaxed) else { return }
        consumer.consume(frame)
    }
    func close(at tick: Tick) { boundary.store(tick.rawValue, ordering: .relaxed) }
}

/// 音频块前面的门：关门之后块按 host time 裁到边界时刻——整块在边界之后的丢掉，跨边界的只送边界之前的样本（平面指针不动，只改帧数）。
/// 泵线程（非实时）上调，一次原子读 + 几次整数运算，不分配。
final class AudioGate: AudioBlockConsumer, @unchecked Sendable {
    let consumer: any AudioBlockConsumer
    private let boundaryTicks = Atomic<UInt64>(UInt64.max)
    init(consumer: any AudioBlockConsumer) { self.consumer = consumer }
    var consumerName: String { consumer.consumerName }
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        let boundary = boundaryTicks.load(ordering: .relaxed)
        var n = frameCount
        if boundary != UInt64.max {
            guard hostTime.ticks < boundary else { return }
            let remaining = HostTime(ticks: boundary) - hostTime
            let allowed = Int((remaining.seconds * Double(AudioFormat.sampleRate)).rounded())
            if allowed < n { n = allowed }
            guard n > 0 else { return }
        }
        consumer.consumeAudio(planes: planes, channelCount: channelCount, frameCount: n, hostTime: hostTime)
    }
    func close(at time: HostTime) { boundaryTicks.store(time.ticks, ordering: .relaxed) }
}

/// 总线观察者：记下 startRecord / stopRecord / startStream / stopStream 生效的拍（回执的 appliedTick），OutputRuntime 用它定起止拍。
/// 在提交方的任务上同步被调（任意线程），只写一个带锁的字典。
final class OutputCommandTicks: CommandBusObserver, @unchecked Sendable {
    private let ticks = Mutex<[Int: Tick]>([:])
    func commandBus(_ bus: CommandBus, didApply entry: CommandLogEntry) {
        guard entry.applied else { return }
        switch entry.command {
        case .startRecord(let n), .stopRecord(let n), .startStream(let n), .stopStream(let n):
            ticks.withLock { $0[n] = entry.appliedTick }
        default:
            break
        }
    }
    /// 取走某输出最近一条起停命令的生效拍。
    func take(output number: Int) -> Tick? { ticks.withLock { $0.removeValue(forKey: number) } }
}

/// 输出运行表（主线程）。
@MainActor
final class OutputRuntime {
    enum Event: Equatable {
        case recordingStarted(output: Int, url: URL)
        case recordingStopped(output: Int, url: URL, frames: UInt64, seconds: Double)
        case recordingFailed(output: Int, message: String)
        case streamStarted(output: Int)
        case streamStopped(output: Int)
        case streamFailed(output: Int, message: String)
    }

    /// 一路在跑的录制（主线程改，封口回调经主线程；标 @unchecked Sendable 只为能捕获进回调）。
    final class RecordEntry: @unchecked Sendable {
        let output: OutputState
        let recorder: Recorder
        let gate: FrameGate
        let audioGate: AudioGate
        let start: RecordingStart
        var audioToken: AudioConsumerToken?
        var stopping = false
        init(output: OutputState, recorder: Recorder, gate: FrameGate, audioGate: AudioGate, start: RecordingStart) {
            self.output = output
            self.recorder = recorder
            self.gate = gate
            self.audioGate = audioGate
            self.start = start
        }
    }

    final class StreamEntry: @unchecked Sendable {
        let output: OutputState
        let stream: StreamOutput
        var audioToken: AudioConsumerToken?
        var stopping = false
        init(output: OutputState, stream: StreamOutput) {
            self.output = output
            self.stream = stream
        }
    }

    private let engine: Engine
    private let audio: AudioRuntime?
    private let format: ProgramFormat
    /// 节目名（文件名模板的 {show}）。
    var showName: String
    /// 当前节目时钟（引擎起了才有）。
    var clock: TickClockSpec?
    var onEvent: ((Event) -> Void)?
    /// 起停命令生效拍的记录（挂在总线上）。
    let commandTicks = OutputCommandTicks()
    /// 起 / 停都比命令生效拍晚这么多拍：要盖住 rec.start（VT 会话创建 + PrepareToEncodeFrames）和主线程 1/60 s 的快照轮询。
    static let leadTicks = 10
    /// 最近一次 rec.start 花的时间（诊断 / 测试看）。
    private(set) var lastStartCost: HostDuration = .zero

    private(set) var recorders: [Int: RecordEntry] = [:]
    private(set) var streams: [Int: StreamEntry] = [:]
    /// 已停的录制器 / 推流（Stats 里继续报 stopped / failed，直到该输出再次起来）。
    private var finishedRecorders: [Int: Recorder] = [:]
    private var finishedStreams: [Int: StreamOutput] = [:]
    /// 起不来的输出（enabled 仍为 true）：不反复重试，等它被关掉再清。
    private(set) var failed: [Int: String] = [:]
    private(set) var lastResults: [Int: RecordingResult] = [:]
    private var lastOutputs: [OutputState] = []
    private let stats = EncoderStatsSource()

    init(engine: Engine, audio: AudioRuntime?, format: ProgramFormat, showName: String) {
        self.engine = engine
        self.audio = audio
        self.format = format
        self.showName = showName
    }

    /// Stats.encoder（采样线程上调）。
    var statsProvider: @Sendable () -> [Stats.EncoderEntry] {
        let s = stats
        return { s.entries() }
    }

    // MARK: 跟快照

    /// 让运行表跟上快照：enabled 且没在跑的起，不 enabled 且在跑的停，消失的停。
    func reconcile(_ state: MixerState) {
        lastOutputs = state.outputs
        let wanted = Dictionary(uniqueKeysWithValues: state.outputs.map { ($0.number, $0) })
        for (n, e) in recorders where wanted[n]?.kind != .record && !e.stopping { stopRecording(n) }
        for (n, e) in streams where wanted[n]?.kind != .stream && !e.stopping { stopStream(n) }
        for (n, _) in failed where wanted[n]?.enabled != true { failed.removeValue(forKey: n) }
        for output in state.outputs {
            switch output.kind {
            case .record:
                if output.enabled, recorders[output.number] == nil, failed[output.number] == nil { startRecording(output) }
                else if !output.enabled, let e = recorders[output.number], !e.stopping { stopRecording(output.number) }
            case .stream:
                if output.enabled, streams[output.number] == nil, failed[output.number] == nil { startStream(output) }
                else if !output.enabled, let e = streams[output.number], !e.stopping { stopStream(output.number) }
            default:
                break
            }
        }
        rebuildStats()
    }

    /// 停掉全部（换节目 / 退出）：录制封口等到完成（每个最多 10 s）。
    func stopAll() async {
        for n in recorders.keys.sorted() where !recorders[n]!.stopping { stopRecording(n) }
        for n in streams.keys.sorted() where !streams[n]!.stopping { stopStream(n) }
        let deadline = Date().addingTimeInterval(10)
        while (!recorders.isEmpty || !streams.isEmpty) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !recorders.isEmpty || !streams.isEmpty {
            NSLog("输出没在 10 s 内停完：录制 \(recorders.keys.sorted())，推流 \(streams.keys.sorted())")
            for (_, e) in recorders { engine.removeConsumer(e.gate) }
            for (_, e) in streams { engine.removeConsumer(e.stream) }
            recorders.removeAll()
            streams.removeAll()
        }
        rebuildStats()
    }

    // MARK: 录制

    private func startRecording(_ output: OutputState) {
        guard let clock else { return }   // 引擎还没起：等 start 后的 reconcile
        let settings = output.settings
        let record = settings.record ?? RecordSettings(directory: ShowDocuments.defaultRecordDirectory)
        let url = record.outputURL(showName: showName, outputName: output.name)
        let cfg = Recorder.Configuration(url: url, format: format, video: settings.video ?? VideoEncodeSettings(),
                                         audio: settings.audio ?? AudioEncodeSettings(), audioChannels: 2,
                                         fragmentIntervalSeconds: record.fragmentIntervalSeconds, remuxToMP4: record.remuxToMP4,
                                         name: "record\(output.number)")
        let rec = Recorder(configuration: cfg)
        // 起始拍：命令生效拍 + lead；主线程来晚了（轮询 / 卡顿）就至少从现在之后第 2 拍起，别让已经送到的帧算进去
        let applied = commandTicks.take(output: output.number)
        let startTick = max(applied.map { $0 + Self.leadTicks } ?? Tick(Int64.min), clock.tick(at: .now()) + 2)
        let start = RecordingStart(clock: clock, tick: startTick)
        let began = HostClock.now()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rec.start(at: start)
        } catch {
            let message = "录制 \(output.number) 起不来：\(error)"
            NSLog("%@", message)
            failed[output.number] = message
            finishedRecorders[output.number] = rec   // Stats 里报 failed
            onEvent?(.recordingFailed(output: output.number, message: message))
            return
        }
        lastStartCost = HostClock.now() - began
        let margin = clock.time(of: startTick) - HostClock.now()
        if margin.ticks < 0 {
            NSLog("录制 \(output.number)：rec.start 花了 \(String(format: "%.1f", lastStartCost.milliseconds)) ms，起始拍已过 \(String(format: "%.1f", -margin.milliseconds)) ms，开头会少帧")
        }
        let gate = FrameGate(consumer: rec)
        let audioGate = AudioGate(consumer: rec)
        engine.addConsumer(gate)
        let entry = RecordEntry(output: output, recorder: rec, gate: gate, audioGate: audioGate, start: start)
        if let audio {
            do { entry.audioToken = try audio.engine.addConsumer(audioGate, source: .master) } catch { NSLog("录制 \(output.number) 挂不上音频：\(error)") }
        }
        recorders[output.number] = entry
        finishedRecorders.removeValue(forKey: output.number)
        onEvent?(.recordingStarted(output: output.number, url: url))
    }

    private func stopRecording(_ number: Int) {
        guard let entry = recorders[number], !entry.stopping, let clock else { return }
        entry.stopping = true
        // 边界拍：命令生效拍 + lead（与起点同样的提前量，时长 = 两条命令生效拍之差）；主线程来晚了就至少是现在之后第 1 拍（那一拍的帧还没送到）
        let applied = commandTicks.take(output: number)
        var boundary = max(applied.map { $0 + Self.leadTicks } ?? Tick(Int64.min), clock.tick(at: .now()) + 1)
        if boundary < entry.start.tick { boundary = entry.start.tick }
        let boundaryTime = clock.time(of: boundary)
        entry.gate.close(at: boundary)
        entry.audioGate.close(at: boundaryTime)
        var wait = clock.duration(ofTicks: 2)
        if let audio {
            let audioWait = audio.engine.alignmentDuration + audio.engine.blockDuration * 2 + HostDuration(milliseconds: 6)
            if audioWait > wait { wait = audioWait }
        }
        let deadline = boundaryTime + wait
        Task { @MainActor [weak self] in
            let remaining = deadline - HostClock.now()
            if remaining.ticks > 0 { try? await Task.sleep(for: .nanoseconds(Int(remaining.nanoseconds))) }
            if let token = entry.audioToken {
                self?.audio?.engine.removeConsumer(token)
                entry.audioToken = nil
            }
            entry.recorder.stop(atTick: boundary) { result in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRecording(number, entry: entry, result: result) } }
            }
        }
    }

    private func finishRecording(_ number: Int, entry: RecordEntry, result: Result<RecordingResult, any Error>) {
        engine.removeConsumer(entry.gate)
        if recorders[number] === entry { recorders.removeValue(forKey: number) }
        finishedRecorders[number] = entry.recorder
        switch result {
        case .success(let r):
            lastResults[number] = r
            onEvent?(.recordingStopped(output: number, url: r.url, frames: r.videoFrames, seconds: r.durationSeconds))
        case .failure(let e):
            onEvent?(.recordingFailed(output: number, message: "录制 \(number) 封口失败：\(e)"))
        }
        rebuildStats()
        // 停的过程中又被打开：按最新快照再起一次
        if let output = lastOutputs.first(where: { $0.number == number }), output.kind == .record, output.enabled, failed[number] == nil {
            startRecording(output)
            rebuildStats()
        }
    }

    // MARK: 推流

    private func startStream(_ output: OutputState) {
        let settings = output.settings
        guard let streamSettings = settings.stream, !streamSettings.url.isEmpty else {
            let message = "推流 \(output.number) 没有地址"
            failed[output.number] = message
            onEvent?(.streamFailed(output: output.number, message: message))
            return
        }
        let video = settings.video ?? VideoEncodeSettings()
        let cfg = StreamOutput.Configuration(name: "stream\(output.number)", format: format, video: video,
                                             audio: settings.audio ?? AudioEncodeSettings(), audioChannels: 2, stream: streamSettings)
        let stream: StreamOutput
        do {
            stream = try StreamOutput(configuration: cfg, transportFactory: HaishinKitTransportFactory(format: format, video: video))
            try stream.start()
        } catch {
            let message = "推流 \(output.number) 起不来：\(error)"
            NSLog("%@", message)
            failed[output.number] = message
            onEvent?(.streamFailed(output: output.number, message: message))
            return
        }
        engine.addConsumer(stream)
        let entry = StreamEntry(output: output, stream: stream)
        if let audio {
            do { entry.audioToken = try audio.engine.addConsumer(stream, source: .master) } catch { NSLog("推流 \(output.number) 挂不上音频：\(error)") }
        }
        streams[output.number] = entry
        finishedStreams.removeValue(forKey: output.number)
        onEvent?(.streamStarted(output: output.number))
    }

    private func stopStream(_ number: Int) {
        guard let entry = streams[number], !entry.stopping else { return }
        entry.stopping = true
        engine.removeConsumer(entry.stream)
        if let token = entry.audioToken {
            audio?.engine.removeConsumer(token)
            entry.audioToken = nil
        }
        Task { @MainActor [weak self] in
            await entry.stream.stopAsync()
            guard let self else { return }
            if self.streams[number] === entry { self.streams.removeValue(forKey: number) }
            self.finishedStreams[number] = entry.stream
            self.onEvent?(.streamStopped(output: number))
            self.rebuildStats()
            if let output = self.lastOutputs.first(where: { $0.number == number }), output.kind == .stream, output.enabled, self.failed[number] == nil {
                self.startStream(output)
                self.rebuildStats()
            }
        }
    }

    // MARK: Stats

    /// Stats.encoder 的来源表：与 outputs 里带编码器的输出（record / stream / ndi）同序；没在跑的报 idle / stopped / failed。
    private func rebuildStats() {
        var sources: [EncoderStatsSource.Source] = []
        for output in lastOutputs {
            switch output.kind {
            case .record:
                if let e = recorders[output.number] { sources.append(.recorder(e.recorder)) }
                else if let r = finishedRecorders[output.number] { sources.append(.recorder(r)) }
                else { sources.append(.idleRecord(directory: output.settings.record?.directory ?? ShowDocuments.defaultRecordDirectory)) }
            case .stream:
                if let e = streams[output.number] { sources.append(.stream(e.stream)) }
                else if let s = finishedStreams[output.number] { sources.append(.stream(s)) }
                else { sources.append(.idle) }
            case .ndi:
                sources.append(.idle)   // NDI 发送的 App 接线在 W3-C
            default:
                break
            }
        }
        stats.replace(sources)
    }
}

/// 把录制器 / 推流的计数变成 Stats.encoder 的项（每个输出一项，顺序 = outputs 顺序）：skipped / frames / dropped / disk_free_mb /
/// reconnects / state 由各自的 statsEntry 填，bitrate 按上次采样以来的窗口算。只在 Stats 采样线程上被调；表由主线程换。
final class EncoderStatsSource: @unchecked Sendable {
    enum Source {
        case recorder(Recorder)
        case stream(StreamOutput)
        case idleRecord(directory: String)
        case idle
    }

    private struct Slot {
        var source: Source
        var previousRecorder: RecorderCounters?
        var previousStream: StreamCounters?
        var at: HostTime?
    }

    private let slots = Mutex<[Slot]>([])

    func replace(_ sources: [Source]) {
        slots.withLock { old in
            // 同一对象继续用上次的计数（窗口不断）；换了对象就从头算
            old = sources.map { s in
                let prev = old.first { same($0.source, s) }
                return Slot(source: s, previousRecorder: prev?.previousRecorder, previousStream: prev?.previousStream, at: prev?.at)
            }
        }
    }

    private func same(_ a: Source, _ b: Source) -> Bool {
        switch (a, b) {
        case (.recorder(let x), .recorder(let y)): x === y
        case (.stream(let x), .stream(let y)): x === y
        default: false
        }
    }

    func entries() -> [Stats.EncoderEntry] {
        let now = HostClock.now()
        return slots.withLock { list in
            var out: [Stats.EncoderEntry] = []
            for i in list.indices {
                let window = list[i].at.map { max((now - $0).seconds, 1e-3) } ?? 1
                switch list[i].source {
                case .recorder(let r):
                    let c = r.counters
                    out.append(c.statsEntry(previous: list[i].previousRecorder, windowSeconds: window, state: r.state.statsName))
                    list[i].previousRecorder = c
                case .stream(let s):
                    let c = s.counters
                    out.append(c.statsEntry(previous: list[i].previousStream, windowSeconds: window, encoderSkipped: s.videoEncoder.counters.skipped))
                    list[i].previousStream = c
                case .idleRecord(let directory):
                    let free = Recorder.freeBytes(for: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("x.mov"))   // 按文件路径取所在卷
                    out.append(Stats.EncoderEntry(skipped: 0, bitrate: 0, diskFreeMb: Double(free) / 1_048_576, state: "idle"))
                case .idle:
                    out.append(Stats.EncoderEntry(skipped: 0, bitrate: 0, state: "idle"))
                }
                list[i].at = now
            }
            return out
        }
    }
}
