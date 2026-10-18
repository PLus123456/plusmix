import Foundation
import Synchronization
import XCTest
import SwitcherContracts
@testable import SwitcherNDISend

/// D05（Codex 2026-10-13 审查 §1.2）：NDI 发送线程的音频环（NDISender.swift 里的 PCMRing）。原实现 `pop` 释放了槽却把槽内指针交给锁外读，
/// 队列原本满时下一次 `push`（泵线程的 consumeAudio）就覆盖发送线程正在拷的块。契约：pop 出来的块到下一次 pop 之前有效。
final class PCMRingTests: XCTestCase {
    private let channels = 2
    private let frames = 4

    private func push(_ k: Int, into ring: PCMRing, source: NDIRingSignature) -> Bool {
        source.fill(block: k)
        return source.withPlanes { ring.push(planes: $0, channelCount: channels, frameCount: frames, hostTime: HostTime(ticks: UInt64(k))) }
    }

    /// 核一块：PTS、帧数、样本都得是第 k 块的。返回是否对（交错用例第一次不对就停，免得每轮都报一遍）。
    @discardableResult
    private func check(_ block: PCMRing.Block, isBlock k: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let got = (0..<channels).flatMap { c in (0..<frames).map { block.planes[c][$0] } }
        let want = (0..<channels).flatMap { c in (0..<frames).map { NDIRingSignature.value(k, c, $0) } }
        XCTAssertEqual(block.hostTime, HostTime(ticks: UInt64(k)), "\(what)：PTS", file: file, line: line)
        XCTAssertEqual(block.frameCount, frames, "\(what)：帧数", file: file, line: line)
        XCTAssertEqual(got, want, "\(what)：样本应当是第 \(k) 块的（读到第 \(Int(got.first ?? 0) / 32) 块）", file: file, line: line)
        return block.hostTime == HostTime(ticks: UInt64(k)) && block.frameCount == frames && got == want
    }

    /// Codex 的触发条件：容量 2 / 128 / 256，推满后 pop 第 1 块、读之前 push 一块 999 → 读到的仍是第 1 块、PTS 1（原实现样本变 999）。
    func testD05_A1_fullRingPopThenPush_poppedBlockKeepsSamplesAndPTS() throws {
        for capacity in [2, 128, 256] {
            let ring = PCMRing(channelCount: channels, maxFrames: frames, capacity: capacity)
            let source = NDIRingSignature(channels: channels, frames: frames)
            for k in 1...capacity { XCTAssertFalse(push(k, into: ring, source: source)) }
            let block = try XCTUnwrap(ring.pop())
            XCTAssertFalse(push(999, into: ring, source: source), "容量 \(capacity)：pop 之后有空位，这次 push 不丢")
            check(block, isBlock: 1, "容量 \(capacity)：满队列 pop 之后 push 一次")
        }
    }

    /// 满队列 pop / push 交错 3 × 容量 轮每块完整；溢出 5 块 → push 返回 true 5 次（NDISender 计 audioBlocksDropped）、丢的是最旧的；
    /// 空环 pop 给 nil、之后照常。
    func testD05_A1_interleavedPopPushOnFullRing_everyBlockIntact_dropAndUnderrunAccounting() throws {
        for capacity in [2, 128, 256] {
            let ring = PCMRing(channelCount: channels, maxFrames: frames, capacity: capacity)
            let source = NDIRingSignature(channels: channels, frames: frames)
            for k in 1...capacity { _ = push(k, into: ring, source: source) }
            var next = capacity + 1
            var expected = 1
            for round in 0..<(3 * capacity) {
                let block = try XCTUnwrap(ring.pop())
                XCTAssertFalse(push(next, into: ring, source: source))
                next += 1
                let ok = check(block, isBlock: expected, "容量 \(capacity) 第 \(round) 轮交错")
                expected += 1
                if !ok { break }
            }
            var drops = 0
            for _ in 0..<5 {
                if push(next, into: ring, source: source) { drops += 1 }
                next += 1
            }
            XCTAssertEqual(drops, 5, "满了每次 push 都丢最旧的一块并返回 true")
            expected += 5
            while let block = ring.pop() {
                let ok = check(block, isBlock: expected, "容量 \(capacity) 溢出后排空")
                expected += 1
                if !ok { break }
            }
            XCTAssertEqual(expected, next)
            XCTAssertNil(ring.pop())
            XCTAssertFalse(push(next, into: ring, source: source))
            check(try XCTUnwrap(ring.pop()), isBlock: next, "容量 \(capacity) 欠载之后")
        }
    }

