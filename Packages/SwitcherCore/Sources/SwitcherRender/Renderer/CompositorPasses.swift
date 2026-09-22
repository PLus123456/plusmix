// 每拍的合成 pass，严格按设计方案 §5 的顺序：
//   1 PGM 底（裁切 / 缩放 / 变换）→ 2 转场混合（Fade / Wipe / Zoom / Stinger）→ 3 Overlay 1→4 → 4 FTB → 5 PVW（可选叠加）→ 6 多画面 → 输出 RGB→NV12。
// 这是唯一编码这些 pass 的地方：实时路径（MetalRenderer.render）和离线路径（OfflineRenderer）都调 `encodeFrame`，
// 只是目标纹理和命令缓冲区不同。渲染线程调用时零分配：所有参数都是值或预建对象，uniforms 在栈上。
// W3-B：转场 Wipe / Zoom / Stinger、叠加的 slide / zoom 动画与边框、抠像、多画面布局表、PVW / 多画面的 NV12 输出。
@preconcurrency import Metal
import simd
import SwitcherContracts

enum CompositorPasses {
    /// 一次编码要用到的预建对象。
    struct Context {
        let resources: RenderResources
        let table: SurfaceTextureTable
        let labels: LabelSet?
        /// 多画面布局（快照 sequence 变了才重新解析）。
        let layout: MultiviewLayoutTable
        let frameIndex: UInt64
        /// PVW 也画叠加（提案 010 过渡做法）。
        var overlaysInPreview = false
    }

    /// 一个 NV12 输出目标（IOSurface 两个平面的整数视图）。
    struct NV12Target {
        let luma: any MTLTexture
        let chroma: any MTLTexture
    }

    /// 这一帧要转成 NV12 的画面；nil 的跳过（测试里 program 也可以为 nil）。
    struct FrameOutputs {
        var program: NV12Target? = nil
        var preview: NV12Target? = nil
        var multiview: NV12Target? = nil
    }

