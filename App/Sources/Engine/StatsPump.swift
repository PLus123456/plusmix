// Stats 采样（铁律 4：只有一份）：每秒在一条普通线程上调一次 Engine.makeStats()，同一个 Stats 对象同时
// 送去 stats.jsonl（可选，TestKit 的 StatsWriter）和主线程（状态行、调音台的表）。两个消费者读的是同一行，
// 不各自另算；makeStats 的"窗口"= 上次调用到这次，所以全进程只能有这里一个调用点。
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherTestKit

final class StatsPump: @unchecked Sendable {
    private let engine: Engine
    private let queue = DispatchQueue(label: "app.switcher.stats", qos: .utility)
    private var timer: (any DispatchSourceTimer)?
    private let writer = Mutex<StatsWriter?>(nil)
    private let onStats: @Sendable (Stats) -> Void
    private let gpu: GPUUtilization?

    /// - Parameter onStats: 每秒一次，在采样线程上调；接收方自己跳主线程。
    init(engine: Engine, onStats: @escaping @Sendable (Stats) -> Void) {
        self.engine = engine
        self.onStats = onStats
        gpu = GPUUtilization()
        if let gpu {
            engine.gpuPercentProvider = { gpu.deviceUtilizationPercent() }
        }
    }

    /// 开始每秒采样（leeway 10 ms，不是实时线程）。
    func start(interval: TimeInterval = 1) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
        t.setEventHandler { [self] in
            let stats = engine.makeStats()
            writer.withLock { $0?.submit(stats) }
            onStats(stats)
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        closeLog()
    }

    /// 同时把每行写进 stats.jsonl（append = false：从头写）。
    func startLog(url: URL) throws {
        let w = try StatsWriter(url: url, append: false)
        let old = writer.withLock { box -> StatsWriter? in
            let o = box
            box = w
            return o
        }
        old?.close()
    }

    func closeLog() {
        let old = writer.withLock { box -> StatsWriter? in
            let o = box
            box = nil
            return o
        }
        old?.close()
    }

    /// 日志文件（没开为 nil）。
    var logURL: URL? { writer.withLock { $0?.url } }
}
