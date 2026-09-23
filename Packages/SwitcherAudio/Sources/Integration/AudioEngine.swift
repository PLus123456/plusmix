import Foundation
import CoreAudio
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio

// 音频引擎（W2-E 集成层）：把 W1-D 的混音器挂进引擎（设计方案 §3.5、§3.6、§7）。
//
// 职责：
//   1. 输入：每路 Input 的 AudioRing 注册进混音上下文（先 attach、对齐、再放音；摘除先淡出再 detach，环在非实时线程释放）。
//   2. 对齐与 PTS：每路输入按目标年龄就绪（W1-D2：注册时给混音器目标年龄 = min(任何相位都能命中的最小值, 对齐延迟)，就绪年龄不再带
//      生产者相位），就绪后读它的年龄（InputSlotStats.ageSetpoint），用延迟线补齐剩下的 alignmentFrames − 年龄（默认 P 256 时 2048 − 959 = 1089，
//      确定值；相位不利被钳到安全下限的输入才有不同的值）；Master / ISO 块的 PTS = 块首样本 host time − 对齐延迟 = 内容被采集的时刻，
//      与视频拍点同一 host 时基（G2 问题单 A2 的修法）。耳机总线默认不经这条延迟线（monitorPoint），监听延迟只有环年龄 + 设备。
//   3. AFV：状态机的转场事件（AudioStateBridge）→ 同一拍点的 host time 起做等幅交叉淡变，长度 = 转场时长；Cut = 1 块短淡；
//      T-bar 跟推杆；FTB 同步淡出 Master。**所有跟视频对齐的音频动作都在混音时间 = 拍点 + 对齐延迟 处应用**：混音块 T 里流过的
//      内容是 T − 对齐延迟 时刻采集的（PTS 也是它），要让录制文件 / 扬声器里的音频转场与画面同一时刻，增益变化就得晚对齐延迟这么多
//      （离线用例第一版没加这个偏移，音频淡变在文件里领先画面 42.7 ms）。
//   4. 每路参数 / 总线 / 监听方式：从状态快照 diff 落到混音命令。
//   5. 消费者：Master / 总线 / ISO 块经泵线程送录制 / 编码；真设备时重采样到 host 时钟（A3）。ISO（AudioTapSource.input）取
//      推子后、AFV 前（W1-D2），AFV 门控不进 ISO 音轨；.inputProgram 才是含 AFV 的节目信号。
//   6. Stats.audio 与状态快照（表、对齐、AFV、设备）。
// 线程：所有混音命令都在非实时线程发（控制线程 / 泵线程 / 组装方线程）；实时回调里只有 W1-D 的 C 代码。
public final class AudioEngine: AudioControlEventSink, @unchecked Sendable {
    public let stateMachine: StateMachine
    public let configuration: AudioEngineConfiguration
    /// 混音器（W1-D）。离线测试用它建 OfflineAudioDriver。
    public let mixer: AudioMixer
    /// 对齐延迟。
    public let alignmentDuration: HostDuration
    /// 一块的时长。
    public let blockDuration: HostDuration

    private enum OutputChoice {
        case null(NullOutputDevice)
        case device(AudioOutputDevice)
        case offline
    }

    /// 一路已注册输入的槽位记录（lock 保护）。
    private final class SlotRecord {
        let number: Int
        let slot: Int
        let ring: any AudioRing
        let hints: AudioInputHints
        var settings: InputAudioSettings
        var aligned = false
        var targetAge = 0
        var ageSetpoint: Double = 0
        var alignmentDelayFrames = 0
        var residualFrames = 0
        var lastReprimes: UInt64 = 0
        var afvGain: Float = 1
        var removing: HostTime?
        init(number: Int, slot: Int, ring: any AudioRing, hints: AudioInputHints, settings: InputAudioSettings) {
            self.number = number; self.slot = slot; self.ring = ring; self.hints = hints; self.settings = settings
        }
    }

