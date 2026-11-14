// W6-A（prompt 144）用例的公共工具：换节目画布、加 16 路轻量输入、在新排布下量一遍主窗口（画面、上半区、下边一行、中间那一列的档、露出路数），
// 以及方案示意页里"第一层"那段 layout() / pickTier() 的 Swift 抄本（RefLayout）。
// 抄本只给用例当参照：喂方案的常数（K.spec）应逐格得出方案 §2.2 / §2.3 的三张表（证明抄得对）；喂量出来的常数（K.measured）应和 App 真排出来的
// 一致（证明 App 照规则排）。两者对不上的格子写进报告"方案 / 实测"，不改规则、不改表。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
extension AppTest {
    /// 换节目画布（= 换节目格式，换一个 session；输入原样带过去）；等新 session 跑起来、主窗口按新画布排好。
    @discardableResult
    static func setCanvas(width: Int, height: Int, frameRate: FrameRate = .fps30) throws -> SwitcherSession {
        let format = ProgramFormat(width: width, height: height, frameRate: frameRate)
        if let s = controller.session, s.format == format { return s }
        let done = expectationBox()
        Task { await controller.changeProgramFormat(format); done.value = true }
        guard waitUntil(20, { done.value && controller.session?.isRunning == true && controller.session?.format == format }) else {
            throw XCTSkip("换画布 \(width)×\(height) 没起来：\(String(describing: controller.lastError))")
        }
        let session = controller.session!
        let count = session.state.inputs.count
        if count > 0 { _ = waitUntil(10) { (1...count).allSatisfy { session.inputs.runtimeState(of: $0) == .live } } }
        pump(seconds: 0.2)
        controller.windowController.window?.contentView?.layoutSubtreeIfNeeded()
        return session
    }

