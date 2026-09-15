import CoreVideo
import Darwin
import SwitcherContracts

/// IOSurface 背后的 NV12 像素缓冲池：创建时把 `maximumBuffers` 个缓冲全部建好、每一页摸一遍，之后 `take()` 只回收复用，
/// 每帧零 malloc。
///
/// 为什么不用 CVPixelBufferPool：macOS 26 实测（W1-A 探针，malloc_logger 逐次计数）`CVPixelBufferPoolCreatePixelBuffer`
/// 每取一次都新建 CVPixelBuffer 对象——池只回收 IOSurface，不回收对象——每帧 5 次 malloc + 5 次 free；预热无济于事。
/// 这里自己持有全部对象，用引用计数判断"没人在用"（只有池自己那一份 → CFGetRetainCount == 1）：帧槽和下游拿的都是 `Frame`
/// 里的引用，放手后计数回到 1 就能复用。取不到（下游持有的帧超过池容量）返回 nil，生产者计数并跳过这帧，绝不阻塞、绝不分配。
/// 线程规则：`take()` 只由生产者线程调（单线程），其他线程只通过 `Frame` 持有 / 释放。
public final class NV12PixelBufferPool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// 池里的缓冲个数（帧槽 3 + 正在画 1 + 下游暂存 4）。
    public let maximumBuffers: Int
    /// 池持有的那一份引用（Unmanaged：检查引用计数时不能再让 Swift 顺手 retain 一次）。
    private let buffers: [Unmanaged<CVPixelBuffer>]
    private var cursor = 0
    /// "没人在用"时 `CFGetRetainCount` 读到的值。release 下是 1（池那一份）；debug 下 Swift 会在检查时多 retain 一次读到 2，
    /// 所以在 init 末尾（所有临时引用都已释放）用同一条代码路径量一次当基准，两种构建都对。
    private let idleRetainCount: CFIndex

    public enum PoolError: Error {
        case createFailed(CVReturn)
    }

    public init(width: Int, height: Int, maximumBuffers: Int = 8, range: ColorRange = .limited) throws {
        precondition(maximumBuffers >= 2)
        self.width = width
        self.height = height
        self.maximumBuffers = maximumBuffers
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var list: [Unmanaged<CVPixelBuffer>] = []
        list.reserveCapacity(maximumBuffers)
        for _ in 0..<maximumBuffers {
            var pb: CVPixelBuffer?
            let r = CVPixelBufferCreate(nil, width, height, PixelFormat.nv12.cvPixelFormatType(range: range), attrs as CFDictionary, &pb)
            guard r == kCVReturnSuccess, let pb else { throw PoolError.createFailed(r) }
            // IOSurface 内存是懒映射的：不摸的话第一帧画进去会缺页几毫秒（实测 1080p 第一帧 12 ms）。填合法黑场。
            CVPixelBufferLockBaseAddress(pb, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
                    memset(base, plane == 0 ? 16 : 128, CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            list.append(Unmanaged.passRetained(pb))
        }
        buffers = list
        idleRetainCount = NV12PixelBufferPool.retainCount(list[0])
    }

    deinit { for b in buffers { b.release() } }

    /// 取一个没人在用的缓冲（从上次之后轮询）；全被占着返回 nil。
    @inline(__always)
    public func take() -> CVPixelBuffer? {
        for _ in 0..<maximumBuffers {
            let u = buffers[cursor]
            cursor = (cursor + 1) % maximumBuffers
            if isFree(u) { return u.takeUnretainedValue() }
        }
        return nil
    }

    @inline(__always)
    static func retainCount(_ u: Unmanaged<CVPixelBuffer>) -> CFIndex {
        u._withUnsafeGuaranteedRef { CFGetRetainCount($0) }
    }

    /// 只有池自己那一份引用（等于 init 时量到的基准）。
    @inline(__always)
    func isFree(_ u: Unmanaged<CVPixelBuffer>) -> Bool { NV12PixelBufferPool.retainCount(u) == idleRetainCount }

    /// 当前空闲的缓冲数（诊断用）。
    public var freeCount: Int { buffers.reduce(0) { $0 + (isFree($1) ? 1 : 0) } }
}
