// 引擎运行时向系统要的"别睡"（W5-L，01a P1 / 02 N01 / 04 Q47）：W4-A / G4 实测，用户"空闲"时 macOS 会把实时线程的唤醒拖 10–18 ms
// （reports/G4.md §11.3），以前只能靠手册让用户自己跑 caffeinate。现在引擎在跑就拿着两条：
//   - 系统那一条：ProcessInfo.beginActivity([.userInitiated, .latencyCritical, .idleSystemSleepDisabled])——不进空闲睡眠、不进 App Nap、
//     定时器按最高精度走（macOS 27 上落成一条 PreventUserIdleSystemSleep 电源断言，名字 = systemReason；探针结论见 reports/w5-app-misc.md §5）；
//   - 显示器那一条：.idleDisplaySleepDisabled（PreventUserIdleDisplaySleep），单独一个开关，默认也阻止。
// 两个开关在设置"性能与电源"页，即时生效；停引擎（退出 / 换节目的间隙）就 endActivity。
import Foundation
import IOKit.pwr_mgt

@MainActor
final class EngineActivity {
    /// 系统那一条的选项（userInitiated 已含 idleSystemSleepDisabled，写全是为了对上 prompt 与 pmset 里看到的）。
    static let systemOptions: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
    /// 显示器那一条的选项。
    static let displayOptions: ProcessInfo.ActivityOptions = [.idleDisplaySleepDisabled]
    /// 断言名（`pmset -g assertions` 里看到的就是它；系统界面不显示，所以不走本地化）。
    static let systemReason = "PlusMix engine running: no idle sleep, no App Nap"
    static let displayReason = "PlusMix engine running: no display sleep"

    private var systemToken: (any NSObjectProtocol)?
    private var displayToken: (any NSObjectProtocol)?

    var holdsSystemActivity: Bool { systemToken != nil }
    var holdsDisplayActivity: Bool { displayToken != nil }

    /// 按"引擎在不在跑 × 两个开关"拿 / 放（幂等）。
    func update(engineRunning: Bool, preventSleep: Bool, preventDisplaySleep: Bool) {}

    /// 一条电源断言（类型 + 名字）。
    struct PowerAssertion: Equatable, Sendable, CustomStringConvertible {
        var type: String
        var name: String
        var description: String { "\(type) \"\(name)\"" }
    }

    /// 本进程现在挂着的电源断言（IOPMCopyAssertionsByProcess：与 `pmset -g assertions` 同一份数据）。
    static func processAssertions() -> [PowerAssertion] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let all = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (all[NSNumber(value: getpid())] ?? []).map {
            PowerAssertion(type: $0["AssertType"] as? String ?? "?", name: $0["AssertName"] as? String ?? "?")
        }
    }
}
