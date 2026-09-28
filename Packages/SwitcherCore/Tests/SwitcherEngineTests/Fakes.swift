import CoreVideo
import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

// 测试用的假实现。渲染器 / 消费者的真实现分别在 W1-C / W1-E；这里只模拟它们的线程行为与耗时。

/// 所有测试共用的像素缓冲：帧槽 / 渲染表只存引用，不看像素。
enum TestFrames {
    nonisolated(unsafe) static let sharedBuffer: CVPixelBuffer = {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }()

    static func frame(input: Int = 1, sequence: UInt64, pts: HostTime, ingress: HostTime? = nil) -> Frame {
        Frame(pixelBuffer: sharedBuffer, pts: pts, duration: HostDuration(ticks: 400_000), color: .bt709Limited,
              inputNumber: input, sequence: sequence, ingressTime: ingress ?? pts)
    }
}

/// 假渲染器：`render` 在渲染线程立即返回（可选忙等到 tickTime + busy 模拟 CPU 耗时），
/// 完成回调由自己的工作线程在 submitTime + gpuDelay 之后发出，模拟 GPU 完成时刻。
final class FakeRenderer: Renderer, @unchecked Sendable {
    var sink: (any RenderSink)?
    let gpuDelay: HostDuration
    let busyUntilOffset: HostDuration?
    let skipEvery: Int
    /// prepare 的耗时（模拟着色器编译 / 纹理池分配等一次性准备；W1-B3 启动用例）。
    let prepareDelay: HostDuration
    let prepareCalls = Atomic<UInt64>(0)
    private let queue = SPSCOverwriteRing<Pending>(capacity: 64)
    private let semaphore = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var worker: NativeThread?
    let renderCalls = Atomic<UInt64>(0)
    let submitted = Atomic<UInt64>(0)
    let completed = Atomic<UInt64>(0)
    /// 渲染线程 / 完成线程的 mach 端口（第一次被调时记下，给分配探针用）。
    let renderThread = Atomic<UInt32>(0)
    let completionThread = Atomic<UInt32>(0)
    /// 每拍记录输入 1 的帧序号（-1 = 没有帧），给挑帧测试看。预分配，渲染路径不分配。
    let input1Sequence: UnsafeMutablePointer<Int64>
    let recordCapacity = 4096
    private var programBuffer: CVPixelBuffer?

    struct Pending {
        var tick: Tick
        var tickTime: HostTime
        var submitTime: HostTime
    }

    init(gpuDelay: HostDuration = HostDuration(milliseconds: 2), busyUntilOffset: HostDuration? = nil, skipEvery: Int = 0,
         prepareDelay: HostDuration = .zero) {
        self.gpuDelay = gpuDelay
        self.busyUntilOffset = busyUntilOffset
        self.skipEvery = skipEvery
        self.prepareDelay = prepareDelay
        input1Sequence = .allocate(capacity: recordCapacity)
        input1Sequence.initialize(repeating: -1, count: recordCapacity)
    }
    deinit { input1Sequence.deallocate() }

    func prepare(format: ProgramFormat, maxInputs: Int) throws {
        prepareCalls.add(1, ordering: .relaxed)
        if prepareDelay > .zero { mach_wait_until((HostClock.now() + prepareDelay).ticks) }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        programBuffer = pb
        running.store(true, ordering: .releasing)
        let t = NativeThread(config: NativeThreadConfig(name: "fake-gpu", qos: QOS_CLASS_USER_INITIATED)) { [self] in
            completionThread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
            while running.load(ordering: .acquiring) {
                semaphore.wait()
                while let p = queue.pop() {
                    let due = p.submitTime + gpuDelay
                    mach_wait_until(due.ticks)
                    let end = HostClock.now()
                    let frame = TestFrames.frame(input: 0, sequence: UInt64(p.tick.rawValue), pts: p.tickTime)
                    let rendered = RenderedFrame(tick: p.tick, tickTime: p.tickTime, program: frame, submitTime: p.submitTime, gpuStart: p.submitTime, gpuEnd: end)
                    completed.add(1, ordering: .relaxed)
                    sink?.renderer(self, didComplete: rendered)
                }
            }
        }
        try t.start()
        worker = t
    }

    func render(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict {
        let n = renderCalls.add(1, ordering: .relaxed).oldValue
        if n == 0 { renderThread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed) }
        let idx = Int(tick.rawValue)
        if idx >= 0 && idx < recordCapacity {
            input1Sequence[idx] = inputs[inputNumber: 1].map { Int64($0.sequence) } ?? -1
        }
        if let busy = busyUntilOffset {
            let until = tickTime + busy
            while HostClock.now() < until {}
        }
        if skipEvery > 0 && (n + 1) % UInt64(skipEvery) == 0 { return .skipped }
        _ = queue.push(Pending(tick: tick, tickTime: tickTime, submitTime: HostClock.now()))
        submitted.add(1, ordering: .relaxed)
        semaphore.signal()
        return .submitted
    }

