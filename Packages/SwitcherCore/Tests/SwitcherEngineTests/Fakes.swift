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

    init(gpuDelay: HostDuration = HostDuration(milliseconds: 2), busyUntilOffset: HostDuration? = nil, skipEvery: Int = 0) {
        self.gpuDelay = gpuDelay
        self.busyUntilOffset = busyUntilOffset
        self.skipEvery = skipEvery
        input1Sequence = .allocate(capacity: recordCapacity)
        input1Sequence.initialize(repeating: -1, count: recordCapacity)
    }
    deinit { input1Sequence.deallocate() }

    func prepare(format: ProgramFormat, maxInputs: Int) throws {
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
