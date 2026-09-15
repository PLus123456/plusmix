// 每拍的合成 pass，严格按设计方案 §5 的顺序：
//   1 PGM 底（裁切 / 缩放 / 变换）→ 2 转场混合 → 3 Overlay 1→4 → 4 FTB → 5 PVW → 6 多画面 → 输出 RGB→NV12。
// 这是唯一编码这些 pass 的地方：实时路径（MetalRenderer.render）和离线路径（OfflineRenderer）都调 `encodeFrame`，
// 只是目标纹理和命令缓冲区不同。渲染线程调用时零分配：所有参数都是值或预建对象，uniforms 在栈上。
@preconcurrency import Metal
import simd
import SwitcherContracts

enum CompositorPasses {
    /// 一次编码要用到的预建对象。
    struct Context {
        let resources: RenderResources
        let table: SurfaceTextureTable
        let labels: LabelSet?
        let frameIndex: UInt64
    }

    /// 编一整帧：PGM、PVW、多画面三张纹理 + NV12 输出。输出纹理为 nil 时跳过 NV12 pass（只在测试里出现）；
    /// multiview = false 时跳过多画面（省 GPU 的选项）。
    static func encodeFrame(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                            commandBuffer: any MTLCommandBuffer,
                            outputLuma: (any MTLTexture)?, outputChroma: (any MTLTexture)?, multiview: Bool = true) {
        let t = slot.targets
        RenderSignposts.begin(.program)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: t.programPass) {
            enc.label = "PGM"
            encodeProgram(state: state, inputs: inputs, slot: slot, context: context, encoder: enc,
                          width: t.width, height: t.height)
            enc.endEncoding()
        }
        RenderSignposts.end(.program)