    func shutdown() {
        running.store(false, ordering: .releasing)
        semaphore.signal()
        worker?.join()
        worker = nil
    }

    /// 等所有已提交的帧完成回调发出。
    func waitForCompletion(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while completed.load(ordering: .acquiring) < submitted.load(ordering: .acquiring) && Date() < deadline { usleep(1000) }
    }
}

/// 立即返回的消费者：只计数、记录收到的拍序列（检查有无重复 / 乱序）。
final class CountingConsumer: FrameConsumer, @unchecked Sendable {
    let consumerName: String
    let received = Atomic<UInt64>(0)
    let outOfOrder = Atomic<UInt64>(0)
    private let lastTick = Atomic<Int64>(Int64.min)
    init(name: String) { consumerName = name }
    func consume(_ frame: RenderedFrame) {
        received.add(1, ordering: .relaxed)
        let prev = lastTick.exchange(frame.tick.rawValue, ordering: .acquiringAndReleasing)
        if frame.tick.rawValue <= prev { outOfOrder.add(1, ordering: .relaxed) }
    }
}

/// 慢消费者：符合契约（consume 立即返回，帧进自己的有界队列），但每帧处理 50 ms。
final class SlowConsumer: FrameConsumer, @unchecked Sendable {
    let consumerName: String
    let inner: QueuedFrameConsumer
    final class Counter: Sendable { let value = Atomic<UInt64>(0) }
    private let processed = Counter()
    init(name: String, perFrame: HostDuration = HostDuration(milliseconds: 50), depth: Int = 2) {
        consumerName = name
        let processed = self.processed
        inner = QueuedFrameConsumer(name: name, depth: depth) { _ in
            let until = HostClock.now() + perFrame
            mach_wait_until(until.ticks)
            processed.value.add(1, ordering: .relaxed)
        }
    }
    var processedCount: UInt64 { processed.value.load(ordering: .acquiring) }
    func consume(_ frame: RenderedFrame) { inner.consume(frame) }
    func start() throws { try inner.start() }
    func stop() { inner.stop() }
}

/// 转场事件收集器。
final class EventCollector: TransitionEventSink, @unchecked Sendable {
    private let lock = Mutex<[(TransitionEvent, Bool)]>([])
    func stateMachine(_ machine: StateMachine, didEmit event: TransitionEvent, afv: Bool) {
        lock.withLock { $0.append((event, afv)) }
    }
    var events: [(TransitionEvent, Bool)] { lock.withLock { $0 } }
}

extension XCTestCase {
    /// 轮询直到条件成立或超时。
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            usleep(500)
        }
        return true
    }
}

// MARK: - L1 参考实现（提案 005 验收：与 W2-A 的 SwitcherInputsHarness/LatencyFrameSlot 同一算法，抄到测试里当参考；引擎的实现在 Engine/InputLatencyRecorder.swift）

/// 包一层真帧槽，按拍记下"返回了哪一帧（ingressTime、是不是新帧）"；256 项原子环，渲染线程写、消费者线程读。
final class ReferenceLatencySlot: FrameSlot, ArrivalPacedFrameSlot, @unchecked Sendable {
    let inner: LockFreeFrameSlot
    let spec: TickClockSpec
    static let ringSize = 256
    private let ticks: UnsafeMutablePointer<Atomic<Int64>>
    private let ingress: UnsafeMutablePointer<Atomic<UInt64>>
    private let flags: UnsafeMutablePointer<Atomic<UInt64>>   // 0 = 没帧，1 = 重复上一帧，2 = 新帧
    private var lastSequence: UInt64 = 0
    private var hasLast = false

