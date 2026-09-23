@preconcurrency import Metal
import CoreText
import CoreVideo
import Foundation
import SwitcherContracts

/// Aux 的帧来源：组装方按输入编号开一个只给这个窗口读的帧槽（App 里 = `InputRuntime.openBranch` → `InputFrameTee.addBranch`），
/// 窗口换输入 / 关掉 / 那路输入没了时还回去（`InputRuntime.releaseBranch`）。
/// 读法是契约的读入口 `FrameSlot.latest(atOrBefore:)`：不走引擎的 `latest(forTick:)`，不碰主槽，也不动到达余量的统计（G4 裁定）。
public struct AuxFrameTap {
    /// 给输入 n 开一个分支帧槽；这路不在 / 分支用完（每路 4 个，ISO 与 Aux 共用）返回 nil，窗口画占位，下次快照变了再试。
    public var open: @MainActor (_ input: Int) -> (any FrameSlot)?
    /// 还回去。
    public var close: @MainActor (_ input: Int, _ slot: any FrameSlot) -> Void

    public init(open: @escaping @MainActor (_ input: Int) -> (any FrameSlot)?,
                close: @escaping @MainActor (_ input: Int, _ slot: any FrameSlot) -> Void) {
        self.open = open
        self.close = close
    }
}

/// Aux（外部显示选"输入 n"）的画法：每次显示刷新从帧槽取该路最新帧，CVMetalTextureCache 零拷贝包成纹理，按渲染器同一套系数全幅画进目标
/// （窗口里是 drawable，测试里是离屏纹理；抠像 / 裁切 / 变换在 Aux 上不生效 = 原始画面）。没有帧 / 无信号画占位（与多画面格子同一套文案）。
///
/// 线程：主线程（窗口的 display link 回调）。主线程只做取帧、包纹理（约 2 µs，探针）、编码一次绘制；像素换算在 GPU，
/// 占位文字在后台队列栅格化。
///
/// 计数（提案 013，`Stats.display[]`）：`presentedFrames` = 画出去的输入帧（占位不算）；`droppedFrames` = 没赶上显示刷新的帧 =
/// 两次刷新之间在帧槽里被挤掉 / 跳过的（FrameSlotStats.dropped 的增量）+ 取了却没画出去（拿不到 drawable）又被新帧顶掉的。
/// 不在呈现的时段（窗口收起 / 被遮住 / 换输入 / 占位期间）不记：`invalidate()` 断开，下一次只取基线。
@MainActor
public final class AuxInputPresenter {
    /// 这次刷新画什么。
    public enum Draw {
        /// 不用画（没有新帧，或占位已经画过）。
        case nothing
        /// 画这一帧。
        case frame(Frame)
        /// 画占位。
        case placeholder
    }

    /// 这一路现在的样子。
    public enum Signal: Hashable, Sendable {
        /// 没绑输入（窗口的源不是输入）。
        case detached
        /// 组装方没给帧槽（没接线 / 分支用完 / 那路不在）。
        case noSlot
        /// 帧槽里还没有过帧。
        case waitingForFrames
        case live
        /// 输入报无信号，或帧断了超过 3 个帧间隔（与输入的无信号看门狗同一口径，只在组装方没给运行状态时用）。
        case noSignal
        /// 输入报错（文案原样）。
        case error(String)
        /// 像素格式不是 NV12 / BGRA / UYVY，或不是 IOSurface 背后。
        case unsupportedFormat(UInt32)
    }

    /// "无信号"的默认文案（与 App 多画面缩略格子的 input.noSignal 同字；App 按本地化表换 `noSignalText`）。
    public static let defaultNoSignalText = "无信号"
    /// 帧断了多少个帧间隔算无信号（输入的 NoSignalWatchdog 同一个 N）。
    public static let staleFrameMultiplier = 3
    /// 帧间隔很短时的下限（60 fps × 3 = 50 ms）。
    public static let minimumStaleness = HostDuration(milliseconds: 50)

    public let device: any MTLDevice
    public private(set) var input: Int?
    public private(set) var inputName = ""
    public private(set) var signal: Signal = .detached
    /// 组装方给的该路运行状态（App：InputRuntime.runtimeState）；nil = 只看帧新不新。
    public var inputState: InputState?
    /// 无信号的文案。
    public var noSignalText = AuxInputPresenter.defaultNoSignalText

