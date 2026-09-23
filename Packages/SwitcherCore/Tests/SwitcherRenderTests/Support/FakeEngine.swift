// 假引擎：按节目时钟（TickClockSpec，mach_wait_until 等到拍点）在自己的线程上调 renderer.render，
// 输入帧从预先生成的像素缓冲里轮换（模拟每路输入的池子），收 RenderedFrame 统计 render_ms。
// 它就是 W1-B 引擎渲染线程的最小替身：读快照 → 填 RenderInputTable → render → 回调里派发。
import CoreVideo
import Darwin
import Foundation
import Synchronization
import SwitcherContracts
@testable import SwitcherRender

/// 收完成回调。只存时间戳（存 RenderedFrame 会把输出缓冲全部扣住，环就空了）；要帧的话设 holdDepth。
final class CollectingSink: RenderSink, @unchecked Sendable {
    struct Sample {
        let tick: Tick
        let tickTime: HostTime
        let submitTime: HostTime
        let gpuStart: HostTime
        let gpuEnd: HostTime
        var renderMs: Double { (gpuEnd - tickTime).milliseconds }
    }
    private let lock = NSLock()
    private(set) var samples: [Sample] = []
    /// 派发时刻（V3 抖动口径要它）。
    private(set) var dispatchTimes: [HostTime] = []
    /// 模拟一个慢消费者：持有最近 N 帧（含输出缓冲）。
    var holdDepth = 0
    private(set) var held: [RenderedFrame] = []
    /// 只留这几拍的帧（跑之前设好；按拍号取，不像 holdDepth 那样一直扣着最近几帧的输出缓冲）。
    var keepTicks: Set<Int64> = []
    private var keptFrames: [Int64: RenderedFrame] = [:]

    func renderer(_ renderer: any Renderer, didComplete frame: RenderedFrame) {
        lock.lock()
        samples.append(Sample(tick: frame.tick, tickTime: frame.tickTime, submitTime: frame.submitTime, gpuStart: frame.gpuStart, gpuEnd: frame.gpuEnd))
        dispatchTimes.append(HostClock.now())
        if holdDepth > 0 {
            held.append(frame)
            if held.count > holdDepth { held.removeFirst() }
        }
        if keepTicks.contains(frame.tick.rawValue) { keptFrames[frame.tick.rawValue] = frame }
        lock.unlock()
    }

    /// keepTicks 里某一拍的帧。
    func kept(_ tick: Int64) -> RenderedFrame? { lock.lock(); defer { lock.unlock() }; return keptFrames[tick] }

    var renderMs: [Double] { lock.lock(); defer { lock.unlock() }; return samples.map(\.renderMs) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
    var lastHeld: RenderedFrame? { lock.lock(); defer { lock.unlock() }; return held.last }
}

/// 一路合成输入：几张轮换的像素缓冲。
struct FakeInput {
    let number: Int
    let buffers: [CVPixelBuffer]
    let color: ColorInfo
}

final class FakeEngine: @unchecked Sendable {
    let renderer: MetalRenderer
    let sink = CollectingSink()
    let format: ProgramFormat
    let inputs: [FakeInput]
    let snapshot = Mutex<MixerSnapshot>(MixerSnapshot(state: MixerState(), sequence: 0, tick: .zero))
    let table: RenderInputTable
    private var thread: Thread?
    private let stop = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    /// render 的结果计数。
    let submitted = Atomic<UInt64>(0)
    let skipped = Atomic<UInt64>(0)
    /// mach_wait_until 醒来时刻 − 拍点时刻，累计（host tick）和次数：看渲染线程的唤醒延迟占 render_ms 多少。
    let wakeLagTicks = Atomic<UInt64>(0)
    let wakeLagCount = Atomic<UInt64>(0)
    var meanWakeLagMs: Double {
        let n = wakeLagCount.load(ordering: .relaxed)
        return n == 0 ? 0 : HostDuration(ticks: Int64(wakeLagTicks.load(ordering: .relaxed) / n)).milliseconds
    }
    /// 渲染线程的 pthread（分配探针要它）。
    let renderThread = Mutex<pthread_t?>(nil)
    /// 每拍在 render 前后可以做点别的（测试挂钩），在渲染线程上跑。
    var beforeRender: ((Tick) -> Void)?
    var afterRender: ((Tick, RenderVerdict) -> Void)?

