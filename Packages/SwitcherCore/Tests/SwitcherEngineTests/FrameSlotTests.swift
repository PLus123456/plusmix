import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 帧槽：挑帧规则在 30 / 59.94 / 60(+100 ppm) 输入进 60 fps 拍点时的重复 / 丢弃与理论值精确相等（V4 设计内口径），
/// 以及队列满丢最旧、未来帧保留、双线程压力。
final class FrameSlotTests: XCTestCase {
    /// 拍点 n/60 s，输入第 k 帧 pts = k × period；到达时刻 = pts（无延迟）。事件按时间排序，同一时刻先 push 后取。
    /// 返回槽的统计，并把每帧被返回的次数交给调用方核对。
    private func simulate(inputPeriod: Rational, ticks: Int, arrivalLatency: HostDuration = .zero) -> (FrameSlotStats, [UInt64: Int]) {
        let tb = HostClock.timebase
        let t0 = HostTime(ticks: 10_000_000)
        let tickSpec = TickClockSpec(t0: t0, frameRate: .fps60)
        let inputSpec = TickClockSpec(t0: t0, frameDuration: inputPeriod)
        let slot = LockFreeFrameSlot(capacity: 3)
        var returned: [UInt64: Int] = [:]
        var k: Int64 = 0
        for n in 0..<ticks {
            let tickTime = tickSpec.time(of: Tick(Int64(n)), timebase: tb)
            // 先把到达时刻 ≤ 拍点的输入帧全部 push
            while inputSpec.time(of: Tick(k), timebase: tb) + arrivalLatency <= tickTime {
                let pts = inputSpec.time(of: Tick(k), timebase: tb)
                slot.push(TestFrames.frame(sequence: UInt64(k), pts: pts, ingress: pts + arrivalLatency))
                k += 1
            }
            if let f = slot.latest(atOrBefore: tickTime) { returned[f.sequence, default: 0] += 1 }
        }
        return (slot.stats, returned)
    }

    func testV4_30fpsInto60_reuseExactly50Percent_dropZero() {
        // 偶数拍数：帧 k 在第 2k、2k+1 拍各用一次
        let ticks = 6000
        let (stats, returned) = simulate(inputPeriod: Rational(1, 30), ticks: ticks)
        XCTAssertEqual(stats.consumed, UInt64(ticks))
        XCTAssertEqual(stats.reused * 2, stats.consumed, "30 进 60：重复率恰好 50%")
        XCTAssertEqual(stats.reused, 3000)
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertEqual(stats.pushed, 3000)
        // 每一帧恰好被用两次
        XCTAssertEqual(Set(returned.values), [2])
        XCTAssertEqual(returned.count, 3000)
    }

    func testV4_5994Into60_oneReusePer1000Ticks() {
        let ticks = 60_001
        let (stats, returned) = simulate(inputPeriod: Rational(1001, 60_000), ticks: ticks)
        // 理论：第 n 拍可用的最新帧号 = ⌊n·1000/1001⌋，重复次数 = (T−1) − ⌊(T−1)·1000/1001⌋ = 60000 − 59940
        let theory = UInt64((ticks - 1) - (ticks - 1) * 1000 / 1001)
        XCTAssertEqual(theory, 60)
        XCTAssertEqual(stats.reused, theory, "59.94 进 60：每 1000 拍重复 1 次")
        XCTAssertEqual(stats.consumed, UInt64(ticks))
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertEqual(returned.values.filter { $0 == 2 }.count, Int(theory))
        XCTAssertEqual(returned.values.filter { $0 > 2 }.count, 0)
    }

    func testV4_60fpsPlus100ppmInto60_oneDropPer10000Ticks() {
        let ticks = 60_000
        // 60 × 1.0001 fps = 60006/1000 → 帧长 1000/60006 s
        let (stats, returned) = simulate(inputPeriod: Rational(1000, 60_006), ticks: ticks)
        let theory = UInt64((ticks - 1) / 10_000)
        XCTAssertEqual(theory, 5)
        XCTAssertEqual(stats.dropped, theory, "60 +100 ppm 进 60：每 10000 拍丢 1 帧")
        XCTAssertEqual(stats.reused, 0)
        XCTAssertEqual(stats.consumed, UInt64(ticks))
        XCTAssertEqual(stats.pushed, UInt64(ticks) + theory, "多出来的帧数正好是丢掉的")
        XCTAssertEqual(Set(returned.values), [1])
    }