    private let output: OutputChoice
    private let pump: ConsumerPump
    private let timebase: MachTimebase
    private let lock = NSLock()
    private var slots: [Int: SlotRecord] = [:]
    private var freeSlots: [Int]
    private var settingsCache: [Int: InputAudioSettings] = [:]
    private var buses: [BusState] = Bus.allCases.map { BusState(bus: $0) }
    private var afvOn = false
    private var monitorMode: MonitorMode = .afl
    private var ftbRamp: (on: Bool, start: HostTime, duration: HostDuration)?
    private var ftbFactor: Float = 1
    private var ftbLevel: Double = 0
    private var activeTransition: (from: Int, to: Int, source: TransitionSource, at: HostTime)?
    /// 到点再设的门控（T-bar：推杆位置要晚对齐延迟才作用到音频）。
    private var deferredGates: [(due: HostTime, number: Int, gain: Float)] = []
    private let pendingEvents = Mutex<[AudioControlEvent]>([])
    private var bridge: AudioStateBridge?
    private(set) public var clock: TickClockSpec?
    private let started = Atomic<Bool>(false)
    private var controlThread: Thread?
    private let wake = DispatchSemaphore(value: 0)
    private let stopFlag = Atomic<Bool>(false)
    private let controlFinished = DispatchSemaphore(value: 0)
    private let statusBox = Mutex<AudioEngineStatus?>(nil)
    private var lastStatusAt: HostTime = .zero
    /// 状态快照刷新间隔。
    public var statusInterval = HostDuration(milliseconds: 50)
    /// 控制循环跑了多少次。
    public private(set) var controlCycles: UInt64 = 0

    /// - Parameters:
    ///   - stateMachine: 引擎的状态机（AFV / 参数从它来）。
    ///   - configuration: 参数。设备在这里创建（找不到设备就抛）。
    public init(stateMachine: StateMachine, configuration: AudioEngineConfiguration = AudioEngineConfiguration()) throws {
        self.stateMachine = stateMachine
        var cfg = configuration
        cfg.mixer.blockFrames = configuration.blockFrames
        self.configuration = cfg
        let mixer = AudioMixer(configuration: cfg.mixer)
        self.mixer = mixer
        timebase = cfg.mixer.timebase
        alignmentDuration = HostDuration(ticks: Int64((Double(cfg.alignmentFrames) * mixer.hostTicksPerFrame).rounded()))
        blockDuration = HostDuration(ticks: Int64((Double(cfg.blockFrames) * mixer.hostTicksPerFrame).rounded()))
        freeSlots = Array((0..<mixer.inputCapacity).reversed())
        let isRealDevice: Bool
        switch cfg.output {
        case .null:
            output = .null(NullOutputDevice(mixer: mixer, blockFrames: cfg.blockFrames))
            isRealDevice = false
        case .systemDefault:
            output = .device(try AudioOutputDevice(mixer: mixer, deviceID: nil, blockFrames: cfg.blockFrames, busMap: cfg.outputChannelMap, followsDefault: true))
            isRealDevice = true
        case .device(let name):
            guard let info = AudioHAL.device(named: name) else { throw AudioDeviceError.noDevice }
            output = .device(try AudioOutputDevice(mixer: mixer, deviceID: info.id, blockFrames: cfg.blockFrames, busMap: cfg.outputChannelMap, followsDefault: false))
            isRealDevice = true
        case .deviceID(let id):
            output = .device(try AudioOutputDevice(mixer: mixer, deviceID: id, blockFrames: cfg.blockFrames, busMap: cfg.outputChannelMap, followsDefault: false))
            isRealDevice = true
        case .offline:
            output = .offline
            isRealDevice = false
        }
        let resample: Bool
        switch cfg.hostClockResampling {
        case .auto: resample = isRealDevice
        case .on: resample = true
        case .off: resample = false
        }
        pump = ConsumerPump(mixer: mixer, alignment: alignmentDuration, resample: resample, detectDiscontinuities: cfg.detectDiscontinuities,
                            period: cfg.pumpPeriod, tapCapacity: cfg.tapCapacityBlocks, timebase: timebase)
        mixer.setMonitorPoint(cfg.monitorPoint)
    }

    deinit {
        if started.load(ordering: .acquiring) { stopSync() }
    }

    /// 消费者流是否经过 host 时钟重采样。
    public var resamplesToHostClock: Bool { pump.resample }
    /// 输出设备（真设备时）。
    public var outputDevice: AudioOutputDevice? { if case .device(let d) = output { return d } else { return nil } }
    /// 空设备（null 时）。
    public var nullDevice: NullOutputDevice? { if case .null(let d) = output { return d } else { return nil } }

    // MARK: 输入注册（组装方线程）

