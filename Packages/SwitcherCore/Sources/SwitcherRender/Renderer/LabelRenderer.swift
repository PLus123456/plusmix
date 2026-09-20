// 多画面里的名字：预渲染成纹理，渲染线程只 blit（"文字用预渲染 atlas"）。
//
// 做法：每路输入一个切片（texture2d_array，下标 = 输入编号），文字在非实时线程用 CoreText 画进 CPU 缓冲再 replace 进纹理。
// 两套切片双缓冲：写另一套、原子发布下标，渲染线程在帧开始时读一次下标；写之前等旧那套的在途帧全部完成。
// 不用字形 atlas 拼字的原因：输入名可以是中文，字形集合无法预先枚举；整条标签预渲染同样满足"渲染线程零分配、不碰 CoreText"。
@preconcurrency import Metal
import CoreGraphics
import CoreText
import Foundation
import Synchronization
import SwitcherContracts

/// 一套标签切片：下标 = 输入编号的切片 inputSlices 个（0 号不用），末尾再加 2 个固定切片 "PGM" / "PVW"（多画面的节目 / 预监格用，W3-B）。
final class LabelSet: @unchecked Sendable {
    static let width = 512
    static let height = 48
    /// 末尾固定切片数（PGM、PVW）。
    static let extraSlices = 2
    let texture: any MTLTexture
    /// 每个切片当前画的文字（"" = 空白）。
    var texts: [String]

    init(device: any MTLDevice, inputSlices: Int) throws {
        let total = max(1, inputSlices) + LabelSet.extraSlices
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .bgra8Unorm
        d.width = LabelSet.width
        d.height = LabelSet.height
        d.arrayLength = total
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resource("建不出标签纹理数组") }
        t.label = "labels"
        texture = t
        texts = Array(repeating: "", count: total)
    }

    /// 切片总数（含末尾两个）。
    var slices: Int { texts.count }
    /// 输入编号必须 < 这个数才有切片。
    var inputSlices: Int { texts.count - LabelSet.extraSlices }
    /// "PGM" 的切片。
    static func programSlice(totalSlices: Int) -> Int { totalSlices - 2 }
    /// "PVW" 的切片。
    static func previewSlice(totalSlices: Int) -> Int { totalSlices - 1 }
    var programSlice: Int { LabelSet.programSlice(totalSlices: slices) }
    var previewSlice: Int { LabelSet.previewSlice(totalSlices: slices) }
}

/// 把文字画进 BGRA 预乘缓冲并写入切片。非实时线程用。
enum LabelPainter {
    /// 字号（像素，标签高 48）。
    static let fontSize: CGFloat = 30

    /// 画一条标签：左侧留边，白字加黑描边，透明底。
    static func paint(_ text: String, into set: LabelSet, slice: Int, scratch: UnsafeMutableRawPointer) {
        let w = LabelSet.width, h = LabelSet.height, bpr = w * 4
        memset(scratch, 0, bpr * h)
        guard !text.isEmpty else {
            set.texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: slice,
                                withBytes: scratch, bytesPerRow: bpr, bytesPerImage: bpr * h)
            set.texts[slice] = text
            return
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: scratch, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: space, bitmapInfo: info) else { return }
        // 半透明黑底条，读起来不受画面干扰
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(str)
        // 超宽就截断
        let truncated = CTLineCreateTruncatedLine(line, Double(w - 16), .end, nil) ?? line
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(truncated, &ascent, &descent, nil)
        // CGBitmapContext 内存第 0 行就是图像顶行（CG 坐标原点在左下只是坐标系的事），与纹理的行序一致，不用翻转
        ctx.textPosition = CGPoint(x: 12, y: (CGFloat(h) - ascent - descent) / 2 + descent)
        ctx.setTextDrawingMode(.fill)
        CTLineDraw(truncated, ctx)
        set.texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: slice,
                            withBytes: scratch, bytesPerRow: bpr, bytesPerImage: bpr * h)
        set.texts[slice] = text
    }

    /// 多画面格子里显示的文字。
    static func labelText(for input: InputConfig) -> String {
        input.name.isEmpty ? "\(input.number)" : "\(input.number)  \(input.name)"
    }

    /// 状态里每个切片该显示的文字（slices = 总数，含末尾的 PGM / PVW 两个）。
    static func wantedTexts(for state: MixerState, slices: Int) -> [String] {
        var wanted = Array(repeating: "", count: slices)
        let inputSlices = slices - LabelSet.extraSlices
        for input in state.inputs where input.number > 0 && input.number < inputSlices {
            wanted[input.number] = labelText(for: input)
        }
        if slices >= 2 {
            wanted[LabelSet.programSlice(totalSlices: slices)] = "PGM"
            wanted[LabelSet.previewSlice(totalSlices: slices)] = "PVW"
        }
        return wanted
    }

    /// 这套切片和状态里的名字是否有出入。
    static func needsUpdate(_ set: LabelSet, from state: MixerState) -> Bool {
        wantedTexts(for: state, slices: set.slices) != set.texts
    }

    /// 把状态里每路输入的名字画进这套切片（只画变了的）。
    static func update(_ set: LabelSet, from state: MixerState, scratch: UnsafeMutableRawPointer) {
        let wanted = wantedTexts(for: state, slices: set.slices)
        for slice in 0..<set.slices where wanted[slice] != set.texts[slice] {
            paint(wanted[slice], into: set, slice: slice, scratch: scratch)
        }
    }
}

