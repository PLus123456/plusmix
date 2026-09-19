// Stats 采样（铁律 4：只有一份；提案 003 §D2）：SwitcherEngine.StatsPublisher 是唯一的采样线程，每秒调一次 Engine.makeStats()，
// 同一行扇出给 stats.jsonl（可选，TestKit 的 StatsWriter）、状态推送源（API 的 WS / GET /state）和主线程（状态行、调音台）。
// makeStats 的"窗口"= 上次调用到这次，所以全进程只能有 StatsPublisher 这一个调用点；W2-B 的 StatsPump 由它替换。
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherTestKit

final class StatsHub: @unchecked Sendable {
    let publisher: StatsPublisher
    /// jsonl 写手放在一个可共享的盒子里（Mutex 是不可拷贝类型，闭包捕获要经引用）。
    private final class WriterBox: @unchecked Sendable {
        let writer = Mutex<StatsWriter?>(nil)
    }
    private let box = WriterBox()
    private let gpu: GPUUtilization?

    /// - Parameters:
    ///   - consumers: 采样线程上同步调的消费者（要快；接收方自己跳线程）。
    init(engine: Engine, interval: TimeInterval = 1, consumers: [@Sendable (Stats) -> Void]) {
        publisher = StatsPublisher(engine: engine, interval: interval)
        gpu = GPUUtilization()
        if let gpu {
            engine.gpuPercentProvider = { gpu.deviceUtilizationPercent() }
        }
        let box = self.box
        publisher.addConsumer { stats in _ = box.writer.withLock { $0?.submit(stats) } }
        for c in consumers { publisher.addConsumer(c) }
    }

    func start() throws { try publisher.start() }

    /// 停采样再关文件；最后一行是停机前那一秒的。
    func stop() {
        publisher.stop()
        closeLog()
    }

    /// 最近一行。
    var latest: Stats? { publisher.latest }

    /// 同时把每行写进 stats.jsonl（append = false：从头写）。
    func startLog(url: URL) throws {
        let w = try StatsWriter(url: url, append: false)
        let old = box.writer.withLock { slot -> StatsWriter? in
            let o = slot
            slot = w
            return o
        }
        old?.close()
    }

    func closeLog() {
        let old = box.writer.withLock { slot -> StatsWriter? in
            let o = slot
            slot = nil
            return o
        }
        old?.close()
    }

    /// 日志文件（没开为 nil）。
    var logURL: URL? { box.writer.withLock { $0?.url } }
}
