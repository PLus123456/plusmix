// 表读数的 50 ms 分发（W3-E3 交付第 4 条）：主线程每 50 ms 读一次 AudioEngineStatus（音频控制循环每 AudioEngine.statusInterval = 50 ms
// 刷新的那一份快照），同一份交给
//   - 多画面电平表：拼成 Stats.AudioCounters.Meters（形态 = Stats.audio.meters，含提案 017 的 rms_db）调 renderer.setMeters(_:at:)，
//     时间用快照时刻（峰值保持 1 s、过期 3 s 都按它算：音频控制循环停了，表就在 3 s 后自己退回占位）；
//   - 调音台条子 / 纯音频输入的缩略图表（观察者）。
// 替掉 G4 检查点在 Stats 1 Hz 消费者里喂的那一条（1 Hz 下峰值保持基本等于当前值，W3-B2 报告 §1.1）。数的来源仍只有 AudioMixer.meters（铁律 4）：
// Stats 1 Hz 的那份是采样那一刻的同一张表，这里是 UI 高刷新率另读的那份（Stats.swift 的说明允许）。
// 线程：只在主线程（setMeters 分配、拿锁，不许进音频回调 / 渲染线程；渲染线程那头每帧零分配地读，W3-B2 的用例保证）。
import Foundation
import SwitcherContracts
import SwitcherAudioIntegration

@MainActor
final class AudioMeterFeed {
    /// 与 AudioEngine.statusInterval（音频控制循环刷新 AudioEngineStatus 的间隔）一样。
    static let interval: TimeInterval = 0.05

    private let status: @MainActor () -> AudioEngineStatus?
    private let sink: @MainActor (Stats.AudioCounters.Meters?, HostTime) -> Void
    private var timer: Timer?
    private var lastAt: HostTime?
    private var observers: [(key: UInt64, block: @MainActor (AudioEngineStatus) -> Void)] = []
    private var observerCounter: UInt64 = 0

    /// 喂给渲染器的次数（不含停的时候那次 nil）。测试看频率。
    private(set) var feeds: UInt64 = 0
    /// 不在主线程喂的次数（应恒为 0；测试看线程）。
    private(set) var offMainThreadFeeds: UInt64 = 0
    /// 最近一次喂出去的快照与表。
    private(set) var lastStatus: AudioEngineStatus?
    private(set) var lastFedMeters: Stats.AudioCounters.Meters?
    /// 停的时候显式清过渲染器的表（setMeters(nil)）。
    private(set) var cleared = false

    /// - Parameters:
    ///   - status: 取当前快照（AudioRuntime.status）；nil = 没有音频引擎。
    ///   - sink: 喂渲染器（MetalRenderer.setMeters）。
    init(status: @escaping @MainActor () -> AudioEngineStatus?, sink: @escaping @MainActor (Stats.AudioCounters.Meters?, HostTime) -> Void) {
        self.status = status
        self.sink = sink
    }

    /// 起 50 ms 定时器（音频引擎起了之后；common 模式：拖窗口 / 模态期间表也在动）。
    func start() {
        guard timer == nil else { return }
        cleared = false
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// 停定时器；clearRenderer = 显式 setMeters(nil)（音频引擎停了，多画面退回占位，不等 3 s 过期）。
    func stop(clearRenderer: Bool = true) {
        timer?.invalidate()
        timer = nil
        lastAt = nil
        if clearRenderer {
            sink(nil, HostClock.now())
            cleared = true
        }
    }

    var isRunning: Bool { timer != nil }

    /// 每 50 ms：取一份快照；同一份（控制循环还没刷新）不重复喂——两个 50 ms 相位漂移时偶尔会读到同一份、偶尔跳过一份。
    private func tick() {
        guard let s = status(), s.at != lastAt else { return }
        lastAt = s.at
        let meters = Self.meters(from: s)
        if !Thread.isMainThread { offMainThreadFeeds &+= 1 }
        sink(meters, s.at)
        feeds &+= 1
        lastStatus = s
        lastFedMeters = meters
        for o in observers { o.block(s) }
    }

    /// 每次有新快照时回调（主线程，与喂渲染器同一拍、同一份）。释放凭据即取消。
    func observe(_ block: @escaping @MainActor (AudioEngineStatus) -> Void) -> ObserverToken {
        observerCounter &+= 1
        let key = observerCounter
        observers.append((key, block))
        if let lastStatus { block(lastStatus) }
        return ObserverToken { [weak self] in
            Task { @MainActor in self?.observers.removeAll { $0.key == key } }
        }
    }

    /// AudioEngineStatus → Stats.audio.meters 的形态（AudioEngine.statsMeters 同一口径）：buses 按 Bus.allCases、bus = Bus.name，
    /// inputs 键 = 输入编号（正在摘除的路不算，与调音台条子一致）；dB 下限 −120（非有限数也给下限），LUFS / LRA 同 Stats 的钳法。
    static func meters(from status: AudioEngineStatus) -> Stats.AudioCounters.Meters {
        typealias M = Stats.AudioCounters.Meters
        func floored(_ v: [Double]) -> [Double] { v.map { $0.isFinite ? max(M.floorDb, $0) : M.floorDb } }
        let buses = status.buses.map { b in
            Stats.AudioCounters.BusMeter(bus: b.bus.name, peakDb: floored(b.peakDb), rmsDb: floored(b.rmsDb), truePeakDb: floored(b.truePeakDb),
                                         lufsM: M.loudness(b.momentaryLUFS), lufsS: M.loudness(b.shortTermLUFS),
                                         lufsI: M.loudness(b.integratedLUFS), lra: M.loudness(b.loudnessRangeLU))
        }
        var inputs: [Int: Stats.AudioCounters.InputMeter] = [:]
        for i in status.inputs where !i.removing {
            inputs[i.number] = Stats.AudioCounters.InputMeter(peakDb: floored(i.peakDb), rmsDb: floored(i.rmsDb))
        }
        return M(buses: buses, inputs: inputs)
    }
}
