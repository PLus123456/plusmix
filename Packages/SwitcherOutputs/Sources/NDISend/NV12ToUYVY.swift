import CoreVideo
import Foundation
@preconcurrency import Metal

/// NV12（Y 平面 + 交错 CbCr，4:2:0）→ UYVY（打包 4:2:2）。NDI 的原生视频格式是 UYVY；4:2:0 → 4:2:2 只做垂直复制（相邻两行共用一行色度），
/// 不做滤波（与 NDI SDK 自己收 NV12 时的做法一致，也保证测试图案的色块不被模糊）。
///
/// 两个实现输出逐字节相同（NDISendTests 证明）：
/// - `CPU`：逐行写，一个线程；1080p 约 2 MB 读 + 4 MB 写，M5 Max 上 ~0.6 ms / 帧（报告有数）。
/// - `GPU`：Metal compute kernel，每线程处理 2 个像素，输出到共享内存 MTLBuffer；命令缓冲区完成后 CPU 直接读（统一内存，零拷贝）。
///   双缓冲：NDI 的异步发送要求上一帧的缓冲在下一次调用前保持有效。
public enum NV12ToUYVY {
    /// 错误。
    public enum Error: Swift.Error, Equatable {
        case notNV12
        case lockFailed(CVReturn)
        case noMetal
        case metal(String)
    }

    /// 输出缓冲：UYVY，行距 = width × 2。
    public struct UYVYBuffer: @unchecked Sendable {
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let base: UnsafeMutableRawPointer
        public let byteCount: Int
        public init(width: Int, height: Int, base: UnsafeMutableRawPointer) {
            self.width = width
            self.height = height
            bytesPerRow = width * 2
            self.base = base
            byteCount = bytesPerRow * height
        }
    }

    /// CPU 参考实现。`out` 必须能放下 width × height × 2 字节。
    public static func convertCPU(_ pixelBuffer: CVPixelBuffer, into out: UYVYBuffer) throws {
        let type = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { throw Error.notNV12 }
        let r = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard r == kCVReturnSuccess else { throw Error.lockFailed(r) }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = min(CVPixelBufferGetWidth(pixelBuffer), out.width)
        let height = min(CVPixelBufferGetHeight(pixelBuffer), out.height)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw Error.notNV12
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let pairs = width / 2
        for y in 0..<height {
            let yRow = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)
            let cRow = cBase.advanced(by: (y / 2) * cStride).assumingMemoryBound(to: UInt8.self)
            let o = out.base.advanced(by: y * out.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < pairs {
                let c = i * 2
                o[c * 2] = cRow[c]          // Cb
                o[c * 2 + 1] = yRow[c]      // Y0
                o[c * 2 + 2] = cRow[c + 1]  // Cr
                o[c * 2 + 3] = yRow[c + 1]  // Y1
                i += 1
            }
        }
    }

    /// Metal 版：kernel 源码内嵌（小，运行时编译一次）。
    public static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    // 每线程 2 个像素：out[4 * tid.x + {0,1,2,3}] = {Cb, Y0, Cr, Y1}；色度取 (tid.x, y / 2)。
    kernel void nv12_to_uyvy(texture2d<float, access::read> yTex [[texture(0)]],
                             texture2d<float, access::read> cTex [[texture(1)]],
                             device uchar4 *out [[buffer(0)]],
                             constant uint &pairsPerRow [[buffer(1)]],
                             uint2 tid [[thread_position_in_grid]]) {
        if (tid.x >= pairsPerRow || tid.y >= yTex.get_height()) { return; }
        uint x0 = tid.x * 2;
        float y0 = yTex.read(uint2(x0, tid.y)).r;
        float y1 = yTex.read(uint2(x0 + 1, tid.y)).r;
        float2 c = cTex.read(uint2(tid.x, tid.y / 2)).rg;
        out[tid.y * pairsPerRow + tid.x] = uchar4(uchar(round(c.x * 255.0)), uchar(round(y0 * 255.0)), uchar(round(c.y * 255.0)), uchar(round(y1 * 255.0)));
    }
    """

    /// GPU 转换器：一台设备一个；持有纹理缓存和双缓冲输出。不是线程安全的（NDISender 只在自己的线程上用）。
    public final class GPU: @unchecked Sendable {
        public let device: any MTLDevice
        public let width: Int
        public let height: Int
        private let queue: any MTLCommandQueue
        private let pipeline: any MTLComputePipelineState
        private let textureCache: CVMetalTextureCache
        private let buffers: [any MTLBuffer]
        private var next = 0

        /// 建管线、纹理缓存和 2 个输出缓冲（Apple GPU 统一内存，`.storageModeShared`）。
        public init(device: any MTLDevice, width: Int, height: Int, bufferCount: Int = 2) throws {
            self.device = device
            self.width = width
            self.height = height
            guard let queue = device.makeCommandQueue() else { throw Error.metal("makeCommandQueue") }
            self.queue = queue
            let options = MTLCompileOptions()
            options.mathMode = .safe
            let library: any MTLLibrary
            do { library = try device.makeLibrary(source: kernelSource, options: options) } catch { throw Error.metal("编译 kernel：\(error)") }
            guard let fn = library.makeFunction(name: "nv12_to_uyvy") else { throw Error.metal("找不到 nv12_to_uyvy") }
            do { pipeline = try device.makeComputePipelineState(function: fn) } catch { throw Error.metal("管线：\(error)") }
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw Error.metal("CVMetalTextureCache") }
            textureCache = cache
            var bufs: [any MTLBuffer] = []
            for _ in 0..<max(1, bufferCount) {
                guard let b = device.makeBuffer(length: width * height * 2, options: .storageModeShared) else { throw Error.metal("makeBuffer") }
                bufs.append(b)
            }
            buffers = bufs
        }

        /// 转一帧：提交、等 GPU 完成，返回下一块输出缓冲的视图（下一次 convert 之后的下一次才会被覆盖）。
        public func convert(_ pixelBuffer: CVPixelBuffer) throws -> UYVYBuffer {
            let type = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
                throw Error.notNV12
            }
            let w = min(CVPixelBufferGetWidth(pixelBuffer), width)
            let h = min(CVPixelBufferGetHeight(pixelBuffer), height)
            var yTexRef: CVMetalTexture?
            var cTexRef: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .r8Unorm, w, h, 0, &yTexRef) == kCVReturnSuccess,
                  CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .rg8Unorm, w / 2, h / 2, 1, &cTexRef) == kCVReturnSuccess,
                  let yTexRef, let cTexRef, let yTex = CVMetalTextureGetTexture(yTexRef), let cTex = CVMetalTextureGetTexture(cTexRef) else {
                throw Error.metal("纹理")
            }
            let out = buffers[next]
            next = (next + 1) % buffers.count
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw Error.metal("命令缓冲区") }
            var pairs = UInt32(w / 2)
            enc.setComputePipelineState(pipeline)
            enc.setTexture(yTex, index: 0)
            enc.setTexture(cTex, index: 1)
            enc.setBuffer(out, offset: 0, index: 0)
            enc.setBytes(&pairs, length: MemoryLayout<UInt32>.size, index: 1)
            let tg = MTLSize(width: 32, height: 8, depth: 1)
            let grid = MTLSize(width: w / 2, height: h, depth: 1)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            CVMetalTextureCacheFlush(textureCache, 0)
            if let e = cb.error { throw Error.metal("执行：\(e)") }
            return UYVYBuffer(width: w, height: h, base: out.contents())
        }
    }
}
