import Foundation
import Synchronization
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// D05（Codex 2026-10-13 审查 §1.2）：录制器入口的音频环（AudioBlockRing）。
/// 原实现 `pop` 把槽从队列里释放了，却把槽内指针交给锁外读——队列原本满的时候，下一次 `push` 的尾槽正好是刚 pop 出来的那一格，
/// 消费者还没读完就被覆盖：样本变成新块的、PTS 还是旧块的。契约（`Block` 的注释）是"pop 出来的块到下一次 pop 之前有效"。
/// 块签名：第 k 块（PTS = k）第 c 声道第 i 帧 = `RingSignature.value(k, c, i)`，读到的样本与 PTS 必须是同一块。
final class AudioBlockRingTests: XCTestCase {
    private let channels = 2
    private let frames = 4

    private func push(_ k: Int, into ring: AudioBlockRing, source: RingSignature) -> Bool {
        source.fill(block: k)
        return source.withPlanes { ring.push(planes: $0, frameCount: frames, hostTime: HostTime(ticks: UInt64(k))) }
    }

    /// 核一块：PTS、帧数、样本都得是第 k 块的。返回是否对（交错用例第一次不对就停，免得每轮都报一遍）。
    @discardableResult
    private func check(_ block: AudioBlockRing.Block, isBlock k: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let got = (0..<channels).flatMap { c in (0..<frames).map { block.planes[c][$0] } }
        let want = (0..<channels).flatMap { c in (0..<frames).map { RingSignature.value(k, c, $0) } }
        XCTAssertEqual(block.hostTime, HostTime(ticks: UInt64(k)), "\(what)：PTS", file: file, line: line)
        XCTAssertEqual(block.frameCount, frames, "\(what)：帧数", file: file, line: line)
        XCTAssertEqual(got, want, "\(what)：样本应当是第 \(k) 块的（读到第 \(Int(got.first ?? 0) / 32) 块）", file: file, line: line)
        return block.hostTime == HostTime(ticks: UInt64(k)) && block.frameCount == frames && got == want
    }

    /// Codex 的触发条件原样：容量 2 / 128 / 256，推满后 pop 一块（第 1 块），读之前再 push 一块 999——
    /// 读到的样本仍是第 1 块、PTS 仍是 1（原实现：样本变 999、PTS 还是 1）；这次 push 有空位，不丢。
    func testD05_A1_fullRingPopThenPush_poppedBlockKeepsSamplesAndPTS() throws {
        for capacity in [2, 128, 256] {
            let ring = AudioBlockRing(channelCount: channels, maxFrames: frames, capacity: capacity)
            let source = RingSignature(channels: channels, frames: frames)
            for k in 1...capacity { XCTAssertFalse(push(k, into: ring, source: source), "容量 \(capacity)：推满之前不丢") }
            XCTAssertEqual(ring.depth, capacity)
            let block = try XCTUnwrap(ring.pop())
            XCTAssertFalse(push(999, into: ring, source: source), "容量 \(capacity)：pop 之后有一个空位，这次 push 不丢")
            check(block, isBlock: 1, "容量 \(capacity)：满队列 pop 之后 push 一次")
            XCTAssertEqual(ring.dropped, 0, "容量 \(capacity)")
        }
    }

    /// 满队列下 pop 与 push 交错 3 × 容量 轮（每轮 push 都正好落在刚 pop 出来的那一格），每块读到的都是它自己；
    /// 之后不 pop 连推 5 块：丢最旧的 5 块、`dropped` = 5、push 返回 true；剩下的按 PTS 顺序出来；
    /// 空环 pop 给 nil（欠载不改状态），再推一块照常出来。
    func testD05_A1_interleavedPopPushOnFullRing_everyBlockIntact_dropAndUnderrunAccounting() throws {
        for capacity in [2, 128, 256] {
            let ring = AudioBlockRing(channelCount: channels, maxFrames: frames, capacity: capacity)
            let source = RingSignature(channels: channels, frames: frames)
            for k in 1...capacity { _ = push(k, into: ring, source: source) }
            var next = capacity + 1
            var expected = 1
            for round in 0..<(3 * capacity) {
                let block = try XCTUnwrap(ring.pop(), "容量 \(capacity) 第 \(round) 轮")
                XCTAssertFalse(push(next, into: ring, source: source))
                next += 1
                let ok = check(block, isBlock: expected, "容量 \(capacity) 第 \(round) 轮交错")
                expected += 1
                if !ok { break }
            }
            XCTAssertEqual(ring.dropped, 0, "容量 \(capacity)：交错期间队列从没溢出")
            // 溢出：不 pop 连推 5 块 → 丢最旧的 5 块
            for _ in 0..<5 {
                XCTAssertTrue(push(next, into: ring, source: source), "容量 \(capacity)：满了 push 丢最旧并返回 true")
                next += 1
            }
            XCTAssertEqual(ring.dropped, 5, "容量 \(capacity)：丢块计数 = 溢出次数")
            expected += 5
            while let block = ring.pop() {
                let ok = check(block, isBlock: expected, "容量 \(capacity) 溢出后排空")
                expected += 1
                if !ok { break }
            }
            XCTAssertEqual(expected, next, "容量 \(capacity)：丢掉的正好是最旧的 5 块，其余一块不少")
            // 欠载：空环 pop 给 nil、深度 0；再推一块照常
            XCTAssertNil(ring.pop())
            XCTAssertEqual(ring.depth, 0)
            XCTAssertFalse(push(next, into: ring, source: source))
            check(try XCTUnwrap(ring.pop()), isBlock: next, "容量 \(capacity) 欠载之后")
            XCTAssertEqual(ring.dropped, 5)
        }
    }

