// PVW / 多画面的 NV12 输出环按需建（W3-B2 可选项；P3 报告 §5 第 1 条）。
//
// P3 为了"状态里有 enabled 且 source = preview / multiview 的输出就自动填 RenderedFrame.preview / .multiview"，在 prepare 里把两个环都建好
// （prepare 时还没有状态，渲染线程又不许分配），1080p / ringSize 8 下每个环常驻约 25 MB，没有这类输出时白占。
// 现在：`options.previewOutput` / `multiviewOutput`（强制开）照旧在 prepare 里建；否则等渲染线程第一次看到状态要它时，
// 渲染线程只置一个请求位、敲一下信号量（零分配），由后台线程（switcher.render.aux）建环、原子发布，渲染线程之后的帧拿来用。
// 请求那一帧和建好之前的一两帧这个画面不出（RenderedFrame.preview / .multiview 为 nil，契约允许），不拖 PGM。
// 建好就不拆（状态里的输出关掉之后环留着，直到下次 prepare / shutdown）；环的 NV12 纹理在建环时一起包好，渲染线程拿来就用。
//
// 为什么不在状态线程建：渲染器看不到引擎的状态线程（Renderer 协议只有 prepare / render / shutdown，快照只在 render 里递进来），
// 要在状态线程建就得改协议或让组装方另调接口；这里的后台线程是渲染器里离"状态变化"最近的地方（渲染线程看到新快照的那一帧就叫醒它）。
@preconcurrency import Metal
import Foundation
import Synchronization

final class AuxOutputRings: @unchecked Sendable {
    enum Kind: Int {
        case preview = 0, multiview = 1
    }

    private let preview = AtomicLazyReference<OutputBufferRing>()
    private let multiview = AtomicLazyReference<OutputBufferRing>()
    /// 渲染线程要过、还没建好的环（按 Kind 的位）。
    private let requested = Atomic<Int>(0)
    /// 后台线程建环的次数（测试 / 报告看）。
    let builds = Atomic<Int>(0)
    /// 建环失败的次数（建不出 CVPixelBuffer / 纹理；失败了下次请求再试）。
    let failures = Atomic<Int>(0)

    private let width: Int
    private let height: Int
    private let count: Int
    private let device: any MTLDevice
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stopped = Atomic<Bool>(false)
    private var thread: Thread?

    /// eager 里的环当场建好（prepare 的线程；强制开的输出）。其余等渲染线程要。
    init(device: any MTLDevice, width: Int, height: Int, count: Int, eager: [Kind]) throws {
        self.device = device
        self.width = width
        self.height = height
        self.count = count
        for kind in eager {
            _ = store(try OutputBufferRing(width: width, height: height, count: count, device: device), kind)
        }
    }

    /// 渲染线程每帧调：环建好了就返回；没建就请后台线程建（这一帧返回 nil）。一次原子读，第一次请求时再一次原子或 + 信号量；零分配。
    @inline(__always)
    func ring(_ kind: Kind) -> OutputBufferRing? {
        if let r = load(kind) { return r }
        let bit = 1 << kind.rawValue
        if requested.bitwiseOr(bit, ordering: .acquiringAndReleasing).oldValue & bit == 0 { wake.signal() }
        return nil
    }

    /// 建好了没有（测试 / 报告看）。
    func isBuilt(_ kind: Kind) -> Bool { load(kind) != nil }

    /// 建好的环常驻的像素字节数。
    var residentBytes: Int { (load(.preview)?.residentBytes ?? 0) + (load(.multiview)?.residentBytes ?? 0) }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "switcher.render.aux"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        stopped.store(true, ordering: .releasing)
        wake.signal()
        finished.wait()
        thread = nil
    }

    @inline(__always)
    private func load(_ kind: Kind) -> OutputBufferRing? {
        switch kind {
        case .preview: preview.load()
        case .multiview: multiview.load()
        }
    }

    private func store(_ ring: OutputBufferRing, _ kind: Kind) -> OutputBufferRing {
        switch kind {
        case .preview: preview.storeIfNil(ring)
        case .multiview: multiview.storeIfNil(ring)
        }
    }

    private func loop() {
        defer { finished.signal() }
        while !stopped.load(ordering: .acquiring) {
            wake.wait()
            if stopped.load(ordering: .acquiring) { return }
            let want = requested.load(ordering: .acquiring)
            for kind in [Kind.preview, .multiview] where want & (1 << kind.rawValue) != 0 && load(kind) == nil {
                do {
                    _ = store(try OutputBufferRing(width: width, height: height, count: count, device: device), kind)
                    builds.wrappingAdd(1, ordering: .relaxed)
                } catch {
                    failures.wrappingAdd(1, ordering: .relaxed)
                    // 清掉请求位，渲染线程下一帧会再请求一次
                    requested.bitwiseAnd(~(1 << kind.rawValue), ordering: .acquiringAndReleasing)
                }
            }
        }
    }
}