    /// 把一路输入的音频环挂进混音器。挂上后先按状态里的参数设好、对齐前静音；就绪后由控制循环设对齐延迟并放音。
    public func registerInput(number: Int, ring: any AudioRing, hints: AudioInputHints = AudioInputHints()) throws {
        precondition(number > MixerState.noInput)
        lock.lock()
        guard slots[number] == nil else { lock.unlock(); throw AudioEngineError.inputAlreadyRegistered(number) }
        guard let slot = freeSlots.popLast() else { lock.unlock(); throw AudioEngineError.noFreeSlot }
        let latest = bridge?.lastSeenState ?? stateMachine.publisher.latest?.state
        let settings = settingsCache[number] ?? latest?.input(number)?.settings.audio ?? InputAudioSettings()
        let rec = SlotRecord(number: number, slot: slot, ring: ring, hints: hints, settings: settings)
        if let s = latest {
            rec.afvGain = AudioProgramGate.gains(for: s)[number] ?? (s.audio.afv && settings.afv ? 0 : 1)
        } else {
            rec.afvGain = afvOn && settings.afv ? 0 : 1
        }
        // 目标年龄：任何相位都能命中的最小值（目标 + P/2 + hf + chunk/2 + P，真设备再加输出提前量），但不超过对齐延迟——超过了延迟线补不回来，
        // 不如压到对齐延迟让年龄正好等于它（生产者块 > 混音块的源每块相位不同，混音器会等到能命中的那一块）；对齐延迟 0 = 旧规则（尽早就绪）
        let targetFrames = hints.targetFrames(blockFrames: configuration.blockFrames)
        let targetAge: Int
        if let explicit = hints.targetAgeFrames {
            targetAge = max(0, explicit)
        } else {
            let deterministic = mixer.deterministicAgeFrames(targetFrames: targetFrames, producerBlockFrames: hints.producerBlockFrames ?? configuration.blockFrames,
                                                             resampled: !hints.sameClockAsOutput) + outputLeadFrames
            targetAge = min(deterministic, max(0, configuration.alignmentFrames))
        }
        rec.targetAge = targetAge
        slots[number] = rec
        lock.unlock()
        mixer.attach(ring: ring, toSlot: slot, resampling: hints.sameClockAsOutput ? .bypass : .estimated,
                     targetFrames: targetFrames, targetAgeFrames: targetAge)
        applySettings(rec)
        mixer.setAFVGain(slot: slot, rec.afvGain)
    }

    /// 真设备的混音块 host time 是 inOutputTime（首样本的呈现时刻），比回调进入早 buffer + 安全偏移（内置扬声器 256 + 48 = 304 帧，
    /// W1-D 实测 6.23–6.35 ms）；源按采集时刻打戳、采完才交，所以相对混音时间线它的数据天然"老"这么多，目标年龄要把它加上才能任何相位都命中
    /// （否则混音器等满上限后退回旧规则，年龄 = 下限 + 提前量 + 相位，本会话真设备实测 1142）。空设备 / 离线的时间线就是"现在"，提前量 0。
    private var outputLeadFrames: Int {
        guard case .device(let d) = output else { return 0 }
        let buffer = d.isRunning ? d.actualBlockFrames : configuration.blockFrames
        return buffer + AudioHAL.safetyOffset(d.info.id, scope: kAudioObjectPropertyScopeOutput)
    }

    /// 摘除一路输入：先把它淡出（AFV 增益 → 0，3 ms），`removalFadeBlocks` 块后由控制循环 detach；环对象等实时线程确认后才释放。
    public func unregisterInput(number: Int, now: HostTime = .now()) {
        lock.lock()
        guard let rec = slots[number], rec.removing == nil else { lock.unlock(); return }
        rec.removing = now
        lock.unlock()
        mixer.setAFVGain(slot: rec.slot, 0)
    }

    /// 输入编号 → 槽位（没注册为 nil）。
    public func slot(forInput number: Int) -> Int? { lock.lock(); defer { lock.unlock() }; return slots[number]?.slot }
    /// 已注册的输入编号（升序）。
    public var registeredInputs: [Int] { lock.lock(); defer { lock.unlock() }; return slots.keys.sorted() }

    // MARK: 消费者

    /// 加一个消费者（录制 / 编码 / 推流）。同一来源的多个消费者共享一个混音器 tap。
    @discardableResult
    public func addConsumer(_ consumer: any AudioBlockConsuming, source: AudioTapSource = .master) throws -> AudioConsumerToken {
        try pump.add(consumer, source: source) { self.slot(forInput: $0) }
    }

    public func removeConsumer(_ token: AudioConsumerToken) { pump.remove(token) }

