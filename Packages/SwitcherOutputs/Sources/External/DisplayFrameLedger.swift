@preconcurrency import Metal
import SwitcherRender

/// 显示记账：夹在渲染器（`DisplayFrameSource`）与 `MetalDisplayView` 之间的转发源，数 PGM / PVW / 多画面窗口"没赶上显示刷新的帧"
/// （提案 013 的 dropped，prompt 65 的口径：引擎给了新帧但两次刷新间被覆盖）。MetalDisplayView 与渲染器都不用改。
///
/// 依据（两边的公开行为）：
/// - 渲染器每完成一帧，`DisplayFrame.version` + 1；
/// - MetalDisplayView 每次 display link 回调（可见时）恰好调一次 `latestDisplayFrame`，之后要么 blit（`presentedFrames` + 1），
///   要么因为同版本 / 限速 / 拿不到 drawable 不画。
/// 所以下一次被调时看 presentedFrames 涨没涨，就知道上一次交出去的版本画没画；相邻两次画出去的版本差 − 1 = 两次刷新之间被覆盖的帧。
/// 同一版本重画（视图换源 / 改尺寸 / 恢复可见时会重画当前版本）不算丢。
///
/// 连续性：视图暂停（窗口收起 / 被遮住 / 隐藏）期间没有回调，恢复后第一帧与暂停前最后一帧之间的版本差不是"没赶上"，不算——
/// 窗口在这些时刻调 `breakRun()`；本类自己也看 `linkCallbacks` 有没有跳号（不可见的回调不来取数）。
/// 主线程卡住（回调来不了、画面没更新）期间被覆盖的版本照算：那正是没赶上刷新。
///
/// 读数的时刻最多落后一次回调（最后交出去的那一版画没画要到下一次回调才知道），累计值单调不减。
@MainActor
public final class DisplayFrameLedger {
    /// 真正的来源（渲染器）。
    public let upstream: any DisplayFrameSource
    /// 记哪个视图的账（它的 presentedFrames / linkCallbacks）。
    public weak var view: MetalDisplayView?
    /// 累计：两次呈现之间被覆盖的版本数。
    public private(set) var droppedFrames: UInt64 = 0

    /// 本轮连续呈现里最后一次画出去的版本；nil = 断开之后还没画过。
    private var lastPresentedVersion: UInt64?
    /// 上一次交给视图的版本。
    private var handedVersion: UInt64?
    private var presentedAtHand: UInt64 = 0
    private var callbacksAtHand: UInt64 = 0
    private var breakPending = true

    public init(upstream: any DisplayFrameSource, view: MetalDisplayView?) {
        self.upstream = upstream
        self.view = view
    }

    /// 断开连续呈现（窗口收起 / 被遮住 / 换源）：下一次呈现只取基线，不和断开前比。
    public func breakRun() {
        breakPending = true
    }
}

extension DisplayFrameLedger: @preconcurrency DisplayFrameSource {
    public var displayCommandQueue: any MTLCommandQueue { upstream.displayCommandQueue }

    public func latestDisplayFrame(for target: DisplayTarget) -> DisplayFrame? {
        if let view {
            let presented = view.presentedFrames, callbacks = view.linkCallbacks
            // 1. 上一次交出去的版本画了没有（画了就是在任何断开之前画的，照常记）
            if presented != presentedAtHand, let handed = handedVersion {
                if let last = lastPresentedVersion, handed > last &+ 1 { droppedFrames &+= handed - last - 1 }
                lastPresentedVersion = handed
            }
            // 2. 断开：窗口标记过，或中间有不来取数的回调（视图当时不可见）
            if breakPending || callbacks &- callbacksAtHand > 1 {
                lastPresentedVersion = nil
                breakPending = false
            }
            presentedAtHand = presented
            callbacksAtHand = callbacks
        }
        let frame = upstream.latestDisplayFrame(for: target)
        handedVersion = frame?.version
        return frame
    }
}