    /// 加 n 路轻量合成源（640×360、30 帧、无声）：排布只看路数（缩略图切多画面纹理的格子，格子大小随路数变），不看源分辨率。
    static func addLightInputs(_ session: SwitcherSession, count: Int) throws {
        for n in 1...count {
            let settings = SyntheticSourceSettings(frameRate: .fps30, width: 640, height: 360, background: .gray(level: UInt8(40 + (180 * n) / max(count, 1))), audio: false)
            session.send(.addInput(config: InputConfig(number: n, name: "输入 \(n)", source: .synthetic(settings: settings))))
        }
        guard waitUntil(15, { session.state.inputs.count == count && (1...count).allSatisfy { session.inputs.runtimeState(of: $0) == .live } }) else {
            throw XCTSkip("轻量合成源没起来：\(session.state.inputs.map(\.number))")
        }
        pump(seconds: 0.2)
        controller.windowController.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// 主窗口改成正好这么大（W6-A：方案表里有 2560×1440，比这台机器屏幕的可见区高，放开 constrainFrameRect 的限制）；
    /// 屏幕放得下就摆在可见区正中，放不下就从屏幕左上角摆。用完 restoreWindowSizeLimit()。
    @discardableResult
    static func setExactWindowSize(_ size: NSSize) -> NSRect {
        guard let window = controller.windowController.window as? MainWindow else { return .zero }
        window.allowsFrameBeyondVisibleArea = true
        let screen = window.screen ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let full = screen?.frame ?? visible
        var origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        if size.height > visible.height || size.width > visible.width { origin = NSPoint(x: full.minX, y: full.maxY - size.height) }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        pump(seconds: 0.2)
        window.contentView?.layoutSubtreeIfNeeded()
        return window.frame
    }

    static func restoreWindowSizeLimit() {
        (controller.windowController.window as? MainWindow)?.allowsFrameBeyondVisibleArea = false
    }

    /// 快速改主窗口大小（连续缩放的扫描用：不泵 0.2 s，只让布局跟上）。
    static func resizeMainWindowQuickly(_ size: NSSize) {
        guard let window = controller.windowController.window else { return }
        (window as? MainWindow)?.allowsFrameBeyondVisibleArea = true
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// 合成鼠标拖动一个视图（按下 → 拖到 → 松开，都发给这个视图自己；位移是窗口坐标里的点）。
    static func drag(_ view: NSView, by delta: NSPoint) {
        guard let window = view.window else { return }
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown, start), let mid = event(.leftMouseDragged, NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)),
              let moved = event(.leftMouseDragged, end), let up = event(.leftMouseUp, end) else { return }
        view.mouseDown(with: down)
        view.mouseDragged(with: mid)
        view.mouseDragged(with: moved)
        view.mouseUp(with: up)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

// MARK: 量 App

/// 新排布下主窗口量出来的样子（都从视图的 frame 量，单位 pt）。
struct ArrangementMeasure: CustomStringConvertible {
    enum Mode: String { case sideBySide = "并排", stacked = "叠放", portrait = "竖屏" }
    var mode: Mode
    /// PVW 画面区（不含标题条）。
    var picture: NSSize
    var programPicture: NSSize
    /// 横屏：上半区高（= 中间那一列的高）；竖屏：排布区高。
    var top: CGFloat
    /// 横屏：下边一行高（输入区 = 调音台）；竖屏：输入区高。
    var bottom: CGFloat
    var mixerHeight: CGFloat
    var mixerWidth: CGFloat
    var inputWidth: CGFloat
    var tier: TransitionPanelView.ColumnTier
    /// 监看下面空出来的高（上半区高 − 监看本身的高）。
    var slack: CGFloat
    /// 输入区里完整露出的格子数、每行几格、放得下几行。
    var visible: Int
    var columns: Int
    var rows: Int

    var description: String {
        "\(mode.rawValue) 画面 \(Int(picture.width))×\(Int(picture.height.rounded())) 上 \(fmt(top)) 档 \(tier.title) 空 \(fmt(slack)) 下 \(fmt(bottom)) 输入 \(fmt(inputWidth)) 宽 \(columns) 列 × \(rows) 行 露 \(visible)"
    }
    private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }
}

@MainActor
extension AppTest {
    /// 在新排布下量一遍主窗口。
    static func measureArrangement() -> ArrangementMeasure {
        let wc = controller.windowController
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let root = wc.layoutView
        func frame(_ v: NSView) -> NSRect { root.convert(v.bounds, from: v) }   // 排布区坐标（翻转：y 朝下）
        let pvw = frame(wc.previewMonitor), pgm = frame(wc.programMonitor), column = frame(wc.transitionPanel)
        let strip = frame(wc.inputStrip), mixer = wc.isMixerPanelVisible ? frame(wc.mixerPanel) : .zero
        let picture = wc.previewMonitor.display.frame.size, programPicture = wc.programMonitor.display.frame.size
        let mode: ArrangementMeasure.Mode
        if strip.minX >= pvw.maxX - 0.5, strip.minY < pvw.maxY - 0.5 { mode = .portrait }
        else if pgm.minY >= pvw.maxY - 0.5 { mode = .stacked }
        else { mode = .sideBySide }
        let content: CGFloat = mode == .stacked ? pgm.maxY - pvw.minY : pvw.height
        let top: CGFloat = mode == .portrait ? root.bounds.height : column.height
        return ArrangementMeasure(mode: mode, picture: picture, programPicture: programPicture, top: top, bottom: strip.height,
                                  mixerHeight: mixer.height, mixerWidth: mixer.width, inputWidth: strip.width,
                                  tier: wc.transitionPanel.tier, slack: max(0, top - content),
                                  visible: wc.inputStrip.fullyVisibleNumbers().count, columns: wc.inputStrip.gridColumns,
                                  rows: wc.inputStrip.fullyVisibleRows)
    }