    /// 某块 Master 的 PTS：块首样本 host time − 对齐延迟。
    public func programPTS(forBlockHostTime t: HostTime) -> HostTime { t - alignmentDuration }

    // MARK: 生命周期

    /// 起：桥（转场事件 + 快照）→ 设备 → 泵 → 控制线程。`clock` = 引擎的节目时钟（拍 → host time）。
    public func start(clock: TickClockSpec) async throws {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { throw AudioEngineError.alreadyStarted }
        self.clock = clock
        let b = AudioStateBridge(stateMachine: stateMachine, clock: clock, sink: self)
        bridge = b
        await b.attach()
        b.pollSnapshot()
        switch output {
        case .null(let d): try d.start()
        case .device(let d): try d.start()
        case .offline: break
        }
        if configuration.controlMode == .thread {
            stopFlag.store(false, ordering: .releasing)
            pump.start()
            let t = Thread { [self] in controlLoop() }
            t.name = "switcher.audio-control"
            t.qualityOfService = .userInteractive
            controlThread = t
            t.start()
        }
    }

    /// 停：控制线程 → 泵（搬完剩下的块）→ 设备 → 桥；所有槽位 detach。
    public func stop() async {
        guard started.load(ordering: .acquiring) else { return }
        stopControlThread()
        pump.stop()
        switch output {
        case .null(let d): d.stop()
        case .device(let d): d.stop()
        case .offline: break
        }
        await bridge?.detach()
        bridge = nil
        detachAll()
        started.store(false, ordering: .releasing)
    }

    private func stopSync() {
        stopControlThread()
        pump.stop()
        switch output {
        case .null(let d): d.stop()
        case .device(let d): d.stop()
        case .offline: break
        }
        detachAll()
        started.store(false, ordering: .releasing)
    }

    private func stopControlThread() {
        guard controlThread != nil else { return }
        stopFlag.store(true, ordering: .releasing)
        wake.signal()
        controlFinished.wait()
        controlThread = nil
    }

    private func detachAll() {
        lock.lock()
        let all = Array(slots.values)
        slots.removeAll()
        freeSlots = Array((0..<mixer.inputCapacity).reversed())
        lock.unlock()
        for rec in all { mixer.detach(slot: rec.slot) }
    }

    public var isRunning: Bool { started.load(ordering: .acquiring) }

    // MARK: 事件入口（状态机线程 / 控制线程）

    public func audioControl(_ event: AudioControlEvent) {
        pendingEvents.withLock { $0.append(event) }
        wake.signal()
    }

    // MARK: 控制循环

    private func controlLoop() {
        defer { controlFinished.signal() }
        let period = DispatchTimeInterval.nanoseconds(Int(configuration.controlPeriod.nanoseconds(timebase: timebase)))
        while !stopFlag.load(ordering: .acquiring) {
            runControlCycle(now: HostClock.now())
            _ = wake.wait(timeout: .now() + period)
        }
        runControlCycle(now: HostClock.now())
    }

    /// 一次控制循环（手动模式由测试按块调；线程模式每 controlPeriod 或事件到达时调）：
    /// 读快照 diff → 处理事件 → 对齐维护 → FTB 斜坡 → 到期的摘除 → 状态快照。
    public func runControlCycle(now: HostTime = .now()) {
        controlCycles &+= 1
        bridge?.pollSnapshot()
        let events = pendingEvents.withLock { list -> [AudioControlEvent] in
            let out = list
            list.removeAll(keepingCapacity: true)
            return out
        }
        for e in events { handle(e, now: now) }
        applyDeferredGates(now: now)
        maintainAlignment()
        stepFadeToBlack(now: now)
        finishRemovals(now: now)
        if now - lastStatusAt >= statusInterval || lastStatusAt == .zero {
            lastStatusAt = now
            refreshStatus(now: now)
            // 真设备换了（默认设备变更 / 拔插重建 IOProc）：设备时钟变了，消费者流的重采样器重新测速率、重新锚定 PTS
            if let d = outputDevice, d.rebuilds != seenRebuilds {
                seenRebuilds = d.rebuilds
                pump.resetResamplers()
            }
        }
    }
    private var seenRebuilds = 0

    /// 手动模式：把消费者队列里的块搬给消费者。
    @discardableResult
    public func pumpOnce() -> Int { pump.runOnce() }

    // MARK: 事件处理

