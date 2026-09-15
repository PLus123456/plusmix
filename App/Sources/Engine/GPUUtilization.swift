// GPU 占用（Stats.gpu_pct）。与 Tools/switcher-headless/GPUUtilization.swift 同一份逻辑（Tools 不是库，App 只能抄一份；
// 报告里提议挪进 TestKit 或 Engine）：IOKit 里 IOAccelerator 的 PerformanceStatistics["Device Utilization %"]，
// 不用 root，一次读取 0.1–3 ms，只在 Stats 采样线程（1 Hz）上读。
import Foundation
import IOKit

final class GPUUtilization: @unchecked Sendable {
    private let service: io_service_t

    /// 找第一个带 PerformanceStatistics 的 IOAccelerator；找不到返回 nil（gpu_pct 就写 0）。
    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: io_service_t = 0
        var candidate = IOIteratorNext(iterator)
        while candidate != 0 {
            if found == 0, GPUUtilization.read(candidate) != nil {
                found = candidate
            } else {
                IOObjectRelease(candidate)
            }
            candidate = IOIteratorNext(iterator)
        }
        guard found != 0 else { return nil }
        service = found
    }

    deinit { IOObjectRelease(service) }

    /// 设备占用百分比；读不到返回 0。
    func deviceUtilizationPercent() -> Double { GPUUtilization.read(service) ?? 0 }

    private static func read(_ service: io_service_t) -> Double? {
        guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else { return nil }
        guard let dict = raw.takeRetainedValue() as? [String: Any], let v = dict["Device Utilization %"] else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
