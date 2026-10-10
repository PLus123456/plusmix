import Foundation
import XCTest
import Synchronization
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// MIDIHost（进程级 CoreMIDI 宿主线程）的 sync 在压力下不 trap（W2-C3，prompt 106）。
final class MIDIHostTests: XCTestCase {
    /// prompt 106 交付 1：宿主线程上一直有活（有界地排着空块，另外隔 5–10 ms 塞一个睡 1–5 ms 的慢块），主线程连续 `sync` 2000 次，
    /// 再起停 `MIDIController` 200 次（App 新建 / 打开节目、改格式、退出时起停 session 走的就是 start / stop → `MIDIHost.sync`），Debug 构建不 trap；
    /// 返回值、执行线程（宿主线程）、在宿主线程上 sync 自己直接跑，这几条行为不变。
    /// 修前：`sync` 的块里先 `done.signal()`，块被 run loop 释放时才放掉 `withoutActuallyEscaping` 的闭包，调用方被放行后抢在这之前离开就 trap
    /// "non-escaping closure has escaped"（S1，reports/issues/W5A-w2-control-midihost-sync-escaping-crash.md）。宿主线程醒着（正在处理别的块）时最容易撞上，
    /// 只塞慢块的话撞上的概率低得多（探针数据见 reports/w2-control-3.md §1）。
    func testC_midiHostSync_stressNoTrap() throws {
        XCTAssertTrue(Thread.isMainThread, "要在主线程上 sync（App 起停 session 都在主线程）")
        let host = MIDIHost.shared
        // 已经在宿主线程上：直接跑、不等自己
        XCTAssertTrue(host.sync { host.sync { host.isCurrent } })

        let noise = MIDIHostNoise(host: host)
        noise.start()
        defer { noise.stop() }

        // 1. 主线程连续 sync 2000 次：返回值对、都在宿主线程上跑
        var wrong = 0
        for i in 0..<2000 {
            let (value, onHost) = host.sync { (i &* 7, host.isCurrent) }
            if value != i &* 7 || !onHost { wrong += 1 }
        }
        XCTAssertEqual(wrong, 0, "sync 的返回值或执行线程不对")

        // 2. 起停 MIDIController 200 次：每 10 轮换一个全新的控制器（换节目），其余是同一个实例停了再起
        let f = BusFixture()
        defer { f.stop() }
        let tag = UUID().uuidString.prefix(8)
        var controller = MIDIController(bus: f.bus, clientName: "PlusMix 压力 \(tag)")
        var startFailures: [String] = []
        var wrongState = 0
        for round in 0..<200 {
            if round % 10 == 0 { controller = MIDIController(bus: f.bus, clientName: "PlusMix 压力 \(tag) \(round / 10)") }
            do {
                try controller.start()
            } catch {
                // 进程一开始就连不上 MIDIServer（例如它正在空闲退出）时每一轮都回 -304：按环境跳过，sync 那段已经跑完
                if round == 0 { throw XCTSkip("CoreMIDI 不可用（\(error)）：起停那段没跑，sync 2000 次那段已过") }
                startFailures.append("第 \(round) 轮：\(error)")
                continue
            }
            if !controller.isRunning { wrongState += 1 }
            controller.stop()
            if controller.isRunning { wrongState += 1 }
        }
        XCTAssertEqual(startFailures, [], "第一轮起得来，之后不该起不来")
        XCTAssertEqual(wrongState, 0, "start 之后应在跑、stop 之后应停")

        noise.stop()
        XCTAssertGreaterThan(noise.slowBlocks, 0, "慢块没塞进去：压力没加上")
        XCTAssertGreaterThan(noise.awakeBlocks, 0, "空块没塞进去：压力没加上")
    }
}

/// 测试用：让 MIDIHost 的宿主线程一直有活。
///   - 醒着：另一条线程不停塞空块、最多 4 个排着队，宿主线程的 run loop 几乎不睡——sync 的块常在调用方刚进 / 还没进 `wait` 时就跑完，
///     修前的竞态窗口（signal 之后、块被释放之前）最容易被调用方抢到；有界是为了不让队列无限长（sync 的块排在后面会等很久）。
///   - 慢块：隔 5–10 ms 塞一个睡 1–5 ms 的块（prompt 106 的做法），sync 的块时不时排在慢块后面、调用方进内核睡着再被叫醒。
/// `stop()` 等两条线程都退出，再 sync 一次把已塞的块排空，之后宿主线程上没有本测试的东西。
final class MIDIHostNoise: Sendable {
    private let host: MIDIHost
    private let running = Atomic<Bool>(false)
    private let queued = Atomic<Int>(0)
    private let awakeCount = Atomic<Int>(0)
    private let slowCount = Atomic<Int>(0)
    private let exited = DispatchSemaphore(value: 0)

    init(host: MIDIHost) { self.host = host }

    var awakeBlocks: Int { awakeCount.load(ordering: .relaxed) }
    var slowBlocks: Int { slowCount.load(ordering: .relaxed) }

    func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let awake = Thread { [self] in
            while running.load(ordering: .acquiring) {
                if queued.load(ordering: .relaxed) < 4 {
                    queued.add(1, ordering: .relaxed)
                    awakeCount.add(1, ordering: .relaxed)
                    host.async { self.queued.subtract(1, ordering: .relaxed) }
                } else {
                    sched_yield()
                }
            }
            exited.signal()
        }
        awake.name = "测试：宿主线程保持醒着"
        awake.qualityOfService = .userInteractive
        awake.start()
        let slow = Thread { [self] in
            while running.load(ordering: .acquiring) {
                host.async { usleep(UInt32.random(in: 1000...5000)) }
                slowCount.add(1, ordering: .relaxed)
                usleep(UInt32.random(in: 5000...10000))
            }
            exited.signal()
        }
        slow.name = "测试：宿主线程慢块"
        slow.qualityOfService = .userInitiated
        slow.start()
    }

    func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        exited.wait()
        exited.wait()
        host.sync {}
    }
}