    private func handle(_ event: AudioControlEvent, now: HostTime) {
        switch event {
        case .inputsChanged(let added, let removed):
            lock.lock()
            for cfg in added { settingsCache[cfg.number] = cfg.settings.audio }
            var toApply: [SlotRecord] = []
            for cfg in added where slots[cfg.number] != nil {
                slots[cfg.number]!.settings = cfg.settings.audio
                toApply.append(slots[cfg.number]!)
            }
            var toRemove: [SlotRecord] = []
            for n in removed {
                settingsCache.removeValue(forKey: n)
                if let rec = slots[n], rec.removing == nil { rec.removing = now; toRemove.append(rec) }
            }
            lock.unlock()
            for rec in toApply { applySettings(rec) }
            for rec in toRemove { mixer.setAFVGain(slot: rec.slot, 0) }
        case .inputAudioSettings(let n, let s):
            lock.lock()
            let afvFlipped = slots[n]?.settings.afv != s.afv
            settingsCache[n] = s
            let rec = slots[n]
            rec?.settings = s
            lock.unlock()
            if let rec { applySettings(rec) }
            // 每路 AFV 开关翻了就立刻按最新状态重算这一路的门控增益（用户 2026-09-22 批）
            if afvFlipped { applyGates() }
        case .buses(let b):
            lock.lock(); buses = b; lock.unlock()
            applyBuses()
        case .monitorMode(let m):
            lock.lock(); monitorMode = m; lock.unlock()
            mixer.setMonitorMode(m)
        case .afv(let on):
            lock.lock(); afvOn = on; lock.unlock()
            applyGates()
        case .cut(let from, let to, _, let at):
            guard afvOn, from != to else { return }
            crossfade(from: from, to: to, frames: max(1, configuration.cutFadeBlocks) * configuration.blockFrames, start: at + alignmentDuration)
        case .transitionStarted(let from, let to, _, let source, _, let at, _, let duration):
            lock.lock(); activeTransition = (from, to, source, at); lock.unlock()
            guard afvOn, source == .auto, from != to else { return }
            // 时长按帧（W1-D2；30 拍 @60 = 24000 帧精确，@59.94 = 24024），不再按块取整
            let frames = max(1, Int((Double(duration.ticks) / mixer.hostTicksPerFrame).rounded()))
            crossfade(from: from, to: to, frames: frames, start: at + alignmentDuration)
        case .tbarProgress(let from, let to, let p):
            guard afvOn else { return }
            let pp = min(max(p, 0), 1)
            // 推杆位置在"现在"生效于画面，音频要晚对齐延迟：排到 now + 对齐延迟 再设
            let due = now + alignmentDuration
            lock.lock()
            if participatesInAFV(from) { deferredGates.append((due, from, Float(cos(pp * Double.pi / 2)))) }
            if participatesInAFV(to) { deferredGates.append((due, to, Float(sin(pp * Double.pi / 2)))) }
            lock.unlock()
        case .transitionEnded(_, _, _, _, let completed):
            lock.lock()
            let was = activeTransition
            activeTransition = nil
            lock.unlock()
            guard afvOn else { return }
            // auto 转场由 C 侧的淡变自己收口（时长按块取整可能比拍晚 < 1 块，这里不要去打断）；T-bar / 取消按最新状态重新门控
            if was?.source == .tbar || !completed { applyGates() }
        case .fadeToBlack(let on, _, let at, _, let duration):
            guard configuration.fadeMasterWithFTB else { return }
            lock.lock(); ftbRamp = (on, at, duration); lock.unlock()
        }
    }

    /// 切换 / 转场的交叉淡变。`InputAudioSettings.afv = false` 的路不进 from / to：它的门控增益恒 1（用户 2026-09-22 批）。
    private func crossfade(from: Int, to: Int, frames: Int, start: HostTime) {
        lock.lock()
        let fromRec = participatesInAFV(from) ? slots[from] : nil
        let toRec = participatesInAFV(to) ? slots[to] : nil
        fromRec?.afvGain = 0
        toRec?.afvGain = 1
        lock.unlock()
        guard fromRec != nil || toRec != nil else { return }
        mixer.crossfade(from: fromRec?.slot, to: toRec?.slot, durationFrames: frames, startHostTime: start)
    }

    /// 这一路参不参与 AFV 门控（`InputAudioSettings.afv`；不认识的路当参与）。调用方持锁。
    private func participatesInAFV(_ number: Int) -> Bool {
        (slots[number]?.settings ?? settingsCache[number])?.afv ?? true
    }

