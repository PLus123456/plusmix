// 温度环境探针（W4-A；测试标准 §7 报告头"温度环境"）：打印一行 `thermal=<nominal|fair|serious|critical> low_power=<0|1>`。
// macOS 27 上 AppleSmartBattery 不再给电池温度，powermetrics 的 thermal_pressure 要 sudo；ProcessInfo.thermalState 不要权限，
// 是系统自己对"热不热、要不要降频"的判断（与 powermetrics 的 thermal pressure 同源）。soak / perf 脚本开跑时编一次（swiftc），每分钟调一次。
import Foundation

let state: String
switch ProcessInfo.processInfo.thermalState {
case .nominal: state = "nominal"
case .fair: state = "fair"
case .serious: state = "serious"
case .critical: state = "critical"
@unknown default: state = "unknown"
}
print("thermal=\(state) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)")
