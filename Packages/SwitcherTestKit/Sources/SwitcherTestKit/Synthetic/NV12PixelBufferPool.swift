import CoreVideo
import Darwin
import SwitcherContracts

/// IOSurface 背后的 NV12 像素缓冲池，创建时预热到 `maximumBuffers` 个；之后 `take()` 只回收复用，不再分配。
/// 消费者（帧槽 + 下游）合计持有超过 `maximumBuffers` 帧时 `take()` 返回 nil（`kCVReturnWouldExceedAllocationThreshold`），
/// 生产者按"这帧产不出来"计数并跳过，绝不阻塞、绝不越过阈值分配。
public final class NV12PixelBufferPool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// 池里最多几个缓冲（帧槽 3 + 正在画 1 + 下游暂存 4）。
    public let maximumBuffers: Int
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    public init(width: Int, height: Int, maximumBuffers: Int = 8, range: ColorRange = .limited) throws {
        self.width = width
        self.height = height
        self.maximumBuffers = maximumBuffers
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: PixelFormat.nv12.cvPixelFormatType(range: range),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: maximumBuffers]
        var p: CVPixelBufferPool?
        let r = CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
        guard r == kCVReturnSuccess, let p else { throw PoolError.createFailed(r) }
        pool = p
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: maximumBuffers] as CFDictionary
        // 预热：把 maximumBuffers 个都分配出来、把每一页都摸一遍（IOSurface 内存是懒映射的，不摸的话第一帧画进去
        // 会缺页几毫秒——实测 1080p 第一帧 12 ms）、再放回去；之后 take 既不分配也不缺页。
        var warm: [CVPixelBuffer] = []
        warm.reserveCapacity(maximumBuffers)
        for _ in 0..<maximumBuffers {
            var pb: CVPixelBuffer?
            let rr = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes, &pb)
            guard rr == kCVReturnSuccess, let pb else { throw PoolError.createFailed(rr) }
            CVPixelBufferLockBaseAddress(pb, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
                    let bytes = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane)
                    memset(base, plane == 0 ? 16 : 128, bytes) // 合法黑场
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            warm.append(pb)
        }
        warm.removeAll()
    }

    /// 取一个缓冲；超过阈值返回 nil。
    @inline(__always)
    public func take() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxAttributes, &pb)
        return r == kCVReturnSuccess ? pb : nil
    }

    public enum PoolError: Error {
        case createFailed(CVReturn)
    }
}
