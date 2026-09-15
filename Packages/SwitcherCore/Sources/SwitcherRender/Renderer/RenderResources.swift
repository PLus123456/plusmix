// 设备级资源：着色器库、管线状态。整个进程建一次（prepare 里），之后所有帧共用；渲染线程只读。
@preconcurrency import Metal
import Foundation

/// 渲染器的错误。
public enum RenderError: Error, CustomStringConvertible {
    /// 没有 Metal 设备。
    case noDevice
    /// 着色器库找不到 / 编不过。
    case shaderLibrary(String)
    /// 管线状态建不出来。
    case pipeline(String)
    /// 建纹理 / 缓冲失败。
    case resource(String)
    /// 输出像素缓冲池建不出来。
    case pixelBufferPool(Int32)
    /// prepare 之前调了 render，或 shutdown 之后再调。
    case notPrepared

    public var description: String {
        switch self {
        case .noDevice: "没有可用的 Metal 设备"
        case .shaderLibrary(let s): "着色器库：\(s)"
        case .pipeline(let s): "管线状态：\(s)"
        case .resource(let s): "资源：\(s)"
        case .pixelBufferPool(let code): "输出像素缓冲池：CVReturn \(code)"
        case .notPrepared: "渲染器未 prepare"
        }
    }
}

/// 着色器库的加载：Xcode 构建时包资源里有 default.metallib；`swift build` 只会把 .metal 原样拷进 bundle，
/// 这时读源码在运行时编译（M5 Max 上约 0.3 s，只在 prepare 里发生一次）。两种情况用的是同一份 Compositor.metal。
enum ShaderLibrary {
    static func load(device: any MTLDevice) throws -> any MTLLibrary {
        let bundle = Bundle.module
        if let lib = try? device.makeDefaultLibrary(bundle: bundle) {
            return lib
        }
        guard let url = bundle.url(forResource: "Compositor", withExtension: "metal") else {
            throw RenderError.shaderLibrary("bundle 里既没有 default.metallib 也没有 Compositor.metal")
        }
        let source: String
        do { source = try String(contentsOf: url, encoding: .utf8) } catch {
            throw RenderError.shaderLibrary("读不到 \(url.path)：\(error)")
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe   // 色彩换算要可预测，不许 fast-math 重排
        do { return try device.makeLibrary(source: source, options: options) } catch {
            throw RenderError.shaderLibrary("运行时编译失败：\(error)")
        }
    }
}

/// 一台设备上的管线状态集合。
/// `@unchecked Sendable`：所有成员都在 init 里建好且不可变；MTLLibrary 没标 Sendable，但这里只读。
final class RenderResources: @unchecked Sendable {
    let device: any MTLDevice
    let library: any MTLLibrary
    /// 不混合的 quad（PGM 底、PVW、多画面格子）。
    let quadOpaque: any MTLRenderPipelineState
    /// 预乘 source-over 混合的 quad（叠加、转场新画面、FTB、边框）。
    let quadBlend: any MTLRenderPipelineState
    /// 标签纹理数组，预乘混合。
    let labelBlend: any MTLRenderPipelineState
    /// RGB → NV12。
    let rgbToNV12: any MTLComputePipelineState
    /// 中间纹理 / 显示 drawable 的格式（决策 6：BGRA8 gamma 域）。
    static let workingFormat: MTLPixelFormat = .bgra8Unorm

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt64: RenderResources] = [:]

    /// 每台设备一份，进程内共享：渲染器、离线渲染器、显示视图都用它，着色器只编译一次。
    static func shared(for device: any MTLDevice) throws -> RenderResources {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let r = cache[device.registryID] { return r }
        let r = try RenderResources(device: device)
        cache[device.registryID] = r
        return r
    }

    init(device: any MTLDevice) throws {
        precondition(MemoryLayout<DrawUniforms>.stride == DrawUniforms.expectedStride,
                     "DrawUniforms 的 Swift 布局（\(MemoryLayout<DrawUniforms>.stride)）与 Metal 不一致")
        let lib = try ShaderLibrary.load(device: device)
        let vertex = try RenderResources.function("quadVertex", in: lib)
        let fragment = try RenderResources.function("quadFragment", in: lib)
        let label = try RenderResources.function("labelFragment", in: lib)
        let convert = try RenderResources.function("rgbToNV12", in: lib)
        self.device = device
        library = lib
        quadOpaque = try RenderResources.pipeline("quadOpaque", device: device, vertex: vertex, fragment: fragment, blend: false)
        quadBlend = try RenderResources.pipeline("quadBlend", device: device, vertex: vertex, fragment: fragment, blend: true)
        labelBlend = try RenderResources.pipeline("labelBlend", device: device, vertex: vertex, fragment: label, blend: true)
        do { rgbToNV12 = try device.makeComputePipelineState(function: convert) } catch {
            throw RenderError.pipeline("rgbToNV12：\(error)")
        }
    }

    private static func function(_ name: String, in library: any MTLLibrary) throws -> any MTLFunction {
        guard let f = library.makeFunction(name: name) else { throw RenderError.pipeline("找不到函数 \(name)") }
        return f
    }

    private static func pipeline(_ label: String, device: any MTLDevice, vertex: any MTLFunction, fragment: any MTLFunction,
                                 blend: Bool) throws -> any MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.label = label
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = RenderResources.workingFormat
        ca.isBlendingEnabled = blend
        if blend {
            // 预乘 alpha 的 source-over
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do { return try device.makeRenderPipelineState(descriptor: d) } catch {
            throw RenderError.pipeline("\(label)：\(error)")
        }
    }
}