    /// 从 App 量出参照算法要的那组常数（排布区、底栏、列宽、标题条、格子、中间那一列四档的 fittingSize……）。
    static func measuredK() -> RefLayout.K {
        let wc = controller.windowController
        let window = wc.window!
        let content = window.contentView!
        let strip = wc.inputStrip
        var k = RefLayout.K.spec
        k.TB = window.frame.height - content.bounds.height
        k.BB = wc.bottomBar.frame.height
        k.TCOL = wc.transitionPanel.frame.width
        k.GAP = MainLayoutView.monitorGap
        k.DIV = MainLayoutView.dividerThickness
        if wc.isMixerPanelVisible, wc.mixerPanel.frame.width > 0 { k.MIX = wc.mixerPanel.frame.width }
        k.TITLE = Theme.monitorTitleHeight
        let size = strip.cellSize
        if strip.effectiveThumbnailSize == .compact {
            k.PW = size.width
            k.PHT = size.height
        } else {
            k.CW = size.width
            k.CH = size.height
        }
        k.CG = InputStripView.itemSpacing
        k.HDR = InputStripView.headerHeight
        k.INSET = InputStripView.stackInset
        k.TIERS = TransitionPanelView.ColumnTier.allCases.map { wc.transitionPanel.fittingHeight(of: $0) }
        k.ALLOWED = wc.allowedColumnTiers.map(\.rawValue)
        return k
    }
}

// MARK: 方案示意页 layout() 的抄本

/// docs/spec/大屏与时间线方案-示意页.html 脚本"第一层"一段（layout / pickTier / rowsFor）逐行抄成 Swift。字面量 36 = 头一行 30 + 上留白 6，195 = 36 + 格子 153 + 6，
/// 抄的时候换成 K 里对应的量（喂方案的 K 得到的就是原来的字面量）。
enum RefLayout {
    struct K {
        var TB: CGFloat, BB: CGFloat, TCOL: CGFloat, GAP: CGFloat, MIX: CGFloat, TITLE: CGFloat, TOL: CGFloat
        var CW: CGFloat, CG: CGFloat, CH: CGFloat, HDR: CGFloat, INSET: CGFloat, TOTAL: Int, RMIN: CGFloat, PW: CGFloat, PHT: CGFloat
        var DIV: CGFloat
        var TIERS: [CGFloat]
        /// 允许用的档（时钟偏好："一直显示" = 只有全档，"不显示" = 去掉全档）。
        var ALLOWED: [Int]
        var STRIPMIN: CGFloat { HDR + INSET + CH + CG }

        /// 示意页的 K（方案 §2.2 / §2.3 的表都是它算的）。
        static let spec = K(TB: 52, BB: 58, TCOL: 150, GAP: 2, MIX: 340, TITLE: 26, TOL: 24, CW: 200, CG: 6, CH: 153, HDR: 30, INSET: 6, TOTAL: 16,
                            RMIN: 346, PW: 72, PHT: 146, DIV: 1, TIERS: [392, 328, 280, 228], ALLOWED: [0, 1, 2, 3])
    }

    struct L {
        var mode: ArrangementMeasure.Mode
        var iw: CGFloat = 0, ih: CGFloat = 0
        var sideIw: CGFloat = 0, sideIh: CGFloat = 0
        var topH: CGFloat = 0
        var tier = 0
        var contentH: CGFloat = 0
        var slack: CGFloat = 0
        var rowH: CGFloat = 0
        var rows = 0
        var perRow = 0
        var visible = 0
        var inW: CGFloat = 0
        // 竖屏
        var sideW: CGFloat = 0
        var mixH: CGFloat = 0
        var inH: CGFloat = 0
        var cols = 0
    }

    static func rowsFor(_ rowH: CGFloat, _ k: K) -> Int { max(1, Int(((rowH - k.HDR - k.INSET) / (k.CH + k.CG)).rounded(.down))) }

    /// 选"放得下的最大一档"：不比监看那一块高出 TOL 以上、不超过上半区的上限、不因此少露一行输入。
    static func pickTier(_ contentH: CGFloat, _ topMax: CGFloat, _ availH: CGFloat, _ k: K) -> Int {
        let best = rowsFor(availH - min(contentH, topMax) - k.DIV, k)
        for i in k.ALLOWED {
            let top = max(contentH, k.TIERS[i])
            if k.TIERS[i] <= contentH + k.TOL, top <= topMax, rowsFor(availH - top - k.DIV, k) >= best { return i }
        }
        return k.ALLOWED.last ?? 3
    }

