// 多画面里的名字：预渲染成纹理，渲染线程只贴图（"文字用预渲染 atlas"）。名字只在这里画一处（显示视图只贴多画面纹理，不另画）。
//
// 一套标签 = 一张 texture2d_array：最多 64 个输入槽（= 多画面布局表的格数上限）+ 末尾 "PGM" / "PVW" 两个固定切片。
// 槽按输入编号分配（`numbers[槽] = 编号`），只给多画面里看得见的输入（布局表的输入格，去重，按格子顺序）；已有槽的输入留在原槽，
// 改名只重画一个切片。W3-B 时切片下标就是输入编号、切片数 = 输入表容量，编号大的节目会把纹理撑大；W3-B2 改成按槽分配、封顶 64（交付 3）。
// 文字在非实时线程用 CoreText 画进 CPU 缓冲再 replace 进纹理；渲染线程按编号线性查槽（≤ 64），只贴图、零分配、不碰 CoreText。
//
// 两套交替（实时路径，LabelRenderer）：标签线程在渲染线程不用的那套上画好，交给渲染线程；渲染线程在下一帧开头接手。
// 交接用一个原子字：`待接手(套)` 或 `已接手(套, 帧号)`，渲染线程用一次比较交换把前者换成后者，标签线程用一次交换收回——
// 同一套不会既被接手又被收回，接手的帧号和套号一起可见。标签线程要写的那套若在接手之前的帧里用过，先等那些帧在 GPU 上完成。
// W3-B 时标签线程醒来先睡 20 ms 攒变化、再等"当时已提交的所有帧"完成，改名要两三帧才出来；现在画完就交，改名的下一帧就是新名字。
// 不用字形 atlas 拼字的原因：输入名可以是中文，字形集合无法预先枚举；整条标签预渲染同样满足"渲染线程零分配、不碰 CoreText"。
@preconcurrency import Metal
import CoreGraphics
import CoreText
import Foundation
import Synchronization
import SwitcherContracts

/// 一套标签切片：inputSlots 个输入槽（0…inputSlots−1）+ 末尾 2 个固定切片 "PGM" / "PVW"（多画面的节目 / 预监格用）。
final class LabelSet: @unchecked Sendable {
    static let width = 512
    static let height = 48
    /// 输入槽的上限：多画面最多 64 格，看得见的输入不会更多。
    static let maxInputSlots = MultiviewLayoutTable.capacity
    /// 末尾固定切片数（PGM、PVW）。
    static let extraSlices = 2
    let texture: any MTLTexture
    /// 输入槽数（≤ 64）。
    let inputSlots: Int
    /// 槽 → 输入编号（0 = 空）。渲染线程读；标签线程只在渲染线程不用这套时写。
    var numbers: [Int32]
    /// 每个切片当前画的文字（"" = 空白），末尾两个是 "PGM" / "PVW"。
    var texts: [String]

    /// inputSlots 按需要给（实时路径 = 输入表容量），超过 64 按 64 建。
    init(device: any MTLDevice, inputSlots requested: Int) throws {
        inputSlots = min(max(1, requested), LabelSet.maxInputSlots)
        let total = inputSlots + LabelSet.extraSlices
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
        numbers = Array(repeating: 0, count: inputSlots)
        texts = Array(repeating: "", count: total)
    }

    /// 切片总数（含末尾两个）。
    var slices: Int { texts.count }
    /// "PGM" 的切片。
    var programSlice: Int { inputSlots }
    /// "PVW" 的切片。
    var previewSlice: Int { inputSlots + 1 }

    /// 输入 n 的切片；没有槽（看不见 / 状态里没有这一路）为 nil。线性查找（≤ 64），渲染线程每格一次，零分配。
    @inline(__always)
    func slice(forInput n: Int) -> Int? {
        guard n > 0 else { return nil }
        let key = Int32(truncatingIfNeeded: n)
        var i = 0
        while i < inputSlots {
            if numbers[i] == key { return i }
            i += 1
        }
        return nil
    }
}

/// 把文字画进 BGRA 预乘缓冲并写入切片；算一套标签该是什么样。非实时线程用。
enum LabelPainter {
    /// 字号（像素，标签高 48）。
    static let fontSize: CGFloat = 30

    /// 画一条标签：左侧留边，白字，55% 黑底条。
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