    /// 真并发：生产者尽快推（队列几乎一直满），消费者 pop 之后先"慢"一会儿（模拟编码 / 写盘）再读。
    /// 每块的样本签名都要等于它的 PTS（原实现会读到后来覆盖进来的块）；推进去的 = 收到的 + 丢掉的；消费者线程里不分配。
    func testD05_A1_concurrentFastProducerSlowConsumer_noTornBlocks() throws {
        let frames = 64
        let ring = AudioBlockRing(channelCount: channels, maxFrames: frames, capacity: 8)
        let report = RingStress.run(seconds: 0.4, channels: channels, frames: frames,
                                    push: { planes, k in ring.push(planes: planes, frameCount: frames, hostTime: HostTime(ticks: UInt64(k))) },
                                    pop: { ring.pop().map { RingStress.Popped(hostTime: $0.hostTime, frameCount: $0.frameCount,
                                                                           planes: UnsafeRawPointer($0.planes).assumingMemoryBound(to: UnsafePointer<Float>.self)) } })
        print("D05 AudioBlockRing 并发：\(report)")
        XCTAssertGreaterThan(report.popped, 100, "消费者真的收到了块")
        XCTAssertGreaterThan(report.dropped, 0, "生产者确实比消费者快（队列满过）")
        XCTAssertEqual(report.torn, 0, "读到的样本与 PTS 不是同一块：\(report.firstTorn)")
        XCTAssertEqual(report.pushed, report.popped + report.dropped, "推进去的 = 收到的 + 丢掉的")
        XCTAssertEqual(UInt64(report.dropped), ring.dropped)
    }
}

/// 块签名：第 k 块第 c 声道第 i 帧的样本值（整数；k 按 2^19 取模，值 < 2^24，Float 精确表示）。
final class RingSignature: @unchecked Sendable {
    let channels: Int
    let frames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let planes: UnsafeMutablePointer<UnsafePointer<Float>>

    init(channels: Int, frames: Int) {
        self.channels = channels
        self.frames = frames
        storage = .allocate(capacity: channels * frames)
        storage.initialize(repeating: 0, count: channels * frames)
        planes = .allocate(capacity: channels)
        for c in 0..<channels { planes[c] = UnsafePointer(storage + c * frames) }
    }

    deinit {
        storage.deallocate()
        planes.deallocate()
    }

    static func value(_ k: Int, _ c: Int, _ i: Int) -> Float { Float((k & 0x7FFFF) * 32 + (c & 3) * 8 + (i & 7)) }

    func fill(block k: Int) {
        for c in 0..<channels { for i in 0..<frames { storage[c * frames + i] = Self.value(k, c, i) } }
    }

    func withPlanes<R>(_ body: (UnsafePointer<UnsafePointer<Float>>) -> R) -> R { body(UnsafePointer(planes)) }
}

/// 生产者 / 消费者两条线程真并发跑一个环：生产者尽快推带签名的块，消费者 pop 之后自旋 ~20 µs 再核签名。
enum RingStress {
    struct Popped {
        var hostTime: HostTime
        var frameCount: Int
        var planes: UnsafePointer<UnsafePointer<Float>>
    }

    struct Report: CustomStringConvertible {
        var pushed = 0
        var dropped = 0
        var popped = 0
        var torn = 0
        var firstTorn = ""
        var description: String { "推 \(pushed)、丢 \(dropped)、收 \(popped)、读到别的块的 \(torn)\(firstTorn.isEmpty ? "" : "（首例 \(firstTorn)）")" }
    }

    /// 两条线程共用的计数（Atomic 不能被逃逸闭包直接捕获，装进一个引用里）。
    private final class Shared: Sendable {
        let stop = Atomic<Bool>(false)
        let pushed = Atomic<Int>(0)
        let dropped = Atomic<Int>(0)
    }

    static func run(seconds: Double, channels: Int, frames: Int,
                    push: @escaping @Sendable (UnsafePointer<UnsafePointer<Float>>, Int) -> Bool,
                    pop: @escaping @Sendable () -> Popped?) -> Report {
        let shared = Shared()
        let producerDone = DispatchSemaphore(value: 0)
        let source = RingSignature(channels: channels, frames: frames)
        let producer = Thread {
            var k = 1
            while !shared.stop.load(ordering: .acquiring) {
                source.fill(block: k)
                if source.withPlanes({ push($0, k) }) { shared.dropped.add(1, ordering: .relaxed) }
                shared.pushed.add(1, ordering: .relaxed)
                k += 1
            }
            producerDone.signal()
        }
        producer.qualityOfService = .userInitiated
        var report = Report()
        func consume(_ b: Popped) {
            report.popped += 1
            // 慢消费者：pop 之后过 ~20 µs 才读（编码器 / writer 在忙）
            let until = HostClock.now() + HostDuration(nanoseconds: 20_000)
            while HostClock.now() < until {}
            let k = Int(b.hostTime.ticks)
            var bad = b.frameCount != frames
            var c = 0
            while !bad && c < channels {
                var i = 0
                while i < frames { if b.planes[c][i] != RingSignature.value(k, c, i) { bad = true; break }; i += 1 }
                c += 1
            }
            if bad {
                report.torn += 1
                if report.firstTorn.isEmpty { report.firstTorn = "PTS \(k) 读到 \(Int(b.planes[0][0]) / 32) 块" }
            }
        }
        producer.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let b = pop() { consume(b) }
        }
        shared.stop.store(true, ordering: .releasing)
        producerDone.wait()
        while let b = pop() { consume(b) }
        report.pushed = shared.pushed.load(ordering: .relaxed)
        report.dropped = shared.dropped.load(ordering: .relaxed)
        return report
    }
}