    private func setGate(_ number: Int, _ g: Float) {
        lock.lock()
        guard let rec = slots[number], rec.removing == nil else { lock.unlock(); return }
        rec.afvGain = g
        lock.unlock()
        mixer.setAFVGain(slot: rec.slot, g)
    }

    /// 到点的延后门控：命令在下一块开始时应用，所以 due 落在下一块内的现在就发。
    private func applyDeferredGates(now: HostTime) {
        lock.lock()
        let horizon = now + blockDuration
        let ready = deferredGates.filter { $0.due <= horizon }
        deferredGates.removeAll { $0.due <= horizon }
        lock.unlock()
        for g in ready { setGate(g.number, g.gain) }
    }

    /// 按最新状态重新门控所有槽位。
    private func applyGates() {
        guard let state = bridge?.lastSeenState ?? stateMachine.publisher.latest?.state else { return }
        let gains = AudioProgramGate.gains(for: state)
        lock.lock()
        let afv = afvOn
        var changes: [(Int, Float)] = []
        for (n, rec) in slots where rec.removing == nil {
            let g = gains[n] ?? (afv && rec.settings.afv ? 0 : 1)
            if g != rec.afvGain { rec.afvGain = g; changes.append((rec.slot, g)) }
        }
        lock.unlock()
        for (slot, g) in changes { mixer.setAFVGain(slot: slot, g) }
    }

    /// 每路参数落到混音器：增益 / 静音（对齐前强制静音）/ 独听 / 声像 / 路由 / 延迟（对齐延迟 + 用户延迟补偿）。
    private func applySettings(_ rec: SlotRecord) {
        lock.lock()
        let s = rec.settings
        let muted = s.muted || !rec.aligned
        let delay = rec.alignmentDelayFrames + s.delayMs * AudioFormat.sampleRate / 1000
        let slot = rec.slot
        lock.unlock()
        mixer.setGain(slot: slot, dB: s.gainDb)
        mixer.setMuted(slot: slot, muted)
        mixer.setSolo(slot: slot, s.solo)
        mixer.setPan(slot: slot, s.pan)
        mixer.setRouting(slot: slot, s.routing)
        mixer.setDelay(slot: slot, frames: delay)
    }

    private func applyBuses() {
        lock.lock()
        let b = buses
        let factor = ftbFactor
        lock.unlock()
        for bs in b {
            let linear = Float(pow(10, bs.gainDb / 20)) * (bs.bus == .master ? factor : 1)
            mixer.setBusGain(bs.bus, linear: linear)
            mixer.setBusMuted(bs.bus, bs.muted)
        }
    }

    // MARK: 对齐维护

    /// 读混音器统计：新就绪的槽位按年龄设对齐延迟并放音；掉出就绪的重新静音等它回来。
    /// W1-D2 起年龄是混音器按目标就绪的确定值（rec.targetAge），延迟线只补 alignmentFrames − 年龄 这段残差（默认 1089 帧，各路相同）；
    /// 仍然读实际的 ageSetpoint 而不是直接用目标：相位不利被钳到安全下限、或目标本来就低于下限的输入，年龄会比目标大。
    /// 统计快照 3 KB + 32 路数组，每 4 个控制周期（≈ 8 ms）读一次就够（对齐前输入是静音的，晚几毫秒放音无所谓）。
    private func maintainAlignment() {
        if controlCycles % 4 != 1 { return }
        let stats = mixer.stats
        lock.lock()
        let records = Array(slots.values)
        lock.unlock()
        for rec in records {
            guard rec.slot < stats.inputs.count else { continue }
            let st = stats.inputs[rec.slot]
            guard st.attached else { continue }
            if st.primed {
                lock.lock()
                let needs = !rec.aligned || st.reprimes != rec.lastReprimes
                lock.unlock()
                guard needs else { continue }
                let age = st.ageSetpoint
                let ageFrames = Int(age.rounded())
                let delay = max(0, configuration.alignmentFrames - ageFrames)
                lock.lock()
                rec.ageSetpoint = age
                rec.alignmentDelayFrames = delay
                rec.residualFrames = max(0, ageFrames - configuration.alignmentFrames)
                rec.lastReprimes = st.reprimes
                rec.aligned = true
                let s = rec.settings
                lock.unlock()
                // 先设延迟再取消对齐静音：两条命令在同一块开始时应用，静音平滑（3 ms）从延迟已经跳好的那一刻开始起
                mixer.setDelay(slot: rec.slot, frames: delay + s.delayMs * AudioFormat.sampleRate / 1000)
                mixer.setMuted(slot: rec.slot, s.muted)
            } else {
                lock.lock()
                let wasAligned = rec.aligned
                rec.aligned = false
                lock.unlock()
                if wasAligned { mixer.setMuted(slot: rec.slot, true) }
            }
        }
    }

