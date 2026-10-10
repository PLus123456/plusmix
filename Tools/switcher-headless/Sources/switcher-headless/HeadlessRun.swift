import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherAudio
import SwitcherAudioIntegration
import SwitcherOutputs
import SwitcherNDISend
import SwitcherStreaming
import SwitcherControl
import SwitcherTally
import VMixCompat
import SwitcherInputs
import SwitcherNDI
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
    /// --compat：第三方 API 兼容层（W3-D VMixCompat，默认关；C5 用）。nil = 不起。
    var compat: VMixCompatConfiguration? = nil
    /// --tally-port：W3-D 的 tally 流（WS /tally + GET /tally）；nil = 不起。
    var tallyPort: Int? = nil
    /// --ndi-send <名字>：起 W2-D 的 NDISender 送 PGM（+ Master 音频），gate4-ndi 的回环发送端。
    var ndiSend: String? = nil
    /// --ndi-jitter-frames：节目里 NDI 输入的抖动缓冲深度（W3-A，0–2，默认 1）。
    var ndiJitterFrames: Int = 1
    /// --stream <地址>（W4-A，可多次）：每个地址一路 W2-D 的 StreamOutput（PGM + Master 音频）。
    var streamURLs: [String] = []
    /// --av-compensation（W1-B4，提案 028）：videoDelay（默认，画面也晚 L）/ audioPTS（W5-C：音频 PTS 前移 L）。
    var avCompensation: AVCompensation = .videoDelay
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
    /// --ndi-send 的发送端：排在录制器之后（它不在节目文件的 outputs 里，是命令行加的，G4 的 NDI 回环工装）。
    private let ndi: NDISender?
    private let lastNDI = Mutex<(counters: NDISendCounters, at: HostTime)?>(nil)

    /// 019：每路录制器在节目输出表里的编号（PGM 录制器 = 节目里第一个 record 输出，ISO 音轨不是输出表里的项 = 0）；NDI 同理（第一个 ndi 输出）。
    private let outputNumbers: [Int]
    private let ndiOutput: Int
    /// W4-A --stream 的推流：排在 NDI 之后，第 i 路对节目里第 i 个 stream 输出的编号（没有 = 0）。
    private let streams: [StreamOutput]
    private let streamOutputs: [Int]
    private let lastStreams = Mutex<[(counters: StreamCounters, at: HostTime)?]>([])

    init(recorders: [Recorder], outputNumbers: [Int] = [], ndi: NDISender? = nil, ndiOutput: Int = 0,
         streams: [StreamOutput] = [], streamOutputs: [Int] = []) {
        self.recorders = recorders
        self.outputNumbers = (0..<recorders.count).map { $0 < outputNumbers.count ? outputNumbers[$0] : 0 }
        self.ndi = ndi
        self.ndiOutput = ndiOutput
        self.streams = streams
        self.streamOutputs = (0..<streams.count).map { $0 < streamOutputs.count ? streamOutputs[$0] : 0 }
        last.withLock { $0 = Array(repeating: nil, count: recorders.count) }
        lastStreams.withLock { $0 = Array(repeating: nil, count: streams.count) }
    }

    func entries() -> [Stats.EncoderEntry] {
        let now = HostClock.now()
        let current = recorders.map(\.counters)
        let previous = last.withLock { box -> [(counters: RecorderCounters, at: HostTime)?] in
            let p = box
            box = current.map { ($0, now) }
            return p
        }
        var entries = current.enumerated().map { i, c in
            let window = previous[i].map { max((now - $0.at).seconds, 1e-3) } ?? 1
            return c.statsEntry(previous: previous[i]?.counters, windowSeconds: window, state: recorders[i].state.statsName, output: outputNumbers[i])
        }
        if let ndi {
            let snapshot = ndi.countersSnapshot
            let prev = lastNDI.withLock { box -> (counters: NDISendCounters, at: HostTime)? in
                let p = box
                box = (snapshot, now)
                return p
            }
            entries.append(ndi.statsEntry(previous: prev?.counters, windowSeconds: prev.map { max((now - $0.at).seconds, 1e-3) } ?? 1, output: ndiOutput))
        }
        if !streams.isEmpty {
            let snapshots = streams.map(\.counters)
            let previous = lastStreams.withLock { box -> [(counters: StreamCounters, at: HostTime)?] in
                let p = box
                box = snapshots.map { ($0, now) }
                return p
            }
            for (i, stream) in streams.enumerated() {
                let window = previous[i].map { max((now - $0.at).seconds, 1e-3) } ?? 1
                entries.append(snapshots[i].statsEntry(previous: previous[i]?.counters, windowSeconds: window,
                                                        encoderSkipped: stream.videoEncoder.counters.skipped, output: streamOutputs[i]))
            }
        }
        return entries
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
        // W1-B4：videoDelay 下引擎最多把帧压 maxDelay 再派发——输出环按它加深（不加深会被延迟队列扣满、退回池子分配）；
        // 开着预览窗口时显示也延后（多留几格合成目标，显示源按引擎正在用的延后挑到期的帧）
        var renderOptions = MetalRendererOptions()
        if options.avCompensation == .videoDelay {
            renderOptions.videoDelayHeadroom = EngineOptions().videoDelay.maxDelay
            renderOptions.displayDelayHistory = options.preview
        }
        renderer = try MetalRenderer(options: renderOptions)
        stateMachine = StateMachine(initialState: state)
        let maxNumber = state.inputs.map(\.number).max() ?? 1
        let engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(16, maxNumber))
        self.engine = engine
        if options.avCompensation == .videoDelay && options.preview {
            renderer.displayDelayProvider = { engine.videoDelayApplied }
        }
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
        // 0. 慢的准备工作放在算 t0 之前（否则吃掉 --lead-ms，引擎起晚开头跳拍——gate4-ndi 第一次跑 missed_render 11 就是发现器的 1.5 s 造成的）：
        //    NDI 发送端（--ndi-send，G4 的 NDI 回环工装）先起——节目里的 NDI 输入要在发现列表里找到它，帧要等引擎起了才来；
        //    节目里 ndi 输入的源名在这里解析好（不含 "(" 的名字 = 本机发送端，按后缀在发现列表里找，每轮 1.5 s、最多 10 s）。
        var ndiSender: NDISender?
        if let name = options.ndiSend {
            guard NDISender.isAvailable else { throw CLIError("--ndi-send 需要 NDI SDK（编译时没探测到 /Library/NDI SDK for Apple）") }
            let sender = NDISender(configuration: NDISender.Configuration(name: name, format: format, source: .program))
            try sender.start()
            engine.addConsumer(sender)
            ndiSender = sender
        }
        // 0b. 推流（W4-A --stream）：每个地址一路 StreamOutput（自己的编码器 + 发送队列 + HaishinKit 连接，路与路之间没有共享锁 / 队列，E7 的口径）。
        //     连接在它自己的 Task 里做、连不上按退避重试，这里不等；编码器会话在算 t0 之前建好（同 NDI 发送端：别吃掉 --lead-ms）。
        //     第 i 个地址对节目里第 i 个 stream 输出：编码参数取它的、编号进 Stats.encoder[].output（019）；节目里没有就默认参数、编号 0。
        let showStreamOutputs = show.outputs.filter { $0.kind == .stream }
        let showHasAudio = initialState.inputs.contains { cfg in
            switch cfg.source {
            case .synthetic(let settings): return settings.audio
            case .file, .audio: return true
            default: return false
            }
        }
        var streams: [StreamOutput] = []
        for (i, url) in options.streamURLs.enumerated() {
            let showOutput = i < showStreamOutputs.count ? showStreamOutputs[i] : nil
            let video = showOutput?.settings.video ?? VideoEncodeSettings()
            let cfg = StreamOutput.Configuration(name: "stream\(i + 1)", format: format, video: video,
                                                 audio: showHasAudio ? (showOutput?.settings.audio ?? AudioEncodeSettings()) : nil, audioChannels: 2,
                                                 stream: StreamSettings(url: url, streamKey: "",
                                                                        reconnectMaxSeconds: showOutput?.settings.stream?.reconnectMaxSeconds ?? 30))
            let stream = try StreamOutput(configuration: cfg, transportFactory: HaishinKitTransportFactory(format: format, video: video))
            try stream.start()
            engine.addConsumer(stream)
            streams.append(stream)
            print("推流 \(i + 1)：\(stream.destination)（节目输出 \(showOutput.map { "\($0.number)" } ?? "无，编号 0")，\(video.codec) \(video.bitrateBps / 1000) kb/s）")
        }
        var resolvedNDINames: [Int: String] = [:]
        for cfg in initialState.inputs {
            if case .ndi(let sourceName, _, _) = cfg.source {
                guard NDIInput.isSDKAvailable else { throw CLIError("输入 \(cfg.number)「\(cfg.name)」是 NDI，但 \(SwitcherNDIInfo.unavailableMessage)") }
                resolvedNDINames[cfg.number] = try NDILoop.resolveSourceName(sourceName)
            }
        }

        let t0 = HostClock.now() + HostDuration(milliseconds: options.leadMs)
        let spec = TickClockSpec(t0: t0, frameRate: format.frameRate)
        let lastTick = Tick(totalTicks - 1)

        // 1. 输入：合成源（G2 / M0）；G4 起另接图片（W2-A ImageInput，Stinger 的 alpha 图层）和 NDI（W3-A NDIInput，回环 L1）。
        //    合成源每路自己的帧槽（W1-B）+ 像素池（W1-A）；带音频的路另起一个独立的合成音频源写进 C 环（W1-D）。
        //    时间线：视频第 k 帧的 pts = 节目拍点 − 提前量（默认半个节目帧，8.3 ms @60）。提前量模拟真设备"帧在它该被合成的拍之前到达"：
        //    没有它，pts 恰好落在拍点上的帧到达时刻与拍点只差唤醒 + 画帧的几十微秒到几毫秒，带 ±3 ms 抖动的那路每帧都在赌"先到还是拍先到"，
        //    一半重复一半丢（冒烟跑实测 50%），量到的是拍点竞态而不是引擎的挑帧规则。音频（click）不带提前量，t0 = 节目第 0 拍，
        //    这样闪光帧在第 60k 拍合成、click 在 t0 + k s，录制文件里两者同刻（A2 = 0 才是对的）。
        //    图片 / NDI 用 W2-A 的 ProgramTiming（同一个拍点时钟）：图片每拍 pts = 拍点；NDI pts = 到达 − 抖动 + J × 帧间隔（W3-A §1.2）。
        let programFrameSeconds = format.frameDuration.doubleValue
        let inputLeadMs = options.inputLeadMs ?? programFrameSeconds * 500
        let videoT0 = t0 - HostDuration(milliseconds: inputLeadMs)
        let timing = ProgramTiming(format: format, clock: spec)
        var inputs: [SyntheticVideoInput] = []
        var otherInputs: [any Input] = []
        var audioInputs: [(number: Int, ring: CAudioRing, settings: InputAudioSettings, source: SyntheticAudioInput)] = []
        var deviceAudioInputs: [(number: Int, ring: CAudioRing)] = []   // 纯音频设备（W2-A2）：环注册进音频引擎；输入对象在 otherInputs 里起停
        var fileAudioInputs: [(number: Int, ring: CAudioRing, blockFrames: Int)] = []   // 文件输入（W4-A）：同上
        for cfg in initialState.inputs {
            let slot = LockFreeFrameSlot(capacity: 3)
            switch cfg.source {
            case .synthetic(let settings):
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
            case .image(let path):
                // 相对路径相对节目文件所在目录（scenarios/g4-show.json 旁边的 g4-stinger.png）
                let resolved = path.hasPrefix("/") ? path : options.showURL.deletingLastPathComponent().appendingPathComponent(path).path
                let input = try ImageInput(number: cfg.number, name: cfg.name, path: resolved, timing: timing, videoSlot: slot)
                engine.registerInput(number: cfg.number, slot: slot)
                otherInputs.append(input)
            case .ndi(let sourceName, let bandwidth, let jitter):
                let resolved = resolvedNDINames[cfg.number] ?? sourceName
                // 提案 008：带宽与抖动缓冲从 case 取；--ndi-jitter-frames 与默认（1）不同 = 命令行显式给了，以它为准
                var ndiOptions = NDIInput.Options()
                ndiOptions.bandwidth = NDIInput.Bandwidth(bandwidth)
                ndiOptions.jitterBufferFrames = options.ndiJitterFrames == 1 ? jitter : options.ndiJitterFrames
                let input = NDIInput(number: cfg.number, name: cfg.name, sourceName: resolved, timing: timing, videoSlot: slot,
                                     audioRing: nil, options: ndiOptions)
                engine.registerInput(number: cfg.number, slot: slot)
                otherInputs.append(input)
                print("NDI 输入 \(cfg.number)：源「\(resolved)」，带宽 \(ndiOptions.bandwidth.rawValue)，抖动缓冲 \(ndiOptions.jitterBufferFrames) 帧")
            case .camera:
                // W4-A：内置摄像头 / UVC（W2-A CameraInput）。只接画面：不注入音频环 = 不开设备自带的麦克风（长稳不采环境声、不弹麦克风授权）。
                // 没授权 / 设备不在：state = error / noSignal，每秒重查，帧槽空着画黑（soak 报告里这路的 fps 看得出来）。
                let input = try CameraInput(config: cfg, timing: timing, videoSlot: slot, audioRing: nil)
                engine.registerInput(number: cfg.number, slot: slot)
                otherInputs.append(input)
            case .file(let path, let endAction, let rate):
                // W4-A：文件输入（W2-A FileInput，时钟从属于节目拍点）。相对路径相对节目文件所在目录（同图片）；声音进环、注册进音频引擎，路由按节目。
                let resolved = path.hasPrefix("/") ? path : options.showURL.deletingLastPathComponent().appendingPathComponent(path).path
                var fileConfig = cfg
                fileConfig.source = .file(path: resolved, endAction: endAction, rate: rate)
                let ring = CAudioRing(channelCount: 2)
                let fileOptions = FileInput.Options()
                let input = try FileInput(config: fileConfig, timing: timing, videoSlot: slot, audioRing: ring, options: fileOptions)
                engine.registerInput(number: cfg.number, slot: slot)
                otherInputs.append(input)
                fileAudioInputs.append((cfg.number, ring, fileOptions.audioChunkFrames))
            case .audio:
                // W2-A2：Core Audio 设备 → 环（IOProc 零分配、泵线程写环）；没有视频——槽注册了也永远挑不到帧、画黑（契约 Input.videoSlot 的口径）。
                // 声道映射（提案 014）从 case 取；设备不在 = noSignal + 文案，插上会自己好；权限被拒 = error。端到端 A2（回环线）靠它跑。
                let ring = CAudioRing(channelCount: 2)
                let input = try AudioDeviceInput(config: cfg, audioRing: ring)
                engine.registerInput(number: cfg.number, slot: slot)
                otherInputs.append(input)
                deviceAudioInputs.append((cfg.number, ring))
                print("纯音频输入 \(cfg.number)「\(cfg.name)」：Core Audio 设备，环 2 声道")
            default:
                throw CLIError("headless 只接合成源 / 图片 / NDI / 纯音频设备 / 摄像头 / 文件：输入 \(cfg.number)「\(cfg.name)」是 \(cfg.kind)")
            }
        }

        // 2. 音频：W2-E 的 AudioEngine（混音器 + 设备 + 对齐延迟 + AFV + 消费者泵 + 真设备 host 时钟重采样）；
        //    每路带音频的输入把环注册进去，每路参数（增益 / 路由 / 静音…）由它从状态机快照 diff 出来，不用在这里 apply。
        var audioConfig = AudioEngineConfiguration()
        audioConfig.output = try AudioOutputChoice.output(options.audioDevice)
        // 对齐延迟与监听点从节目文件读（提案 007）；命令行没有对应的覆盖参数（只有 --audio-device 选设备）
        audioConfig.alignmentFrames = max(0, show.audio.alignmentFrames)
        audioConfig.monitorPoint = SwitcherAudio.MonitorPoint(show.audio.monitorPoint)
        // SW_AUDIO_SILENT=1：真设备也不出声（Master 不映射到设备通道，仍照常处理、照常送录制器）——长跑 / 真设备 A2 用
        if ProcessInfo.processInfo.environment["SW_AUDIO_SILENT"] == "1" { audioConfig.outputChannelMap = BusChannelMap(master: nil) }
        audioConfig.avCompensation = options.avCompensation
        let audioEngine = try AudioEngine(stateMachine: stateMachine, configuration: audioConfig)
        // W1-B4：videoDelay 下把视频引擎接上——Master 效果链的实测延迟交给它，画面晚同样的毫秒数派发（不接 = 按 audioPTS 走）
        if options.avCompensation == .videoDelay { audioEngine.videoDelay = engine }
        for entry in audioInputs {
            var hints = AudioInputHints()
            hints.producerBlockFrames = entry.source.blockFrames
            try audioEngine.registerInput(number: entry.number, ring: entry.ring, hints: hints)
        }
        for entry in deviceAudioInputs {
            var hints = AudioInputHints()
            hints.producerBlockFrames = 1024   // 设备 IO 块本机 512、走采样率转换约 558；给 1024 稳妥（同 App 的摄像头 / DeckLink，W2-A2 问题单）
            try audioEngine.registerInput(number: entry.number, ring: entry.ring, hints: hints)
        }
        for entry in fileAudioInputs {
            var hints = AudioInputHints()
            hints.producerBlockFrames = entry.blockFrames   // FileInput 每块 256 帧（同 App 的 DefaultInputFactory）
            try audioEngine.registerInput(number: entry.number, ring: entry.ring, hints: hints)
        }
        let hasAudio = !audioInputs.isEmpty || !deviceAudioInputs.isEmpty || !fileAudioInputs.isEmpty
        if let sender = ndiSender, hasAudio { _ = try audioEngine.addConsumer(sender, source: .master) }
        var streamAudioTokens: [AudioConsumerToken] = []
        if hasAudio {
            for stream in streams { streamAudioTokens.append(try audioEngine.addConsumer(stream, source: .master)) }
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
                                             audio: hasAudio ? (outputSettings?.audio ?? AudioEncodeSettings()) : nil,
                                             audioChannels: 2,
                                             fragmentIntervalSeconds: outputSettings?.record?.fragmentIntervalSeconds ?? 1,
                                             remuxToMP4: outputSettings?.record?.remuxToMP4 ?? false,
                                             name: "record")
            let rec = Recorder(configuration: cfg)
            engine.addConsumer(rec)
            if hasAudio { recorderAudioToken = try audioEngine.addConsumer(rec, source: .master) }
            recorder = rec
            // A4：ISO 音轨录制器（视频仍是 PGM——每路视频 ISO 是 W3-C 的事）；编号表只取合成音频源（A4 要的是 click），纯音频设备不进 --iso-audio
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
            if recorder != nil || ndiSender != nil || !streams.isEmpty {
                // 019：encoder[] 带输出编号——PGM 录制器对节目里第一个 record 输出，NDI 发送对第一个 ndi 输出（都是 --record / --ndi-send 起的，节目里没有就 0）；ISO 音轨 0；
                // 推流（W4-A --stream）排在最后，第 i 路对第 i 个 stream 输出
                let recordNumber = show.outputs.first { $0.kind == .record }?.number ?? 0
                let ndiNumber = show.outputs.first { $0.kind == .ndi }?.number ?? 0
                let source = EncoderStatsSource(recorders: (recorder.map { [$0] } ?? []) + isoRecorders.map(\.0),
                                                outputNumbers: recorder == nil ? [] : [recordNumber], ndi: ndiSender, ndiOutput: ndiNumber,
                                                streams: streams, streamOutputs: showStreamOutputs.prefix(streams.count).map(\.number))
                engine.encoderStatsProvider = { source.entries() }
            }
            engine.audioStatsProvider = { audioEngine.audioCounters }
            if options.gpuStats, let g = GPUUtilization() {
                gpu = g
                engine.gpuPercentProvider = { g.deviceUtilizationPercent() }
            }
            let publisher = StatsPublisher(engine: engine, interval: 1)
            // W3-B2：多画面的真实电平表由组装方喂数（铁律 4，数只来自 Stats.audio.meters）；1 Hz 够用，3 s 没喂渲染器自动退回占位
            let meterSink = renderer
            publisher.addConsumer { meterSink.setMeters($0.audio.meters) }
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

        // 4b. API（W2-C）：先于引擎起，让客户端在第 0 拍前就能连上。兼容层（W3-D VMixCompat，--compat）与 tally 流（--tally-port）同一个总线 / 推送源。
        let compat = options.compat.map { VMixCompatServer(bus: commandBus, feed: stateFeed, configuration: $0) }
        let tallyPublisher = options.tallyPort.map { _ in TallyPublisher(stateMachine: stateMachine) { [weak engine] in engine?.clock?.spec } }
        var tallyServer: TallyServer?
        if let tallyPublisher, let port = options.tallyPort {
            tallyServer = TallyServer(publisher: tallyPublisher, configuration: TallyServerConfiguration(host: "0.0.0.0", port: port))
        }
        if apiServer != nil || compat != nil || tallyServer != nil { await stateFeed.start() }
        if let server = apiServer { try await server.start() }
        if let compat { try await compat.start() }
        if let tallyPublisher { await tallyPublisher.start() }
        if let tallyServer { try await tallyServer.start() }

        // 5. 场景：全部预排程到状态机，按拍应用（跳过的拍也逐拍走，命令不会漏）。
        if let sc = scenario {
            for e in sc.sortedEvents { await stateMachine.schedule(e.command, at: e.tick) }
        }

        // 6. 起：音频引擎（设备 + 控制线程 + 泵）→ 视频输入（到 t0 才出第一帧）→ 音频输入 → 录制（起点 = 第 0 拍；尽量晚起，
        //    它的入口环只存 256 块 ≈ 1.4 s，起点之前的块留在里面等第一个压缩视频样本到了才会被丢掉）→ 引擎（start 里 prepare 渲染器，lead 要盖住它）
        try await audioEngine.start(clock: spec)
        for input in inputs { try input.start() }
        for input in otherInputs { try input.start() }
        for entry in audioInputs { try entry.source.start() }
        if let rec = recorder { try rec.start(at: RecordingStart(clock: spec, tick: .zero)) }
        for (iso, _) in isoRecorders { try iso.start(at: RecordingStart(clock: spec, tick: .zero)) }
        // 预告停止边界（W1-E2 `setStopTick`）：总拍数一开始就知道。stop(atTick:) 要是等引擎停了才调，边界之前送到的越界音频块已经写进文件
        // （G4 第一次 10 分钟跑音轨多 49 ms ≈ 对齐延迟 + 一块：块 PTS 比实时晚 42.67 ms，引擎停时录制器还没收到含边界的块，
        // 之后到的块没有边界可比就照写）。预告之后录制器按块 PTS 裁到边界；Ctrl-C 提前停时 stop(atTick:) 会把边界改早（没有越界内容时允许）。
        let announcedStop = Tick(totalTicks)
        if let rec = recorder { rec.setStopTick(announcedStop) }
        for (iso, _) in isoRecorders { iso.setStopTick(announcedStop) }
        if stopRequested {
            await apiServer?.stop()
            await compat?.stop()
            await tallyServer?.stop()
            await tallyPublisher?.stop()
            await stateFeed.stop()
            await shutdownEarly(inputs: inputs, others: otherInputs, audioInputs: audioInputs.map(\.source), recorder: recorder, ndi: ndiSender,
                                streams: streams, audioEngine: audioEngine, writer: writer)
            return
        }
        try await engine.start(t0: t0, firstTick: .zero, lastTick: lastTick)
        let leadLeft = (t0 - HostClock.now()).milliseconds
        try statsPublisher?.start()
        guard let clock = engine.clock else { throw CLIError("引擎没有时钟") }
        print("""
            switcher-headless \(SwitcherVersion.current)
              节目：\(show.name)（\(options.showURL.path)）\(format.width)×\(format.height)@\(format.frameRate)，\(inputs.count) 路合成源\(otherInputs.isEmpty ? "" : " + \(otherInputs.count) 路其他（图片 / NDI / 摄像头 / 文件 / 纯音频）")，\(audioInputs.count + fileAudioInputs.count + deviceAudioInputs.count) 路音频
              场景：\(options.scriptURL?.path ?? "无")（\(scenario?.events.count ?? 0) 个事件）
              时长：\(totalTicks) 拍（\(String(format: "%.1f", options.durationSeconds)) s）  t0 距现在 \(String(format: "%.0f", leadLeft)) ms\(leadLeft < 0 ? "  ⚠️ 起晚了，开头会跳拍" : "")  合成源提前量 \(String(format: "%.2f", inputLeadMs)) ms
              音频：\(options.audioDevice)（对齐延迟 \(String(format: "%.2f", audioEngine.alignmentDuration.milliseconds)) ms，消费者流\(audioEngine.resamplesToHostClock ? "重采样到 host 时钟" : "不重采样")）  录制：\(options.recordURL?.path ?? "无")\(isoRecorders.isEmpty ? "" : "（+ \(isoRecorders.count) 路 ISO 音轨）")  stats：\(options.statsURL?.path ?? "无")  GPU 占用：\(gpu == nil ? "不可用" : "IOKit")
              API：\(apiServer.flatMap(\.baseURL).map { "\($0.absoluteString)/api/v1（WS /api/v1/events）\(options.api?.token == nil ? "" : "，token 鉴权开")" } ?? "关")  兼容层：\(options.compat.map { "\($0.host) TCP \($0.tcpPort) / HTTP \($0.httpPort)" } ?? "关")  tally：\(options.tallyPort.map { "0.0.0.0:\($0)" } ?? "关")  NDI 发送：\(options.ndiSend ?? "关")  推流：\(streams.isEmpty ? "关" : streams.map { "\($0.destination)" }.joined(separator: " / "))
              时钟实时策略：\(clock.isRealtime ? "已生效" : "⚠️ 未生效（V3 会超）")  A/V 补偿：\(audioEngine.avCompensationInEffect.rawValue)（视频延后队列 \(engine.videoDelayQueueCapacity) 帧，最多 \(String(format: "%.0f", engine.options.videoDelay.maxDelay.milliseconds)) ms）
            """)

        // 7. 等：跑完 totalTicks 拍（派发 + 跳过 = 总拍数），或收到信号。
        //    平时 100 ms 看一次；最后 30 拍改 2 ms，这样最后一拍派完后 ≤ 2 ms 就能停视频源——否则 60 fps 的源在这 100 ms 里再推 5–6 帧，
        //    3 格候选表挤掉 2–3 帧记成 dropped，stats 最后一行的 V4 精确核算会多出 1–2 帧设计外（G3 第一次跑 8 号输入就是这样）。
        while !(clock.ticksDispatched + clock.ticksSkipped >= UInt64(totalTicks)) && !stopRequested {
            let remaining = Int64(totalTicks) - Int64(clock.ticksDispatched + clock.ticksSkipped)
            try? await Task.sleep(for: remaining > 30 ? .milliseconds(100) : .milliseconds(2))
        }
        let interrupted = stopRequested

        // 7b. 先停入口（API / 兼容层 / tally：不再收命令、关掉连接），推送源等引擎停了再停（最后几拍的快照还要推）
        await apiServer?.stop()
        await compat?.stop()
        await tallyServer?.stop()

        // 8. 停。跑满的情况：时钟已派完最后一拍、不会再挑帧，先停视频源再停引擎——反过来的话引擎排空在途帧的那几十毫秒里视频源还在 push，
        //    满槽挤掉的帧会被记成 dropped，stats 最后一行的 V4 精确核算每路多出 2–3 帧（W1-B 报告 §4 第 13 条）。
        //    中断的情况：时钟还在跑，先停引擎（否则末尾几拍每路多 1–2 次 reuse），视频源紧接着停。
        //    然后录制封口（边界 = 最后一拍 + 1：音频恰好裁到最后一帧末尾，再多 writer 会因为音频超前于已结束的视频拒收而死等；
        //    封口期间音频源、泵、设备都还在跑）→ 泵 → 音频设备 → 音频源 → stats 关文件
        //    W4-A：文件输入的声音在它自己身上，停了它环就空了，而音频引擎要等录制封口、推流排空之后才停——这几秒里混音器把这一路记成欠载
        //    （soak 冒烟：最后一拍后 1 s 内 +8、停机段 +179，E4 同样）。所以先把文件输入从音频引擎摘掉（3 ms 淡出后 detach），过 50 ms 再停；
        //    合成源不受影响（先停），没有文件输入时顺序与原来完全相同。
        func stopOtherInputs() async {
            if !fileAudioInputs.isEmpty {
                for entry in fileAudioInputs { audioEngine.unregisterInput(number: entry.number) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            for input in otherInputs { input.stop() }
        }
        if interrupted {
            await engine.stop()
            for input in inputs { input.stop() }
            await stopOtherInputs()
        } else {
            for input in inputs { input.stop() }
            await stopOtherInputs()
            await engine.stop()
        }
        if let sender = ndiSender {
            engine.removeConsumer(sender)
            sender.stop()
        }
        let boundary = Tick((engine.counters.lastTick?.rawValue ?? -1) + 1)
        var recordResult: RecordingResult?
        if let rec = recorder {
            // W1-E2 起录制器自己把两轨裁到边界拍：stop(atTick:) 可以在含边界的音频块到达之前调，之后到的越界块入口就丢并计数
            // （RecorderCounters.audioFramesBeyondStop / audioFramesDroppedAfterStop）。G3 之前这里先等"含边界的块"送到、摘消费者、再 stop，
            // 反而把边界后 1.5 拍的音频先写进了文件（E5 音轨多 24 ms，reports/G3-notes.md §11）；G4 撤掉（prompt 60 末节第 1 条），
            // 消费者在封口之后再摘（摘不摘都不影响文件，只是别让泵给已停的录制器白送块）。
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
        if let token = recorderAudioToken { audioEngine.removeConsumer(token); recorderAudioToken = nil }
        for (_, t) in isoRecorders { audioEngine.removeConsumer(t) }
        // W4-A 推流收尾：摘视频消费者（引擎已停）和 Master 消费者，再排空发送队列、关连接（每路最多 drain 3 s + linger 1 s + 连接超时）
        for stream in streams { engine.removeConsumer(stream) }
        for token in streamAudioTokens { audioEngine.removeConsumer(token) }
        for stream in streams { await stream.stopAsync() }
        let audioStatus = audioEngine.status
        await audioEngine.stop()
        for entry in audioInputs { entry.source.stop() }
        statsPublisher?.stop()   // 先停采样再关文件；最后一行是停机前那一秒的
        writer?.close()
        await tallyPublisher?.stop()
        await stateFeed.stop()

        // 9. 汇总（stdout；数字来源都是各对象的计数器，正式指标以 stats.jsonl / frameprobe 为准）
        printSummary(clock: clock, inputs: inputs, others: otherInputs, audioInputs: audioInputs.map { (number: $0.number, source: $0.source) },
                     audioStatus: audioStatus, recorder: recorder, recordResult: recordResult, writer: writer, interrupted: interrupted,
                     ndi: ndiSender, compat: compat, tally: tallyPublisher, streams: streams)
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

    private func shutdownEarly(inputs: [SyntheticVideoInput], others: [any Input], audioInputs: [SyntheticAudioInput], recorder: Recorder?,
                               ndi: NDISender?, streams: [StreamOutput], audioEngine: AudioEngine, writer: StatsWriter?) async {
        if let rec = recorder {
            _ = await stopRecorder(rec, atTick: .zero, timeoutSeconds: 10)
        }
        for stream in streams {
            engine.removeConsumer(stream)
            await stream.stopAsync()
        }
        await audioEngine.stop()
        for a in audioInputs { a.stop() }
        for input in inputs { input.stop() }
        for input in others { input.stop() }
        ndi?.stop()
        writer?.close()
        print("引擎启动前收到信号，已收尾退出")
        exitCode = 130
    }

    private func printSummary(clock: ProgramClock, inputs: [SyntheticVideoInput], others: [any Input], audioInputs: [(number: Int, source: SyntheticAudioInput)],
                              audioStatus a: AudioEngineStatus, recorder: Recorder?,
                              recordResult: RecordingResult?, writer: StatsWriter?, interrupted: Bool,
                              ndi: NDISender?, compat: VMixCompatServer?, tally: TallyPublisher?, streams: [StreamOutput] = []) {
        let c = engine.counters
        func ms(_ d: HostDuration?) -> String { d.map { String(format: "%.3f", $0.milliseconds) } ?? "—" }
        var lines: [String] = []
        lines.append("结束：\(interrupted ? "信号中断" : "跑满") \(c.ticksDispatched + c.ticksSkipped) / \(totalTicks) 拍")
        lines.append("  引擎：派发 \(c.ticksDispatched) 拍，跳拍 \(c.ticksSkipped)，渲染器 skipped \(c.renderSkipped)（missed_render = \(c.missedRender)），提交 \(c.framesSubmitted)，完成 \(c.framesCompleted)，派发给消费者 \(c.framesDispatched)，快照等待 \(c.snapshotWaits) / 过期 \(c.snapshotStale)，慢消费者调用 \(c.slowConsumeCalls)")
        lines.append("  时钟：唤醒抖动 p99 \(ms(clock.jitter.percentile(0.99))) ms，max \(ms(clock.jitter.allTimeMax)) ms（\(clock.jitter.sampleCount) 拍）；渲染 V1 平均 \(String(format: "%.3f", c.averageRenderMs)) ms")
        lines.append("  视频延后（\(options.avCompensation.rawValue)）：最后 \(String(format: "%.3f", c.videoDelayMs)) ms，经延迟队列 \(c.framesDelayed) 帧，队列最多压 \(c.videoDelayQueueMax) / \(engine.videoDelayQueueCapacity)，满了丢 \(c.videoDelayOverflow)，派发晚到期 max \(ms(c.takeVideoDelayLateMax())) ms")
        for input in inputs {
            let k = input.counters
            let s = input.videoSlot?.stats
            var pacing = ""
            if let ps = engine.pacingStats(forInput: input.number) {
                pacing = "；到达余量 \(String(format: "%.2f", ps.margin.milliseconds)) ms（窗口最大到达延迟 \(String(format: "%.2f", ps.windowMaxLatency.milliseconds)) ms，迟到 \(ps.lateFrames)，抬 \(ps.raises) / 降 \(ps.decreases)）"
            }
            lines.append("  输入 \(input.number)：生成 \(k.generated)，设定丢 \(k.droppedByDesign)，池不够 \(k.poolStarved)，迟到 \(k.late)，唤醒 max \(String(format: "%.3f", Double(k.wakeLatencyMaxNs) / 1e6)) ms；帧槽 pushed \(s?.pushed ?? 0) consumed \(s?.consumed ?? 0) reused \(s?.reused ?? 0) dropped \(s?.dropped ?? 0)" + pacing)
        }
        for input in others {
            var pacing = ""
            if let ps = engine.pacingStats(forInput: input.number) {
                pacing = "；到达余量 \(String(format: "%.2f", ps.margin.milliseconds)) ms（窗口最大到达延迟 \(String(format: "%.2f", ps.windowMaxLatency.milliseconds)) ms，迟到 \(ps.lateFrames)）"
            }
            let s = input.videoSlot?.stats
            var detail = ""
            if let ndi = input as? NDIInput {
                let c = ndi.ndiCounters
                detail = "；收 \(c.framesReceived) 帧 / 推 \(c.framesPushed)，SDK 丢 \(c.sdkVideoDropped)，格式不支持 \(c.framesUnsupported)，池耗尽 \(c.framesPoolExhausted)，重连 \(c.reconnects)，抖动均值 / 最大 \(String(format: "%.2f / %.2f", c.jitterMeanMs, c.jitterMaxMs)) ms" + (ndi.lastError.map { "；\($0)" } ?? "")
            } else if let image = input as? ImageInput {
                detail = "；\(image.imageWidth)×\(image.imageHeight)" + (image.lastError.map { "；\($0)" } ?? "")
            } else if let camera = input as? CameraInput {
                let k = camera.counters, t = camera.timestampStats
                detail = "；设备 \(camera.deviceName ?? camera.uniqueID)，协商 \(camera.negotiated.map { "\($0)" } ?? "—")，收 \(k.framesReceived) 帧 / 推 \(k.framesPushed)，采集丢 \(t.droppedByCapture)，"
                    + "到达延迟均值 / 最大 \(String(format: "%.2f / %.2f", t.meanDelayMs, t.maxDelayMs)) ms，状态切换 \(k.stateTransitions)（noSignal \(k.noSignalTransitions) / error \(k.errorTransitions)）"
                    + (camera.lastError.map { "；\($0)" } ?? "")
            } else if let file = input as? FileInput {
                let k = file.counters, f = file.fileCountersSnapshot
                detail = "；\(URL(fileURLWithPath: file.path).lastPathComponent) \(String(format: "%.2f", file.durationSeconds)) s，推 \(k.framesPushed) 帧，跳过 \(k.framesRejected)，"
                    + "循环 \(f.loops) 圈，解码没跟上 \(f.ticksStarved) 拍，音频块 \(f.audioChunksWritten) / 跳 \(f.audioChunksSkipped)，推帧线程晚醒 \(f.lateWakes)"
                    + (file.lastError.map { "；\($0)" } ?? "")
            }
            lines.append("  输入 \(input.number)（\(input.kind)）：状态 \(input.state)；帧槽 pushed \(s?.pushed ?? 0) consumed \(s?.consumed ?? 0) reused \(s?.reused ?? 0) dropped \(s?.dropped ?? 0)" + detail + pacing)
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
                lines.append("  录制：\(r.url.path)  视频 \(r.videoFrames) 帧 / 音频 \(r.audioFrames) 样本 / \(String(format: "%.3f", r.durationSeconds)) s / \(r.videoBytes / 1024) KB；编码 skipped \(r.encoder.skipped)，被 writer 拒 \(k.videoFramesRejected)，音频块丢 \(k.audioBlocksDropped)，音频漂移 \(String(format: "%.3f", k.audioDrift.milliseconds)) ms，硬校正 \(k.audioCorrections)，停止拍 \(r.stopTick)，越界丢弃 视频 \(k.videoFramesBeyondStop) 帧 / 音频 \(k.audioFramesBeyondStop) + 停后 \(k.audioFramesDroppedAfterStop) 样本")
            } else {
                lines.append("  录制：状态 \(rec.state)，视频 \(k.videoFrames) 帧，编码 skipped \(k.encoder.skipped)")
            }
        }
        if let w = writer {
            lines.append("  stats：\(w.url.path) 写 \(w.writtenLines) 行，丢 \(w.droppedLines)，清洗 \(w.sanitizedLines)")
        }
        if apiServer != nil || compat != nil {
            let b = commandBus.counters, f = stateFeed.counters
            lines.append("  API：命令 \(b.applied) 条应用（其中 \(b.ignored) 条被 reducer 忽略）/ \(b.rejected) 条拒绝 / \(b.queued) 条排过队；推送快照 \(f.snapshots) 条、stats \(f.stats) 条、唤醒 \(f.wakeups) 次")
        }
        if let compat {
            let c = compat.counters
            lines.append("  兼容层：函数 \(c.functions)（出错 \(c.functionErrors)），TCP 连接 \(c.tcpConnectionsAccepted)，XML \(c.xmlServed) 次，tally 事件 \(c.tallyEvents)，ACTS 事件 \(c.actsEvents)")
        }
        if let tally {
            let c = tally.counters
            lines.append("  tally 流：\(c)")
        }
        for (i, stream) in streams.enumerated() {
            let c = stream.counters
            lines.append("  推流 \(i + 1)（\(stream.destination)）：状态 \(c.state)，编码交出 \(c.framesReceived) 帧 / 送出 \(c.framesSent)（关键帧 \(c.keyframesSent)），网络丢 \(c.networkDropped)，"
                         + "编码 skipped \(stream.videoEncoder.counters.skipped)，音频包 \(c.audioPacketsSent) / 丢 \(c.audioDropped)，\(c.bytesSent / 1_048_576) MB，"
                         + "连接 \(c.connectAttempts) 次 / 重连 \(c.reconnects) / 断线 \(c.disconnects)"
                         + (stream.lastExitReasonDescription.isEmpty ? "" : "；最后一次退出发布循环：\(stream.lastExitReasonDescription)"))
        }
        if let ndi {
            let c = ndi.countersSnapshot
            lines.append("  NDI 发送：收 \(c.framesReceived) 帧 / 发 \(c.framesSent) / 队列丢 \(c.skipped)，转换失败 \(c.conversionFailures)，音频块 \(c.audioBlocksSent) / 丢 \(c.audioBlocksDropped)，转换 \(c.conversion)\(c.usingGPU ? "(GPU)" : "(CPU)") 最近 \(String(format: "%.2f", c.lastConvertMs)) ms，连接 \(c.connections)\(c.unavailable ? "，SDK 不可用" : "")")
        }
        print(lines.joined(separator: "\n"))
    }
}