    init(inner: LockFreeFrameSlot, spec: TickClockSpec) {
        self.inner = inner
        self.spec = spec
        ticks = .allocate(capacity: Self.ringSize)
        ingress = .allocate(capacity: Self.ringSize)
        flags = .allocate(capacity: Self.ringSize)
        for i in 0..<Self.ringSize {
            (ticks + i).initialize(to: Atomic(Int64.min))
            (ingress + i).initialize(to: Atomic(0))
            (flags + i).initialize(to: Atomic(0))
        }
    }
    deinit {
        ticks.deinitialize(count: Self.ringSize); ticks.deallocate()
        ingress.deinitialize(count: Self.ringSize); ingress.deallocate()
        flags.deinitialize(count: Self.ringSize); flags.deallocate()
    }
    var capacity: Int { inner.capacity }
    func push(_ frame: Frame) { inner.push(frame) }
    var stats: FrameSlotStats { inner.stats }
    func configurePacing(_ options: PacingOptions) { inner.configurePacing(options) }
    var pacingStats: PacingStats { inner.pacingStats }
    func latest(atOrBefore time: HostTime) -> Frame? {
        let f = inner.latest(atOrBefore: time)
        record(tick: spec.tick(at: time), frame: f)
        return f
    }
    func latest(forTick tickTime: HostTime) -> Frame? {
        let f = inner.latest(forTick: tickTime)
        record(tick: spec.tick(at: tickTime), frame: f)
        return f
    }
    private func record(tick: Tick, frame: Frame?) {
        let i = Int(tick.rawValue & Int64(Self.ringSize - 1))
        var flag: UInt64 = 0
        var ing: UInt64 = 0
        if let frame {
            ing = frame.ingressTime.ticks
            flag = (hasLast && frame.sequence == lastSequence) ? 1 : 2
            lastSequence = frame.sequence
            hasLast = true
        }
        (ingress + i).pointee.store(ing, ordering: .relaxed)
        (flags + i).pointee.store(flag, ordering: .relaxed)
        (ticks + i).pointee.store(tick.rawValue, ordering: .releasing)
    }
    func entry(forTick tick: Tick) -> (ingressTime: HostTime, isNew: Bool)? {
        let i = Int(tick.rawValue & Int64(Self.ringSize - 1))
        guard (ticks + i).pointee.load(ordering: .acquiring) == tick.rawValue else { return nil }
        let flag = (flags + i).pointee.load(ordering: .relaxed)
        guard flag != 0 else { return nil }
        return (HostTime(ticks: (ingress + i).pointee.load(ordering: .relaxed)), flag == 2)
    }
}

/// 参考消费者：consume 入口打戳（= 编码器入口），对每路查 ReferenceLatencySlot 算 L1；只算新帧，进槽早于 t0 的帧不算。
final class ReferenceLatencyConsumer: FrameConsumer, @unchecked Sendable {
    let consumerName = "l1-reference"
    let slots: [(number: Int, slot: ReferenceLatencySlot)]
    let t0: HostTime
    private let samples: [UnsafeMutablePointer<Int64>]
    private let counts: UnsafeMutablePointer<Atomic<Int>>
    private let reusedTicks: UnsafeMutablePointer<Atomic<Int>>
    let capacity = 1 << 16
    init(slots: [(number: Int, slot: ReferenceLatencySlot)], t0: HostTime) {
        self.slots = slots
        self.t0 = t0
        samples = slots.map { _ in
            let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1 << 16)
            p.initialize(repeating: 0, count: 1 << 16)
            return p
        }
        counts = .allocate(capacity: slots.count)
        reusedTicks = .allocate(capacity: slots.count)
        for i in 0..<slots.count { (counts + i).initialize(to: Atomic(0)); (reusedTicks + i).initialize(to: Atomic(0)) }
    }
    deinit {
        for p in samples { p.deallocate() }
        counts.deinitialize(count: slots.count); counts.deallocate()
        reusedTicks.deinitialize(count: slots.count); reusedTicks.deallocate()
    }
    func consume(_ frame: RenderedFrame) {
        let now = HostClock.now()
        var i = 0
        while i < slots.count {
            if let e = slots[i].slot.entry(forTick: frame.tick) {
                if e.isNew, e.ingressTime.ticks >= t0.ticks {
                    let n = (counts + i).pointee.load(ordering: .relaxed)
                    if n < capacity {
                        samples[i][n] = (now - e.ingressTime).ticks
                        (counts + i).pointee.store(n + 1, ordering: .releasing)
                    }
                } else if !e.isNew {
                    (reusedTicks + i).pointee.add(1, ordering: .relaxed)
                }
            }
            i += 1
        }
    }
    /// 某路：样本数、平均 ms、最大 ms、重复拍数。
    func stats(forInput number: Int) -> (samples: Int, meanMs: Double, maxMs: Double, reusedTicks: Int)? {
        guard let i = slots.firstIndex(where: { $0.number == number }) else { return nil }
        let n = (counts + i).pointee.load(ordering: .acquiring)
        let v = (0..<n).map { HostDuration(ticks: samples[i][$0]).milliseconds }
        return (n, v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count), v.max() ?? 0, (reusedTicks + i).pointee.load(ordering: .relaxed))
    }
}