    // MARK: FTB

    private func stepFadeToBlack(now: HostTime) {
        lock.lock()
        guard let ramp = ftbRamp else { lock.unlock(); return }
        // 混音块 T 里的内容是 T − 对齐延迟 采集的，斜坡按内容时刻评估；再提前 3 ms（总线增益一阶平滑 τ = 3 ms），曲线就对上斜坡
        let at = now - alignmentDuration + HostDuration(milliseconds: 3, timebase: timebase)
        let level = AudioProgramGate.fadeToBlackLevel(at: at, on: ramp.on, start: ramp.start, duration: ramp.duration)
        ftbLevel = level
        let factor = Float(1 - level)
        let changed = factor != ftbFactor
        ftbFactor = factor
        let done = level == (ramp.on ? 1 : 0) && at >= ramp.start
        if done { ftbRamp = nil }
        let master = buses.first { $0.bus == .master } ?? BusState(bus: .master)
        lock.unlock()
        // 只推 Master 增益一条命令（斜坡期间每个控制周期一条；别把四条总线的增益 / 静音都重发一遍）
        if changed { mixer.setBusGain(.master, linear: Float(pow(10, master.gainDb / 20)) * factor) }
    }

    // MARK: 摘除

    private func finishRemovals(now: HostTime) {
        let wait = blockDuration * max(1, configuration.removalFadeBlocks)
        lock.lock()
        let due = slots.values.filter { rec in rec.removing.map { now - $0 >= wait } ?? false }
        for rec in due {
            slots.removeValue(forKey: rec.number)
            freeSlots.append(rec.slot)
        }
        lock.unlock()
        for rec in due { mixer.detach(slot: rec.slot) }
    }

    // MARK: 状态与统计

    /// 测试标准 §7 的 audio 一节（铁律 4：引擎 Stats 从这里灌，UI / API 读同一份）：dropouts / underruns 来自混音器，
    /// discontinuities 来自泵（A1 第三项），meters 是此刻的表读数（提案 004，来源只有 `AudioMixer.meters`；dB 下限 −120，静音总线的 LUFS 也钳到 −120）。
    /// 1 Hz 的 Stats 留档 / API / 测试用；UI 高刷新率的表继续读 `meters` / `status`。只在普通线程上调（每秒一次的采样线程）。
    public var audioCounters: Stats.AudioCounters {
        var c = mixer.audioCounters
        c.discontinuities = pump.discontinuities
        c.meters = statsMeters(mixer.meters)
        return c
    }

    /// MixerMeters → Stats 的表：buses 顺序 = Bus.allCases，inputs 键 = 输入编号（槽位表在 lock 下换算）。
    private func statsMeters(_ m: MixerMeters) -> Stats.AudioCounters.Meters {
        typealias M = Stats.AudioCounters.Meters
        func dB(_ v: [Float]) -> [Double] { v.map { M.decibels(fromLinear: Double($0)) } }
        let buses = Bus.allCases.compactMap { b -> Stats.AudioCounters.BusMeter? in
            guard b.rawValue < m.buses.count else { return nil }
            let r = m.buses[b.rawValue]
            return .init(bus: b.name, peakDb: dB(r.peak), truePeakDb: dB(r.truePeak), lufsM: M.loudness(r.momentaryLUFS),
                         lufsS: M.loudness(r.shortTermLUFS), lufsI: M.loudness(r.integratedLUFS), lra: M.loudness(r.loudnessRangeLU))
        }
        lock.lock()
        let pairs = slots.map { ($0.key, $0.value.slot) }
        lock.unlock()
        var inputs: [Int: Stats.AudioCounters.InputMeter] = [:]
        for (number, slot) in pairs where slot >= 0 && slot < m.inputs.count {
            inputs[number] = .init(peakDb: dB(m.inputs[slot].peak))
        }
        return M(buses: buses, inputs: inputs)
    }
    /// 表读数（实时刷新，UI 用）。
    public var meters: MixerMeters { mixer.meters }
    /// 最近一次状态快照（控制循环每 statusInterval 刷新；还没有就现算一份）。
    public var status: AudioEngineStatus {
        if let s = statusBox.withLock({ $0 }) { return s }
        refreshStatus(now: .now())
        return statusBox.withLock { $0! }
    }