    /// 有 2 ms 到达延迟时（更接近真实采集），30 进 60 仍是精确 50%：帧 k 在第 2k+1、2k+2 拍各用一次，第 0 拍没有帧。
    func testV4_30fpsInto60_withArrivalLatency_stillExactly50Percent() {
        let (stats, returned) = simulate(inputPeriod: Rational(1, 30), ticks: 6001, arrivalLatency: HostDuration(milliseconds: 2))
        XCTAssertEqual(stats.consumed, 6000)
        XCTAssertEqual(stats.reused * 2, stats.consumed)
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertEqual(Set(returned.values), [2])
    }

    func testV4_pushWhenFull_evictsOldest_countsDropped() {
        let slot = LockFreeFrameSlot(capacity: 3)
        XCTAssertEqual(slot.capacity, 3)
        for k in 0..<5 { slot.push(TestFrames.frame(sequence: UInt64(k), pts: HostTime(ticks: UInt64(100 + k)))) }
        XCTAssertEqual(slot.stats.pushed, 5)
        XCTAssertEqual(slot.stats.dropped, 2, "槽满挤掉最旧的 0、1")
        let f = slot.latest(atOrBefore: HostTime(ticks: 1000))
        XCTAssertEqual(f?.sequence, 4)
        XCTAssertEqual(slot.stats.dropped, 4, "2、3 被更新的 4 跳过，也算丢弃")
        XCTAssertEqual(slot.stats.consumed, 1)
        XCTAssertEqual(slot.stats.reused, 0)
        // 之后没有新帧：重复返回 4
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(ticks: 2000))?.sequence, 4)
        XCTAssertEqual(slot.stats.reused, 1)
        XCTAssertEqual(slot.stats.consumed, 2)
    }

    func testV4_futureFrameIsKeptUntilItsTick_andNothingBeforeFirstFrame() {
        let slot = LockFreeFrameSlot(capacity: 3)
        XCTAssertNil(slot.latest(atOrBefore: HostTime(ticks: 100)), "没有帧返回 nil")
        XCTAssertEqual(slot.stats.consumed, 0)
        slot.push(TestFrames.frame(sequence: 1, pts: HostTime(ticks: 500)))
        XCTAssertNil(slot.latest(atOrBefore: HostTime(ticks: 400)), "pts 在拍点之后的帧不返回")
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(ticks: 500))?.sequence, 1, "pts == 拍点算 ≤")
        slot.push(TestFrames.frame(sequence: 2, pts: HostTime(ticks: 900)))
        slot.push(TestFrames.frame(sequence: 3, pts: HostTime(ticks: 1300)))
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(ticks: 1000))?.sequence, 2)
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(ticks: 1200))?.sequence, 2)
        XCTAssertEqual(slot.stats.reused, 1)
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(ticks: 1300))?.sequence, 3)
        XCTAssertEqual(slot.stats.dropped, 0)
    }

    /// 双线程压力：生产者狂推 20 万帧（不定时小睡），消费者按拍取。检查：返回的序号单调不减、
    /// 同一帧连续返回时 reused 计数一致、pushed = 被返回过的不同帧数 + dropped + 槽里剩的。
    func testV4_twoThreadStress_invariantsHold() throws {
        let slot = LockFreeFrameSlot(capacity: 3)
        let total: UInt64 = 200_000
        let producer = NativeThread(config: NativeThreadConfig(name: "producer", qos: QOS_CLASS_USER_INITIATED)) {
            for k in 0..<total {
                slot.push(TestFrames.frame(sequence: k, pts: HostTime(ticks: k)))
                if k % 997 == 0 { usleep(50) }
            }
        }
        try producer.start()
        var distinct = 0
        var reusedSeen: UInt64 = 0
        var last: UInt64? = nil
        var calls: UInt64 = 0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let now = slot.stats
            if let f = slot.latest(atOrBefore: HostTime(ticks: UInt64.max)) {
                calls += 1
                if let l = last {
                    XCTAssertGreaterThanOrEqual(f.sequence, l, "返回的序号必须单调")
                    if f.sequence == l { reusedSeen += 1 } else { distinct += 1 }
                } else { distinct += 1 }
                last = f.sequence
            }
            if now.pushed >= total && slot.stats.pushed == total { break }
            if calls % 3 == 0 { usleep(20) }
        }
        producer.join()
        // 生产者结束后再取一次，把最后的帧拿完
        if let f = slot.latest(atOrBefore: HostTime(ticks: UInt64.max)), let l = last {
            if f.sequence != l { distinct += 1 } else { reusedSeen += 1 }
        }
        let s = slot.stats
        XCTAssertEqual(s.pushed, total)
        XCTAssertEqual(s.reused, reusedSeen)
        XCTAssertEqual(s.pushed, UInt64(distinct) + s.dropped, "每一帧要么被返回过、要么算丢弃")
        XCTAssertGreaterThan(s.dropped, 0, "生产者快得多，必然有丢弃")
    }
}