    /// 一套标签该是什么样：每个输入槽放哪路、每个切片什么文字（含末尾 PGM / PVW）。
    struct Contents: Equatable {
        var numbers: [Int32]
        var texts: [String]
    }

    /// 状态 + 按这个状态解析好的布局表 → 这套标签该是什么样。
    /// 看得见的输入 = 布局表里的输入格（去重、按格子顺序、状态里有这一路的才算）；`keeping` 里已有槽的输入留在原槽，
    /// 新出现的按顺序占空槽，槽满了的不画名字（布局表最多 64 格，槽也是 64，实际不会满）。
    static func contents(for state: MixerState, layout: MultiviewLayoutTable, inputSlots: Int, keeping previous: [Int32]?) -> Contents {
        var visible: [Int] = []
        var wanted = Set<Int>()
        for i in 0..<layout.cellCount where layout.cells[i].kind == .input {
            let n = Int(layout.cells[i].input)
            if n > 0, !wanted.contains(n), CompositorPasses.inputConfig(n, in: state) != nil {
                wanted.insert(n)
                visible.append(n)
            }
        }
        var numbers = [Int32](repeating: 0, count: inputSlots)
        var placed = Set<Int>()
        if let previous {
            for k in 0..<min(inputSlots, previous.count) where wanted.contains(Int(previous[k])) && !placed.contains(Int(previous[k])) {
                numbers[k] = previous[k]
                placed.insert(Int(previous[k]))
            }
        }
        var free = 0
        for n in visible where !placed.contains(n) {
            while free < inputSlots && numbers[free] != 0 { free += 1 }
            guard free < inputSlots else { break }
            numbers[free] = Int32(n)
            placed.insert(n)
        }
        var texts = [String](repeating: "", count: inputSlots + LabelSet.extraSlices)
        for k in 0..<inputSlots where numbers[k] != 0 {
            if let config = CompositorPasses.inputConfig(Int(numbers[k]), in: state) { texts[k] = labelText(for: config) }
        }
        texts[inputSlots] = "PGM"
        texts[inputSlots + 1] = "PVW"
        return Contents(numbers: numbers, texts: texts)
    }

    /// 把一套标签画成 contents：只重画文字变了的切片，槽表整体换。
    static func apply(_ contents: Contents, to set: LabelSet, scratch: UnsafeMutableRawPointer) {
        for s in 0..<set.slices where set.texts[s] != contents.texts[s] {
            paint(contents.texts[s], into: set, slice: s, scratch: scratch)
        }
        set.numbers = contents.numbers
    }

    /// 同步画好（离线路径；布局表已按这个状态解析过）。沿用这套现有的槽。
    static func update(_ set: LabelSet, from state: MixerState, layout: MultiviewLayoutTable, scratch: UnsafeMutableRawPointer) {
        apply(contents(for: state, layout: layout, inputSlots: set.inputSlots, keeping: set.numbers), to: set, scratch: scratch)
    }
}

/// 两套标签 + 标签线程。实时路径用。
final class LabelRenderer: @unchecked Sendable {
    private let sets: [LabelSet]
    /// 渲染线程这一帧用哪套（只有渲染线程读写）。
    private var active = 0

    /// 交接字：0 = 空；`pendingFlag | 套` = 标签线程画好、等渲染线程接手；`adoptedFlag | 帧号 << 2 | 套` = 渲染线程在那一帧接手了。
    private let handoff = Atomic<UInt64>(0)
    private static let pendingFlag: UInt64 = 1 << 63
    private static let adoptedFlag: UInt64 = 1 << 62
    private static let frameMask: UInt64 = (1 << 60) - 1

    /// 标签线程交出去的次数（测试 / 报告看）。
    let publishedCount = Atomic<Int>(0)
    /// 最近一次交出去的 host time（ticks；0 = 还没有）。
    let lastPublishTicks = Atomic<UInt64>(0)

    private let lock = NSLock()
    private var pendingSnapshot: MixerSnapshot?
    private var lastSeenSequence: UInt64 = .max
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stopped = Atomic<Bool>(false)
    private var thread: Thread?
    private let scratch: UnsafeMutableRawPointer
    /// 由 MetalRenderer 提供：已完成的帧数（等在途帧完成用）。
    private let completedFrames: () -> UInt64

    // 以下只有标签线程碰
    private let workerLayout = MultiviewLayoutTable()
    /// 标签线程所知的渲染线程在用的那套，及它被接手时的帧号（这之前的帧用的是另一套）。
    private var workerActive = 0
    private var workerFence: UInt64 = 0

