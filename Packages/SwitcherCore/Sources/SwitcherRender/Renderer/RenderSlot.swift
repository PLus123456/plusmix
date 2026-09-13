// 一组"一帧在途"的资源：三重缓冲的每一重（设计方案 §3.2）。prepare 里建，之后每帧轮换复用，零分配。
@preconcurrency import Metal
import CoreVideo
import SwitcherContracts

/// 合成目标的三张纹理 + 预建的 render pass 描述。
/// `@unchecked Sendable`：纹理对象建好后不变；内容由 GPU 写、GPU 读（显示视图 blit），同一命令队列上由 Metal 追踪冲突。
final class RenderTargets: @unchecked Sendable {
    let program: any MTLTexture
    let preview: any MTLTexture
    let multiview: any MTLTexture
    let programPass: MTLRenderPassDescriptor
    let previewPass: MTLRenderPassDescriptor
    let multiviewPass: MTLRenderPassDescriptor
    let width: Int
    let height: Int

    init(device: any MTLDevice, width: Int, height: Int, label: String, storage: MTLStorageMode = .private) throws {
        self.width = width
        self.height = height
        func make(_ name: String) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderResources.workingFormat,
                                                             width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resource("建不出 \(label).\(name) 纹理") }
            t.label = "\(label).\(name)"
            return t
        }
        func pass(_ t: any MTLTexture) -> MTLRenderPassDescriptor {
            let p = MTLRenderPassDescriptor()
            let ca = p.colorAttachments[0]!
            ca.texture = t
            ca.loadAction = .clear
            ca.storeAction = .store
            ca.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return p
        }
        program = try make("program")
        preview = try make("preview")
        multiview = try make("multiview")
        programPass = pass(program)
        previewPass = pass(preview)
        multiviewPass = pass(multiview)
    }
}

/// 三重缓冲的一重。只有渲染线程写、完成线程读（顺序由 MetalRenderer 的在途计数保证）。
final class RenderSlot: @unchecked Sendable {
    let index: Int
    let targets: RenderTargets
    /// 这一帧用到的输入帧：渲染线程 render 返回后 RenderInputTable 可能被覆盖，GPU 还在读它们的 IOSurface，所以在这里 retain 到完成为止。
    var heldFrames: [Frame?]
    /// 输出 NV12 缓冲（环里挑的）。
    var outputBuffer: CVPixelBuffer?
    var commandBuffer: (any MTLCommandBuffer)?
    var tick: Tick = .zero
    var tickTime: HostTime = .zero
    var submitTime: HostTime = .zero
    var frameIndex: UInt64 = 0

    init(index: Int, targets: RenderTargets, maxInputs: Int) {
        self.index = index
        self.targets = targets
        heldFrames = Array(repeating: nil, count: max(1, maxInputs))
    }

    /// 完成后释放这一帧持有的东西（release 不是 malloc，完成线程上做）。
    func releaseFrame() {
        var i = 0
        while i < heldFrames.count { heldFrames[i] = nil; i += 1 }
        outputBuffer = nil
        commandBuffer = nil
    }
}