        RenderSignposts.begin(.preview)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: t.previewPass) {
            enc.label = "PVW"
            encodePreview(state: state, inputs: inputs, slot: slot, context: context, encoder: enc,
                          width: t.width, height: t.height)
            enc.endEncoding()
        }
        RenderSignposts.end(.preview)

        if multiview {
            RenderSignposts.begin(.multiview)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: t.multiviewPass) {
                enc.label = "MV"
                encodeMultiview(state: state, inputs: inputs, slot: slot, context: context, encoder: enc, targets: t)
                enc.endEncoding()
            }
            RenderSignposts.end(.multiview)
        }

        if let outputLuma, let outputChroma {
            RenderSignposts.begin(.nv12)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "NV12"   // 编码器标签只用短 ASCII：长于 9 字节或非 ASCII 的字面量桥接成 NSString 会分配
                encodeNV12(source: t.program, luma: outputLuma, chroma: outputChroma, context: context, encoder: enc)
                enc.endEncoding()
            }
            RenderSignposts.end(.nv12)
        }
    }

    // MARK: - 查输入

    /// 输入编号 → GPU 纹理 + 配置；同时把帧 retain 进 slot（GPU 还要读它）。没帧 / 不是 IOSurface / 编号 0 → nil（画黑）。
    @inline(__always)
    static func lookup(_ number: Int, state: MixerState, inputs: RenderInputTable, slot: RenderSlot,
                       context: Context) -> (InputTextures, InputConfig?)? {
        guard number > 0, let frame = inputs[inputNumber: number] else { return nil }
        let lite = ColorInfoLite(fullRange: frame.color.range == .full, matrix: matrixID(frame.color.matrix))
        guard let tex = context.table.inputTextures(for: frame.pixelBuffer, color: lite, frame: context.frameIndex) else { return nil }
        if number < slot.heldFrames.count { slot.heldFrames[number] = frame }
        return (tex, inputConfig(number, in: state))
    }

    /// 按编号找输入配置。等价于 MixerState.input(_:)，但用下标循环：契约里的 first(where:) 在 -Onone 下会分配。
    @inline(__always)
    static func inputConfig(_ number: Int, in state: MixerState) -> InputConfig? {
        let n = state.inputs.count
        var i = 0
        while i < n {
            if state.inputs[i].number == number { return state.inputs[i] }
            i += 1
        }
        return nil
    }

    @inline(__always)
    static func matrixID(_ m: YCbCrMatrix) -> Int32 {
        switch m {
        case .bt709: 0
        case .bt601: 1
        case .bt2020: 2
        }
    }

    // MARK: - 画一个 quad

    /// 把一路输入按 crop / transform 画进 dest。blend = false 只对 NV12 / UYVY 生效（它们 alpha 恒 1）；
    /// BGRA 源可能带 alpha，永远走混合，让底下清好的不透明黑透出来，输出纹理的 alpha 才恒为 1。
    @inline(__always)
    static func drawInput(_ tex: InputTextures, config: InputConfig?, dest: PixelRect, opacity: Float, blend: Bool,
                          width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        let blend = blend || tex.format == .bgra || opacity < 1
        var u = DrawUniforms()
        let crop = config?.settings.crop ?? .none
        let transform = config?.settings.transform ?? .identity
        Placement.fill(&u, sourceWidth: tex.width, sourceHeight: tex.height, crop: crop, transform: transform,
                       dest: dest, targetWidth: width, targetHeight: height)
        u.format = tex.format.rawValue
        u.fullRange = tex.fullRange ? 1 : 0
        u.matrix = tex.matrix
        u.chromaSize = SIMD2(Float(tex.chromaWidth), Float(tex.chromaHeight))
        u.tint = SIMD4(repeating: opacity)
        encoder.setRenderPipelineState(blend ? context.resources.quadBlend : context.resources.quadOpaque)
        // 0/1 是 float 采样路径，2/3 是 half 采样路径（同一张纹理，着色器按 taps 选一条）
        encoder.setFragmentTexture(tex.tex0, index: 0)
        encoder.setFragmentTexture(tex.tex1 ?? tex.tex0, index: 1)
        encoder.setFragmentTexture(tex.tex0, index: 2)
        encoder.setFragmentTexture(tex.tex1 ?? tex.tex0, index: 3)
        withUnsafeBytes(of: &u) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 已经是 BGRA 的纹理（PGM / PVW 结果）原样画进 dest。
    @inline(__always)
    static func drawTexture(_ texture: any MTLTexture, dest: PixelRect, opacity: Float, blend: Bool,
                            width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        var u = DrawUniforms()
        Placement.fillTexture(&u, textureWidth: texture.width, textureHeight: texture.height,
                              dest: dest, targetWidth: width, targetHeight: height)
        u.format = DrawFormat.bgra.rawValue
        u.tint = SIMD4(repeating: opacity)
        encoder.setRenderPipelineState(blend ? context.resources.quadBlend : context.resources.quadOpaque)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(texture, index: 1)
        encoder.setFragmentTexture(texture, index: 2)
        encoder.setFragmentTexture(texture, index: 3)
        withUnsafeBytes(of: &u) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 纯色矩形（预乘颜色）。
    @inline(__always)
    static func drawSolid(_ color: SIMD4<Float>, dest: PixelRect, width: Int, height: Int,
                          context: Context, encoder: any MTLRenderCommandEncoder) {
        var u = DrawUniforms()
        Placement.fillSolid(&u, dest: dest, targetWidth: width, targetHeight: height, color: color)
        encoder.setRenderPipelineState(color.w < 1 ? context.resources.quadBlend : context.resources.quadOpaque)
        withUnsafeBytes(of: &u) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 标签切片。
    @inline(__always)
    static func drawLabel(_ labels: LabelSet, slice: Int, dest: PixelRect, width: Int, height: Int,
                          context: Context, encoder: any MTLRenderCommandEncoder) {
        var u = DrawUniforms()
        Placement.fillTexture(&u, textureWidth: LabelSet.width, textureHeight: LabelSet.height,
                              dest: dest, targetWidth: width, targetHeight: height)
        u.format = DrawFormat.label.rawValue
        u.slice = Int32(slice)
        u.tint = SIMD4(repeating: 1)
        encoder.setRenderPipelineState(context.resources.labelBlend)
        encoder.setFragmentTexture(labels.texture, index: 0)
        withUnsafeBytes(of: &u) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - §5 步骤 1–4：PGM

    static func encodeProgram(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                              encoder: any MTLRenderCommandEncoder, width: Int, height: Int) {
        let full = PixelRect(x: 0, y: 0, width: Float(width), height: Float(height))
        // 1. PGM 底
        if let (tex, cfg) = lookup(state.program, state: state, inputs: inputs, slot: slot, context: context) {
            drawInput(tex, config: cfg, dest: full, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
        }
        // 2. 转场：新画面（= preview 输入）按进度盖上来。Cut 没有中间态（状态机原子换号，这里永远只画底）。
        let tr = state.transition
        if tr.type != .cut, tr.progress > 0 {
            let progress = Float(min(max(tr.progress, 0), 1))
            let blendAmount = TransitionRenderer.mixAmount(type: tr.type, progress: progress)
            if let (tex, cfg) = lookup(state.preview, state: state, inputs: inputs, slot: slot, context: context) {
                drawInput(tex, config: cfg, dest: full, opacity: blendAmount, blend: true, width: width, height: height, context: context, encoder: encoder)
            } else if state.preview == MixerState.noInput {
                // 切向黑场：按进度压黑
                drawSolid(SIMD4(0, 0, 0, blendAmount), dest: full, width: width, height: height, context: context, encoder: encoder)
            }
        }
        // 3. Overlay 1 → 4（下标循环，见 inputConfig 的说明）
        let overlayCount = state.overlays.count
        var k = 0
        while k < overlayCount {
            let o = state.overlays[k]
            k += 1
            guard o.isVisible, let input = o.input else { continue }
            let opacity = OverlayRenderer.opacity(o)
            guard opacity > 0 else { continue }
            guard let (tex, cfg) = lookup(input, state: state, inputs: inputs, slot: slot, context: context) else { continue }
            let dest = PixelRect(o.rect, in: width, height)
            encoder.setScissorRect(scissor(dest, width: width, height: height))
            drawInput(tex, config: cfg, dest: dest, opacity: opacity, blend: true, width: width, height: height, context: context, encoder: encoder)
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
        }
        // 4. FTB：乘 (1 − level)，等价于叠一层 alpha = level 的黑
        let level = Float(min(max(state.ftb.level, 0), 1))
        if level > 0 {
            drawSolid(SIMD4(0, 0, 0, level), dest: full, width: width, height: height, context: context, encoder: encoder)
        }
    }

    @inline(__always)
    static func scissor(_ r: PixelRect, width: Int, height: Int) -> MTLScissorRect {
        let x0 = max(0, min(width, Int(r.x.rounded(.down))))
        let y0 = max(0, min(height, Int(r.y.rounded(.down))))
        let x1 = max(x0, min(width, Int((r.x + r.width).rounded(.up))))
        let y1 = max(y0, min(height, Int((r.y + r.height).rounded(.up))))
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: - §5 步骤 5：PVW

    static func encodePreview(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                              encoder: any MTLRenderCommandEncoder, width: Int, height: Int) {
        let full = PixelRect(x: 0, y: 0, width: Float(width), height: Float(height))
        if let (tex, cfg) = lookup(state.preview, state: state, inputs: inputs, slot: slot, context: context) {
            drawInput(tex, config: cfg, dest: full, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
        }
    }

    // MARK: - §5 步骤 6：多画面

    static let tallyProgramColor = SIMD4<Float>(0.9, 0.1, 0.1, 1)
    static let tallyPreviewColor = SIMD4<Float>(0.1, 0.8, 0.1, 1)
    static let tallyOffColor = SIMD4<Float>(0.28, 0.28, 0.28, 1)
    static let cellBackground = SIMD4<Float>(0, 0, 0, 1)

    /// 基础布局：上半 PVW（左）+ PGM（右），下半输入按 4 列排，行数按输入数。
    static func encodeMultiview(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                                encoder: any MTLRenderCommandEncoder, targets: RenderTargets) {
        let width = targets.width, height = targets.height
        let w = Float(width), h = Float(height)
        let margin = (h / 135).rounded()          // 1080 → 8
        let border = max(2, (h / 270).rounded())  // 1080 → 4

        // 上半：PVW / PGM
        let topH = h / 2 - 1.5 * margin
        let topW = (w - 3 * margin) / 2
        let pvwCell = PixelRect(x: margin, y: margin, width: topW, height: topH)
        let pgmCell = PixelRect(x: 2 * margin + topW, y: margin, width: topW, height: topH)
        drawCell(texture: targets.preview, cell: pvwCell, borderColor: tallyPreviewColor, border: border,
                 width: width, height: height, context: context, encoder: encoder)
        drawCell(texture: targets.program, cell: pgmCell, borderColor: tallyProgramColor, border: border,
                 width: width, height: height, context: context, encoder: encoder)

        // 下半：输入。格子数固定成 4×2 / 6×3 / 8×4，让每格接近 16:9（没用到的格子留黑）
        let count = state.inputs.count
        guard count > 0 else { return }
        let columns = count <= 8 ? 4 : (count <= 18 ? 6 : 8)
        let rows = count <= 8 ? 2 : (count <= 18 ? 3 : 4)
        let areaY = h / 2 + margin / 2
        let areaH = h / 2 - 1.5 * margin
        let cellW = (w - Float(columns + 1) * margin) / Float(columns)
        let cellH = (areaH - Float(rows - 1) * margin) / Float(rows)
        var i = 0
        while i < count {
            let input = state.inputs[i]
            let col = i % columns, row = i / columns
            i += 1
            let cell = PixelRect(x: margin + Float(col) * (cellW + margin), y: areaY + Float(row) * (cellH + margin),
                                 width: cellW, height: cellH)
            let tally = state.tally(ofInput: input.number)
            let color = tally.program ? tallyProgramColor : (tally.preview ? tallyPreviewColor : tallyOffColor)
            drawSolid(color, dest: cell, width: width, height: height, context: context, encoder: encoder)
            let inner = cell.insetBy(border)
            drawSolid(cellBackground, dest: inner, width: width, height: height, context: context, encoder: encoder)
            if let (tex, cfg) = lookup(input.number, state: state, inputs: inputs, slot: slot, context: context) {
                encoder.setScissorRect(scissor(inner, width: width, height: height))
                drawInput(tex, config: cfg, dest: inner, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
            }
            if let labels = context.labels, input.number > 0, input.number < labels.slices {
                let lh = max(12, (cellH * 0.14).rounded())
                let lw = lh * Float(LabelSet.width) / Float(LabelSet.height)
                let dest = PixelRect(x: inner.x, y: inner.y + inner.height - lh, width: min(lw, inner.width), height: lh)
                drawLabel(labels, slice: input.number, dest: dest, width: width, height: height, context: context, encoder: encoder)
            }
        }
    }

    @inline(__always)
    static func drawCell(texture: any MTLTexture, cell: PixelRect, borderColor: SIMD4<Float>, border: Float,
                         width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        drawSolid(borderColor, dest: cell, width: width, height: height, context: context, encoder: encoder)
        let inner = cell.insetBy(border)
        drawSolid(cellBackground, dest: inner, width: width, height: height, context: context, encoder: encoder)
        drawTexture(texture, dest: inner, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
    }

    // MARK: - 输出：RGB → NV12

    static func encodeNV12(source: any MTLTexture, luma: any MTLTexture, chroma: any MTLTexture, context: Context,
                           encoder: any MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(context.resources.rgbToNV12)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(luma, index: 1)
        encoder.setTexture(chroma, index: 2)
        let grid = MTLSize(width: chroma.width, height: chroma.height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
    }
}

/// 转场怎么混（§5 步骤 2）。本期只有 Cut / Fade；Wipe / Zoom / Stinger 的接口留在这里，W3-B 填：
/// 需要遮罩 / 变换插值 / 带 alpha 的视频叠加时，把 `mixAmount` 换成各自的 pass（encodeProgram 里只有这一个调用点）。
enum TransitionRenderer {
    /// 新画面盖在旧画面上的不透明度。
    @inline(__always)
    static func mixAmount(type: TransitionType, progress: Float) -> Float {
        switch type {
        case .cut: 0
        case .fade: progress
        case .wipe, .zoom, .stinger: progress   // W3-B：暂按 Fade 处理
        }
    }
}

/// 叠加通道的进出动画怎么解释 animProgress（本期只有静态位置；Slide / Zoom 由 W3-B 填）。
enum OverlayRenderer {
    @inline(__always)
    static func opacity(_ o: OverlayState) -> Float {
        let p = Float(min(max(o.animProgress, 0), 1))
        return switch o.animation.kind {
        case .cut: p > 0 ? 1 : 0
        case .fade: p
        case .slide, .zoom: p          // W3-B：暂按 Fade 处理
        }
    }
}
