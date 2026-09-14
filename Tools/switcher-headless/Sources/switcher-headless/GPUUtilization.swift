import Foundation
import IOKit

/// GPU 占用（Stats.gpu_pct）。没有公开 API，powermetrics 要 root；IOKit 里 AGXAccelerator 的
/// PerformanceStatistics["Device Utilization %"] 不用 sudo 就能读（探针见 reports/G2.md），一次读取约 0.1–3 ms，
/// 只在 Stats 采样线程（1 Hz，非实时）上读。口径与 powermetrics 的 GPU 占用同源（设备级忙碌百分比）。
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
