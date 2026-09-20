// 输出接线（W2-B2 接缝 5、6；W3-C 加 ISO 分路、同一拍起停、磁盘保护）：把 MixerState.outputs 里"应该在跑"（enabled）的录制 / 推流
// 变成活的 Recorder（W1-E）/ StreamOutput（W2-D），跟着快照起停；Stats.encoder 的项也从这里出（与 outputs 里带编码器的输出同序，测试标准 §7）。
//
// 录制的起点 / 终点都是拍（Recorder 的时间基 = 起始拍的拍点），由 SharedTickPlanner（SwitcherISO）定：
// - 起：同一次 reconcile 里新打开的录制输出是一批，共用一个起始拍 = max(现在 + 2, 最晚的生效拍 + 10 + 每多一路 3 拍)；上一批的拍还在
//   现在之后 ≥ 6 拍的，后来的路沿用它（ISO = 同一拍发多条 startRecord，CONTRACTS.md §8）。rec.start（VT 会话）对一批并发做，主线程等它们完成。
// - 停：边界拍 = 生效拍 + 10（与起点同样的提前量，文件时长 = 两条命令生效拍之差），命令生效就 rec.stop(atTick: 边界)：录制器自己等边界前的帧、
//   截两轨到边界、越界块入口就丢（W1-E2），不用再等音频块、也不用先摘消费者（G4 交接第 3 条：撤了 W2-B2 的 FrameGate / AudioGate）。
// - 视频 ISO（settings.source = .input(n)）：引擎 → ISOFrameTap（该路的分支槽上按拍挑帧）→ Recorder；音轨挂 AudioTapSource.input(number:)
//   （推子后、AFV 前）；没注册音频的路不带音轨。文件是节目尺寸（VT 直接吃各路的尺寸 / 格式）。
// - 磁盘（S7）：RecordingDiskMonitor 每秒看每路的剩余空间（DiskGuard.freeBytes，非启动卷也对）：跌破警戒线提示；跌破下限或写满 →
//   有备用目录就在下一拍把那一路切到备用目录继续录（S7 目标档），否则只停那一路（发 stopRecord 让快照一致）并提示；推流 / 渲染不在这条链上。
//   Recorder 自己的 minimumFreeBytes 设 0（它的 freeBytes 在非启动卷上是 0，见 reports/issues/W3C-w1-outputs-recorder-freebytes-nonboot-volume.md）。
// - 推流：StreamOutput 自己有编码器 + 有界队列 + 重连；起 = start() + 挂消费者，停 = 摘消费者 + stopAsync()。
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
import SwitcherStreaming
import SwitcherAudioIntegration
import SwitcherControl
import SwitcherISO

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
        /// 磁盘剩余空间跌破警戒线（提示）。
        case recordingDiskLow(output: Int, freeMB: Double)
        /// 磁盘满 / 低于下限，切到备用目录继续录。
        case recordingSwitchedToFallback(output: Int, url: URL)
        case streamStarted(output: Int)
        case streamStopped(output: Int)
        case streamFailed(output: Int, message: String)
    }

    /// 一路在跑的录制（主线程改，封口回调经主线程；标 @unchecked Sendable 只为能捕获进回调）。
    final class RecordEntry: @unchecked Sendable {
        let output: OutputState
        let recorder: Recorder
        /// 挂在引擎上的消费者：PGM 路 = recorder 本身；ISO 路 = ISOFrameTap（下游是 recorder）。
        let consumer: any FrameConsumer
        /// ISO 路的分支槽（停时还给输入）。
        let branch: LockFreeFrameSlot?
        let start: RecordingStart
        var audioToken: AudioConsumerToken?
        var stopping = false
        /// 已经切到备用目录（不再切第二次）。
        var onFallback = false
        init(output: OutputState, recorder: Recorder, consumer: any FrameConsumer, branch: LockFreeFrameSlot?, start: RecordingStart) {
            self.output = output
            self.recorder = recorder
            self.consumer = consumer
            self.branch = branch
            self.start = start
        }
        var url: URL { recorder.configuration.url }
        var inputNumber: Int? { if case .input(let n) = output.settings.source { n } else { nil } }
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
    private let inputs: InputRuntime?
    private let format: ProgramFormat
    /// 节目名（文件名模板的 {show}）。
    var showName: String
    /// 当前节目时钟（引擎起了才有）。
    var clock: TickClockSpec?
    var onEvent: ((Event) -> Void)?
    /// 往命令总线发命令（磁盘满停录制时让快照一致）。
    var sendCommand: ((Command) -> Void)?
    /// 磁盘策略（AppSettings）。
    var fallbackDirectory: String?
    var minimumFreeBytes: UInt64 = 200 * 1024 * 1024
    /// 起停命令生效拍的记录（挂在总线上）。
    let commandTicks = OutputCommandTicks()
    /// 起 / 停都比命令生效拍晚这么多拍（SharedTickPlanner.start / .stop 的 leadTicks）。
    static let leadTicks = SharedTickPlanner.start.leadTicks
    /// 最近一次（一批）rec.start 花的时间（诊断 / 测试看）。
    private(set) var lastStartCost: HostDuration = .zero
    private var startPlanner = SharedTickPlanner.start
    private var stopPlanner = SharedTickPlanner.stop

    private(set) var recorders: [Int: RecordEntry] = [:]
    private(set) var streams: [Int: StreamEntry] = [:]
    /// 已停的录制器 / 推流（Stats 里继续报 stopped / failed，直到该输出再次起来）。
    private var finishedRecorders: [Int: Recorder] = [:]
    private var finishedStreams: [Int: StreamOutput] = [:]
    /// 起不来的输出（enabled 仍为 true）：不反复重试，等它被关掉再清。
    private(set) var failed: [Int: String] = [:]
    private(set) var lastResults: [Int: RecordingResult] = [:]
    /// 每路最近一次的磁盘事件（测试 / 面板看）。
    private(set) var diskEvents: [Int: RecordingDiskMonitor.Event] = [:]
    private var lastOutputs: [OutputState] = []
    private let stats = EncoderStatsSource()
    let diskMonitor = RecordingDiskMonitor(warnBelowBytes: 1024 * 1024 * 1024, interval: 1)

    init(engine: Engine, audio: AudioRuntime?, inputs: InputRuntime?, format: ProgramFormat, showName: String) {
        self.engine = engine
        self.audio = audio
        self.inputs = inputs
        self.format = format
        self.showName = showName
        diskMonitor.onEvent = { [weak self] key, event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleDisk(output: key, event: event) } }
        }
        diskMonitor.start()
    }

    /// Stats.encoder（采样线程上调）。
    var statsProvider: @Sendable () -> [Stats.EncoderEntry] {
        let s = stats
        return { s.entries() }
    }

    // MARK: 跟快照

    /// 让运行表跟上快照：enabled 且没在跑的起（同一批共用起始拍），不 enabled 且在跑的停（共用边界拍），消失的停。
    func reconcile(_ state: MixerState) {
        lastOutputs = state.outputs
        let wanted = Dictionary(uniqueKeysWithValues: state.outputs.map { ($0.number, $0) })
        var toStop: [Int] = []
        for (n, e) in recorders where wanted[n]?.kind != .record && !e.stopping { toStop.append(n) }
        for (n, e) in streams where wanted[n]?.kind != .stream && !e.stopping { stopStream(n) }
        for (n, _) in failed where wanted[n]?.enabled != true { failed.removeValue(forKey: n) }
        var toStart: [OutputState] = []
        for output in state.outputs {
            switch output.kind {
            case .record:
                if output.enabled, recorders[output.number] == nil, failed[output.number] == nil { toStart.append(output) }
                else if !output.enabled, let e = recorders[output.number], !e.stopping { toStop.append(output.number) }
            case .stream:
                if output.enabled, streams[output.number] == nil, failed[output.number] == nil { startStream(output) }
                else if !output.enabled, let e = streams[output.number], !e.stopping { stopStream(output.number) }
            default:
                break
            }
        }
        if !toStop.isEmpty { stopRecordings(toStop) }
        if !toStart.isEmpty { startRecordings(toStart) }
        rebuildStats()
    }

    /// 停掉全部（换节目 / 退出）：录制封口等到完成（每个最多 10 s）。先忘掉快照里的目标状态，封口完成后才不会按"仍 enabled"再起一次。
    func stopAll() async {
        lastOutputs = []
        diskMonitor.stop()
        let running = recorders.keys.sorted().filter { !recorders[$0]!.stopping }
        if !running.isEmpty { stopRecordings(running) }
        for n in streams.keys.sorted() where !streams[n]!.stopping { stopStream(n) }
        let deadline = Date().addingTimeInterval(10)
        while (!recorders.isEmpty || !streams.isEmpty) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !recorders.isEmpty || !streams.isEmpty {
            NSLog("输出没在 10 s 内停完：录制 \(recorders.keys.sorted())，推流 \(streams.keys.sorted())")
            for (_, e) in recorders { engine.removeConsumer(e.consumer) }
            for (_, e) in streams { engine.removeConsumer(e.stream) }
            recorders.removeAll()
            streams.removeAll()
        }
        startPlanner.reset()
        stopPlanner.reset()
        rebuildStats()
    }

    // MARK: 录制

    /// 一批录制输出同一拍起：先给整批定起始拍，再并发建会话，最后挂消费者。
    private func startRecordings(_ outputs: [OutputState]) {
        guard let clock else { return }   // 引擎还没起：等 start 后的 reconcile
        let applied = outputs.map { commandTicks.take(output: $0.number) }
        let startTick = startPlanner.plan(batch: applied, clock: clock, now: .now())
        let start = RecordingStart(clock: clock, tick: startTick)
        // 建录制器（主线程：算路径、分支槽、音轨）
        var prepared: [(OutputState, Recorder, LockFreeFrameSlot?)] = []
        var usedURLs = Set(recorders.values.map(\.url))
        for output in outputs {
            var record = output.settings.record ?? RecordSettings(directory: ShowDocuments.defaultRecordDirectory)
            // 相对目录（headless 的场景文件写 "."，那是相对仓库根）在 App 里没有可靠的 cwd（Finder 起的是 /），一律挂到默认录制目录下
            if !record.directory.hasPrefix("/") {
                record.directory = (ShowDocuments.defaultRecordDirectory as NSString).appendingPathComponent(record.directory)
            }
            var url = record.outputURL(showName: showName, outputName: output.name)
            if usedURLs.contains(url) {   // 同一秒起的几路模板里没有 {output} 时会同名：加编号
                url = url.deletingPathExtension().appendingPathExtension("\(output.number).mov")
            }
            usedURLs.insert(url)
            var branch: LockFreeFrameSlot?
            var hasAudio = audio != nil
            if let n = output.settings.source.inputNumber {
                guard let b = inputs?.openBranch(input: n) else {
                    fail(output: output.number, "ISO 输入 \(n) 不存在或分支用完（每路最多 \(InputFrameTee.maxBranches) 个 ISO / Aux）")
                    continue
                }
                branch = b
                hasAudio = audio?.registeredInputs.contains(n) ?? false   // 音轨挂 .input(n)，在 attach 里
            }
            let cfg = Recorder.Configuration(url: url, format: format, video: output.settings.video ?? VideoEncodeSettings(),
                                             audio: hasAudio ? (output.settings.audio ?? AudioEncodeSettings()) : nil, audioChannels: 2,
                                             fragmentIntervalSeconds: record.fragmentIntervalSeconds, remuxToMP4: record.remuxToMP4,
                                             minimumFreeBytes: 0, name: "record\(output.number)")
            prepared.append((output, Recorder(configuration: cfg), branch))
        }
        guard !prepared.isEmpty else { return }
        // 并发 start（VT 会话创建 64–80 ms 一个），主线程等整批
        final class Errors: @unchecked Sendable {
            let lock = NSLock()
            var byNumber: [Int: String] = [:]
        }
        let errors = Errors()
        let began = HostClock.now()
        let group = DispatchGroup()
        for (output, rec, _) in prepared {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(at: rec.configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try rec.start(at: start)
                } catch {
                    errors.lock.withLock { errors.byNumber[output.number] = "\(error)" }
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 5)
        lastStartCost = HostClock.now() - began
        let margin = clock.time(of: startTick) - HostClock.now()
        if margin.ticks < 0 {
            NSLog("录制批 \(prepared.map(\.0.number))：rec.start 花了 \(String(format: "%.1f", lastStartCost.milliseconds)) ms，起始拍已过 \(String(format: "%.1f", -margin.milliseconds)) ms，开头会少帧")
        }
        for (output, rec, branch) in prepared {
            let number = output.number
            if let message = errors.lock.withLock({ errors.byNumber[number] }) {
                if let branch, let n = output.settings.source.inputNumber { inputs?.releaseBranch(branch, input: n) }
                finishedRecorders[number] = rec   // Stats 里报 failed
                fail(output: number, "录制 \(number) 起不来：\(message)")
                continue
            }
            attach(output: output, recorder: rec, branch: branch, start: start)
        }
    }

    /// 挂消费者（帧 + 音频 + 磁盘监视），登记运行表。
    private func attach(output: OutputState, recorder rec: Recorder, branch: LockFreeFrameSlot?, start: RecordingStart) {
        let number = output.number
        let consumer: any FrameConsumer
        var audioSource: AudioTapSource = .master
        if let n = output.settings.source.inputNumber, let branch {
            consumer = ISOFrameTap(inputNumber: n, branch: branch, sink: rec, name: "iso\(number)")
            audioSource = .input(number: n)
        } else {
            consumer = rec
        }
        engine.addConsumer(consumer)
        let entry = RecordEntry(output: output, recorder: rec, consumer: consumer, branch: branch, start: start)
        if let audio, rec.configuration.audio != nil {
            do { entry.audioToken = try audio.engine.addConsumer(rec, source: audioSource) } catch { NSLog("录制 \(number) 挂不上音频：\(error)") }
        }
        recorders[number] = entry
        finishedRecorders.removeValue(forKey: number)
        diskEvents.removeValue(forKey: number)
        diskMonitor.add(rec, key: number, minimumFreeBytes: minimumFreeBytes)
        onEvent?(.recordingStarted(output: number, url: rec.configuration.url))
    }

    private func fail(output number: Int, _ message: String) {
        NSLog("%@", message)
        failed[number] = message
        onEvent?(.recordingFailed(output: number, message: message))
    }

    /// 一批录制同一拍停：边界拍 = 生效拍 + lead（主线程来晚了就至少是现在之后第 1 拍），命令生效就 rec.stop(atTick:)。
    private func stopRecordings(_ numbers: [Int]) {
        guard let clock else { return }
        let entries = numbers.compactMap { recorders[$0] }.filter { !$0.stopping }
        guard !entries.isEmpty else { return }
        let applied = entries.map { commandTicks.take(output: $0.output.number) }
        let boundary = stopPlanner.plan(batch: applied, clock: clock, now: .now())
        for entry in entries {
            entry.stopping = true
            let number = entry.output.number
            let tick = max(boundary, entry.start.tick)
            entry.recorder.stop(atTick: tick) { [weak self] result in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRecording(number, entry: entry, result: result) } }
            }
        }
    }

    private func finishRecording(_ number: Int, entry: RecordEntry, result: Result<RecordingResult, any Error>) {
        engine.removeConsumer(entry.consumer)
        if let token = entry.audioToken {
            audio?.engine.removeConsumer(token)
            entry.audioToken = nil
        }
        if let branch = entry.branch, let n = entry.inputNumber { inputs?.releaseBranch(branch, input: n) }
        diskMonitor.remove(key: number)
        if recorders[number] === entry { recorders.removeValue(forKey: number) }
        finishedRecorders[number] = entry.recorder
        switch result {
        case .success(let r):
            lastResults[number] = r
            onEvent?(.recordingStopped(output: number, url: r.url, frames: r.videoFrames, seconds: r.durationSeconds))
        case .failure(let e):
            onEvent?(.recordingFailed(output: number, message: L("notice.recordingFinishFailed", number, "\(e)")))
        }
        rebuildStats()
        // 停的过程中又被打开：按最新快照再起一次
        if let output = lastOutputs.first(where: { $0.number == number }), output.kind == .record, output.enabled, failed[number] == nil, recorders[number] == nil {
            startRecordings([output])
            rebuildStats()
        }
    }

    // MARK: 磁盘（S7）

    private func handleDisk(output number: Int, event: RecordingDiskMonitor.Event) {
        diskEvents[number] = event
        guard let entry = recorders[number], !entry.stopping else { return }
        switch event {
        case .lowSpace(let free):
            onEvent?(.recordingDiskLow(output: number, freeMB: Double(free) / 1_048_576))
        case .belowMinimum(let free):
            let reason = "录制 \(number)：磁盘剩余 \(Int(free / 1_048_576)) MB，低于下限 \(Int(minimumFreeBytes / 1_048_576)) MB"
            if canFallback(entry) {
                switchToFallback(entry, reason: reason)
            } else {
                stopForDisk(entry, reason: reason)
            }
        case .failed(let cause, let message, _):
            guard cause == .disk else {
                fail(output: number, "录制 \(number) 失败：\(message)")
                if let clock { entry.stopping = true; entry.recorder.stop(atTick: clock.tick(at: .now())) { [weak self] r in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRecording(number, entry: entry, result: r) } } } }
                return
            }
            let reason = "录制 \(number)：磁盘满（\(message.prefix(80))）"
            if canFallback(entry) {
                switchToFallback(entry, reason: reason)
            } else {
                stopForDisk(entry, reason: reason)
            }
        }
    }

    private func canFallback(_ entry: RecordEntry) -> Bool {
        guard let dir = fallbackDirectory, !dir.isEmpty, !entry.onFallback else { return false }
        return entry.url.deletingLastPathComponent().standardizedFileURL.path != URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL.path
    }

    /// 只停这一路：置 failed（reconcile 不重起）、发 stopRecord 让快照的 enabled 回 false、提示。录制器已失败的直接封口；还在录的按边界停。
    private func stopForDisk(_ entry: RecordEntry, reason: String) {
        let number = entry.output.number
        failed[number] = reason
        onEvent?(.recordingFailed(output: number, message: reason))
        sendCommand?(.stopRecord(output: number))
        guard let clock else { return }
        entry.stopping = true
        entry.recorder.stop(atTick: clock.tick(at: .now()) + 1) { [weak self] r in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRecording(number, entry: entry, result: r) } }
        }
    }

    /// 切备用目录：停旧录制器（失败的直接封口），下一拍在备用目录起新的，运行表换成新的。
    private func switchToFallback(_ entry: RecordEntry, reason: String) {
        guard let clock, let dir = fallbackDirectory else { return }
        let number = entry.output.number
        entry.stopping = true
        entry.onFallback = true
        let boundary = clock.tick(at: .now()) + 2
        let url = RecordingFallback.url(for: entry.url, directory: dir)
        var cfg = entry.recorder.configuration
        cfg.url = url
        let rec = Recorder(configuration: cfg)
        let start = RecordingStart(clock: clock, tick: boundary)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rec.start(at: start)
        } catch {
            stopForDisk(entry, reason: reason + "；备用目录也起不来：\(error)")
            return
        }
        // 旧的停在同一边界；封口回调只做清理（运行表里已经是新的了）
        let old = entry
        old.recorder.stop(atTick: boundary) { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.engine.removeConsumer(old.consumer)
                    if let token = old.audioToken { self.audio?.engine.removeConsumer(token) }
                    if case .success(let res) = r { self.lastResults[number] = res }
                }
            }
        }
        var branch: LockFreeFrameSlot?
        if let n = entry.inputNumber { branch = inputs?.openBranch(input: n) }
        diskMonitor.remove(key: number)
        attach(output: entry.output, recorder: rec, branch: branch, start: start)
        recorders[number]?.onFallback = true
        onEvent?(.recordingSwitchedToFallback(output: number, url: url))
        NSLog("%@", reason + "，已切到备用目录 \(url.path)")
        rebuildStats()
    }

    // MARK: 推流

    private func startStream(_ output: OutputState) {
        let settings = output.settings
        guard let streamSettings = settings.stream, !streamSettings.url.isEmpty else {
            let message = L("notice.streamNoURL", output.number)
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
            let message = L("notice.streamFailed", output.number, "\(error)")
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
                sources.append(.idle)   // NDI 发送的 App 接线（W3-A 的输入之后）
            default:
                break
            }
        }
        stats.replace(sources)
    }

    // MARK: 磁盘余量（ISO 面板）

    /// 某个录制目录现在还能录多久（按所选录制输出的码率之和）。
    static func estimate(directory: String, outputs: [OutputState], reserveBytes: UInt64) -> (freeBytes: UInt64, seconds: Double) {
        let dir = directory.hasPrefix("/") ? directory : (ShowDocuments.defaultRecordDirectory as NSString).appendingPathComponent(directory)
        let free = DiskGuard.freeBytes(for: URL(fileURLWithPath: dir, isDirectory: true))
        let bps = outputs.reduce(0.0) { $0 + DiskEstimate.bytesPerSecond(video: $1.settings.video ?? VideoEncodeSettings(), audio: $1.settings.audio ?? AudioEncodeSettings()) }
        return (free, DiskEstimate.remainingSeconds(freeBytes: free, reserveBytes: reserveBytes, bytesPerSecond: bps))
    }
}

extension OutputSource {
    /// `.input(n)` 的 n。
    var inputNumber: Int? { if case .input(let n) = self { n } else { nil } }
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
                    // 按目录所在卷取（DiskGuard 的算法：非启动卷也对，Recorder.freeBytes 在那些卷上是 0）
                    let free = DiskGuard.freeBytes(for: URL(fileURLWithPath: directory, isDirectory: true))
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