    static func layout(_ W: CGFloat, _ H: CGFloat, mixer: Bool, _ cw: CGFloat, _ ch: CGFloat, _ k: K) -> L {
        let a = cw / ch, availH = H - k.TB - k.BB
        if a >= 1 {
            var L = L(mode: .sideBySide)
            let topMax = availH - k.STRIPMIN - k.DIV
            let monW = (W - k.TCOL - 2 * k.GAP) / 2
            var iw = monW, ih = monW / a
            if ih + k.TITLE > topMax { ih = topMax - k.TITLE; iw = ih * a }
            let hug = ih + k.TITLE, ti = pickTier(hug, topMax, availH, k), topH = min(topMax, max(hug, k.TIERS[ti]))
            let keep = min(2, rowsFor(availH - topH - k.DIV, k))
            let topMax2 = availH - max(k.STRIPMIN, k.HDR + k.INSET + CGFloat(keep) * (k.CH + k.CG)) - k.DIV, stackW = W - k.TCOL - 2 * k.GAP
            let h2 = min(stackW / a, (topMax2 - k.GAP) / 2 - k.TITLE), w2 = h2 * a
            if h2 > 0 && (w2 * h2 >= 1.3 * iw * ih || (topH - hug > k.TOL && w2 * h2 > iw * ih)) {
                let stackH = 2 * (k.TITLE + h2) + k.GAP
                L.mode = .stacked
                L.iw = w2; L.ih = h2; L.sideIw = iw; L.sideIh = ih
                L.tier = pickTier(stackH, topMax2, availH, k); L.contentH = stackH
                L.topH = min(topMax2, max(stackH, k.TIERS[L.tier]))
            } else {
                L.iw = iw; L.ih = ih; L.sideIw = iw; L.sideIh = ih; L.tier = ti; L.contentH = hug; L.topH = topH
            }
            L.slack = max(0, L.topH - L.contentH)
            L.rowH = availH - L.topH - k.DIV
            L.inW = mixer ? W - k.MIX - k.DIV : W
            L.rows = rowsFor(L.rowH, k)
            L.perRow = max(1, Int(((L.inW - k.INSET) / (k.CW + k.CG)).rounded(.down)))
            L.visible = min(k.TOTAL, L.rows * L.perRow)
            return L
        }
        var L = L(mode: .portrait)
        L.ih = availH - k.TITLE; L.iw = L.ih * a
        let maxIw = (W - k.RMIN - k.DIV - k.TCOL - 2 * k.GAP) / 2
        if L.iw > maxIw { L.iw = max(120, maxIw); L.ih = L.iw / a }
        let sideX = 2 * L.iw + k.TCOL + 2 * k.GAP + k.DIV
        L.sideW = max(0, W - sideX)
        L.mixH = mixer ? max(240, min(380, availH - k.DIV - (k.HDR + k.INSET + 2 * (k.PHT + k.CG)))) : 0
        L.inH = availH - (mixer ? L.mixH + k.DIV : 0)
        L.cols = max(1, Int(((L.sideW - k.INSET) / (k.PW + k.CG)).rounded(.down)))
        L.rows = max(1, Int(((L.inH - k.HDR - k.INSET) / (k.PHT + k.CG)).rounded(.down)))
        L.visible = min(k.TOTAL, L.cols * L.rows)
        L.contentH = L.ih + k.TITLE
        L.topH = availH
        // 竖屏时监看很高，中间那一列一直是全档（方案 §2.3）：同一个选法，监看比哪一档都高
        L.tier = pickTier(L.contentH, availH, availH, k)
        return L
    }

