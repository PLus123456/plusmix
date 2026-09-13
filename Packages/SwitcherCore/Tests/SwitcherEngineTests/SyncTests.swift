import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 无锁基础件：原子指针发布（hazard pointer）与 SPSC 覆盖环。
final class SyncTests: XCTestCase {
    final class Tracked: @unchecked Sendable {
        static let alive = Atomic<Int>(0)
        static let magic: UInt64 = 0x5EED_CAFE_F00D_BEEF
        let id: Int
        let magic: UInt64
        init(id: Int) { self.id = id; magic = Self.magic; Self.alive.add(1, ordering: .relaxed) }
        deinit { Self.alive.subtract(1, ordering: .relaxed) }
    }

    func testW1B_hazardPublisher_writerReleasesOnlyUnborrowedObjects() {
        let base = Tracked.alive.load(ordering: .acquiring)
        let pub = HazardPublisher<Tracked>(initial: Tracked(id: 0), readerCapacity: 2)
        let reader = pub.makeReaderSlot()
        let a = reader.borrow()!
        XCTAssertEqual(a._withUnsafeGuaranteedRef { $0.id }, 0)
        pub.publish(Tracked(id: 1))
        pub.publish(Tracked(id: 2))
        XCTAssertEqual(Tracked.alive.load(ordering: .acquiring) - base, 2, "被借用的 0 还活着，1 已释放，2 是当前")
        XCTAssertEqual(a._withUnsafeGuaranteedRef { $0.magic }, Tracked.magic, "借用期间对象完好")
        reader.endBorrow()
        pub.publish(Tracked(id: 3))
        XCTAssertEqual(Tracked.alive.load(ordering: .acquiring) - base, 1, "归还后 0 在下一次发布时释放")
        XCTAssertEqual(pub.latest?.id, 3)
        XCTAssertEqual(reader.acquire()?.id, 3)
        XCTAssertEqual(pub.retiredCount, 0)
    }

    /// 写方狂发 20 万个对象，三个读线程不停借用并校验 magic；结束后除当前对象外全部释放。
    func testW1B_hazardPublisher_stress_noUseAfterFree_noLeak() throws {
        let base = Tracked.alive.load(ordering: .acquiring)
        let pub = HazardPublisher<Tracked>(initial: Tracked(id: 0), readerCapacity: 3)
        let stop = Atomic<Bool>(false)
        let bad = Atomic<Int>(0)
        let borrows = Atomic<Int>(0)
        var readers: [NativeThread] = []
        for _ in 0..<3 {
            let slot = pub.makeReaderSlot()
            let t = NativeThread(config: NativeThreadConfig(name: "reader", qos: QOS_CLASS_USER_INITIATED)) {
                var lastID = -1
                while !stop.load(ordering: .acquiring) {
                    let u = slot.borrow()!
                    let (id, magic) = u._withUnsafeGuaranteedRef { ($0.id, $0.magic) }
                    if magic != Tracked.magic || id < lastID { bad.add(1, ordering: .relaxed) }
                    lastID = id
                    slot.endBorrow()
                    borrows.add(1, ordering: .relaxed)
                }
            }
            try t.start()
            readers.append(t)
        }
        for i in 1...200_000 { pub.publish(Tracked(id: i)) }
        stop.store(true, ordering: .releasing)
        readers.forEach { $0.join() }
        pub.drain()
        XCTAssertEqual(bad.load(ordering: .acquiring), 0, "读到的对象永远完整且单调")
        XCTAssertGreaterThan(borrows.load(ordering: .acquiring), 1000)
        XCTAssertEqual(Tracked.alive.load(ordering: .acquiring) - base, 1, "只剩当前对象")
        XCTAssertEqual(pub.retiredCount, 0)
    }