    init(renderer: MetalRenderer, format: ProgramFormat, inputs: [FakeInput], state: MixerState) {
        self.renderer = renderer
        self.format = format
        self.inputs = inputs
        let maxNumber = inputs.map(\.number).max() ?? 0
        table = RenderInputTable(capacity: max(maxNumber, state.inputs.map(\.number).max() ?? 0) + 1)
        snapshot.withLock { $0 = MixerSnapshot(state: state, sequence: 0, tick: .zero) }
        renderer.sink = sink
    }

    func publish(_ state: MixerState, sequence: UInt64, tick: Tick) {
        snapshot.withLock { $0 = MixerSnapshot(state: state, sequence: sequence, tick: tick) }
    }

    /// 换一个事先建好的快照（在渲染线程的钩子里调也不分配：快照对象在别处建好，这里只换引用）。下一拍生效。
    func publish(_ prebuilt: MixerSnapshot) {
        snapshot.withLock { $0 = prebuilt }
    }

    /// 跑 duration 秒；startDelay 后的第一拍是第 0 拍。阻塞调用者直到跑完（在主线程上想同时泵 run loop 用 startAsync）。
    func run(seconds: Double) {
        startAsync()
        Thread.sleep(forTimeInterval: seconds)
        stopAndWait()
    }

    func startAsync() {
        stop.store(false, ordering: .releasing)
        let t = Thread { [self] in loop() }
        t.name = "fake-engine.render"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stopAndWait() {
        stop.store(true, ordering: .releasing)
        done.wait()
        thread = nil
    }

    private func loop() {
        renderThread.withLock { $0 = pthread_self() }
        // 实时线程优先级（设计方案 §11：pthread + user-interactive）
        var policy = thread_time_constraint_policy()
        let period = UInt32(HostDuration(seconds: 1.0 / format.frameRate.approximateFramesPerSecond).ticks)
        policy.period = period
        policy.computation = period / 4
        policy.constraint = period / 2
        policy.preemptible = 1
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &policy) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                _ = thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), ip, count)
            }
        }
        let spec = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 20), frameRate: format.frameRate)
        var tick = Tick.zero
        var frameCursor = 0
        // 每路输入的帧序号 / pts 由拍推出：输入帧率 = 节目帧率
        while !stop.load(ordering: .acquiring) {
            let tickTime = spec.time(of: tick)
            mach_wait_until(tickTime.ticks)
            wakeLagTicks.wrappingAdd(HostClock.now().ticks &- tickTime.ticks, ordering: .relaxed)
            wakeLagCount.wrappingAdd(1, ordering: .relaxed)
            let snap = snapshot.withLock { $0 }
            // 挑帧：每路取当前轮换到的缓冲（内容不变、IOSurface 轮换，等价于池子回收）
            var n = 0
            while n < inputs.count {   // 下标循环：-Onone 下 for-in 会分配，污染零分配测试的直方图
                let input = inputs[n]
                n += 1
                let pb = input.buffers[frameCursor % input.buffers.count]
                table[inputNumber: input.number] = Frame(pixelBuffer: pb, pts: tickTime, duration: HostDuration(ticks: Int64(period)),
                                                        color: input.color, inputNumber: input.number,
                                                        sequence: UInt64(tick.rawValue), ingressTime: tickTime)
            }
            beforeRender?(tick)
            let verdict = renderer.render(tick: tick, at: tickTime, snapshot: snap, inputs: table)
            afterRender?(tick, verdict)
            switch verdict {
            case .submitted: submitted.wrappingAdd(1, ordering: .relaxed)
            case .skipped: skipped.wrappingAdd(1, ordering: .relaxed)
            }
            frameCursor += 1
            tick += 1
        }
        done.signal()
    }
}

