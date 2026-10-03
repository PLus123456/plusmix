// 输出接线（W2-B2 接缝 5、6；W3-C 加 ISO 分路、同一拍起停、磁盘保护）：把 MixerState.outputs 里"应该在跑"（enabled）的录制 / 推流
// 变成活的 Recorder（W1-E）/ StreamOutput（W2-D），跟着快照起停；Stats.encoder 的项也从这里出（每项带输出编号 output——提案 019，读的一方按它对号；
// 顺序仍 = outputs 里带编码器的输出，测试标准 §7）。
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
// - NDI 发送（W3-E3）：kind = ndi 且 enabled 的输出 = 一个 NDISender（W2-D）。源名 = 输出名，分组 = extra["ndi.groups"]，转换方式 = extra["ndi.conversion"]。
//   PGM / PVW / 多画面：sender 自己是 PGM 帧的消费者，从 RenderedFrame 挑（PVW / 多画面帧由渲染器按状态自动填：有 enabled 的输出要它才转，开头可能缺一两帧）；
//   输入 n（Aux，原始画面）：该路帧槽开一个分支（与 ISO / Aux 窗口共用每路 4 个的额度），ISO 同款的 ISOFrameTap 每拍挑帧交给 NDIInputFeed → sender.send(frame:)
//   （NDISender.consume 对 .input 不动）。音频：PGM / PVW / 多画面送 Master，输入 n 送该路推子后的 ISO 音轨（没有音频的路不带）。
//   名字 / 分组 / 源定死在 sender 里，变了就停掉旧的、按新设置起新的（接收方要重新选源）；转换方式 setConversion 运行时改。
//   start（NDIlib_initialize、send_create、Metal 转换器编译）/ stop（等发送线程退出、销毁实例）都放后台线程做，不卡主线程；
//   起 / 停的过程中快照又变了，做完按最新快照再对一次。Stats.encoder 那一项由 sender 的 statsEntry 填（publishing / idle / unavailable / failed，019 起带接收方数）。
//   源是输入 n、那一路分支用完了（与 ISO / Aux 共用每路 4 个）：sender 照跑、没画面、提示一次、记着在等；InputRuntime 还分支时回调 → 重新要分支、接上、再提示一次（W3-E4）。
// 起不来的录制 / 推流（W5-B，02 X02 / 01a L13）：原因记在 failed 表（人话，底栏提示与推流页那一段照着写），Stats.encoder 里那一项报 failed（原来报 idle）；
//   enabled 仍为真时设置变了（地址 / 目录改对）reconcile 自动重试；底栏主体按钮有起不来的推流路时调 retry 只重试它们，正常的路不动。
//   推流起的时候提示"连接中"，Stats 第一次报 publishing 才提示"已开始"（X37）。
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
import SwitcherStreaming
import SwitcherNDISend
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
        /// 推流起来了、正在连（还没连上，X37）。
        case streamConnecting(output: Int)
        /// 推流连上了（Stats 第一次报 publishing）。
        case streamStarted(output: Int)
        case streamStopped(output: Int)
        case streamFailed(output: Int, message: String)
        case ndiStarted(output: Int, name: String)
        case ndiStopped(output: Int)
        case ndiFailed(output: Int, message: String)
        /// 源是输入 n 的 NDI 发送等到了分支、接上了（W3-E4）。
        case ndiBranchRestored(output: Int, input: Int)
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
        /// 已经提示过"已开始"（第一次报 publishing）。
        var announced = false
        init(output: OutputState, stream: StreamOutput) {
            self.output = output
            self.stream = stream
        }
    }

    /// NDI sender 建好后改不了的那几样：变了就重建 sender。
    struct NDIKey: Equatable, Sendable {
        let name: String
        let groups: String?
        let source: OutputSource
        init(_ output: OutputState) {
            name = output.name
            groups = OutputExtras.string(output, OutputExtras.ndiGroups).flatMap { $0.isEmpty ? nil : $0 }
            source = output.settings.source
        }
    }

    /// 一路 NDI 发送（主线程改；起 / 停在后台线程做完回主线程，标 @unchecked Sendable 只为能捕获进回调）。
    final class NDIEntry: @unchecked Sendable {
        enum Phase { case starting, running, stopping }
        let number: Int
        let key: NDIKey
        let sender: NDISender
        var phase = Phase.starting
        /// 挂在引擎上的消费者：PGM / PVW / 多画面 = sender 本身；输入 n = inputTap。
        var consumer: (any FrameConsumer)?
        /// 源是输入 n 时：该路分支槽上按拍挑帧的 tap（下游 NDIInputFeed → sender），分支槽，接上时那一路的来源（换了来源要换到新 tee 上）。
        var inputTap: ISOFrameTap?
        var branch: LockFreeFrameSlot?
        var inputSource: InputSource?
        /// 源是输入 n、那一路分支用完了：在等 InputRuntime 还分支（W3-E4）；接上 / 摘下时清。
        var branchPending = false
        var audioToken: AudioConsumerToken?
        init(number: Int, key: NDIKey, sender: NDISender) {
            self.number = number
            self.key = key
            self.sender = sender
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
    /// 在起 / 在跑 / 在停的 NDI 发送（键 = 输出编号）。
    private(set) var ndiSenders: [Int: NDIEntry] = [:]
    /// 已停的录制器 / 推流 / NDI（Stats 里继续报 stopped / failed / idle，直到该输出再次起来）。
    private var finishedRecorders: [Int: Recorder] = [:]
    private var finishedStreams: [Int: StreamOutput] = [:]
    private var finishedNDI: [Int: NDISender] = [:]
    /// 起不来的 NDI 输出当时的设置：设置变了（改名 / 换源 / 换分组）就再试，没变不反复试。
    private var ndiFailedKeys: [Int: NDIKey] = [:]
    /// 起不来的输出（enabled 仍为 true）→ 原因（给人看的一句）：不自己反复重试；被关掉、设置改了（reconcile）或底栏点重试（retry）时清。
    private(set) var failed: [Int: String] = [:]
    /// 起不来时那一路的设置：enabled 仍为真、设置变了（地址 / 目录改对）就自动重试一次（W5-B，L13）。
    private var failedSettings: [Int: OutputSettings] = [:]
    private(set) var lastResults: [Int: RecordingResult] = [:]
    /// 每路最近一次的磁盘事件（测试 / 面板看）。
    private(set) var diskEvents: [Int: RecordingDiskMonitor.Event] = [:]
    private var lastOutputs: [OutputState] = []
    /// 最近一次快照的输入表（源是输入 n 的 NDI 发送看那一路换没换来源）。
    private var lastInputs: [InputConfig] = []
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
        // 某路还回来一个分支（ISO 停 / Aux 窗口关 / 别的 NDI 发送摘下）：在等分支的 NDI 发送重新要（W3-E4）。回调在还分支的调用栈上，
        // 挪到下一轮主线程再做，不在别人的收尾里插一手
        inputs?.onBranchReleased = { [weak self] m in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.retryPendingNDIBranches(input: m) } }
        }
    }

    /// Stats.encoder（采样线程上调）。
    var statsProvider: @Sendable () -> [Stats.EncoderEntry] {
        let s = stats
        return { s.entries() }
    }

    // MARK: 跟快照

    /// 让运行表跟上快照：enabled 且没在跑的起（同一批共用起始拍），不 enabled 且在跑的停（共用边界拍），消失的停。
    /// 输入表变了也要调（源是输入 n 的 NDI 发送要跟着那一路换 tee）；其余情况下幂等。
    func reconcile(_ state: MixerState) {
        lastOutputs = state.outputs
        lastInputs = state.inputs
        let wanted = Dictionary(uniqueKeysWithValues: state.outputs.map { ($0.number, $0) })
        var toStop: [Int] = []
        for (n, e) in recorders where wanted[n]?.kind != .record && !e.stopping { toStop.append(n) }
        for (n, e) in streams where wanted[n]?.kind != .stream && !e.stopping { stopStream(n) }
        for (n, _) in ndiSenders where wanted[n]?.kind != .ndi { stopNDI(n) }
        for (n, _) in failed where wanted[n]?.enabled != true {
            failed.removeValue(forKey: n)
            ndiFailedKeys.removeValue(forKey: n)
            failedSettings.removeValue(forKey: n)
        }
        var toStart: [OutputState] = []
        for output in state.outputs {
            switch output.kind {
            case .record:
                if output.enabled, recorders[output.number] == nil, failed[output.number] == nil || retryAfterSettingsChange(output) { toStart.append(output) }
                else if !output.enabled, let e = recorders[output.number], !e.stopping { toStop.append(output.number) }
            case .stream:
                if output.enabled, streams[output.number] == nil, failed[output.number] == nil || retryAfterSettingsChange(output) { startStream(output) }
                else if !output.enabled, let e = streams[output.number], !e.stopping { stopStream(output.number) }
            case .ndi:
                reconcileNDI(output)
            default:
                break
            }
        }
        if !toStop.isEmpty { stopRecordings(toStop) }
        if !toStart.isEmpty { startRecordings(toStart) }
        rebuildStats()
    }

    /// 起不来的一路设置变了（推流页把地址改对、录制目录改了）：清掉 failed，这一次 reconcile 就重试（W5-B，L13）。设置没变返回 false（不反复试）。
    private func retryAfterSettingsChange(_ output: OutputState) -> Bool {
        let n = output.number
        guard failed[n] != nil, let s = failedSettings[n], s != output.settings else { return false }
        clearFailure(n)
        return true
    }

    private func clearFailure(_ n: Int) {
        failed.removeValue(forKey: n)
        failedSettings.removeValue(forKey: n)
    }

    /// 记一路起不来：原因 + 当时的设置（设置变了自动重试），提示一次。
    private func recordFailure(_ output: OutputState, _ message: String) {
        failed[output.number] = message
        failedSettings[output.number] = output.settings
    }

    /// 重试起不来的那几路（底栏推流主体按钮、推流页"重试"；W5-B，X02）：只动 enabled 仍为真、起不来（或推流放弃了）的路，正常在跑的不碰。
    func retry(_ numbers: [Int]) {
        var records: [OutputState] = []
        for n in numbers {
            guard let output = lastOutputs.first(where: { $0.number == n }), output.enabled else { continue }
            switch output.kind {
            case .stream:
                if failed[n] != nil, streams[n] == nil {
                    clearFailure(n)
                    startStream(output)
                } else if let e = streams[n], !e.stopping, case .failed = e.stream.state {
                    stopStream(n)   // 重连放弃了的那一路：停掉，停完按 enabled 再起（stopStream 的收尾会起）
                }
            case .record:
                if failed[n] != nil, recorders[n] == nil {
                    clearFailure(n)
                    records.append(output)
                }
            default:
                break
            }
        }
        if !records.isEmpty { startRecordings(records) }
        rebuildStats()
    }

    /// 一路起不来的原因（没有为 nil）：底栏提示、推流页那一段照着写，底栏主体按钮按它决定"重试"还是"停"。
    /// 起不来的（failed 表）之外，推流的重连放弃了（StreamOutput 停在 failed；App 里不给重连上限，正常不会出现）也算。
    func failureReason(output number: Int) -> String? {
        if let reason = failed[number] { return reason }
        if let e = streams[number], !e.stopping, case .failed(let why) = e.stream.state { return L("notice.streamGaveUp", number, why) }
        return nil
    }

    /// 推流正在 / 即将进行第几次连接（从 1 起；在推 / 没在跑为 nil）。Stats.encoder 里只有成功重连次数，没有尝试次数（见报告 §4），底栏按钮从这里读。
    func streamConnectAttempt(output number: Int) -> Int? {
        guard let e = streams[number] else { return nil }
        switch e.stream.state {
        case .connecting(let attempt): return attempt
        case .backoff(let failures, _): return failures + 1
        default: return nil
        }
    }

    /// 每行 Stats（主线程）：推流第一次报 publishing 时提示"已开始"（X37：start() 之后先提示"连接中"，连上才算开始）。
    func noteStats(_ stats: Stats) {
        for (n, e) in streams where !e.announced && !e.stopping {
            guard Self.encoderEntry(in: stats, forOutput: n)?.state == "publishing" else { continue }
            e.announced = true
            onEvent?(.streamStarted(output: n))
        }
    }

    /// 推流建不起来的原因：地址的错查表成人话，其余原样。原因会写进底栏提示、推流 ▴ 菜单和推流页，带地址的那一种先打码
    /// （user:pass@ / passphrase / streamid 等，W5-F，G6 追加 ①）。
    nonisolated static func streamErrorText(_ error: any Error) -> String {
        switch error as? StreamDestination.Error {
        case .unsupportedScheme(let scheme)?: L("stream.error.unsupportedScheme", scheme)
        case .invalidURL(let url)?: L("stream.error.invalidURL", StreamURLRedaction.redact(url: url))
        case .missingHost?: L("stream.error.missingHost")
        case nil: "\(error)"
        }
    }

    /// 停掉全部（换节目 / 退出）：录制封口等到完成（每个最多 10 s）。先忘掉快照里的目标状态，封口完成后才不会按"仍 enabled"再起一次。
    func stopAll() async {
        lastOutputs = []
        diskMonitor.stop()
        let running = recorders.keys.sorted().filter { !recorders[$0]!.stopping }
        if !running.isEmpty { stopRecordings(running) }
        for n in streams.keys.sorted() where !streams[n]!.stopping { stopStream(n) }
        for n in ndiSenders.keys.sorted() { stopNDI(n) }   // 还在起的那几路：起完按（已清空的）快照再对一次，就停了
        let deadline = Date().addingTimeInterval(10)
        while (!recorders.isEmpty || !streams.isEmpty || !ndiSenders.isEmpty) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !recorders.isEmpty || !streams.isEmpty || !ndiSenders.isEmpty {
            NSLog("输出没在 10 s 内停完：录制 \(recorders.keys.sorted())，推流 \(streams.keys.sorted())，NDI \(ndiSenders.keys.sorted())")
            for (_, e) in recorders { engine.removeConsumer(e.consumer) }
            for (_, e) in streams { engine.removeConsumer(e.stream) }
            for (_, e) in ndiSenders { detachNDI(e) }
            recorders.removeAll()
            streams.removeAll()
            ndiSenders.removeAll()
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
                    failedSettings[output.number] = output.settings
                    fail(output: output.number, L("notice.isoBranchUnavailable", n, InputFrameTee.maxBranches))
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
                finishedRecorders[number] = rec
                failedSettings[number] = output.settings
                fail(output: number, L("notice.recordingFailed", number, message))
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
            let reason = L("notice.recordingBelowMinimum", number, Int(free / 1_048_576), Int(minimumFreeBytes / 1_048_576))
            if canFallback(entry) {
                switchToFallback(entry, reason: reason)
            } else {
                stopForDisk(entry, reason: reason)
            }
        case .failed(let cause, let message, _):
            guard cause == .disk else {
                fail(output: number, L("notice.recordingError", number, message))
                if let clock { entry.stopping = true; entry.recorder.stop(atTick: clock.tick(at: .now())) { [weak self] r in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRecording(number, entry: entry, result: r) } } } }
                return
            }
            let reason = L("notice.recordingDiskFull", number, String(message.prefix(80)))
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
            stopForDisk(entry, reason: L("notice.recordingFallbackFailed", reason, "\(error)"))
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
        guard let streamSettings = settings.stream, !streamSettings.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            let message = L("notice.streamNoURL", output.number)
            recordFailure(output, message)
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
            let message = L("notice.streamFailed", output.number, Self.streamErrorText(error))
            NSLog("%@", message)
            recordFailure(output, message)
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
        onEvent?(.streamConnecting(output: output.number))
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

    // MARK: NDI 发送（W3-E3）

    /// 一路 NDI 输出跟上快照：enabled 且没有 sender 的起；关掉 / 名字 / 分组 / 源变了的停（停完按最新快照再起）；转换方式运行时改；
    /// 源是输入 n、那一路换了来源（InputRuntime 重建了它的 tee）的把分支换到新 tee 上。起 / 停进行中的不动，做完会再对一次。
    private func reconcileNDI(_ output: OutputState) {
        let n = output.number
        let key = NDIKey(output)
        if let e = ndiSenders[n] {
            guard e.phase == .running else { return }
            if !output.enabled || e.key != key {
                stopNDI(n)
                return
            }
            let mode = NDISender.Configuration.Conversion(extra: output.settings.extra)
            if e.sender.conversion != mode { e.sender.setConversion(mode) }
            if case .input(let m) = key.source, e.inputSource != lastInputs.first(where: { $0.number == m })?.source {
                detachNDI(e)
                attachNDI(e)
            }
        } else if output.enabled {
            if let k = ndiFailedKeys[n] {
                guard k != key else { return }   // 设置没变：不反复试
                ndiFailedKeys.removeValue(forKey: n)
                failed.removeValue(forKey: n)
            }
            startNDI(output)
        }
    }

    /// 起：建 sender，后台线程 start（NDIlib_initialize / send_create / 转换器），回主线程挂消费者与音频。
    private func startNDI(_ output: OutputState) {
        let n = output.number
        let key = NDIKey(output)
        let config = NDISender.Configuration(name: key.name, groups: key.groups, format: format, source: key.source,
                                             conversion: NDISender.Configuration.Conversion(extra: output.settings.extra))
        let entry = NDIEntry(number: n, key: key, sender: NDISender(configuration: config))
        ndiSenders[n] = entry
        finishedNDI.removeValue(forKey: n)
        let sender = entry.sender
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try sender.start() }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ndiStarted(entry, result: result) } }
        }
    }

    private func ndiStarted(_ entry: NDIEntry, result: Result<Void, any Error>) {
        let n = entry.number
        guard ndiSenders[n] === entry else { return }
        switch result {
        case .failure(let error):
            ndiSenders.removeValue(forKey: n)
            finishedNDI[n] = entry.sender   // SDK 初始化 / 建实例失败时 sender 自己标 unavailable，Stats 里报它
            let message = L("notice.ndiFailed", n, "\(error)")
            NSLog("%@", message)
            failed[n] = message
            ndiFailedKeys[n] = entry.key
            onEvent?(.ndiFailed(output: n, message: message))
        case .success:
            attachNDI(entry)
            entry.phase = .running
            if entry.sender.countersSnapshot.unavailable {
                // 编译时没有 SDK：空实现照样"起"（帧收了就丢），Stats 里 unavailable；提示一句
                onEvent?(.ndiFailed(output: n, message: L("notice.ndiUnavailable", n)))
            } else {
                onEvent?(.ndiStarted(output: n, name: entry.key.name))
            }
        }
        rebuildStats()
        // 起的过程中快照又变了（关掉 / 删了 / 改了名字或源）：按最新快照再对一次
        if let latest = lastOutputs.first(where: { $0.number == n }), latest.kind == .ndi { reconcileNDI(latest) } else { stopNDI(n) }
    }

    /// 挂上：PGM / PVW / 多画面 = sender 直接当 PGM 帧的消费者；输入 n = 分支槽 + tap（分支用完就记着等，W3-E4）。音频按源挂。
    private func attachNDI(_ entry: NDIEntry) {
        let sender = entry.sender
        var audioSource: AudioTapSource? = .master
        if case .input(let m) = entry.key.source {
            entry.inputSource = lastInputs.first { $0.number == m }?.source
            if !openNDIBranch(entry, input: m), entry.inputSource != nil {
                // 那一路在，但分支用完了（与 ISO / Aux 共用每路 4 个）：sender 照跑、没画面，提示一次；那一路还回分支时 retryPendingNDIBranches 再要
                entry.branchPending = true
                onEvent?(.ndiFailed(output: entry.number, message: L("notice.ndiBranchUnavailable", entry.number, m, InputFrameTee.maxBranches)))
            }
            audioSource = (audio?.registeredInputs.contains(m) ?? false) ? .input(number: m) : nil
        } else {
            entry.consumer = sender
            engine.addConsumer(sender)
        }
        if let audio, let audioSource {
            do { entry.audioToken = try audio.engine.addConsumer(sender, source: audioSource) } catch { NSLog("NDI 发送 \(entry.number) 挂不上音频：\(error)") }
        }
    }

    /// 给源是输入 m 的 NDI 发送开一个分支 + tap、挂到引擎上；那一路分支用完（或没有这路）返回 false。
    private func openNDIBranch(_ entry: NDIEntry, input m: Int) -> Bool {
        guard let branch = inputs?.openBranch(input: m) else { return false }
        let tap = ISOFrameTap(inputNumber: m, branch: branch, sink: NDIInputFeed(sender: entry.sender), name: "ndi\(entry.number).in\(m)")
        entry.branch = branch
        entry.inputTap = tap
        entry.consumer = tap
        engine.addConsumer(tap)
        return true
    }

    /// 输入 m 还回来一个分支：在等分支的 NDI 发送（源是输入 m、在跑、还没接上）重新要一个；要到了接上、提示一次（W3-E4，W3-E3 报告 §3 第 2 条）。
    /// 那一路换了来源 / 删了的不在这里管（reconcileNDI 会摘下重挂）。
    private func retryPendingNDIBranches(input m: Int) {
        guard lastInputs.contains(where: { $0.number == m }) else { return }
        for entry in ndiSenders.values.sorted(by: { $0.number < $1.number })
        where entry.phase == .running && entry.branchPending && entry.branch == nil && entry.key.source == .input(number: m) {
            guard openNDIBranch(entry, input: m) else { return }   // 还是没有：等下一次
            entry.branchPending = false
            onEvent?(.ndiBranchRestored(output: entry.number, input: m))
        }
    }

    /// 摘下：不再收帧 / 音频块，分支还给那一路。
    private func detachNDI(_ entry: NDIEntry) {
        if let c = entry.consumer { engine.removeConsumer(c) }
        entry.consumer = nil
        entry.inputTap = nil
        if let b = entry.branch, case .input(let m) = entry.key.source { inputs?.releaseBranch(b, input: m) }
        entry.branch = nil
        entry.inputSource = nil
        entry.branchPending = false
        if let t = entry.audioToken { audio?.engine.removeConsumer(t) }
        entry.audioToken = nil
    }

    /// 停：主线程摘下，后台线程 stop（等发送线程退出、销毁 NDI 实例），回主线程收尾；还在起的等起完再停（ndiStarted 会再对一次快照）。
    private func stopNDI(_ n: Int) {
        guard let entry = ndiSenders[n], entry.phase == .running else { return }
        entry.phase = .stopping
        detachNDI(entry)
        let sender = entry.sender
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sender.stop()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ndiStopped(entry) } }
        }
    }

    private func ndiStopped(_ entry: NDIEntry) {
        let n = entry.number
        if ndiSenders[n] === entry { ndiSenders.removeValue(forKey: n) }
        finishedNDI[n] = entry.sender
        onEvent?(.ndiStopped(output: n))
        // 停的过程中又被打开 / 改了设置：按最新快照再起
        if ndiSenders[n] == nil, let latest = lastOutputs.first(where: { $0.number == n }), latest.kind == .ndi { reconcileNDI(latest) }
        rebuildStats()
    }

    // MARK: Stats

    /// 某个输出在 Stats.encoder 里的项：按 `EncoderEntry.output` 对号（提案 019）。019 之前靠"与 outputs 里带编码器的输出同序"，
    /// 两次采样之间输出表变了会错一拍（W3-E3 报告 §4 第 2 条）；现在过期的一行也对得准。
    nonisolated static func encoderEntry(_ entries: [Stats.EncoderEntry], forOutput number: Int) -> Stats.EncoderEntry? {
        entries.first { $0.output == number }
    }

    nonisolated static func encoderEntry(in stats: Stats, forOutput number: Int) -> Stats.EncoderEntry? {
        encoderEntry(stats.encoder, forOutput: number)
    }

    /// Stats.encoder 的来源表：与 outputs 里带编码器的输出（record / stream / ndi）同序、每项带输出编号（019）；没在跑的报 idle / stopped / failed。
    private func rebuildStats() {
        var sources: [(output: Int, source: EncoderStatsSource.Source)] = []
        for output in lastOutputs {
            let n = output.number
            switch output.kind {
            case .record:
                let directory = output.settings.record?.directory ?? ShowDocuments.defaultRecordDirectory
                if let e = recorders[n] { sources.append((n, .recorder(e.recorder))) }
                else if failed[n] != nil, output.enabled { sources.append((n, .failed(directory: directory))) }   // 起不来：报 failed（W5-B，原来报 idle / 录制器的 idle）
                else if let r = finishedRecorders[n] { sources.append((n, .recorder(r))) }
                else { sources.append((n, .idleRecord(directory: directory))) }
            case .stream:
                if let e = streams[n] { sources.append((n, .stream(e.stream))) }
                else if failed[n] != nil, output.enabled { sources.append((n, .failed(directory: nil))) }   // 起不来：报 failed（原来报 idle，按钮显示"推流 · idle"）
                else if let s = finishedStreams[n] { sources.append((n, .stream(s))) }
                else { sources.append((n, .idle)) }
            case .ndi:
                if let e = ndiSenders[n] { sources.append((n, .ndi(e.sender))) }
                else if let s = finishedNDI[n] { sources.append((n, .ndi(s))) }
                else { sources.append((n, .idle)) }
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

/// 把录制器 / 推流 / NDI 的计数变成 Stats.encoder 的项（每个输出一项，顺序 = outputs 顺序，每项带输出编号 output——提案 019）：skipped / frames /
/// dropped / disk_free_mb / reconnects / connections / state 由各自的 statsEntry 填，bitrate 按上次采样以来的窗口算。只在 Stats 采样线程上被调；表由主线程换。
final class EncoderStatsSource: @unchecked Sendable {
    enum Source {
        case recorder(Recorder)
        case stream(StreamOutput)
        case ndi(NDISender)
        case idleRecord(directory: String)
        case idle
        /// 起不来的录制 / 推流（enabled 仍为真）：state = failed；录制带目录（报所在卷的剩余）。
        case failed(directory: String?)
    }

    private struct Slot {
        var output: Int
        var source: Source
        var previousRecorder: RecorderCounters?
        var previousStream: StreamCounters?
        var previousNDI: NDISendCounters?
        var at: HostTime?
    }

    private let slots = Mutex<[Slot]>([])

    func replace(_ sources: [(output: Int, source: Source)]) {
        slots.withLock { old in
            // 同一对象继续用上次的计数（窗口不断）；换了对象就从头算
            old = sources.map { s in
                let prev = old.first { same($0.source, s.source) }
                return Slot(output: s.output, source: s.source, previousRecorder: prev?.previousRecorder, previousStream: prev?.previousStream,
                            previousNDI: prev?.previousNDI, at: prev?.at)
            }
        }
    }

    private func same(_ a: Source, _ b: Source) -> Bool {
        switch (a, b) {
        case (.recorder(let x), .recorder(let y)): x === y
        case (.stream(let x), .stream(let y)): x === y
        case (.ndi(let x), .ndi(let y)): x === y
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
                    // disk_free_mb：录制器自己读到 0（非启动卷，Recorder.freeBytes 的问题单）时由 DiskGuard 重新量（W3-C3）
                    out.append(DiskGuard.statsEntry(for: r, counters: c, previous: list[i].previousRecorder, windowSeconds: window, output: list[i].output))
                    list[i].previousRecorder = c
                case .stream(let s):
                    let c = s.counters
                    out.append(c.statsEntry(previous: list[i].previousStream, windowSeconds: window, encoderSkipped: s.videoEncoder.counters.skipped, output: list[i].output))
                    list[i].previousStream = c
                case .ndi(let s):
                    // 同一份快照算这一项、也当下一窗口的起点（sender.statsEntry 自己另取快照，两次之间送出的帧会两边都不算）
                    let c = s.countersSnapshot
                    out.append(c.statsEntry(previous: list[i].previousNDI, windowSeconds: window, bytesPerFrame: s.uyvyBytesPerFrame, running: s.isRunning, output: list[i].output))
                    list[i].previousNDI = c
                case .idleRecord(let directory):
                    // 按目录所在卷取（DiskGuard 的算法：非启动卷也对，Recorder.freeBytes 在那些卷上是 0）
                    let free = DiskGuard.freeBytes(for: URL(fileURLWithPath: directory, isDirectory: true))
                    out.append(Stats.EncoderEntry(output: list[i].output, skipped: 0, bitrate: 0, diskFreeMb: Double(free) / 1_048_576, state: "idle"))
                case .idle:
                    out.append(Stats.EncoderEntry(output: list[i].output, skipped: 0, bitrate: 0, state: "idle"))
                case .failed(let directory):
                    let free = directory.map { Double(DiskGuard.freeBytes(for: URL(fileURLWithPath: $0, isDirectory: true))) / 1_048_576 } ?? 0
                    out.append(Stats.EncoderEntry(output: list[i].output, skipped: 0, bitrate: 0, diskFreeMb: free, state: "failed"))
                }
                list[i].at = now
            }
            return out
        }
    }
}

/// 源是输入 n 的 NDI 发送：ISOFrameTap 每拍在该路分支槽上挑好帧（换上这一拍的拍点）交到这里，转给 NDISender.send(frame:tickTime:)
/// （NDISender.consume 只从 RenderedFrame 挑 PGM / PVW / 多画面，对 .input 不动）。在引擎派发线程上被调，只转一手，零分配。
final class NDIInputFeed: FrameConsumer, @unchecked Sendable {
    let sender: NDISender
    let consumerName: String

    init(sender: NDISender) {
        self.sender = sender
        consumerName = sender.consumerName + ".input"
    }

    func consume(_ frame: RenderedFrame) {
        sender.send(frame: frame.program, tickTime: frame.tickTime)
    }
}