    /// 编一整帧：PGM、PVW、多画面三张纹理 + NV12 输出。multiview = false 时跳过多画面（省 GPU 的选项；此时 outputs.multiview 也不转）。
    static func encodeFrame(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                            commandBuffer: any MTLCommandBuffer, outputs: FrameOutputs, multiview: Bool = true) {
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

        if outputs.program != nil || outputs.preview != nil || (multiview && outputs.multiview != nil) {
            RenderSignposts.begin(.nv12)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "NV12"   // 编码器标签只用短 ASCII：长于 9 字节或非 ASCII 的字面量桥接成 NSString 会分配
                if let o = outputs.program { encodeNV12(source: t.program, target: o, context: context, encoder: enc) }
                if let o = outputs.preview { encodeNV12(source: t.preview, target: o, context: context, encoder: enc) }
                if multiview, let o = outputs.multiview { encodeNV12(source: t.multiview, target: o, context: context, encoder: enc) }
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

    /// Wipe 遮罩参数（只有转场的新画面带）。
    struct WipeMask {
        var mode: WipeMode
        var edge: Float
        var softness: Float
    }

    /// 把一路输入按 crop / transform 画进 dest。blend = false 只对 NV12 / UYVY 生效（它们 alpha 恒 1）；
    /// BGRA 源可能带 alpha，永远走混合，让底下清好的不透明黑透出来，输出纹理的 alpha 才恒为 1。抠像 / Wipe 也走混合。
    /// offsetScale：输入自己的平移按这个比例缩（Zoom 转场里新画面整体缩小时用）。
    @inline(__always)
    static func drawInput(_ tex: InputTextures, config: InputConfig?, dest: PixelRect, opacity: Float, blend: Bool,
                          wipe: WipeMask? = nil, offsetScale: Float = 1,
                          width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        var u = DrawUniforms()
        let crop = config?.settings.crop ?? .none
        var transform = config?.settings.transform ?? .identity
        if offsetScale != 1 {
            transform.offsetX *= Double(offsetScale)
            transform.offsetY *= Double(offsetScale)
        }
        Placement.fill(&u, sourceWidth: tex.width, sourceHeight: tex.height, crop: crop, transform: transform,
                       dest: dest, targetWidth: width, targetHeight: height)
        u.format = tex.format.rawValue
        u.fullRange = tex.fullRange ? 1 : 0
        u.matrix = tex.matrix
        u.chromaSize = SIMD2(Float(tex.chromaWidth), Float(tex.chromaHeight))
        u.tint = SIMD4(repeating: opacity)
        var keyed = false
        if let keyer = config?.settings.keyer, keyer.enabled {
            keyed = true
            Keyer.fill(&u, keyer)
        }
        if let wipe {
            u.wipeMode = wipe.mode.rawValue
            u.wipeEdge = wipe.edge
            u.wipeSoftness = wipe.softness
        }
        let blend = blend || tex.format == .bgra || opacity < 1 || keyed || wipe != nil
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

    /// 纯色矩形（预乘颜色）。wipe 非 nil 时按遮罩（切向黑场的 Wipe 用）。
    @inline(__always)
    static func drawSolid(_ color: SIMD4<Float>, dest: PixelRect, wipe: WipeMask? = nil, width: Int, height: Int,
                          context: Context, encoder: any MTLRenderCommandEncoder) {
        var u = DrawUniforms()
        Placement.fillSolid(&u, dest: dest, targetWidth: width, targetHeight: height, color: color)
        if let wipe {
            u.wipeMode = wipe.mode.rawValue
            u.wipeEdge = wipe.edge
            u.wipeSoftness = wipe.softness
        }
        encoder.setRenderPipelineState(color.w < 1 || wipe != nil ? context.resources.quadBlend : context.resources.quadOpaque)
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

    @inline(__always)
    static func scissor(_ r: PixelRect, width: Int, height: Int) -> MTLScissorRect {
        let x0 = max(0, min(width, Int(r.x.rounded(.down))))
        let y0 = max(0, min(height, Int(r.y.rounded(.down))))
        let x1 = max(x0, min(width, Int((r.x + r.width).rounded(.up))))
        let y1 = max(y0, min(height, Int((r.y + r.height).rounded(.up))))
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: - §5 步骤 1–4：PGM

    static func encodeProgram(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                              encoder: any MTLRenderCommandEncoder, width: Int, height: Int) {
        let full = PixelRect(x: 0, y: 0, width: Float(width), height: Float(height))
        // 1. PGM 底
        if let (tex, cfg) = lookup(state.program, state: state, inputs: inputs, slot: slot, context: context) {
            drawInput(tex, config: cfg, dest: full, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
        }
        // 2. 转场：新画面（= preview 输入）按进度盖上来。Cut 没有中间态（状态机原子换号，这里永远只画底）；progress 0 = 空闲。
        let tr = state.transition
        if tr.type != .cut, tr.progress > 0 {
            encodeTransition(tr, state: state, inputs: inputs, slot: slot, context: context, encoder: encoder, full: full, width: width, height: height)
        }
        // 3. Overlay 1 → 4
        encodeOverlays(state: state, inputs: inputs, slot: slot, context: context, encoder: encoder, width: width, height: height)
        // 4. FTB：乘 (1 − level)，等价于叠一层 alpha = level 的黑
        let level = Float(min(max(state.ftb.level, 0), 1))
        if level > 0 {
            drawSolid(SIMD4(0, 0, 0, level), dest: full, width: width, height: height, context: context, encoder: encoder)
        }
    }

    /// §5 步骤 2：Fade = mix，Wipe = 遮罩，Zoom = 变换插值，Stinger = 带 alpha 的输入叠加（底在第 cutAtTick 拍换）。
    static func encodeTransition(_ tr: TransitionState, state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                                 encoder: any MTLRenderCommandEncoder, full: PixelRect, width: Int, height: Int) {
        let progress = Float(min(max(tr.progress, 0), 1))
        let new = lookup(state.preview, state: state, inputs: inputs, slot: slot, context: context)
        let toBlack = new == nil && state.preview == MixerState.noInput
        switch tr.type {
        case .cut:
            return
        case .fade:
            if let (tex, cfg) = new {
                drawInput(tex, config: cfg, dest: full, opacity: progress, blend: true, width: width, height: height, context: context, encoder: encoder)
            } else if toBlack {
                drawSolid(SIMD4(0, 0, 0, progress), dest: full, width: width, height: height, context: context, encoder: encoder)
            }
        case .wipe:
            let mask = WipeMask(mode: TransitionRenderer.wipeMode(tr.wipe.direction), edge: progress,
                                softness: Float(min(max(tr.wipe.softness, 0), 1)))
            if let (tex, cfg) = new {
                drawInput(tex, config: cfg, dest: full, opacity: 1, blend: true, wipe: mask, width: width, height: height, context: context, encoder: encoder)
            } else if toBlack {
                drawSolid(SIMD4(0, 0, 0, 1), dest: full, wipe: mask, width: width, height: height, context: context, encoder: encoder)
            }
        case .zoom:
            let dest = full.scaled(progress)
            if let (tex, cfg) = new {
                encoder.setScissorRect(scissor(dest, width: width, height: height))
                drawInput(tex, config: cfg, dest: dest, opacity: 1, blend: false, offsetScale: progress, width: width, height: height, context: context, encoder: encoder)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
            } else if toBlack {
                drawSolid(SIMD4(0, 0, 0, 1), dest: dest, width: width, height: height, context: context, encoder: encoder)
            }
        case .stinger:
            if TransitionRenderer.stingerShowsNewUnder(progress: tr.progress, durationTicks: tr.durationTicks, cutAtTick: tr.stinger.cutAtTick) {
                if let (tex, cfg) = new {
                    drawInput(tex, config: cfg, dest: full, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
                } else if toBlack {
                    drawSolid(SIMD4(0, 0, 0, 1), dest: full, width: width, height: height, context: context, encoder: encoder)
                }
            }
            if let stingerInput = tr.stinger.input,
               let (tex, cfg) = lookup(stingerInput, state: state, inputs: inputs, slot: slot, context: context) {
                drawInput(tex, config: cfg, dest: full, opacity: 1, blend: true, width: width, height: height, context: context, encoder: encoder)
            }
        }
    }

    /// §5 步骤 3：Overlay 1 → 4。下标循环，见 inputConfig 的说明。
    /// `previewPass` = 这一遍画的是 PVW：只画 `previewOn` 的通道（`context.overlaysInPreview` 是"全部预览"总开关，两者取或，提案 010）。
    static func encodeOverlays(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                               encoder: any MTLRenderCommandEncoder, width: Int, height: Int, previewPass: Bool = false) {
        let overlayCount = state.overlays.count
        let fullScissor = MTLScissorRect(x: 0, y: 0, width: width, height: height)
        var k = 0
        while k < overlayCount {
            let o = state.overlays[k]
            k += 1
            if previewPass && !context.overlaysInPreview && !o.previewOn { continue }
            guard OverlayRenderer.isDrawable(o), let input = o.input else { continue }
            let placement = OverlayRenderer.placement(o)
            guard placement.opacity > 0 else { continue }
            guard let (tex, cfg) = lookup(input, state: state, inputs: inputs, slot: slot, context: context) else { continue }
            let dest = PixelRect(placement.rect, in: width, height)
            let opacity = placement.opacity
            if let border = OverlayDecoration.border(for: o, config: cfg) {
                let outer = dest.outsetBy(Float(border.width) * Float(height))
                let sc = scissor(outer, width: width, height: height)
                if sc.width > 0 && sc.height > 0 {
                    encoder.setScissorRect(sc)
                    drawSolid(border.color * opacity, dest: outer, width: width, height: height, context: context, encoder: encoder)
                }
            }
            let sc = scissor(dest, width: width, height: height)
            if sc.width > 0 && sc.height > 0 {
                encoder.setScissorRect(sc)
                drawInput(tex, config: cfg, dest: dest, opacity: opacity, blend: true, width: width, height: height, context: context, encoder: encoder)
            }
            encoder.setScissorRect(fullScissor)
        }
    }

    // MARK: - §5 步骤 5：PVW

    static func encodePreview(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                              encoder: any MTLRenderCommandEncoder, width: Int, height: Int) {
        let full = PixelRect(x: 0, y: 0, width: Float(width), height: Float(height))
        if let (tex, cfg) = lookup(state.preview, state: state, inputs: inputs, slot: slot, context: context) {
            drawInput(tex, config: cfg, dest: full, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
        }
        encodeOverlays(state: state, inputs: inputs, slot: slot, context: context, encoder: encoder,
                       width: width, height: height, previewPass: true)
    }

    // MARK: - §5 步骤 6：多画面

    static let tallyProgramColor = SIMD4<Float>(0.9, 0.1, 0.1, 1)
    static let tallyPreviewColor = SIMD4<Float>(0.1, 0.8, 0.1, 1)
    static let tallyOffColor = SIMD4<Float>(0.28, 0.28, 0.28, 1)
    static let cellBackground = SIMD4<Float>(0, 0, 0, 1)
    /// 安全框线（预乘 70% 白）。
    static let safeAreaColor = SIMD4<Float>(0.7, 0.7, 0.7, 0.7)
    /// 电平表占位：条底（预乘 70% 黑）和刻度（预乘 50% 白）。
    static let meterBackground = SIMD4<Float>(0, 0, 0, 0.7)
    static let meterTick = SIMD4<Float>(0.5, 0.5, 0.5, 0.5)

    /// 按布局表画：每格 tally 边框 + 黑底 + 内容 + 名字；PGM / PVW 格可选安全框，输入格可选电平表占位。
    static func encodeMultiview(state: MixerState, inputs: RenderInputTable, slot: RenderSlot, context: Context,
                                encoder: any MTLRenderCommandEncoder, targets: RenderTargets) {
        let width = targets.width, height = targets.height
        let h = Float(height)
        let layout = context.layout
        let border = layout.border
        let fullScissor = MTLScissorRect(x: 0, y: 0, width: width, height: height)
        var i = 0
        while i < layout.cellCount {
            let cell = layout.cells[i]
            i += 1
            let rect = cell.rect
            let inner = rect.insetBy(border)
            switch cell.kind {
            case .program, .preview:
                let isProgram = cell.kind == .program
                drawCell(texture: isProgram ? targets.program : targets.preview, cell: rect,
                         borderColor: isProgram ? tallyProgramColor : tallyPreviewColor, border: border,
                         width: width, height: height, context: context, encoder: encoder)
                if layout.safeArea { drawSafeArea(inner, width: width, height: height, context: context, encoder: encoder) }
                if let labels = context.labels {
                    drawCellLabel(labels, slice: isProgram ? labels.programSlice : labels.previewSlice, inner: inner, cellHeight: rect.height,
                                  frameHeight: h, width: width, height: height, context: context, encoder: encoder)
                }
            case .input:
                let number = Int(cell.input)
                let tally = state.tally(ofInput: number)
                let color = tally.program ? tallyProgramColor : (tally.preview ? tallyPreviewColor : tallyOffColor)
                drawSolid(color, dest: rect, width: width, height: height, context: context, encoder: encoder)
                drawSolid(cellBackground, dest: inner, width: width, height: height, context: context, encoder: encoder)
                if let (tex, cfg) = lookup(number, state: state, inputs: inputs, slot: slot, context: context) {
                    encoder.setScissorRect(scissor(inner, width: width, height: height))
                    drawInput(tex, config: cfg, dest: inner, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
                    encoder.setScissorRect(fullScissor)
                }
                if layout.meters { drawMeterPlaceholder(inner, width: width, height: height, context: context, encoder: encoder) }
                if let labels = context.labels, number > 0, number < labels.inputSlices {
                    drawCellLabel(labels, slice: number, inner: inner, cellHeight: rect.height, frameHeight: h,
                                  width: width, height: height, context: context, encoder: encoder)
                }
            }
        }
    }

    /// 格子左下角的名字条：高 = 格高 × 14%（≥ 12 px，≤ 画面高 × 3.5%），宽按标签纹理比例。
    @inline(__always)
    static func drawCellLabel(_ labels: LabelSet, slice: Int, inner: PixelRect, cellHeight: Float, frameHeight: Float,
                              width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        let lh = max(12, min((cellHeight * 0.14).rounded(), (frameHeight * 0.035).rounded()))
        let lw = lh * Float(LabelSet.width) / Float(LabelSet.height)
        let dest = PixelRect(x: inner.x, y: inner.y + inner.height - lh, width: min(lw, inner.width), height: lh)
        drawLabel(labels, slice: slice, dest: dest, width: width, height: height, context: context, encoder: encoder)
    }

    @inline(__always)
    static func drawCell(texture: any MTLTexture, cell: PixelRect, borderColor: SIMD4<Float>, border: Float,
                         width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        drawSolid(borderColor, dest: cell, width: width, height: height, context: context, encoder: encoder)
        let inner = cell.insetBy(border)
        drawSolid(cellBackground, dest: inner, width: width, height: height, context: context, encoder: encoder)
        drawTexture(texture, dest: inner, opacity: 1, blend: false, width: width, height: height, context: context, encoder: encoder)
    }

    /// 安全框（EBU R95，16:9）：动作安全 3.5%、字幕安全 5%，各一圈细线。
    @inline(__always)
    static func drawSafeArea(_ inner: PixelRect, width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        let line = max(1, (Float(height) / 540).rounded())
        var k = 0
        while k < 2 {
            let f: Float = k == 0 ? 0.035 : 0.05
            k += 1
            let r = PixelRect(x: inner.x + inner.width * f, y: inner.y + inner.height * f,
                              width: inner.width * (1 - 2 * f), height: inner.height * (1 - 2 * f))
            drawSolid(safeAreaColor, dest: PixelRect(x: r.x, y: r.y, width: r.width, height: line), width: width, height: height, context: context, encoder: encoder)
            drawSolid(safeAreaColor, dest: PixelRect(x: r.x, y: r.y + r.height - line, width: r.width, height: line), width: width, height: height, context: context, encoder: encoder)
            drawSolid(safeAreaColor, dest: PixelRect(x: r.x, y: r.y + line, width: line, height: max(0, r.height - 2 * line)), width: width, height: height, context: context, encoder: encoder)
            drawSolid(safeAreaColor, dest: PixelRect(x: r.x + r.width - line, y: r.y + line, width: line, height: max(0, r.height - 2 * line)), width: width, height: height, context: context, encoder: encoder)
        }
    }

    /// 电平表占位：格子右侧一条 3% 宽的暗条，四道刻度。真实电平在 Stats.audio.meters 里（铁律 4），第一版这里只画位置。
    @inline(__always)
    static func drawMeterPlaceholder(_ inner: PixelRect, width: Int, height: Int, context: Context, encoder: any MTLRenderCommandEncoder) {
        let sw = max(4, (inner.width * 0.03).rounded())
        let pad: Float = 2
        let strip = PixelRect(x: inner.x + inner.width - sw - pad, y: inner.y + pad, width: sw, height: max(0, inner.height - 2 * pad))
        drawSolid(meterBackground, dest: strip, width: width, height: height, context: context, encoder: encoder)
        var k = 1
        while k <= 4 {
            let y = strip.y + strip.height * Float(k) / 5
            drawSolid(meterTick, dest: PixelRect(x: strip.x, y: y, width: sw, height: 1), width: width, height: height, context: context, encoder: encoder)
            k += 1
        }
    }

    // MARK: - 输出：RGB → NV12

    static func encodeNV12(source: any MTLTexture, target: NV12Target, context: Context, encoder: any MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(context.resources.rgbToNV12)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target.luma, index: 1)
        encoder.setTexture(target.chroma, index: 2)
        let grid = MTLSize(width: target.chroma.width, height: target.chroma.height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
    }
}

/// 转场怎么混（§5 步骤 2）。纯函数，测试直接调。
enum TransitionRenderer {
    @inline(__always)
    static func wipeMode(_ d: WipeDirection) -> WipeMode {
        switch d {
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        case .topToBottom: .topToBottom
        case .bottomToTop: .bottomToTop
        case .diagonal: .diagonal
        }
    }

    /// Stinger 的底什么时候换成新画面：stinger 第 k 拍（k = round(progress × d)）≥ max(cutAtTick, 1)。
    /// 第 0 拍是应用命令的那一拍（progress 0，什么都不叠），所以最早在第 1 拍换；cutAtTick ≥ d 时过渡期间不换（完成时状态机对调）。
    @inline(__always)
    static func stingerShowsNewUnder(progress: Double, durationTicks d: Int, cutAtTick c: Int) -> Bool {
        guard d > 0 else { return true }
        guard c < d else { return false }
        let k = Int((progress * Double(d)).rounded())
        return k >= max(c, 1)
    }
}

/// 叠加通道的进出动画怎么解释 animProgress（§5 步骤 3；契约 OverlayState 的注释）。
enum OverlayRenderer {
    enum Edge { case left, right, top, bottom }

    /// 画不画：有输入、开着或退出动画未完、且进度 > 0。
    @inline(__always)
    static func isDrawable(_ o: OverlayState) -> Bool {
        o.isVisible && o.animProgress > 0
    }

    /// slide 从哪条边进：`OverlayAnimation.slideFrom` 指定的那条（提案 010），
    /// nil 时是离 rect 最近的边；并列时底 > 顶 > 左 > 右（整幅 rect 从底边，下三分之一自然向上滑入）。
    @inline(__always)
    static func slideEdge(for r: NormalizedRect, from explicit: OverlayEdge? = nil) -> Edge {
        if let explicit {
            switch explicit {
            case .left: return .left
            case .right: return .right
            case .top: return .top
            case .bottom: return .bottom
            }
        }
        let dl = r.x, dr = 1 - (r.x + r.width), dt = r.y, db = 1 - (r.y + r.height)
        var edge = Edge.bottom
        var best = db
        if dt < best { best = dt; edge = .top }
        if dl < best { best = dl; edge = .left }
        if dr < best { edge = .right }
        return edge
    }

    /// animProgress → (画在哪, 不透明度)。cut：p > 0 就完整显示；fade：不透明度 = p；
    /// slide：从 `slideFrom`（没给就是最近的）那条边平移进来；zoom：绕 `anchor` 缩放（默认 center，提案 010）。
    @inline(__always)
    static func placement(_ o: OverlayState) -> (rect: NormalizedRect, opacity: Float) {
        let p = min(max(o.animProgress, 0), 1)
        let r = o.rect
        switch o.animation.kind {
        case .cut:
            return (r, p > 0 ? 1 : 0)
        case .fade:
            return (r, Float(p))
        case .slide:
            var moved = r
            let back = 1 - p
            switch slideEdge(for: r, from: o.animation.slideFrom) {
            case .left: moved.x = r.x - back * (r.x + r.width)
            case .right: moved.x = r.x + back * (1 - r.x)
            case .top: moved.y = r.y - back * (r.y + r.height)
            case .bottom: moved.y = r.y + back * (1 - r.y)
            }
            return (moved, 1)
        case .zoom:
            let w = r.width * p, h = r.height * p
            let (u, v) = o.anchor.unitPoint
            return (NormalizedRect(x: r.x + (r.width - w) * u, y: r.y + (r.height - h) * v, width: w, height: h), 1)
        }
    }
}

extension CompositorPasses {
    /// 状态里有没有 enabled 且 source 是该画面的输出（提案 010 / W3-B §4 第 5 条的裁定：
    /// `RenderedFrame.preview` / `.multiview` 据此自动填）。下标循环，渲染线程每拍调，零分配。
    @inline(__always)
    static func wants(_ source: OutputSource, in state: MixerState) -> Bool {
        let outputs = state.outputs
        var i = 0
        while i < outputs.count {
            if outputs[i].enabled && outputs[i].settings.source == source { return true }
            i += 1
        }
        return false
    }
}

/// 效果格的标识（契约 EffectSlot.id；视频效果由合成会话定义）。
enum EffectIDs {
    /// 画中画边框：params {"width": 占节目高的比例（默认 0.006，钳 0–0.1）, "color": [r, g, b] 0–255（默认白）}。提案 010 的过渡做法。
    static let border = "border"
}

/// 叠加通道的装饰（现在只有边框）。提案 010 落地后正式字段 `OverlayState.border` 优先，
/// 过渡做法（该输入效果链里的 "border" 格）保留一个版本作后备。
enum OverlayDecoration {
    struct Border {
        var width: Double
        /// 预乘颜色，alpha 1。
        var color: SIMD4<Float>
    }

    /// 这一路叠加的边框：先看 `OverlayState.border`（正式字段），没有才看输入效果链里的 "border" 格（过渡做法）。
    /// 下标循环、只 retain，渲染线程可调。
    @inline(__always)
    static func border(for overlay: OverlayState, config: InputConfig?) -> Border? {
        if let b = overlay.border { return resolve(b) }
        return border(for: config)
    }

    /// 正式字段 → 渲染参数：宽钳 0–0.1，颜色转预乘（alpha 1 所以就是除 255）。
    @inline(__always)
    static func resolve(_ b: OverlayBorder) -> Border {
        Border(width: min(max(b.width, 0), 0.1),
               color: SIMD4<Float>(Float(b.color.red) / 255, Float(b.color.green) / 255, Float(b.color.blue) / 255, 1))
    }

    /// 后备：输入的效果链里第一个启用的 "border"；没有为 nil。下标循环、只 retain，渲染线程可调。
    static func border(for config: InputConfig?) -> Border? {
        guard let config else { return nil }
        let effects = config.settings.effects
        var i = 0
        while i < effects.count {
            let e = effects[i]
            i += 1
            guard e.enabled, e.id == EffectIDs.border else { continue }
            var width = 0.006
            if case .number(let w)? = e.params["width"] { width = min(max(w, 0), 0.1) }
            var color = SIMD4<Float>(1, 1, 1, 1)
            if case .array(let a)? = e.params["color"], a.count >= 3 {
                var c = SIMD4<Float>(0, 0, 0, 1)
                var j = 0
                while j < 3 {
                    if case .number(let v) = a[j] { c[j] = Float(min(max(v, 0), 255)) / 255 }
                    j += 1
                }
                color = c
            }
            return Border(width: width, color: color)
        }
        return nil
    }
}

/// 抠像参数 → uniforms（提案 009 的口径）。
enum Keyer {
    @inline(__always)
    static func fill(_ u: inout DrawUniforms, _ k: KeyerSettings) {
        let r = Float(k.keyColor.red) / 255, g = Float(k.keyColor.green) / 255, b = Float(k.keyColor.blue) / 255
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        u.keyer = 1
        let chroma = SIMD2<Float>((b - y) / 1.8556, (r - y) / 1.5748)
        u.keyChroma = chroma
        let len = (chroma.x * chroma.x + chroma.y * chroma.y).squareRoot()
        u.keyNormal = len > 1e-4 ? chroma / len : SIMD2(0, 0)   // 键色是灰：没有方向，不做溢色抑制
        u.keyRange = SIMD2(Float(min(max(k.tolerance, 0), 1)) * 0.5, Float(min(max(k.softness, 0), 1)) * 0.25)
        u.keySpill = Float(min(max(k.spillSuppression, 0), 1))
    }
}