    private func refreshStatus(now: HostTime) {
        let stats = mixer.stats
        let meters = mixer.meters
        lock.lock()
        let records = slots.values.sorted { $0.number < $1.number }
        let afv = afvOn, mode = monitorMode, level = ftbLevel, transition = activeTransition, busStates = buses
        lock.unlock()
        func dB(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-6))) }
        let inputs: [AudioEngineStatus.InputStatus] = records.map { rec in
            let st = rec.slot < stats.inputs.count ? stats.inputs[rec.slot] : nil
            let m = rec.slot < meters.inputs.count ? meters.inputs[rec.slot] : nil
            return AudioEngineStatus.InputStatus(number: rec.number, slot: rec.slot, primed: st?.primed ?? false, aligned: rec.aligned,
                                                 ageSetpointFrames: rec.ageSetpoint, targetAgeFrames: rec.targetAge, ageFrames: st?.ageFrames ?? 0,
                                                 alignmentDelayFrames: rec.alignmentDelayFrames, residualFrames: rec.residualFrames,
                                                 userDelayMs: rec.settings.delayMs, ratio: st?.ratio ?? 1,
                                                 underrunBlocks: st?.underrunBlocks ?? 0, reprimes: st?.reprimes ?? 0, afvGain: rec.afvGain,
                                                 peakDb: (m?.peak ?? [0, 0]).map(dB), removing: rec.removing != nil)
        }
        let busStatus: [AudioEngineStatus.BusStatus] = Bus.allCases.map { b in
            let m = meters[b]
            let s = busStates.first { $0.bus == b } ?? BusState(bus: b)
            return AudioEngineStatus.BusStatus(bus: b, peakDb: m.peak.map(dB), truePeakDb: m.truePeak.map(dB), peakHoldDb: m.peakMax.map(dB),
                                               momentaryLUFS: m.momentaryLUFS, shortTermLUFS: m.shortTermLUFS, integratedLUFS: m.integratedLUFS,
                                               loudnessRangeLU: m.loudnessRangeLU, gainDb: s.gainDb, muted: s.muted)
        }
        let device: AudioEngineStatus.DeviceStatus
        switch output {
        case .null(let d):
            let s = d.stats
            device = .init(kind: "null", name: "空设备", blockFrames: d.blockFrames, running: d.isRunning, callbacks: s.blocks, rebuilds: 0, maxJitterMs: s.maxWakeLateMs)
        case .device(let d):
            let s = d.callbackStats
            device = .init(kind: "device", name: d.info.name, blockFrames: d.actualBlockFrames, running: d.isRunning, callbacks: s.callbacks,
                           rebuilds: d.rebuilds, maxJitterMs: s.maxJitterMs)
        case .offline:
            device = .init(kind: "offline", name: "离线", blockFrames: configuration.blockFrames, running: false, callbacks: stats.blocksRendered, rebuilds: 0, maxJitterMs: 0)
        }
        let consumers = pump.statuses.map {
            AudioEngineStatus.ConsumerStatus(source: "\($0.source)", consumers: $0.consumers, blocks: $0.blocksPopped, frames: $0.framesDelivered,
                                             tapDropped: $0.tapDropped, devicePpm: $0.resampler?.devicePpm, resampleRatio: $0.resampler?.ratio,
                                             resamplerStarved: $0.resampler?.starvedPulls ?? 0)
        }
        let status = AudioEngineStatus(
            device: device, alignmentFrames: configuration.alignmentFrames, alignmentMs: alignmentDuration.milliseconds(timebase: timebase),
            inputs: inputs, buses: busStatus, afv: afv, monitorMode: mode, monitorPoint: configuration.monitorPoint,
            activeTransition: transition.map { "\($0.from)→\($0.to) \($0.source)" }, ftbLevel: level,
            counters: stats.audio, discontinuities: pump.discontinuities, realtimeViolations: stats.rtViolations, tapDrops: stats.tapDrops,
            commandsDropped: stats.commandsDropped + mixer.commandsDropped, blocksRendered: stats.blocksRendered, consumers: consumers, at: now)
        statusBox.withLock { $0 = status }
    }
}