    public private(set) var presentedFrames: UInt64 = 0
    public private(set) var droppedFrames: UInt64 = 0
    /// 画过几次占位（测试 / 诊断）。
    public private(set) var placeholderPresentations: UInt64 = 0
    /// 纹理缓存是给哪一路建的（按输入编号预建、换输入时重建）。
    public private(set) var textureCacheInput: Int?
    /// 纹理缓存重建过几次。
    public private(set) var textureCacheGeneration = 0

    private var slot: (any FrameSlot)?
    private var textureCache: CVMetalTextureCache?
    /// 上一次画出去的帧（序号 + pts）；nil = 下一帧无论新旧都画（占位之后 / 断开之后）。
    private var lastDrawn: (sequence: UInt64, pts: UInt64)?
    /// 上一次刷新时帧槽的 dropped；nil = 断开，下一次只取基线。
    private var lastSlotDropped: UInt64?
    /// 取了却没画出去的那一帧的序号。
    private var unpresentedSequence: UInt64?
    /// 已经画出去的占位（哪一份文字、带没带字）。
    private var placeholderShown: (key: PlaceholderKey, withText: Bool)?
    private var labels: PlaceholderTextures?
    private var labelsInFlight: PlaceholderKey?
    private var presentsSinceFlush = 0

    public init(device: any MTLDevice) {
        self.device = device
    }

    // MARK: 绑定

    /// 绑到输入 n：换了输入就重建纹理缓存（新输入的 IOSurface 与格式都不同）；帧槽换了就断开记账。同一路同一个帧槽只更新名字。
    public func attach(input number: Int, name: String, slot newSlot: (any FrameSlot)?) {
        inputName = name
        if input != number || textureCache == nil {
            input = number
            rebuildTextureCache()
        }
        if (newSlot as AnyObject?) !== (slot as AnyObject?) {
            slot = newSlot
            invalidate()
            signal = newSlot == nil ? .noSlot : .waitingForFrames
        }
    }

    /// 解绑（窗口换成 PGM / PVW / 多画面，或关掉）。
    public func detach() {
        input = nil
        slot = nil
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        textureCache = nil
        textureCacheInput = nil
        signal = .detached
        invalidate()
    }

    /// 断开连续呈现（窗口收起 / 被遮住 / 尺寸变了）：下一次重画当前内容，丢帧记账重新取基线。
    public func invalidate() {
        lastDrawn = nil
        lastSlotDropped = nil
        unpresentedSequence = nil
        placeholderShown = nil
    }

    private func rebuildTextureCache() {
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        textureCacheInput = input
        textureCacheGeneration += 1
        presentsSinceFlush = 0
    }

    // MARK: 每次刷新

    /// 这次刷新画什么（取帧在这里：契约读入口，上限 = 此刻）。
    public func nextDraw(now: HostTime, targetWidth: Int, targetHeight: Int) -> Draw {
        guard input != nil else {
            signal = .detached
            return .nothing
        }
        guard let slot else {
            signal = .noSlot
            return placeholder(width: targetWidth, height: targetHeight)
        }
        let latest = slot.latest(atOrBefore: now)
        let slotDropped = slot.stats.dropped
        guard let frame = latest else {
            signal = .waitingForFrames
            return placeholder(width: targetWidth, height: targetHeight)
        }
        switch inputState {
        case .noSignal?:
            signal = .noSignal
            return placeholder(width: targetWidth, height: targetHeight)
        case .error(let message)?:
            signal = .error(message)
            return placeholder(width: targetWidth, height: targetHeight)
        case .live?:
            break   // 组装方说活着：帧旧了也照画（冻帧，与多画面格子一样）
        case nil:
            if (now - frame.ingressTime).ticks > Self.staleness(of: frame).ticks {
                signal = .noSignal
                return placeholder(width: targetWidth, height: targetHeight)
            }
        }
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        guard Self.isSupported(format), CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil else {
            signal = .unsupportedFormat(format)
            return placeholder(width: targetWidth, height: targetHeight)
        }
        signal = .live
        placeholderShown = nil
        if let last = lastSlotDropped, slotDropped >= last { droppedFrames &+= slotDropped - last }
        lastSlotDropped = slotDropped
        if let last = lastDrawn, last.sequence == frame.sequence, last.pts == frame.pts.ticks { return .nothing }
        return .frame(frame)
    }

