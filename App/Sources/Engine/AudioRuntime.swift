// 音频接线（W2-B2 接缝 4）：W2-E 的 AudioEngine（混音器 + 输出设备 + 对齐 + AFV + 消费者泵）在 App 里的组装。
// 六步同 headless（reports/issues/W2E-g3-headless-audio-engine-wiring.md）：建 → 每路 registerInput(number:ring:hints:) →
// addConsumer(录制器 / 推流, source: .master) → engine.audioStatsProvider = { audioCounters } → start(clock:) / stop()。
// 输出设备来自 AppSettings.audioDevice（--audio-device / UserDefaults），每条总线的声道来自 AppSettings.busOutputMap（W5-K）；设备建不起来（没有输出设备、名字找不到）退到空设备并记下原因，
// 节目照跑（录制 / 推流照常拿 Master），状态行提示一句。
import Foundation
import SwitcherContracts
import SwitcherAudio
import SwitcherAudioIntegration
import SwitcherEngine

@MainActor
final class AudioRuntime {
    let engine: AudioEngine
    /// 实际用的设备选择（退到空设备时与设置不同）。
    let device: AppSettings.AudioDevice
    /// 设备退化的原因（没有就 nil）。
    let fallbackReason: String?
    /// 每路音频环的注册与延后重试（D07 拆出来，用例换计钟替身）。
    let registration: AudioInputRegistration
    /// 注册失败（槽位还在淡出摘除中）时的重试次数。
    var registerRetries: Int { registration.retries }

    /// 每条总线的出口（设置 › 音频设备，本机；nil = 跟设备默认 = 包里的 BusChannelMap.standard）。
    let busOutputMap: BusOutputMap?

    /// - Parameter audioState: 节目文件里的音频状态；对齐延迟与监听点从它取（提案 007）。
    /// - Parameter busOutputMap: 每条总线送到设备哪一对声道（W5-K / J8；同一台设备上的映射，包里已经支持）。
    init(stateMachine: StateMachine, device: AppSettings.AudioDevice, audioState: AudioState = AudioState(), busOutputMap: BusOutputMap? = nil) {
        self.busOutputMap = busOutputMap
        var config = AudioEngineConfiguration()
        config.output = Self.output(for: device)
        config.alignmentFrames = max(0, audioState.alignmentFrames)
        config.monitorPoint = SwitcherAudio.MonitorPoint(audioState.monitorPoint)
        config.outputChannelMap = busOutputMap?.busChannelMap
        // SW_AUDIO_SILENT=1：真设备也不出声（Master 不映射到设备通道，仍照常处理、照常送录制器）——测试机上跑 xcodebuild test 不吵人
        if ProcessInfo.processInfo.environment["SW_AUDIO_SILENT"] == "1" { config.outputChannelMap = BusChannelMap(master: nil) }
        let built: AudioEngine
        do {
            built = try AudioEngine(stateMachine: stateMachine, configuration: config)
            self.device = device
            fallbackReason = nil
        } catch {
            // 退到空设备：混音、对齐、录制音轨全都照常，只是扬声器没声
            var fallback = config
            fallback.output = .null
            built = try! AudioEngine(stateMachine: stateMachine, configuration: fallback)   // 空设备不依赖硬件，建不起来是编程错误
            self.device = .null
            fallbackReason = L("notice.audioDeviceFallback", device.spec, "\(error)")
            NSLog("%@", fallbackReason!)
        }
        engine = built
        registration = AudioInputRegistration(engine: built)
    }

    static func output(for device: AppSettings.AudioDevice) -> AudioEngineConfiguration.Output {
        switch device {
        case .systemDefault: .systemDefault
        case .null: .null
        case .named(let name): .device(name: name)
        }
    }

    /// 把一路输入的环挂进混音器。同一编号刚摘掉还在淡出（removalFadeBlocks ≈ 16 ms）时注册会撞 inputAlreadyRegistered，
    /// 延后 30 ms 再试（最多 10 次）；其他错误（槽位用完）记日志放弃（AudioInputRegistration）。
    func register(number: Int, ring: CAudioRing, blockFrames: Int) {
        var hints = AudioInputHints()
        hints.producerBlockFrames = blockFrames
        registration.register(number: number, ring: ring, hints: hints)
    }

    func unregister(number: Int) {
        registration.unregister(number: number)
    }

    var registeredInputs: [Int] { registration.registered.sorted() }

    /// 非隔离（W3-E6）：SwitcherSession 定 t0 之后把它与引擎的 start 放在同一个非主线程任务里接着做，中间不回主线程。
    nonisolated func start(clock: TickClockSpec) async throws { try await engine.start(clock: clock) }

    func stop() async {
        registration.removeAll()   // 先作废排着的注册重试（D07）：停的过程中到点的不会再往停着的引擎里注册
        await engine.stop()
    }

    /// 状态快照（控制循环每 50 ms 刷新；表读它）。
    var status: AudioEngineStatus { engine.status }

    /// 输出设备的声道数（空设备为 nil；调音台头部"当前设备没有耳机声道"用）。
    var outputChannelCount: Int? { engine.outputDevice?.info.outputChannels }

    /// 实际用的出口：设置里的，没有就按设备声道数的默认。
    var effectiveOutputMap: BusOutputMap? {
        guard let channels = outputChannelCount else { return busOutputMap }
        return busOutputMap ?? .standard(outputChannels: channels)
    }
}