    init(device: any MTLDevice, inputSlots: Int, completedFrames: @escaping () -> UInt64) throws {
        sets = [try LabelSet(device: device, inputSlots: inputSlots), try LabelSet(device: device, inputSlots: inputSlots)]
        scratch = UnsafeMutableRawPointer.allocate(byteCount: LabelSet.width * LabelSet.height * 4, alignment: 16)
        self.completedFrames = completedFrames
    }

    deinit { scratch.deallocate() }

    /// 渲染线程每帧调：快照的 sequence 变了（有命令生效过）才交给标签线程。
    /// 不比对象标识：引擎可能每拍发布一个新快照对象（tick 变了），那样标签线程会每拍空转。零分配；锁只在变了时拿一次。
    func noteSnapshot(_ snapshot: MixerSnapshot) {
        if snapshot.sequence == lastSeenSequence { return }
        lastSeenSequence = snapshot.sequence
        lock.lock()
        pendingSnapshot = snapshot
        lock.unlock()
        wake.signal()
    }

    /// 渲染线程每帧开头调（frame = 这一帧的序号）：标签线程画好了新的一套就接手，返回这一帧用的那套。
    /// 一次原子读；有新的时再一次比较交换（把"待接手"换成"在这一帧接手"）。零分配、不等、不锁。
    @inline(__always)
    func acquire(frame: UInt64) -> LabelSet {
        let v = handoff.load(ordering: .relaxed)
        if v & LabelRenderer.pendingFlag != 0 {
            let set = Int(v & 3)
            let adopted = LabelRenderer.adoptedFlag | ((frame & LabelRenderer.frameMask) << 2) | UInt64(set)
            if handoff.compareExchange(expected: v, desired: adopted, ordering: .acquiringAndReleasing).exchanged {
                active = set
            }
        }
        return sets[active]
    }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "switcher.render.labels"
        t.qualityOfService = .userInitiated   // 改名的下一帧就要用上：别掉到能效核上排队
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
            lock.lock()
            let snap = pendingSnapshot
            pendingSnapshot = nil
            lock.unlock()
            guard let snap else { continue }
            update(from: snap)
        }
    }

    /// 标签线程：按快照画好另一套并交出去（名字没变就什么都不做）。
    private func update(from snap: MixerSnapshot) {
        // 先收回交接字：上次交出去还没被接手的那套收回来重画（它画好之后没有帧用过）；已经被接手的，记下渲染线程现在用哪套、从哪一帧起用
        let v = handoff.exchange(0, ordering: .acquiringAndReleasing)
        let tookBack = v & LabelRenderer.pendingFlag != 0
        let target: Int
        if tookBack {
            target = Int(v & 3)
        } else {
            if v & LabelRenderer.adoptedFlag != 0 {
                workerActive = Int(v & 3)
                workerFence = (v >> 2) & LabelRenderer.frameMask
            }
            target = 1 - workerActive
        }
        workerLayout.parse(state: snap.state, width: 1920, height: 1080)   // 只要"哪些格子放哪路"，像素尺寸无所谓
        let wanted = LabelPainter.contents(for: snap.state, layout: workerLayout, inputSlots: sets[workerActive].inputSlots,
                                           keeping: sets[workerActive].numbers)
        // 渲染线程在用的那套已经是这样了（例如只切了 PGM）：不重画、不交接（收回来的那套留着下次画）
        if wanted.numbers == sets[workerActive].numbers && wanted.texts == sets[workerActive].texts { return }
        if !tookBack {
            // 要写的另一套在渲染线程接手现在这套之前的帧里用过：等那些帧在 GPU 上完成（一般早就完成了；最多等 2 s，防 GPU 卡死时标签线程也卡死）
            var spins = 0
            while completedFrames() < workerFence && !stopped.load(ordering: .acquiring) && spins < 2000 {
                Thread.sleep(forTimeInterval: 0.001)
                spins += 1
            }
        }
        LabelPainter.apply(wanted, to: sets[target], scratch: scratch)
        handoff.store(LabelRenderer.pendingFlag | UInt64(target), ordering: .releasing)
        lastPublishTicks.store(HostClock.now().ticks, ordering: .relaxed)
        publishedCount.wrappingAdd(1, ordering: .releasing)
    }
}