/// 双缓冲的标签集合 + 后台线程。实时路径用。
final class LabelRenderer: @unchecked Sendable {
    private let sets: [LabelSet]
    /// 渲染线程读：当前该用哪套。
    let published = Atomic<Int>(0)
    private let lock = NSLock()
    private var pendingSnapshot: MixerSnapshot?
    private var lastSeenSequence: UInt64 = .max
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stopped = Atomic<Bool>(false)
    private var thread: Thread?
    private let scratch: UnsafeMutableRawPointer
    /// 由 MetalRenderer 提供：已提交 / 已完成的帧数（等在途帧完成用）。
    private let submittedFrames: () -> UInt64
    private let completedFrames: () -> UInt64

    init(device: any MTLDevice, inputSlices: Int, submittedFrames: @escaping () -> UInt64, completedFrames: @escaping () -> UInt64) throws {
        sets = [try LabelSet(device: device, inputSlices: inputSlices), try LabelSet(device: device, inputSlices: inputSlices)]
        scratch = UnsafeMutableRawPointer.allocate(byteCount: LabelSet.width * LabelSet.height * 4, alignment: 16)
        self.submittedFrames = submittedFrames
        self.completedFrames = completedFrames
    }

    deinit { scratch.deallocate() }

    /// 渲染线程每帧调：快照的 sequence 变了（有命令生效过）才交给后台线程。
    /// 不比对象标识：引擎可能每拍发布一个新快照对象（tick 变了），那样标签线程会每拍空转。零分配；锁只在变了时拿一次。
    func noteSnapshot(_ snapshot: MixerSnapshot) {
        if snapshot.sequence == lastSeenSequence { return }
        lastSeenSequence = snapshot.sequence
        lock.lock()
        pendingSnapshot = snapshot
        lock.unlock()
        wake.signal()
    }

    /// 渲染线程用：当前发布的那套。
    var current: LabelSet { sets[published.load(ordering: .acquiring)] }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "switcher.render.labels"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// 停线程并等它退出（之后再释放 MetalRenderer 才安全：闭包里引用着它的计数器）。
    func stop() {
        guard thread != nil else { return }
        stopped.store(true, ordering: .releasing)
        wake.signal()
        finished.wait()
        thread = nil
    }

    private func loop() {
        defer { finished.signal() }
        while !stopped.load(ordering: .acquiring) {
            wake.wait()
            if stopped.load(ordering: .acquiring) { return }
            // 合并短时间内的多次变化
            Thread.sleep(forTimeInterval: 0.02)
            lock.lock()
            let snap = pendingSnapshot
            pendingSnapshot = nil
            lock.unlock()
            guard let snap else { continue }
            let active = published.load(ordering: .acquiring)
            // 名字没变就不翻缓冲
            if !LabelPainter.needsUpdate(sets[active], from: snap.state) { continue }
            let next = 1 - active
            // 另一套可能还被在途帧读着：等它们完成
            let fence = submittedFrames()
            var spins = 0
            while completedFrames() < fence && !stopped.load(ordering: .acquiring) && spins < 1000 {
                Thread.sleep(forTimeInterval: 0.002)
                spins += 1
            }
            // 先把当前这套的内容同步过去（只画差异），再画新名字
            let target = sets[next], source = sets[active]
            for s in 0..<target.slices where target.texts[s] != source.texts[s] {
                LabelPainter.paint(source.texts[s], into: target, slice: s, scratch: scratch)
            }
            LabelPainter.update(target, from: snap.state, scratch: scratch)
            published.store(next, ordering: .releasing)
        }
    }
}
