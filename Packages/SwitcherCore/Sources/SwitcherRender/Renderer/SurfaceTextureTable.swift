// IOSurface → MTLTexture 的零拷贝表。
//
// 为什么不用 CVMetalTextureCache：探针（reports/w1-compositor.md）实测 CVMetalTextureCacheCreateTextureFromImage 每次调用
// 分配 3 个对象（CVMetalTexture、字典、CFData），不满足渲染线程零分配。这里直接用 MTLDevice.makeTexture(descriptor:iosurface:plane:)
// —— 与 CVMetalTextureCache 底层相同的零拷贝机制 —— 并按 IOSurfaceID 记住结果。输入的像素缓冲来自池子，IOSurface 反复出现，
// 稳态下全部命中；只有新 IOSurface 首次出现时建纹理（预热期）。
@preconcurrency import Metal
import IOSurface
import CoreVideo

/// 固定容量的表，线性查找（容量 ≤ 几百，比哈希便宜且没有分配）。只在渲染线程（或离线渲染线程）访问。
final class SurfaceTextureTable {
    private struct Entry {
        var key: UInt64 = 0          // 0 = 空
        var texture: (any MTLTexture)? = nil
        var lastUsed: UInt64 = 0
    }
    private var entries: [Entry]
    private let device: any MTLDevice
    /// 多少帧没用就可以被淘汰（输入停了也不必立刻释放）。
    private let idleFrames: UInt64
    /// 统计：建了多少次纹理（测试看预热后是否为 0）。
    private(set) var createCount = 0
    private(set) var evictCount = 0

    init(device: any MTLDevice, capacity: Int, idleFrames: UInt64 = 600) {
        self.device = device
        self.idleFrames = idleFrames
        entries = Array(repeating: Entry(), count: max(8, capacity))
    }

    /// 取某个 IOSurface 某个平面的纹理；没有就建（分配，仅预热期）。表满时淘汰最久没用的。
    func texture(surface: IOSurfaceRef, plane: Int, format: MTLPixelFormat, width: Int, height: Int,
                 usage: MTLTextureUsage, frame: UInt64) -> (any MTLTexture)? {
        let key = (UInt64(IOSurfaceGetID(surface)) << 16) | (UInt64(plane & 0xF) << 12) | UInt64(format.rawValue & 0xFFF)
        var freeIndex = -1
        var oldestIndex = 0
        var oldestUsed = UInt64.max
        // 显式下标循环（不用 for-in）：-Onone 下泛型迭代器会装箱分配，这里是每帧热路径
        let n = entries.count
        var i = 0
        while i < n {
            let k = entries[i].key
            if k == key {
                // 尺寸不同的同一个 IOSurface（理论上不会发生）：重建
                if let t = entries[i].texture, t.width == width, t.height == height {
                    entries[i].lastUsed = frame
                    return t
                }
                freeIndex = i
                break
            }
            if k == 0 {
                if freeIndex < 0 { freeIndex = i }
            } else if entries[i].lastUsed < oldestUsed {
                oldestUsed = entries[i].lastUsed
                oldestIndex = i
            }
            i += 1
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d, iosurface: surface, plane: plane) else { return nil }
        createCount += 1
        let slot: Int
        if freeIndex >= 0 {
            slot = freeIndex
        } else {
            slot = oldestIndex
            evictCount += 1
        }
        entries[slot] = Entry(key: key, texture: t, lastUsed: frame)
        return t
    }

    /// 释放很久没用的条目（在渲染线程调也只会 release，不会 malloc）。
    func evictIdle(frame: UInt64) {
        var i = 0
        while i < entries.count {
            if entries[i].key != 0 && frame &- entries[i].lastUsed > idleFrames {
                entries[i] = Entry()
                evictCount += 1
            }
            i += 1
        }
    }

    /// 清空。
    func removeAll() {
        for i in entries.indices { entries[i] = Entry() }
    }
}

/// 一路输入帧在 GPU 上的样子：一或两张纹理 + 着色器需要的格式参数。栈上的值，零分配。
struct InputTextures {
    var format: DrawFormat
    var tex0: any MTLTexture
    var tex1: (any MTLTexture)?
    var width: Int
    var height: Int
    var chromaWidth: Int
    var chromaHeight: Int
    var fullRange: Bool
    var matrix: Int32
}

extension SurfaceTextureTable {
    /// 把一个 IOSurface 背后的 CVPixelBuffer 变成可采样的纹理。不是 IOSurface 背后、或格式不认识 → nil（当无信号处理）。
    func inputTextures(for pixelBuffer: CVPixelBuffer, color: ColorInfoLite, frame: UInt64) -> InputTextures? {
        guard let unmanaged = CVPixelBufferGetIOSurface(pixelBuffer) else { return nil }
        let surface = unmanaged.takeUnretainedValue()
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            guard let t = texture(surface: surface, plane: 0, format: .bgra8Unorm, width: width, height: height,
                                  usage: .shaderRead, frame: frame) else { return nil }
            return InputTextures(format: .bgra, tex0: t, tex1: nil, width: width, height: height,
                                 chromaWidth: width, chromaHeight: height, fullRange: true, matrix: color.matrix)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let cw = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), ch = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            guard let y = texture(surface: surface, plane: 0, format: .r8Unorm, width: width, height: height,
                                  usage: .shaderRead, frame: frame),
                  let c = texture(surface: surface, plane: 1, format: .rg8Unorm, width: cw, height: ch,
                                  usage: .shaderRead, frame: frame) else { return nil }
            let full = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return InputTextures(format: .nv12, tex0: y, tex1: c, width: width, height: height,
                                 chromaWidth: cw, chromaHeight: ch, fullRange: full, matrix: color.matrix)
        case kCVPixelFormatType_422YpCbCr8:
            guard let t = texture(surface: surface, plane: 0, format: .bgrg422, width: width, height: height,
                                  usage: .shaderRead, frame: frame) else { return nil }
            return InputTextures(format: .uyvy, tex0: t, tex1: nil, width: width, height: height,
                                 chromaWidth: width / 2, chromaHeight: height, fullRange: color.fullRange, matrix: color.matrix)
        default:
            return nil
        }
    }
}

/// ColorInfo 里着色器关心的两项，提前换算成整数。
struct ColorInfoLite {
    var fullRange: Bool
    var matrix: Int32
}
