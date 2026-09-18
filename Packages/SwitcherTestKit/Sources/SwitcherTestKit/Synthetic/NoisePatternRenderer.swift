import CoreVideo
import Darwin
import IOSurface
import Metal
import SwitcherContracts
import Synchronization

/// 合成源噪声底纹的 GPU 版（提案 006，W1-A2）：一条 Metal 计算着色器把整幅 NV12 图案——噪声底 + 帧号 / 时间戳 / 输入 ID / 闪光块 + 色度平面——
/// 画进 IOSurface 背后的 `CVPixelBuffer`，**逐像素与 `TestPattern.draw` 相同**（`SyntheticSourceTests.testW1A2_noiseGPU_matchesContractDrawPixelExact` 全帧逐字节比）。
///
/// 为什么上 GPU：契约的 CPU 参考实现 1080p 一帧 1.0–1.1 ms（release、背靠背），按 60 fps 节奏跑（线程睡醒、时钟没拉上来）实测 4 ms；
/// 8 路 1080p60 就是 50–200% 的 CPU，S3 的"CPU ≤ 60%"会被测试工装自己撑爆。GPU 版每帧 GPU 0.07 ms、生产者线程 CPU 0.06 ms（编码命令 + 等完成），
/// 8 路合计 GPU ≈ 3.6%、CPU ≈ 3%（数字见 reports/w1-testkit-2.md）。
///
/// 怎么做到逐像素相同：契约的噪声是 SplitMix64——每行一个种子（seed、帧号、行号混合），行内状态每对像素加一次黄金比常数——
/// 第 k 对的状态 = 行种子 + (k + 1) × 常数，不用顺序迭代，所以每个线程独立算自己那两个像素；映射到 −amplitude…+amplitude、截断、
/// limited-range 查表都照抄契约（`TestPattern.NoiseRow` / `noiseValue`）。四样覆盖物按契约同样的先后顺序（行 1、行 2、ID、闪光，后画的盖前面的）在同一核里判定。
///
/// 线程规则：一个渲染器只由一条生产者线程用（和像素池一样）；着色器、管线、查表缓冲全进程共享（`Shared`，第一次用时编译一次），
/// 每个实例自己一条命令队列和一份"IOSurface → 纹理"表（池里的缓冲固定，`prepare` 预建，之后每帧只查表不分配 Swift 对象；
/// Metal 的命令缓冲 / 编码器是 autoreleased 的 ObjC 对象，每帧包一层 autoreleasepool，与 W1-C 渲染线程同一做法）。
public final class NoisePatternRenderer: @unchecked Sendable {
    public enum RendererError: Error, CustomStringConvertible {
        case noMetalDevice
        case compile(String)
        case unsupportedPixelBuffer(String)
        public var description: String {
            switch self {
            case .noMetalDevice: "没有 Metal 设备"
            case .compile(let s): "噪声着色器编译失败：\(s)"
            case .unsupportedPixelBuffer(let s): "噪声渲染器只认 IOSurface 背后的 NV12 缓冲：\(s)"
            }
        }
    }

    /// 最近一帧的成本。
    public struct Cost: Hashable, Sendable {
        /// GPU 开始到结束（命令缓冲的 GPUStartTime / GPUEndTime）。
        public var gpuNanoseconds: UInt64 = 0
        /// 生产者线程在 `draw` 里花掉的 CPU 时间（编码命令 + 提交 + 等完成期间被调度到的时间）。
        public var cpuNanoseconds: UInt64 = 0
        /// `draw` 的墙钟时间（含等 GPU 完成）。
        public var wallNanoseconds: UInt64 = 0
        public init() {}
    }

    /// 着色器里的参数块；布局与 MSL 的 `Params` 逐字段对应（ulong 在最前，其余全是 uint，两边自然对齐一致）。
    struct Params {
        var seed: UInt64
        var frameNumber: UInt32
        var level: UInt32
        var amplitude: UInt32
        var width: UInt32
        var height: UInt32
        var blockSize: UInt32
        var originX: UInt32
        var row1Y: UInt32
        var row2Y: UInt32
        var word1: UInt32
        var word2: UInt32
        var idX: UInt32, idY: UInt32, idW: UInt32, idH: UInt32
        var flashX: UInt32, flashY: UInt32, flashW: UInt32, flashH: UInt32
        var idLuma: UInt32
        var idCb: UInt32
        var idCr: UInt32
        var flashLuma: UInt32
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        ulong seed;
        uint frameNumber; uint level; uint amplitude; uint width; uint height;
        uint blockSize; uint originX; uint row1Y; uint row2Y; uint word1; uint word2;
        uint idX; uint idY; uint idW; uint idH;
        uint flashX; uint flashY; uint flashW; uint flashH;
        uint idLuma; uint idCb; uint idCr; uint flashLuma;
    };

    // SplitMix64 的输出函数（契约 TestPattern.NoiseRow.mix）。
    inline ulong mix64(ulong z) {
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        return z ^ (z >> 31);
    }