/// 造 N 路 1080p 合成输入（NV12，每路 poolDepth 张轮换，内容是 TestPattern）。
enum FakeInputs {
    static func nv12(count: Int, width: Int = 1920, height: Int = 1080, poolDepth: Int = 4) -> [FakeInput] {
        (1...count).map { n in
            let buffers = (0..<poolDepth).map { k -> CVPixelBuffer in
                let pb = PixelBuffers.nv12(width: width, height: height)
                TestPattern.draw(TestPattern.Content(frameNumber: UInt32(k), hostTimeMs: 0, inputID: (n - 1) % 16, flash: k == 0,
                                                     background: .gray(level: UInt8(min(220, 40 + n * 11)))), into: pb)
                return pb
            }
            return FakeInput(number: n, buffers: buffers, color: .bt709Limited)
        }
    }

    /// V8 的四路输入（BGRA）作为假引擎输入，每路一张。
    static func referenceBGRA() -> [FakeInput] {
        TestImages.referenceBuffers().sorted { $0.key < $1.key }.map { FakeInput(number: $0.key, buffers: [$0.value], color: .sRGBFull) }
    }
}

/// V1 的标准负载状态：8 路输入，PGM 1，PVW 2，Fade 进行到一半（多一层混合），4 个 overlay 开（5–8 路在四个角）。
/// W3-B 起（prompt 的 V1 回归："8 路 + 4 overlay + 抠像 + 多画面全开"）：四路叠加输入都开抠像、两路带边框、多画面用自定义布局（安全框 + 电平表占位）。
/// `legacy: true` = W1-C 的负载（无抠像 / 边框 / 布局），用来量本会话加的功能多花了多少（SWITCHER_V1_LEGACY_LOAD=1）；
/// 诊断：SWITCHER_V1_NO_KEYER=1 关抠像，SWITCHER_V1_DEFAULT_MULTIVIEW=1 用默认多画面布局（看各占多少）。
enum LoadStates {
    static func eightInputsFourOverlays(legacy: Bool = ProcessInfo.processInfo.environment["SWITCHER_V1_LEGACY_LOAD"] == "1",
                                        keyer: Bool = ProcessInfo.processInfo.environment["SWITCHER_V1_NO_KEYER"] != "1",
                                        customLayout: Bool = ProcessInfo.processInfo.environment["SWITCHER_V1_DEFAULT_MULTIVIEW"] != "1") -> MixerState {
        var s = MixerState(format: .hd1080p60, inputs: ReferenceStates.inputs(count: 8), program: 1, preview: 2)
        s.transition = TransitionState(type: .fade, durationTicks: 30, progress: 0.5, source: .auto, startTick: Tick(0))
        let rects = [NormalizedRect(x: 0.02, y: 0.02, width: 0.3, height: 0.3), NormalizedRect(x: 0.68, y: 0.02, width: 0.3, height: 0.3),
                     NormalizedRect(x: 0.02, y: 0.68, width: 0.3, height: 0.3), NormalizedRect(x: 0.68, y: 0.68, width: 0.3, height: 0.3)]
        for i in 0..<4 {
            s.overlays[i] = OverlayState(input: 5 + i, on: true, rect: rects[i], animProgress: 1, animation: OverlayAnimation(kind: .fade, durationTicks: 15))
        }
        guard !legacy else { return s }
        if keyer { for i in 4..<8 { s.inputs[i].settings.keyer = ReferenceStates.keyer() } }
        // 叠加 1 / 2（输入 5 / 6）带边框：W3-B 时写在输入 5 / 6 的效果格里，W3-B2 起走正式字段（负载不变，同样两圈边框）
        s.overlays[0].border = OverlayBorder()
        s.overlays[1].border = OverlayBorder(width: 0.01, color: RGB8(red: 255, green: 200, blue: 0))
        return customLayout ? ReferenceStates.withMultiviewLayout(s, ReferenceStates.customLayout) : s
    }
}

/// 闭包能捕获的原子布尔（Atomic 本身不可拷贝，进不了逃逸闭包）。
final class SharedFlag: @unchecked Sendable {
    private let storage = Atomic<Bool>(false)
    var value: Bool {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
}

/// 百分位。
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))
    return sorted[idx]
}