    func testW1B_ring_singleThread_evictsOldestWhenFull() {
        let ring = SPSCOverwriteRing<Int>(capacity: 3)
        XCTAssertNil(ring.pop())
        XCTAssertEqual(ring.push(1), .stored)
        XCTAssertEqual(ring.push(2), .stored)
        XCTAssertEqual(ring.push(3), .stored)
        XCTAssertEqual(ring.push(4), .storedEvictingOldest)
        XCTAssertEqual(ring.push(5), .storedEvictingOldest)
        XCTAssertEqual(ring.pop(), 3)
        XCTAssertEqual(ring.pop(), 4)
        XCTAssertEqual(ring.push(6), .stored)
        XCTAssertEqual(ring.pop(), 5)
        XCTAssertEqual(ring.pop(), 6)
        XCTAssertNil(ring.pop())
        XCTAssertEqual(ring.count, 0)
        // 绕多圈后仍正确
        for i in 0..<1000 { _ = ring.push(i); if i % 2 == 0 { _ = ring.pop() } }
        var last = -1
        while let v = ring.pop() { XCTAssertGreaterThan(v, last); last = v }
    }

    /// 双线程：生产者推 100 万个递增整数（满则挤最旧），消费者持续 pop；弹出序列严格递增，
    /// pushed = popped + 挤掉的 + 丢来帧的（无丢失无重复）。
    func testW1B_ring_twoThreadStress_strictlyIncreasing_noDuplicates() throws {
        let ring = SPSCOverwriteRing<Int>(capacity: 3)
        let total = 1_000_000
        let evicted = Atomic<Int>(0), droppedIncoming = Atomic<Int>(0)
        let producer = NativeThread(config: NativeThreadConfig(name: "producer", qos: QOS_CLASS_USER_INITIATED)) {
            for i in 0..<total {
                switch ring.push(i) {
                case .stored: break
                case .storedEvictingOldest: evicted.add(1, ordering: .relaxed)
                case .droppedIncoming: droppedIncoming.add(1, ordering: .relaxed)
                }
                if i % 100_003 == 0 { usleep(100) }
            }
        }
        try producer.start()
        var popped = 0
        var last = -1
        var idle = 0
        while true {
            if let v = ring.pop() {
                XCTAssertGreaterThan(v, last)
                last = v
                popped += 1
                idle = 0
            } else {
                idle += 1
                if idle > 1000 && ring.count == 0 && evicted.load(ordering: .acquiring) + droppedIncoming.load(ordering: .acquiring) + popped >= total { break }
                if idle > 5_000_000 { XCTFail("消费者饿死"); break }
            }
        }
        producer.join()
        while let v = ring.pop() { XCTAssertGreaterThan(v, last); last = v; popped += 1 }
        XCTAssertEqual(popped + evicted.load(ordering: .acquiring) + droppedIncoming.load(ordering: .acquiring), total)
        print("ring stress: popped \(popped), evicted \(evicted.load(ordering: .acquiring)), droppedIncoming \(droppedIncoming.load(ordering: .acquiring))")
    }

    func testW1B_queuedFrameConsumer_dropsOldestWhenBehind() throws {
        let processed = Atomic<Int>(0)
        let q = QueuedFrameConsumer(name: "enc", depth: 2) { _ in
            usleep(5000)
            processed.add(1, ordering: .relaxed)
        }
        try q.start()
        for t in 0..<50 {
            let f = TestFrames.frame(input: 0, sequence: UInt64(t), pts: HostTime(ticks: UInt64(t)))
            q.consume(RenderedFrame(tick: Tick(Int64(t)), tickTime: f.pts, program: f, submitTime: f.pts, gpuStart: f.pts, gpuEnd: f.pts))
        }
        XCTAssertTrue(waitUntil { q.stats.pending == 0 })
        q.stop()
        let s = q.stats
        XCTAssertEqual(s.received, 50)
        XCTAssertEqual(s.processed + s.dropped, 50)
        XCTAssertGreaterThan(s.dropped, 0)
        XCTAssertEqual(Int(s.processed), processed.load(ordering: .acquiring))
    }
}