    /// 真并发：生产者尽快推（队列几乎一直满），消费者 pop 之后 ~20 µs 才读（发送线程在送视频）；每块签名 = PTS，推 = 收 + 丢。
    func testD05_A1_concurrentFastProducerSlowConsumer_noTornBlocks() throws {
        let frames = 64
        let ring = PCMRing(channelCount: channels, maxFrames: frames, capacity: 8)
        let report = NDIRingStress.run(seconds: 0.4, channels: channels, frames: frames,
                                       push: { planes, k in ring.push(planes: planes, channelCount: 2, frameCount: frames, hostTime: HostTime(ticks: UInt64(k))) },
                                       pop: { ring.pop().map { ($0.hostTime, $0.frameCount, $0.planes) } })
        print("D05 NDI PCMRing 并发：\(report)")
        XCTAssertGreaterThan(report.popped, 100)
        XCTAssertGreaterThan(report.dropped, 0, "生产者确实比消费者快（队列满过）")
        XCTAssertEqual(report.torn, 0, "读到的样本与 PTS 不是同一块：\(report.firstTorn)")
        XCTAssertEqual(report.pushed, report.popped + report.dropped)
    }
}

/// 块签名（同 SwitcherOutputsTests 的 RingSignature；测试 target 之间不共享源码）。
final class NDIRingSignature: @unchecked Sendable {
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

/// 两条线程真并发跑一个环（同 SwitcherOutputsTests 的 RingStress）。
enum NDIRingStress {
    struct Report: CustomStringConvertible {
        var pushed = 0, dropped = 0, popped = 0, torn = 0
        var firstTorn = ""
        var description: String { "推 \(pushed)、丢 \(dropped)、收 \(popped)、读到别的块的 \(torn)\(firstTorn.isEmpty ? "" : "（首例 \(firstTorn)）")" }
    }

    private final class Shared: Sendable {
        let stop = Atomic<Bool>(false)
        let pushed = Atomic<Int>(0)
        let dropped = Atomic<Int>(0)
    }

    static func run(seconds: Double, channels: Int, frames: Int,
                    push: @escaping @Sendable (UnsafePointer<UnsafePointer<Float>>, Int) -> Bool,
                    pop: @escaping @Sendable () -> (HostTime, Int, UnsafePointer<UnsafePointer<Float>>)?) -> Report {
        let shared = Shared()
        let producerDone = DispatchSemaphore(value: 0)
        let source = NDIRingSignature(channels: channels, frames: frames)
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
        func consume(_ b: (HostTime, Int, UnsafePointer<UnsafePointer<Float>>)) {
            report.popped += 1
            let until = HostClock.now() + HostDuration(nanoseconds: 20_000)
            while HostClock.now() < until {}
            let k = Int(b.0.ticks)
            var bad = b.1 != frames
            var c = 0
            while !bad && c < channels {
                var i = 0
                while i < frames { if b.2[c][i] != NDIRingSignature.value(k, c, i) { bad = true; break }; i += 1 }
                c += 1
            }
            if bad {
                report.torn += 1
                if report.firstTorn.isEmpty { report.firstTorn = "PTS \(k) 读到 \(Int(b.2[0][0]) / 32) 块" }
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
