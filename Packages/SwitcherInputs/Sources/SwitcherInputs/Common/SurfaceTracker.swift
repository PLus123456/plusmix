import CoreVideo
import IOSurface
import Synchronization

/// 记录一路输入见过的不同 IOSurfaceID 个数（诊断：解码器 / 采集池是否稳定复用；渲染器的纹理表每路只有 16 项）。
/// 只在输入线程调 `note`；`count` 任何线程读。最多记 64 个 ID，之后只计数不再存。
final class SurfaceTracker: @unchecked Sendable {
    private var ids: [UInt32] = []
    private let total = Atomic<UInt64>(0)

    func note(_ pixelBuffer: CVPixelBuffer) {
        guard let s = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let id = IOSurfaceGetID(s.takeUnretainedValue())
        if ids.contains(id) { return }
        if ids.count < 64 { ids.append(id) }
        total.add(1, ordering: .relaxed)
    }

    var count: UInt64 { total.load(ordering: .relaxed) }
}
