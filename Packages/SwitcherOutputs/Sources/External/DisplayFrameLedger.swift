@preconcurrency import Metal
import SwitcherRender

/// 显示记账：夹在渲染器（`DisplayFrameSource`）与 `MetalDisplayView` 之间的转发源，数 PGM / PVW / 多画面窗口"没赶上显示刷新的帧"
/// （提案 013 的 dropped，prompt 65 的口径：引擎给了新帧但两次刷新间被覆盖）与"不在呈现时没送出去的帧"（提案 018 的 undelivered）。
/// MetalDisplayView 与渲染器都不用改。
///
/// 依据（两边的公开行为）：
/// - 渲染器每完成一帧，`DisplayFrame.version` + 1（PGM / PVW / 多画面同一个计数）；
/// - MetalDisplayView 每次 display link 回调（可见时）恰好调一次 `latestDisplayFrame`，之后要么 blit（`presentedFrames` + 1），
///   要么因为同版本 / 限速 / 拿不到 drawable 不画。
/// 所以下一次被调时看 presentedFrames 涨没涨，就知道上一次交出去的版本画没画；相邻两次画出去的版本差 − 1 = 两次刷新之间被覆盖的帧（dropped）。
/// 同一版本重画（视图换源 / 改尺寸 / 恢复可见时会重画当前版本）不算丢。
///
/// 断开：视图暂停（窗口收起 / 被遮住 / 隐藏）期间没有回调，恢复后第一帧与暂停前最后一帧之间的版本差不是"没赶上"，不记 dropped，
/// 记 undelivered——窗口在这些时刻调 `breakRun(countingUndelivered: true)`；本类自己也看 `linkCallbacks` 有没有跳号（不可见的回调不来取数），
/// 跳号那段同样记 undelivered。换源（窗口改去画 Aux 又换回来）调 `breakRun()`：那段不是这个源的，两边都不记。
/// 主线程卡住（回调来不了、画面没更新）期间被覆盖的版本照算 dropped：那正是没赶上刷新。
///
/// 读数的时刻：dropped 最多落后一次回调（最后交出去的那一版画没画要到下一次回调才知道）；undelivered 在暂停期间按渲染器当前版本边停边估
/// （少估两帧，保证恢复后按实际画出的版本结算时不会回退），恢复后第一帧画出去时按版本号结算。两个累计值都单调不减。
@MainActor
public final class DisplayFrameLedger {
    /// 真正的来源（渲染器）。
    public let upstream: any DisplayFrameSource
    /// 记哪个视图的账（它的 presentedFrames / linkCallbacks）。
    public weak var view: MetalDisplayView?
    /// 累计：两次呈现之间被覆盖的版本数（提案 013 的 dropped）。
    public private(set) var droppedFrames: UInt64 = 0
    /// 累计：暂停呈现期间渲染器出了、视图没画的版本数（提案 018 的 undelivered）；暂停中含按当前版本估的那一段。
    public var undeliveredFrames: UInt64 {
        guard let start = pauseStartVersion, let current = upstream.latestDisplayFrame(for: .program)?.version, current > start &+ 2 else {
            return committedUndelivered
        }
        return committedUndelivered &+ (current - start - 2)
    }

    /// 本轮连续呈现里最后一次画出去的版本；nil = 断开之后还没画过。
    private var lastPresentedVersion: UInt64?
    /// 上一次交给视图的版本。
    private var handedVersion: UInt64?
    private var presentedAtHand: UInt64 = 0
    private var callbacksAtHand: UInt64 = 0
    private var breakPending = true
    private var committedUndelivered: UInt64 = 0
    /// 正在记的暂停：暂停前最后画出去的版本；nil = 没有要记的暂停。
    private var pauseStartVersion: UInt64?

    public init(upstream: any DisplayFrameSource, view: MetalDisplayView?) {
        self.upstream = upstream
        self.view = view
    }

    /// 断开连续呈现：下一次呈现只取基线，不和断开前比（不记 dropped）。
    /// - countingUndelivered = true：这是暂停（窗口收起 / 被遮住），从最后画出去的那一版起，渲染器出的版本记 undelivered；
    /// - false：这是换源——这段不是这个源的，都不记；已经在记的暂停按当前估值结算掉（累计值不回退），断开前画过什么也一并忘掉，
    ///   免得紧跟着的暂停从换源之前的版本算起。
    public func breakRun(countingUndelivered: Bool = false) {
        breakPending = true
        if countingUndelivered {
            if pauseStartVersion == nil { pauseStartVersion = lastShownVersion }
        } else {
            committedUndelivered = undeliveredFrames
            pauseStartVersion = nil
            lastPresentedVersion = nil
            handedVersion = nil
        }
    }

    /// 视图最后画出去的版本（上一次交出去的那一版画了就是它）。
    private var lastShownVersion: UInt64? {
        if let view, view.presentedFrames != presentedAtHand, let handed = handedVersion { return handed }
        return lastPresentedVersion
    }
}

extension DisplayFrameLedger: @preconcurrency DisplayFrameSource {
    public var displayCommandQueue: any MTLCommandQueue { upstream.displayCommandQueue }

    public func latestDisplayFrame(for target: DisplayTarget) -> DisplayFrame? {
        if let view {
            let presented = view.presentedFrames, callbacks = view.linkCallbacks
            // 1. 上一次交出去的版本画了没有（画了就是在任何断开之前画的，照常记）；暂停之后画出去的第一版结算 undelivered
            if presented != presentedAtHand, let handed = handedVersion {
                if let last = lastPresentedVersion {
                    if handed > last &+ 1 { droppedFrames &+= handed - last - 1 }
                } else if let start = pauseStartVersion {
                    let settled = handed > start &+ 1 ? committedUndelivered &+ (handed - start - 1) : committedUndelivered
                    committedUndelivered = max(settled, undeliveredFrames)   // 暂停中少估了两帧，结算不会比读过的估值小；取大保证不回退
                    pauseStartVersion = nil
                }
                lastPresentedVersion = handed
            }
            // 2. 断开：窗口标记过，或中间有不来取数的回调（视图当时不可见——这段记 undelivered）
            if breakPending || callbacks &- callbacksAtHand > 1 {
                if !breakPending, pauseStartVersion == nil { pauseStartVersion = lastPresentedVersion }
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