    /// 示意页的写法：宽遇 .5 往下取（472.5 → 472）、高四舍五入。
    static func px(_ w: CGFloat, _ h: CGFloat) -> String { "\(Int((w - 0.01).rounded()))×\(Int(h.rounded()))" }
}

// MARK: 方案的三张表（§2.2）和竖屏的表（§2.3）

struct SpecLandscapeRow {
    let window: NSSize
    let canvas: (w: Int, h: Int)
    let picture: String          // "473×266"
    let sideBySide: String?      // 48:9 那张表的"并排会是"
    let top: Int
    let tier: Int                // 0 全 / 1 不带时钟 / 2 紧凑 / 3 最小
    let bottom: Int
    let visible: (on: Int, off: Int)
    let stacked: Bool
}

struct SpecPortraitRow {
    let window: NSSize
    let picture: String
    let sideW: Int
    let cols: Int
    let rows: Int                // 调音台开时输入区几行
    let mixH: Int
    let visible: (on: Int, off: Int)
}

enum SpecTables {
    static let windows = [NSSize(width: 1100, height: 720), NSSize(width: 1440, height: 900), NSSize(width: 1728, height: 1117), NSSize(width: 2560, height: 1440)]

    static let hd: [SpecLandscapeRow] = [
        .init(window: windows[0], canvas: (1920, 1080), picture: "473×266", sideBySide: nil, top: 292, tier: 2, bottom: 317, visible: (3, 5), stacked: false),
        .init(window: windows[1], canvas: (1920, 1080), picture: "643×362", sideBySide: nil, top: 392, tier: 0, bottom: 397, visible: (10, 12), stacked: false),
        .init(window: windows[2], canvas: (1920, 1080), picture: "787×443", sideBySide: nil, top: 469, tier: 0, bottom: 537, visible: (16, 16), stacked: false),
        .init(window: windows[3], canvas: (1920, 1080), picture: "1203×677", sideBySide: nil, top: 703, tier: 0, bottom: 626, visible: (16, 16), stacked: false),
    ]
    static let wall: [SpecLandscapeRow] = [
        .init(window: windows[0], canvas: (2460, 1080), picture: "473×208", sideBySide: nil, top: 234, tier: 3, bottom: 375, visible: (6, 10), stacked: false),
        .init(window: windows[1], canvas: (2460, 1080), picture: "643×282", sideBySide: nil, top: 328, tier: 1, bottom: 461, visible: (10, 12), stacked: false),
        .init(window: windows[2], canvas: (2460, 1080), picture: "787×346", sideBySide: nil, top: 392, tier: 0, bottom: 614, visible: (16, 16), stacked: false),
        .init(window: windows[3], canvas: (2460, 1080), picture: "1203×528", sideBySide: nil, top: 554, tier: 0, bottom: 775, visible: (16, 16), stacked: false),
    ]
    static let triple: [SpecLandscapeRow] = [
        .init(window: windows[0], canvas: (5760, 1080), picture: "536×101", sideBySide: "473×89", top: 255, tier: 3, bottom: 354, visible: (6, 10), stacked: true),
        .init(window: windows[1], canvas: (5760, 1080), picture: "1016×191", sideBySide: "643×121", top: 435, tier: 0, bottom: 354, visible: (10, 12), stacked: true),
        .init(window: windows[2], canvas: (5760, 1080), picture: "1574×295", sideBySide: "787×148", top: 644, tier: 0, bottom: 362, visible: (12, 16), stacked: true),
        .init(window: windows[3], canvas: (5760, 1080), picture: "2406×451", sideBySide: "1203×226", top: 956, tier: 0, bottom: 373, visible: (16, 16), stacked: true),
    ]
    static let portrait: [SpecPortraitRow] = [
        .init(window: windows[0], picture: "299×532", sideW: 346, cols: 4, rows: 2, mixH: 269, visible: (8, 12)),
        .init(window: windows[1], picture: "430×764", sideW: 426, cols: 5, rows: 2, mixH: 380, visible: (10, 16)),
        .init(window: windows[2], picture: "552×981", sideW: 469, cols: 5, rows: 3, mixH: 380, visible: (15, 16)),
    ]
}

extension TransitionPanelView.ColumnTier {
    /// 方案表里的叫法。
    var title: String {
        switch self {
        case .full: "全"
        case .noClock: "不带时钟"
        case .compact: "紧凑"
        case .minimal: "最小"
        }
    }
}