    /// 编码进目标纹理（BGRA8，渲染目标）。画不了（管线没编好 / 包不成纹理）返回 false。
    public func encode(_ draw: Draw, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> Bool {
        guard let pipeline = AuxPipeline.cached(for: device) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        switch draw {
        case .nothing:
            return false
        case .frame(let frame):
            guard let prepared = frameTextures(frame, targetWidth: target.width, targetHeight: target.height),
                  let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            let (uniforms, textures) = prepared
            enc.label = "aux.frame"
            enc.setRenderPipelineState(pipeline.state)
            encodeQuad(enc, uniforms: uniforms, tex0: textures.tex0, tex1: textures.tex1)
            enc.endEncoding()
            // CVMetalTexture 要活到 GPU 读完（CVMetalTextureCache 的规矩）；帧（像素缓冲）同理
            let keep = KeepAlive(textures.wrappers, frame.pixelBuffer)
            commandBuffer.addCompletedHandler { _ in keep.release() }
            return true
        case .placeholder:
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            enc.label = "aux.placeholder"
            let key = PlaceholderKey(lines: placeholderLines, width: target.width, height: target.height)
            if let labels, labels.key == key {
                enc.setRenderPipelineState(pipeline.state)
                let layout = AuxPlaceholderLayout(width: target.width, height: target.height)
                if let t = labels.center {
                    let dest = layout.centerRect(textWidth: t.width, textHeight: t.height)
                    encodeQuad(enc, uniforms: AuxUniforms.fit(sourceWidth: t.width, sourceHeight: t.height, dest: dest,
                                                              targetWidth: target.width, targetHeight: target.height), tex0: t, tex1: t)
                }
                if let t = labels.label {
                    let dest = layout.labelRect(textWidth: t.width, textHeight: t.height)
                    encodeQuad(enc, uniforms: AuxUniforms.fit(sourceWidth: t.width, sourceHeight: t.height, dest: dest,
                                                              targetWidth: target.width, targetHeight: target.height), tex0: t, tex1: t)
                }
            }
            enc.endEncoding()
            return true
        }
    }

    /// 这一帧 / 占位画出去了（present 已提交）。
    public func didPresent(_ draw: Draw) {
        switch draw {
        case .nothing:
            break
        case .frame(let frame):
            presentedFrames &+= 1
            if let u = unpresentedSequence, u != frame.sequence, lastSlotDropped != nil { droppedFrames &+= 1 }
            unpresentedSequence = nil
            lastDrawn = (frame.sequence, frame.pts.ticks)
            presentsSinceFlush += 1
            if presentsSinceFlush >= 120, let textureCache {   // 两秒左右清一次缓存里不再用的纹理
                CVMetalTextureCacheFlush(textureCache, 0)
                presentsSinceFlush = 0
            }
        case .placeholder:
            placeholderPresentations &+= 1
            if let key = currentPlaceholderKey { placeholderShown = (key, labels?.key == key) }
        }
    }

    /// 取了但没画出去（拿不到 drawable / 编码失败）：下次刷新如果换成了新帧，这一帧就算丢了。
    public func didNotPresent(_ draw: Draw) {
        if case .frame(let frame) = draw { unpresentedSequence = frame.sequence }
    }

    // MARK: 占位

    /// 占位的两行字：中间 = 无信号（或输入报的错误文案），左下 = 名字条（与多画面格子同一格式）。
    public var placeholderLines: (center: String, label: String) {
        let center: String
        if case .error(let message)? = inputState { center = message } else { center = noSignalText }
        return (center, input.map { Self.label(number: $0, name: inputName) } ?? "")
    }

    /// 多画面格子名字条的格式（SwitcherRender LabelRenderer.labelText）："编号  名字"，没名字只写编号。
    public nonisolated static func label(number: Int, name: String) -> String {
        name.isEmpty ? "\(number)" : "\(number)  \(name)"
    }

    /// 这个尺寸的占位文字栅格化好了没有。
    public func placeholderReady(width: Int, height: Int) -> Bool {
        labels?.key == PlaceholderKey(lines: placeholderLines, width: width, height: height)
    }

    private var currentPlaceholderSize: (width: Int, height: Int)?
    private var currentPlaceholderKey: PlaceholderKey? {
        currentPlaceholderSize.map { PlaceholderKey(lines: placeholderLines, width: $0.width, height: $0.height) }
    }

    /// 进入 / 停在占位：断开帧的记账；文字没好先画黑底，好了再补画一次；画过带字的就不再重画。
    private func placeholder(width: Int, height: Int) -> Draw {
        lastDrawn = nil
        lastSlotDropped = nil
        unpresentedSequence = nil
        currentPlaceholderSize = (width, height)
        let key = PlaceholderKey(lines: placeholderLines, width: width, height: height)
        let ready = labels?.key == key
        if !ready { requestLabels(key) }
        if let shown = placeholderShown, shown.key == key, shown.withText || !ready { return .nothing }
        return .placeholder
    }

    private func requestLabels(_ key: PlaceholderKey) {
        guard labelsInFlight != key else { return }
        labelsInFlight = key
        let device = UncheckedBox(device)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let layout = AuxPlaceholderLayout(width: key.width, height: key.height)
            let center = key.center.isEmpty ? nil : AuxPlaceholderText.texture(key.center, pixelHeight: layout.centerTextHeight, device: device.value)
            let label = key.label.isEmpty ? nil : AuxPlaceholderText.texture(key.label, pixelHeight: layout.labelTextHeight, device: device.value)
            let result = UncheckedBox(PlaceholderTextures(key: key, center: center, label: label))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.labelsArrived(result.value) }
            }
        }
    }

    private func labelsArrived(_ textures: PlaceholderTextures) {
        if labelsInFlight == textures.key { labelsInFlight = nil }
        labels = textures
    }

    // MARK: 纹理

    static func isSupported(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8: true
        default: false
        }
    }

    static func staleness(of frame: Frame) -> HostDuration {
        guard frame.duration.ticks > 0 else { return HostDuration(milliseconds: 250) }
        let n = frame.duration * staleFrameMultiplier
        return n.ticks > minimumStaleness.ticks ? n : minimumStaleness
    }

    /// 与渲染器同一个映射（CompositorPasses.matrixID）。
    static func matrixID(_ m: YCbCrMatrix) -> Int32 {
        switch m {
        case .bt709: 0
        case .bt601: 1
        case .bt2020: 2
        }
    }

    private struct FrameTextures {
        var tex0: any MTLTexture
        var tex1: any MTLTexture
        var wrappers: [CVMetalTexture]
    }

    /// 帧的平面包成纹理 + 着色器参数。色彩参数取法与渲染器相同：NV12 的范围看像素格式（'420f' = full），UYVY 看 ColorInfo.range，矩阵看 ColorInfo.matrix。
    private func frameTextures(_ frame: Frame, targetWidth: Int, targetHeight: Int) -> (AuxUniforms, FrameTextures)? {
        guard let cache = textureCache else { return nil }
        let pb = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        func wrap(_ format: MTLPixelFormat, plane: Int, _ w: Int, _ h: Int) -> CVMetalTexture? {
            var t: CVMetalTexture?
            let st = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &t)
            return st == kCVReturnSuccess ? t : nil
        }
        var u = AuxUniforms.fit(sourceWidth: width, sourceHeight: height, dest: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                                targetWidth: targetWidth, targetHeight: targetHeight)
        u.matrix = Self.matrixID(frame.color.matrix)
        let type = CVPixelBufferGetPixelFormatType(pb)
        switch type {
        case kCVPixelFormatType_32BGRA:
            guard let w0 = wrap(.bgra8Unorm, plane: 0, width, height), let t0 = CVMetalTextureGetTexture(w0) else { return nil }
            u.format = AuxUniforms.Format.bgra.rawValue
            u.fullRange = 1
            return (u, FrameTextures(tex0: t0, tex1: t0, wrappers: [w0]))
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
            guard let wy = wrap(.r8Unorm, plane: 0, width, height), let wc = wrap(.rg8Unorm, plane: 1, cw, ch),
                  let ty = CVMetalTextureGetTexture(wy), let tc = CVMetalTextureGetTexture(wc) else { return nil }
            u.format = AuxUniforms.Format.nv12.rawValue
            u.fullRange = type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
            u.chromaSize = SIMD2(Float(cw), Float(ch))
            return (u, FrameTextures(tex0: ty, tex1: tc, wrappers: [wy, wc]))
        case kCVPixelFormatType_422YpCbCr8:
            guard let w0 = wrap(.bgrg422, plane: 0, width, height), let t0 = CVMetalTextureGetTexture(w0) else { return nil }
            u.format = AuxUniforms.Format.uyvy.rawValue
            u.fullRange = frame.color.range == .full ? 1 : 0
            u.chromaSize = SIMD2(Float(width / 2), Float(height))
            return (u, FrameTextures(tex0: t0, tex1: t0, wrappers: [w0]))
        default:
            return nil
        }
    }

    private func encodeQuad(_ enc: any MTLRenderCommandEncoder, uniforms: AuxUniforms, tex0: any MTLTexture, tex1: any MTLTexture) {
        var u = uniforms
        enc.setFragmentTexture(tex0, index: 0)
        enc.setFragmentTexture(tex1, index: 1)
        withUnsafeBytes(of: &u) { raw in
            enc.setVertexBytes(raw.baseAddress!, length: AuxUniforms.expectedStride, index: 0)
            enc.setFragmentBytes(raw.baseAddress!, length: AuxUniforms.expectedStride, index: 0)
        }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - 占位的文字与版式

struct PlaceholderKey: Hashable, Sendable {
    let center: String
    let label: String
    let width: Int
    let height: Int
    init(lines: (center: String, label: String), width: Int, height: Int) {
        center = lines.center
        label = lines.label
        self.width = width
        self.height = height
    }
}

struct PlaceholderTextures {
    let key: PlaceholderKey
    let center: (any MTLTexture)?
    let label: (any MTLTexture)?
}

/// 占位的版式：黑底，中间一行"无信号"，左下角名字条（高度与多画面格子的名字条同一上限：画面高 × 3.5%，≥ 12 px）。
struct AuxPlaceholderLayout {
    let width: Int
    let height: Int
    var centerTextHeight: Int { max(24, Int((Double(height) * 0.07).rounded())) }
    var labelTextHeight: Int { max(12, Int((Double(height) * 0.035).rounded())) }

    func centerRect(textWidth: Int, textHeight: Int) -> CGRect {
        CGRect(x: (Double(width) - Double(textWidth)) / 2, y: (Double(height) - Double(textHeight)) / 2,
               width: Double(textWidth), height: Double(textHeight))
    }

    func labelRect(textWidth: Int, textHeight: Int) -> CGRect {
        let margin = Double(textHeight) * 0.5
        return CGRect(x: margin, y: Double(height) - margin - Double(textHeight), width: Double(textWidth), height: Double(textHeight))
    }
}

/// 一行字栅格化成 BGRA8 纹理（白字黑底）。CoreText + CGBitmapContext，线程安全，在后台队列上调。
enum AuxPlaceholderText {
    static func texture(_ text: String, pixelHeight: Int, device: any MTLDevice) -> (any MTLTexture)? {
        let fontSize = CGFloat(pixelHeight) * 0.72
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = CGFloat(pixelHeight) * 0.25
        let w = max(1, Int((lineWidth + 2 * pad).rounded(.up))), h = max(1, pixelHeight)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.textPosition = CGPoint(x: pad, y: (CGFloat(h) - ascent - descent) / 2 + descent)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        texture.label = "aux.placeholder.text"
        return texture
    }
}

// MARK: - 小工具

/// 跨线程带一个非 Sendable 的值（Metal 设备 / 纹理：建好之后只读）。
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// 让 CVMetalTexture 与像素缓冲活到 GPU 读完。
final class KeepAlive: @unchecked Sendable {
    private var objects: [AnyObject]?
    init(_ textures: [CVMetalTexture], _ pixelBuffer: CVPixelBuffer) {
        objects = textures.map { $0 as AnyObject } + [pixelBuffer as AnyObject]
    }
    func release() { objects = nil }
}
