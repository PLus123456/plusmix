import Foundation
import SwitcherContracts

/// S5 热插拔计时（用户手动拔插，这里只计时、计数、验证编号不变）。
///
/// 每个周期：等设备断开（输入进 noSignal，记 CameraInput 收到断开通知的时刻）→ 提示插回 → 等回到 live，
/// 恢复时间 = live 时刻 − 收到连接通知的时刻（不含用户插回的手速）。全程进程不崩就是"崩溃 0"。
public enum HotplugTimer {
    public struct CycleRecord: Sendable, Hashable {
        public var index: Int
        /// 断开通知 → noSignal（s）。
        public var noSignalDelaySeconds: Double
        /// 连接通知 → live（s）。
        public var recoverySeconds: Double
        /// 用户拔到插回的总时长（s，参考）。
        public var unpluggedSeconds: Double
    }
    public struct Result: Sendable {
        public var completedCycles: Int
        public var cycles: [CycleRecord]
        public var timedOut: Bool
        public var numberBefore: Int
        public var numberAfter: Int
        public var maxRecoverySeconds: Double { cycles.map(\.recoverySeconds).max() ?? 0 }
        public var meanRecoverySeconds: Double { cycles.isEmpty ? 0 : cycles.map(\.recoverySeconds).reduce(0, +) / Double(cycles.count) }
        public var summary: String {
            var lines = ["S5 热插拔：完成 \(completedCycles) 次\(timedOut ? "（超时中止）" : "")，崩溃 0，编号 \(numberBefore) → \(numberAfter)\(numberBefore == numberAfter ? "（不变）" : "（变了！）")",
                         String(format: "  恢复时间：最大 %.2f s，平均 %.2f s；阈值 ≤ 3 s（目标 ≤ 1 s）", maxRecoverySeconds, meanRecoverySeconds),
                         "  | 次 | 断开→noSignal | 连接→live | 拔着的时长 |", "  |---|---|---|---|"]
            for c in cycles { lines.append(String(format: "  | %d | %.3f s | %.3f s | %.1f s |", c.index, c.noSignalDelaySeconds, c.recoverySeconds, c.unpluggedSeconds)) }
            return lines.joined(separator: "\n")
        }
    }

    /// 阻塞当前线程直到 cycles 次完成或超时。`log` 给用户看提示。
    public static func run(input: CameraInput, cycles: Int, cycleTimeoutSeconds: Double, log: (String) -> Void) -> Result {
        var records: [CycleRecord] = []
        let numberBefore = input.number
        var timedOut = false
        func wait(_ seconds: Double, until cond: () -> Bool) -> Bool {
            let deadline = HostClock.now() + HostDuration(seconds: seconds)
            while HostClock.now() < deadline {
                if cond() { return true }
                usleep(5000)
            }
            return cond()
        }
        for k in 1...max(cycles, 1) {
            log("[\(k)/\(cycles)] 请拔掉设备「\(input.deviceName ?? input.uniqueID)」……")
            let disconnectCountBefore = input.hotplugEvents.disconnects
            guard wait(cycleTimeoutSeconds, until: { input.state != .live && input.hotplugEvents.disconnects > disconnectCountBefore }) else {
                log("  等待断开超时（\(cycleTimeoutSeconds) s），中止"); timedOut = true; break
            }
            let ev1 = input.hotplugEvents
            let noSignalDelay = max(0, ((ev1.lastStateChangeAt ?? .now()) - (ev1.lastDisconnectAt ?? .now())).seconds)
            log(String(format: "  已断开（noSignal，%.3f s），请插回……", noSignalDelay))
            let connectCountBefore = ev1.connects
            guard wait(cycleTimeoutSeconds, until: { input.state == .live && input.hotplugEvents.connects > connectCountBefore }) else {
                log("  等待恢复超时（\(cycleTimeoutSeconds) s），中止：状态 \(input.state) \(input.lastError ?? "")"); timedOut = true; break
            }
            let ev2 = input.hotplugEvents
            let recovery = max(0, ((ev2.lastLiveAt ?? .now()) - (ev2.lastConnectAt ?? .now())).seconds)
            let unplugged = max(0, ((ev2.lastConnectAt ?? .now()) - (ev1.lastDisconnectAt ?? .now())).seconds)
            log(String(format: "  已恢复（live），连接→live %.3f s", recovery))
            records.append(CycleRecord(index: k, noSignalDelaySeconds: noSignalDelay, recoverySeconds: recovery, unpluggedSeconds: unplugged))
        }
        return Result(completedCycles: records.count, cycles: records, timedOut: timedOut, numberBefore: numberBefore, numberAfter: input.number)
    }
}