    inline bool inRect(uint x, uint y, uint rx, uint ry, uint rw, uint rh) {
        return x >= rx && x < rx + rw && y >= ry && y < ry + rh;
    }

    // 四样覆盖物，顺序与契约 drawNV12 相同：行 1、行 2、ID 块、闪光块，后画的盖前面的。
    inline uint overlay(uint x, uint y, uint v, constant Params& p) {
        uint rowSpan = 32 * p.blockSize;
        if (x >= p.originX && x < p.originX + rowSpan) {
            uint i = (x - p.originX) / p.blockSize;
            if (y >= p.row1Y && y < p.row1Y + p.blockSize) v = ((p.word1 >> (31 - i)) & 1) ? 235 : 16;
            if (y >= p.row2Y && y < p.row2Y + p.blockSize) v = ((p.word2 >> (31 - i)) & 1) ? 235 : 16;
        }
        if (inRect(x, y, p.idX, p.idY, p.idW, p.idH)) v = p.idLuma;
        if (inRect(x, y, p.flashX, p.flashY, p.flashW, p.flashH)) v = p.flashLuma;
        return v;
    }

    // 亮度平面：每个线程一对像素（第 k 对的状态 = 行种子 + (k + 1) × 黄金比常数）。
    kernel void noiseLuma(texture2d<uint, access::write> luma [[texture(0)]],
                          constant Params& p [[buffer(0)]],
                          constant uchar* table [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint x = gid.x * 2, y = gid.y;
        if (x >= p.width || y >= p.height) return;
        ulong rowSeed = mix64(p.seed ^ mix64(((ulong)p.frameNumber | ((ulong)y << 32)) + 0x9E3779B97F4A7C15UL));
        ulong state = rowSeed + (ulong)(gid.x + 1) * 0x9E3779B97F4A7C15UL;
        ulong r = mix64(state);
        ulong range = (ulong)(2 * p.amplitude + 1);
        uint lo = (uint)r, hi = (uint)(r >> 32);
        int a = (int)p.level + (int)(((ulong)lo * range) >> 32) - (int)p.amplitude;
        int b = (int)p.level + (int)(((ulong)hi * range) >> 32) - (int)p.amplitude;
        a = clamp(a, 0, 255); b = clamp(b, 0, 255);
        luma.write(uint4(overlay(x, y, table[a], p), 0, 0, 0), uint2(x, y));
        if (x + 1 < p.width) luma.write(uint4(overlay(x + 1, y, table[b], p), 0, 0, 0), uint2(x + 1, y));
    }

    // 色度平面（半分辨率、CbCr 交错）：全 128，ID 块区域填调色板色度。
    kernel void patternChroma(texture2d<uint, access::write> chroma [[texture(0)]],
                              constant Params& p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width / 2 || gid.y >= p.height / 2) return;
        uint cb = 128, cr = 128;
        if (gid.x >= p.idX / 2 && gid.x < (p.idX + p.idW) / 2 && gid.y >= p.idY / 2 && gid.y < (p.idY + p.idH) / 2) { cb = p.idCb; cr = p.idCr; }
        chroma.write(uint4(cb, cr, 0, 0), gid);
    }
    """

    /// 进程共享：设备、管线、limited-range 查表。第一次用时编译（本机实测 20–60 ms）。
    final class Shared: @unchecked Sendable {
        let device: MTLDevice
        let luma: MTLComputePipelineState
        let chroma: MTLComputePipelineState
        let table: MTLBuffer

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noMetalDevice }
            self.device = device
            let library: MTLLibrary
            do { library = try device.makeLibrary(source: NoisePatternRenderer.source, options: nil) } catch { throw RendererError.compile("\(error)") }
            guard let l = library.makeFunction(name: "noiseLuma"), let c = library.makeFunction(name: "patternChroma") else { throw RendererError.compile("找不到核函数") }
            do {
                luma = try device.makeComputePipelineState(function: l)
                chroma = try device.makeComputePipelineState(function: c)
            } catch { throw RendererError.compile("\(error)") }
            // full-range 电平 → limited-range Y，与契约 TestPattern.limitedLuma 同一公式（0…255 没有恰好 .5 的情况，单精度也不会舍错）
            let values = (0...255).map { UInt8((16 + 219 * Double($0) / 255).rounded()) }
            guard let buf = device.makeBuffer(bytes: values, length: values.count, options: .storageModeShared) else { throw RendererError.compile("查表缓冲") }
            table = buf
        }

        static let instance = Mutex<Shared?>(nil)
        static func get() throws -> Shared {
            try instance.withLock { box in
                if let s = box { return s }
                let s = try Shared()
                box = s
                return s
            }
        }
    }

    struct Textures {
        let luma: MTLTexture
        let chroma: MTLTexture
        let width: Int
        let height: Int
    }

    let shared: Shared
    let queue: MTLCommandQueue
    private var textures: [IOSurfaceID: Textures] = [:]
    /// 最近一帧的成本（生产者线程写，其他线程读只做诊断）。
    public private(set) var lastCost = Cost()

    public init() throws {
        shared = try Shared.get()
        guard let q = shared.device.makeCommandQueue() else { throw RendererError.compile("命令队列") }
        queue = q
    }

    /// 为一个缓冲预建纹理（池预热时对每个缓冲调一次；没调过的缓冲第一帧会在 `draw` 里建，那一帧多几十 µs 和一次分配）。
    public func prepare(_ pixelBuffer: CVPixelBuffer) throws {
        _ = try textures(for: pixelBuffer)
    }

    private func textures(for pb: CVPixelBuffer) throws -> Textures {
        guard let surfaceRef = CVPixelBufferGetIOSurface(pb) else { throw RendererError.unsupportedPixelBuffer("没有 IOSurface") }
        let surface = surfaceRef.takeUnretainedValue()
        let id = IOSurfaceGetID(surface)
        if let t = textures[id] { return t }
        guard PixelFormat(cvPixelFormatType: CVPixelBufferGetPixelFormatType(pb)) == .nv12, CVPixelBufferGetPlaneCount(pb) == 2 else {
            throw RendererError.unsupportedPixelBuffer("像素格式 \(CVPixelBufferGetPixelFormatType(pb))")
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let ld = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
        ld.usage = [.shaderWrite]
        ld.storageMode = .shared
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Uint, width: w / 2, height: h / 2, mipmapped: false)
        cd.usage = [.shaderWrite]
        cd.storageMode = .shared
        guard let lt = shared.device.makeTexture(descriptor: ld, iosurface: surface, plane: 0),
              let ct = shared.device.makeTexture(descriptor: cd, iosurface: surface, plane: 1) else {
            throw RendererError.unsupportedPixelBuffer("建不了纹理")
        }
        let t = Textures(luma: lt, chroma: ct, width: w, height: h)
        textures[id] = t
        return t
    }

    /// 画一帧；`content.background` 不是 `.noise`、缓冲不是 NV12 / IOSurface 时返回 false（调用方退回 `TestPattern.draw`）。
    /// 同步：提交后等 GPU 完成再返回，返回时像素已在缓冲里（Apple Silicon 统一内存，`.shared` 纹理在命令缓冲完成后 CPU / 下游立刻可读）。
    @discardableResult
    public func draw(_ content: TestPattern.Content, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard case .noise(let level, let amplitude, let seed) = content.background else { return false }
        guard let t = try? textures(for: pixelBuffer) else { return false }
        let wall0 = HostClock.now()
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let g = TestPattern.Geometry(width: t.width, height: t.height)
        let p = TestPattern.ycbcr(of: TestPattern.palette[content.inputID])
        var params = Params(seed: seed, frameNumber: content.frameNumber, level: UInt32(level), amplitude: UInt32(amplitude),
                            width: UInt32(t.width), height: UInt32(t.height),
                            blockSize: UInt32(g.blockSize), originX: UInt32(g.originX), row1Y: UInt32(g.row1Y), row2Y: UInt32(g.row2Y),
                            word1: TestPattern.encodeWord(content.frameNumber), word2: TestPattern.encodeWord(content.hostTimeMs),
                            idX: UInt32(g.idRect.x), idY: UInt32(g.idRect.y), idW: UInt32(g.idRect.width), idH: UInt32(g.idRect.height),
                            flashX: UInt32(g.flashRect.x), flashY: UInt32(g.flashRect.y), flashW: UInt32(g.flashRect.width), flashH: UInt32(g.flashRect.height),
                            idLuma: UInt32(NoisePatternRenderer.clampByte(p.y)), idCb: UInt32(NoisePatternRenderer.clampByte(p.cb)), idCr: UInt32(NoisePatternRenderer.clampByte(p.cr)),
                            flashLuma: content.flash ? 235 : 16)
        var gpuNs: UInt64 = 0
        let ok: Bool = autoreleasepool {
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
            enc.setComputePipelineState(shared.luma)
            enc.setTexture(t.luma, index: 0)
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.setBuffer(shared.table, offset: 0, index: 1)
            enc.dispatchThreads(MTLSize(width: (t.width + 1) / 2, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            enc.setComputePipelineState(shared.chroma)
            enc.setTexture(t.chroma, index: 0)
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: t.width / 2, height: t.height / 2, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            gpuNs = UInt64(max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1e9))
            return cb.status == .completed
        }
        var cost = Cost()
        cost.gpuNanoseconds = gpuNs
        cost.cpuNanoseconds = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0
        cost.wallNanoseconds = UInt64(max(0, (HostClock.now() - wall0).nanoseconds))
        lastCost = cost
        return ok
    }

    @inline(__always)
    static func clampByte(_ v: Double) -> UInt8 { UInt8(min(max(v.rounded(), 0), 255)) }
}
