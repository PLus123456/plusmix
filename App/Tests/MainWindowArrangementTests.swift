// W6-A（prompt 144，docs/spec/大屏与时间线方案.md §2）：主窗口新排布。监看框 = 画面（M1）、横屏上边监看横贯窗口 / 下边一行"输入 ｜ 调音台"同高（M2）、
// 竖屏监看占满左边 / 右边一栏输入在上调音台在下（M3）、分隔条拖到底不出黑边（M4）、中间那一列四档自动收放（M6）、很宽的画布监看叠放（M7）；
// 节目格式页的竖屏预设与"横 ⇄ 竖"、"窗口 › 排布"的旧排布开关。M5（调音台高度跟着位置走）在 MixerAdaptiveHeightTests。
// 尺寸一律从布局里量；对照用 RefLayout（示意页 layout() 的抄本）：方案常数 → 方案的表（抄得对），量出来的常数 → App 真排出来的（App 照规则排）。
// 带"W6表"前缀的行是报告"方案 / 实测"的原始数据。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class MainWindowArrangementTests: XCTestCase {
    private var wc: MainWindowController { AppTest.controller.windowController }

    override func tearDown() {
        MainActor.assumeIsolated {
            let wc = AppTest.controller.windowController
            if !wc.isMixerPanelVisible { wc.toggleMixerPanel() }
            AppTest.restoreWindowSizeLimit()
            AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        }
        super.tearDown()
    }

    private func setMixer(_ on: Bool) {
        if wc.isMixerPanelVisible != on { wc.toggleMixerPanel() }
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        AppTest.pump(seconds: 0.05)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func size(_ s: NSSize) -> String { "\(Int(s.width))×\(Int(s.height))" }

    /// 抄本喂方案常数，逐格对方案的横屏表（画面、上半区高、档、下边一行高、露出路数、叠不叠放）。
    private func checkSpecRow(_ row: SpecLandscapeRow, file: StaticString = #filePath, line: UInt = #line) {
        let label = "[方案表 \(size(row.window)) \(row.canvas.w)×\(row.canvas.h)]"
        for (mixer, visible) in [(true, row.visible.on), (false, row.visible.off)] {
            let L = RefLayout.layout(row.window.width, row.window.height, mixer: mixer, CGFloat(row.canvas.w), CGFloat(row.canvas.h), .spec)
            XCTAssertEqual(RefLayout.px(L.iw, L.ih), row.picture, "\(label) 画面", file: file, line: line)
            if let side = row.sideBySide { XCTAssertEqual(RefLayout.px(L.sideIw, L.sideIh), side, "\(label) 并排会是", file: file, line: line) }
            XCTAssertEqual(Int(L.topH.rounded()), row.top, "\(label) 上半区高", file: file, line: line)
            XCTAssertEqual(L.tier, row.tier, "\(label) 中间那一列", file: file, line: line)
            XCTAssertEqual(Int(L.rowH.rounded()), row.bottom, "\(label) 下边一行高", file: file, line: line)
            XCTAssertEqual(L.visible, visible, "\(label) 露出（调音台\(mixer ? "开" : "收起")）", file: file, line: line)
            XCTAssertEqual(L.mode == .stacked, row.stacked, "\(label) 叠放", file: file, line: line)
        }
    }

    /// App 量出来的与抄本（喂量出来的常数）逐项比；返回抄本的结果，并打一行"方案 / 实测"。
    @discardableResult
    private func checkApp(_ m: ArrangementMeasure, window: NSSize, canvas: (w: Int, h: Int), mixer: Bool, spec: SpecLandscapeRow?,
                          test: String, file: StaticString = #filePath, line: UInt = #line) -> RefLayout.L {
        let k = AppTest.measuredK()
        let actual = wc.window?.frame.size ?? window   // 规则按真实的窗口尺寸算（屏幕放不下时会比要的小）
        XCTAssertEqual(actual, window, "窗口摆成了要的尺寸", file: file, line: line)
        let L = RefLayout.layout(actual.width, actual.height, mixer: mixer, CGFloat(canvas.w), CGFloat(canvas.h), k)
        let label = "[\(size(window)) \(canvas.w)×\(canvas.h) 调音台\(mixer ? "开" : "收")]"
        XCTAssertEqual(m.mode, L.mode, "\(label) 摆法", file: file, line: line)
        XCTAssertEqual(m.picture.width, L.iw, accuracy: 1, "\(label) 画面宽：App \(m.picture.width) / 规则 \(L.iw)", file: file, line: line)
        XCTAssertEqual(m.picture.height, L.ih, accuracy: 1, "\(label) 画面高：App \(m.picture.height) / 规则 \(L.ih)", file: file, line: line)
        XCTAssertEqual(m.top, L.topH, accuracy: 1, "\(label) 上半区高：App \(m.top) / 规则 \(L.topH)", file: file, line: line)
        XCTAssertEqual(m.tier.rawValue, L.tier, "\(label) 中间那一列：App \(m.tier.title) / 规则 \(TransitionPanelView.ColumnTier(rawValue: L.tier)?.title ?? "?")", file: file, line: line)
        XCTAssertEqual(m.bottom, L.rowH, accuracy: 1, "\(label) 下边一行高：App \(m.bottom) / 规则 \(L.rowH)", file: file, line: line)
        XCTAssertEqual(m.visible, L.visible, "\(label) 露出：App \(m.visible) / 规则 \(L.visible)（\(m.columns) 列 × \(m.rows) 行）", file: file, line: line)
        let specText = spec.map { s in
            "方案 \(s.picture) 上 \(s.top) \(TransitionPanelView.ColumnTier(rawValue: s.tier)?.title ?? "?") 下 \(s.bottom) 露 \(mixer ? s.visible.on : s.visible.off)"
        } ?? "方案 —"
        print("W6表 \(test) \(size(window)) \(canvas.w)×\(canvas.h) 调音台\(mixer ? "开" : "收") | \(specText) | 实测 \(m) | 量出来的常数 格子 \(Int(k.CW))×\(Int(k.CH)) 竖格 \(Int(k.PW))×\(Int(k.PHT)) 四档 \(k.TIERS.map { Int($0) })")
        return L
    }

    // MARK: M1 监看框 = 画面

    /// 4 种窗口 × 4 种画布 × 调音台开 / 收：两幅监看的画面区宽高比与画布差 ≤ 1 pt；监视器的框就是"标题条 + 画面"，框里没有黑边（框外是窗口底色）。
    func testM1_monitorFrameMatchesCanvasAspect() throws {
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 4)
        XCTAssertEqual(wc.arrangement, .adaptive, "默认新排布")
        for canvas in [(1920, 1080), (1080, 1920), (1366, 762), (2460, 1080)] {
            try AppTest.setCanvas(width: canvas.0, height: canvas.1)
            let aspect = CGFloat(canvas.0) / CGFloat(canvas.1)
            XCTAssertEqual(wc.previewMonitor.canvasAspect ?? 0, aspect, accuracy: 0.0001, "换格式时画面区的比例跟着换")
            XCTAssertEqual(wc.programMonitor.canvasAspect ?? 0, aspect, accuracy: 0.0001)
            for window in SpecTables.windows {
                AppTest.setExactWindowSize(window)
                for mixer in [true, false] {
                    setMixer(mixer)
                    let label = "[\(size(window)) \(canvas.0)×\(canvas.1) 调音台\(mixer ? "开" : "收")]"
                    for monitor in [wc.previewMonitor, wc.programMonitor] {
                        let d = monitor.display.frame
                        XCTAssertGreaterThan(d.width, 80, "\(label) 画面区不能缩没")
                        XCTAssertEqual(d.height, d.width / aspect, accuracy: 1, "\(label) \(monitor.target) 画面区 \(d.size) 与画布比例差 ≤ 1 pt")
                        XCTAssertEqual(monitor.bounds.width, d.width, accuracy: 1, "\(label) 框宽 = 画面宽（框外是窗口底色）")
                        XCTAssertEqual(monitor.bounds.height - Theme.monitorTitleHeight, d.height, accuracy: 1, "\(label) 框高 = 标题条 + 画面，没有黑边")
                    }
                }
            }
        }
    }

    // MARK: M2 横屏：上边监看横贯窗口，下边一行"输入 ｜ 调音台"同高

    /// 方案 §2.2 的 16:9 与 20.5:9 两张表逐格：画面尺寸、上半区高、下边一行高、露出路数（16 路输入）；调音台在下边一行、与输入区同高。
    func testM2_landscapeMonitorsSpanFullWidth() throws {
        for row in SpecTables.hd + SpecTables.wall { checkSpecRow(row) }
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 16)
        for table in [SpecTables.hd, SpecTables.wall] {
            try AppTest.setCanvas(width: table[0].canvas.w, height: table[0].canvas.h)
            for row in table {
                AppTest.setExactWindowSize(row.window)
                for mixer in [true, false] {
                    setMixer(mixer)
                    let m = AppTest.measureArrangement()
                    let L = checkApp(m, window: row.window, canvas: row.canvas, mixer: mixer, spec: row, test: "M2")
                    let label = "[\(size(row.window)) \(row.canvas.w)×\(row.canvas.h) 调音台\(mixer ? "开" : "收")]"
                    // 上边：PVW ｜ 转场列 ｜ PGM 横贯整个窗口宽度（不再被调音台占掉 340）
                    let root = wc.layoutView
                    let pvw = root.convert(wc.previewMonitor.bounds, from: wc.previewMonitor)
                    let pgm = root.convert(wc.programMonitor.bounds, from: wc.programMonitor)
                    let column = root.convert(wc.transitionPanel.bounds, from: wc.transitionPanel)
                    let half = (root.bounds.width - column.width - 2 * MainLayoutView.monitorGap) / 2
                    XCTAssertEqual(column.midX, root.bounds.midX, accuracy: 1, "\(label) 转场列在正中")
                    XCTAssertEqual(pvw.midX, half / 2, accuracy: 1, "\(label) PVW 在左半边正中")
                    XCTAssertEqual(pgm.midX, root.bounds.width - half / 2, accuracy: 1, "\(label) PGM 在右半边正中")
                    XCTAssertEqual(m.picture.width, L.sideIw, accuracy: 1, "\(label) 每幅监看用满半个窗口宽")
                    // 下边一行：输入区在左、调音台在右，两者同高；收起调音台后输入区占满整行
                    let strip = root.convert(wc.inputStrip.bounds, from: wc.inputStrip)
                    XCTAssertGreaterThanOrEqual(strip.minY, column.maxY, "\(label) 输入区在上半区下面")
                    if mixer {
                        let mix = root.convert(wc.mixerPanel.bounds, from: wc.mixerPanel)
                        XCTAssertEqual(mix.minY, strip.minY, accuracy: 0.5, "\(label) 调音台挪到下边一行")
                        XCTAssertEqual(mix.height, strip.height, accuracy: 0.5, "\(label) 调音台与输入区同高")
                        XCTAssertEqual(mix.width, Theme.mixerPanelWidth, accuracy: 0.5, "\(label) 调音台默认宽 340")
                        XCTAssertEqual(mix.maxX, root.bounds.width, accuracy: 0.5, "\(label) 调音台贴右边")
                    } else {
                        XCTAssertEqual(strip.width, root.bounds.width, accuracy: 0.5, "\(label) 收起调音台后输入区占满整行")
                    }
                }
            }
        }
        // 16 路全部滚得到（最小窗口、调音台开：只露 3 路）
        try AppTest.setCanvas(width: 1920, height: 1080)
        AppTest.setExactWindowSize(SpecTables.windows[0])
        setMixer(true)
        let strip = wc.inputStrip
        XCTAssertLessThan(strip.fullyVisibleNumbers().count, 16)
        for n in [8, 16] {
            strip.scrollToCell(n)
            AppTest.pump(seconds: 0.05)
            XCTAssertTrue(strip.fullyVisibleNumbers().contains(n), "第 \(n) 路滚得到：\(strip.fullyVisibleNumbers())")
        }
    }

    // MARK: M3 竖屏：监看占满左边，右边一栏输入在上、调音台在下

    /// 方案 §2.3 的表逐格：画面、右边一栏宽、输入几列几行、调音台高、露出路数；监看占满高度；输入格子是竖的小格；16 路全部滚得到。
    func testM3_portraitMonitorsFullHeight() throws {
        for row in SpecTables.portrait {
            for (mixer, visible) in [(true, row.visible.on), (false, row.visible.off)] {
                let L = RefLayout.layout(row.window.width, row.window.height, mixer: mixer, 1080, 1920, .spec)
                let label = "[方案表 竖屏 \(size(row.window)) 调音台\(mixer ? "开" : "收")]"
                XCTAssertEqual(RefLayout.px(L.iw, L.ih), row.picture, label)
                XCTAssertEqual(Int(L.sideW.rounded()), row.sideW, label)
                XCTAssertEqual(L.cols, row.cols, label)
                if mixer {
                    XCTAssertEqual(L.rows, row.rows, label)
                    XCTAssertEqual(Int(L.mixH.rounded()), row.mixH, label)
                }
                XCTAssertEqual(L.visible, visible, label)
            }
        }
        try AppTest.addLightInputs(try AppTest.freshSession(), count: 16)
        let session = try AppTest.setCanvas(width: 1080, height: 1920)   // 换画布 = 换 session，之后看新的
        XCTAssertEqual(wc.inputStrip.effectiveThumbnailSize, .compact, "竖屏：输入格子换成竖的小格")
        let cell = try XCTUnwrap(wc.inputStrip.cells[1])
        XCTAssertTrue(cell.isCompact)
        XCTAssertTrue(cell.firstRowButtons.allSatisfy { $0.isHidden || $0.superview?.isHidden == true }, "小格上的按钮不常显")
        XCTAssertEqual(cell.display.frame.width, ThumbnailSize.compact.width, accuracy: 0.5, "宽 72")
        XCTAssertEqual(cell.display.frame.height, cell.display.frame.width * 1920 / 1080, accuracy: 1, "9:16 的缩略图（不再钳在 16:9 的框里）")
        for row in SpecTables.portrait {
            AppTest.setExactWindowSize(row.window)
            for mixer in [true, false] {
                setMixer(mixer)
                let m = AppTest.measureArrangement()
                let k = AppTest.measuredK()
                let L = RefLayout.layout(row.window.width, row.window.height, mixer: mixer, 1080, 1920, k)
                let label = "[竖屏 \(size(row.window)) 调音台\(mixer ? "开" : "收")]"
                let root = wc.layoutView
                let pvw = root.convert(wc.previewMonitor.bounds, from: wc.previewMonitor)
                let strip = root.convert(wc.inputStrip.bounds, from: wc.inputStrip)
                XCTAssertEqual(m.mode, .portrait, label)
                XCTAssertEqual(m.picture.width, L.iw, accuracy: 1, "\(label) 画面宽：App \(m.picture.width) / 规则 \(L.iw)")
                XCTAssertEqual(m.picture.height, L.ih, accuracy: 1, "\(label) 画面高：App \(m.picture.height) / 规则 \(L.ih)")
                XCTAssertEqual(pvw.minY, 0, accuracy: 0.5, "\(label) 监看从顶上开始")
                XCTAssertEqual(pvw.height, L.ih + k.TITLE, accuracy: 1, "\(label) 监看占满高度（窄窗口时按宽让一点）")
                XCTAssertEqual(strip.width, L.sideW, accuracy: 1, "\(label) 右边一栏宽：App \(strip.width) / 规则 \(L.sideW)")
                XCTAssertEqual(strip.maxX, root.bounds.width, accuracy: 0.5, "\(label) 右边一栏贴右边")
                XCTAssertEqual(strip.minY, 0, accuracy: 0.5, "\(label) 输入区在上")
                XCTAssertEqual(m.columns, L.cols, "\(label) 输入几列")
                XCTAssertEqual(m.rows, L.rows, "\(label) 输入几行")
                XCTAssertEqual(m.visible, L.visible, "\(label) 露出：App \(m.visible) / 规则 \(L.visible)")
                if mixer {
                    let mix = root.convert(wc.mixerPanel.bounds, from: wc.mixerPanel)
                    XCTAssertEqual(mix.width, strip.width, accuracy: 0.5, "\(label) 调音台和输入区同宽")
                    XCTAssertGreaterThanOrEqual(mix.minY, strip.maxY, "\(label) 调音台在输入区下面")
                    XCTAssertEqual(mix.height, L.mixH, accuracy: 1, "\(label) 调音台高：App \(mix.height) / 规则 \(L.mixH)")
                    XCTAssertEqual(mix.maxY, root.bounds.height, accuracy: 0.5, "\(label) 调音台贴底")
                } else {
                    XCTAssertEqual(strip.height, root.bounds.height, accuracy: 0.5, "\(label) 收起调音台后输入区占满整栏")
                }
                XCTAssertEqual(m.tier, .full, "\(label) 竖屏时监看很高，中间那一列一直是全档、带时钟")
                print("W6表 M3 竖屏 \(size(row.window)) 调音台\(mixer ? "开" : "收") | 方案 \(row.picture) 栏宽 \(row.sideW) \(row.cols) 列 × \(row.rows) 行 调音台 \(row.mixH) 露 \(mixer ? row.visible.on : row.visible.off) | 实测 画面 \(Int(m.picture.width))×\(Int(m.picture.height.rounded())) 栏宽 \(Int(strip.width)) \(m.columns) 列 × \(m.rows) 行 调音台 \(Int(m.mixerHeight)) 露 \(m.visible) | 竖格 \(Int(k.PW))×\(Int(k.PHT))")
            }
        }
        // 16 路全部滚得到
        AppTest.setExactWindowSize(SpecTables.windows[0])
        setMixer(true)
        for n in [9, 16] {
            wc.inputStrip.scrollToCell(n)
            AppTest.pump(seconds: 0.05)
            XCTAssertTrue(wc.inputStrip.fullyVisibleNumbers().contains(n), "竖屏第 \(n) 路滚得到：\(wc.inputStrip.fullyVisibleNumbers())")
        }
        // 小格：点 = 选 PVW、⇧ 点 = 直切 PGM，其余动作在右键菜单里
        let tapped = try XCTUnwrap(wc.inputStrip.cells[3])
        wc.inputStrip.scrollToCell(3)
        AppTest.pump(seconds: 0.05)
        clickThumbnail(tapped, shift: false)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 3 }, "点小格 = 选 PVW")
        clickThumbnail(tapped, shift: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 3 }, "⇧ 点小格 = 直切 PGM")
        let titles = tapped.contextMenu().items.map(\.title)
        for title in [L("cell.menu.preview"), L("cell.menu.cut"), L("cell.menu.settings"), L("cell.menu.remove", 3)] {
            XCTAssertTrue(titles.contains(title), "右键菜单有“\(title)”：\(titles)")
        }
    }

    private func clickThumbnail(_ cell: InputCellView, shift: Bool) {
        guard let window = cell.window else { return XCTFail("格子不在窗口里") }
        let p = cell.display.convert(NSPoint(x: cell.display.bounds.midX, y: cell.display.bounds.midY), to: nil)
        let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let target = window.contentView?.hitTest(p) else { return XCTFail("点不到格子") }
        target.mouseDown(with: down)
    }

    // MARK: M4 分隔条拖到底不出黑边

    /// 往下拖最多拖到贴合高（画面不出黑边）；往上拖让下边一行更高，监看等比变小、居中，中间那一列放得下；位置存本机；拖回到底回到按规则排。
    func testM4_dividerNeverLetterboxes() throws {
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 4)
        let prefs = AppTest.controller.layoutPreferences
        for canvas in [(1920, 1080), (2460, 1080)] {
            try AppTest.setCanvas(width: canvas.0, height: canvas.1)
            AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
            let aspect = CGFloat(canvas.0) / CGFloat(canvas.1)
            let label = "[\(canvas.0)×\(canvas.1)]"
            let fit = AppTest.measureArrangement()
            func assertNoLetterbox(_ what: String) {
                for monitor in [wc.previewMonitor, wc.programMonitor] {
                    let d = monitor.display.frame
                    XCTAssertEqual(d.height, d.width / aspect, accuracy: 1, "\(label) \(what)：画面比例")
                    XCTAssertEqual(monitor.bounds.height - Theme.monitorTitleHeight, d.height, accuracy: 1, "\(label) \(what)：框里没有黑边")
                    XCTAssertEqual(monitor.bounds.width, d.width, accuracy: 1, "\(label) \(what)：框宽 = 画面宽")
                }
            }
            // 往下拖 200：不超过贴合高
            AppTest.drag(wc.layoutView.topDivider, by: NSPoint(x: 0, y: -200))
            var m = AppTest.measureArrangement()
            XCTAssertEqual(m.top, fit.top, accuracy: 0.5, "\(label) 往下最多拖到贴合高：\(m.top) / \(fit.top)")
            XCTAssertEqual(m.picture.width, fit.picture.width, accuracy: 0.5)
            assertNoLetterbox("往下拖到底")
            XCTAssertNil(prefs.bottomRowHeight, "\(label) 拖到底 = 按规则排，不存位置")
            // 往上拖 120：下边一行高 120（上半区不小于最矮那一档：20.5:9 时贴合高 328，最多拖到 228），监看等比变小、居中
            AppTest.drag(wc.layoutView.topDivider, by: NSPoint(x: 0, y: 120))
            m = AppTest.measureArrangement()
            let lowest = wc.transitionPanel.fittingHeight(of: .minimal)
            let expectedTop = max(lowest, fit.top - 120)
            XCTAssertEqual(m.top, expectedTop, accuracy: 1, "\(label) 往上拖：上半区 = max(最小档 \(lowest), 贴合高 − 120)")
            XCTAssertEqual(m.bottom, fit.bottom + (fit.top - expectedTop), accuracy: 1, "\(label) 往上拖：下边一行更高")
            XCTAssertLessThan(m.picture.width, fit.picture.width - 10, "\(label) 监看等比变小")
            assertNoLetterbox("往上拖")
            let root = wc.layoutView
            let pvw = root.convert(wc.previewMonitor.bounds, from: wc.previewMonitor)
            let half = (root.bounds.width - wc.transitionPanel.frame.width - 2 * MainLayoutView.monitorGap) / 2
            XCTAssertEqual(pvw.midX, half / 2, accuracy: 1, "\(label) 变小的监看在半边里居中")
            XCTAssertGreaterThanOrEqual(wc.transitionPanel.frame.height, wc.transitionPanel.fittingHeight(of: wc.transitionPanel.tier) - 0.5, "\(label) 中间那一列放得下（\(wc.transitionPanel.tier.title)）")
            XCTAssertEqual(prefs.bottomRowHeight ?? 0, m.bottom, accuracy: 1, "\(label) 分隔条位置存本机")
            // 窗口放大：下边一行保持、上半区不超过贴合高，画面不出黑边
            AppTest.setExactWindowSize(NSSize(width: 1728, height: 1117))
            let big = AppTest.measureArrangement()
            let ref = RefLayout.layout(1728, 1117, mixer: true, CGFloat(canvas.0), CGFloat(canvas.1), AppTest.measuredK())
            XCTAssertLessThanOrEqual(big.top, ref.topH + 0.5, "\(label) 放大后上半区不超过贴合高")
            assertNoLetterbox("放大窗口")
            // 往上拖到顶：上半区不小于最小档（中间那一列放得下）
            AppTest.drag(wc.layoutView.topDivider, by: NSPoint(x: 0, y: 2000))
            m = AppTest.measureArrangement()
            XCTAssertGreaterThanOrEqual(m.top, wc.transitionPanel.fittingHeight(of: .minimal) - 0.5, "\(label) 拖到顶：上半区不小于最小档")
            XCTAssertEqual(m.tier, .minimal)
            assertNoLetterbox("往上拖到顶")
            // 拖回到底：回到按规则排，偏好清掉
            AppTest.drag(wc.layoutView.topDivider, by: NSPoint(x: 0, y: -3000))
            m = AppTest.measureArrangement()
            XCTAssertEqual(m.top, ref.topH, accuracy: 1, "\(label) 拖回到底 = 按规则排")
            XCTAssertNil(prefs.bottomRowHeight)
            assertNoLetterbox("拖回到底")
        }
        // 输入 ｜ 调音台中间的分隔条：调音台默认 340，往左拖变宽，宽度存本机；往右拖不窄于 340
        try AppTest.setCanvas(width: 1920, height: 1080)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        AppTest.drag(wc.layoutView.mixerDivider, by: NSPoint(x: -100, y: 0))
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth + 100, accuracy: 1, "调音台往左拖宽 100")
        XCTAssertEqual(prefs.mixerWidth ?? 0, Theme.mixerPanelWidth + 100, accuracy: 1)
        AppTest.drag(wc.layoutView.mixerDivider, by: NSPoint(x: 150, y: 0))
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 1, "不窄于 340")
        XCTAssertTrue(wc.isMixerPanelVisible)
    }

    // MARK: M6 中间那一列四档自动收放

    /// 三张表"中间那一列"一栏逐格；监看下面的空白 ≤ 24（32:9 配最小窗口那一处除外：方案写明空 69）；各档高度用 fittingSize 量。
    func testM6_transitionColumnTiers() throws {
        // 抄本 + 方案常数：三张表的"中间那一列"与 32:9 的例外
        for row in SpecTables.hd + SpecTables.wall + SpecTables.triple {
            let L = RefLayout.layout(row.window.width, row.window.height, mixer: true, CGFloat(row.canvas.w), CGFloat(row.canvas.h), .spec)
            XCTAssertEqual(L.tier, row.tier, "[方案表 \(size(row.window)) \(row.canvas.w)×\(row.canvas.h)] 中间那一列")
            if row.canvas.w != 3840 { XCTAssertLessThanOrEqual(L.slack, 24) }
        }
        let corner = RefLayout.layout(1100, 720, mixer: true, 3840, 1080, .spec)
        XCTAssertEqual(corner.mode, .sideBySide, "方案：最小窗口配 32:9 叠放并不更大，不换")
        XCTAssertEqual(corner.slack, 69, accuracy: 0.5, "方案写明：最小窗口配 32:9 空 69")

        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 16)
        let panel = wc.transitionPanel
        let heights = TransitionPanelView.ColumnTier.allCases.map { panel.fittingHeight(of: $0) }
        print("W6表 M6 四档 fittingSize：\(heights)（方案 392 / 328 / 280 / 228）")
        XCTAssertEqual(heights, heights.sorted(by: >), "四档一档比一档矮")
        XCTAssertLessThanOrEqual(heights[0], 409, "全档 ≤ 409（W5-A / W5-M 的阈值）")
        for (canvas, rows) in [((1920, 1080), SpecTables.hd), ((2460, 1080), SpecTables.wall), ((5760, 1080), SpecTables.triple)] {
            try AppTest.setCanvas(width: canvas.0, height: canvas.1)
            for row in rows {
                AppTest.setExactWindowSize(row.window)
                let m = AppTest.measureArrangement()
                let L = checkApp(m, window: row.window, canvas: canvas, mixer: true, spec: row, test: "M6")
                XCTAssertLessThanOrEqual(m.slack, 24, "[\(size(row.window)) \(canvas.0)×\(canvas.1)] 监看下面最多空 24：\(m.slack)")
                XCTAssertEqual(panel.frame.height, L.topH, accuracy: 1, "中间那一列和上半区一样高")
                XCTAssertGreaterThanOrEqual(panel.frame.height, panel.fittingHeight(of: m.tier) - 0.5, "这一档放得下")
                XCTAssertEqual(panel.isClockShown, m.tier == .full)
            }
        }
        // 32:9 配最小窗口：方案写明的例外（空 69）；App 按量出来的常数照规则排，和抄本一致
        try AppTest.setCanvas(width: 3840, height: 1080)
        AppTest.setExactWindowSize(SpecTables.windows[0])
        let m32 = AppTest.measureArrangement()
        let L32 = checkApp(m32, window: SpecTables.windows[0], canvas: (3840, 1080), mixer: true, spec: nil, test: "M6-32:9")
        XCTAssertEqual(m32.slack, L32.slack, accuracy: 1, "32:9 配最小窗口：空白与规则一致（方案 69，实测 \(m32.slack)）")
        print("W6表 M6 32:9 配最小窗口 | 方案 并排 空 69 | 实测 \(m32)")

        // 窗口从小拉到大再拉回：同一尺寸，结果相同（档、摆法、上半区高）
        for canvas in [(1920, 1080), (2460, 1080)] {
            try AppTest.setCanvas(width: canvas.0, height: canvas.1)
            let steps = (0...16).map { i -> NSSize in
                let f = CGFloat(i) / 16
                return NSSize(width: (1100 + f * 1460).rounded(), height: (720 + f * 720).rounded())
            }
            var forward: [String] = [], backward: [String] = []
            for s in steps {
                AppTest.resizeMainWindowQuickly(s)
                let m = AppTest.measureArrangement()
                forward.append("\(size(s)) \(m.tier.title) \(m.mode.rawValue) \(Int(m.top.rounded()))")
            }
            for s in steps.reversed() {
                AppTest.resizeMainWindowQuickly(s)
                let m = AppTest.measureArrangement()
                backward.append("\(size(s)) \(m.tier.title) \(m.mode.rawValue) \(Int(m.top.rounded()))")
            }
            XCTAssertEqual(forward, backward.reversed(), "[\(canvas.0)×\(canvas.1)] 拉大再缩回：同一尺寸结果相同")
        }
    }

    /// 时钟"自动"（默认）：放不下时收起，时间改在状态行右端用小字显示；放得下时回来，状态行的时间收起。
    func testM6_clockAutoMovesTimeToStatusLine() throws {
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 4)
        XCTAssertEqual(wc.clockDisplay, .auto, "默认自动")
        let status = wc.bottomBar.statusBar
        try AppTest.setCanvas(width: 2460, height: 1080)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        XCTAssertEqual(wc.transitionPanel.tier, .noClock, "1440×900 配 20.5:9：收起时钟（方案：上半区 328、空 20）")
        XCTAssertFalse(wc.transitionPanel.isClockShown)
        XCTAssertTrue(AppTest.waitUntil(2) { !status.displayedClock.isEmpty }, "时钟收起时状态行右端有时间")
        XCTAssertNotNil(status.displayedClock.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression), "小字时间 HH:mm:ss：\(status.displayedClock)")
        let right = AppTest.alignmentFrame(status.clockLabel, in: status)
        XCTAssertEqual(right.maxX, status.bounds.maxX - StatusBarView.padding, accuracy: 1, "在状态行最右端")
        XCTAssertLessThan(status.clockLabel.font?.pointSize ?? 99, 12, "小字")
        try AppTest.setCanvas(width: 1920, height: 1080)
        XCTAssertEqual(wc.transitionPanel.tier, .full, "放得下时时钟回来")
        XCTAssertTrue(wc.transitionPanel.isClockShown)
        XCTAssertEqual(status.displayedClock, "", "列里有时钟，状态行不再显示时间")
    }

    /// 时钟"一直显示"：回到今天的样子，宁可空着也留时钟；存本机。
    func testM6_clockAlwaysKeepsFullColumn() throws {
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 4)
        try AppTest.setCanvas(width: 2460, height: 1080)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        wc.setClockDisplay(.always)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(AppTest.controller.layoutPreferences.clockDisplay, .always, "存本机")
        XCTAssertEqual(AppTest.controller.defaults.string(forKey: MainLayoutPreferences.Keys.clockDisplay), "always")
        let m = AppTest.measureArrangement()
        XCTAssertEqual(m.tier, .full, "一直显示：全档带时钟")
        XCTAssertTrue(wc.transitionPanel.isClockShown)
        XCTAssertGreaterThanOrEqual(m.top, wc.transitionPanel.fittingHeight(of: .full) - 0.5, "宁可空着也留时钟")
        XCTAssertGreaterThan(m.slack, 24, "这一档比监看高出 24 以上也不收")
        XCTAssertEqual(wc.bottomBar.statusBar.displayedClock, "", "状态行不显示时间")
        AppTest.setExactWindowSize(SpecTables.windows[0])
        XCTAssertEqual(wc.transitionPanel.tier, .full, "最小窗口也一直显示")
    }

    /// 时钟"不显示"：中间那一列永远不带时钟（最多到"不带时钟"档），时间在状态行；存本机。
    func testM6_clockNeverHidesClock() throws {
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 4)
        AppTest.setExactWindowSize(NSSize(width: 2560, height: 1440))
        XCTAssertEqual(wc.transitionPanel.tier, .full)
        wc.setClockDisplay(.never)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(AppTest.controller.layoutPreferences.clockDisplay, .never)
        XCTAssertEqual(wc.transitionPanel.tier, .noClock, "不显示：大窗口也不带时钟")
        XCTAssertFalse(wc.transitionPanel.isClockShown)
        XCTAssertTrue(AppTest.waitUntil(2) { !self.wc.bottomBar.statusBar.displayedClock.isEmpty }, "时间在状态行")
        // 旧排布也照这个偏好：不显示时钟
        wc.setArrangement(.legacy)
        defer { wc.setArrangement(.adaptive) }
        XCTAssertFalse(wc.transitionPanel.isClockShown, "旧排布照偏好不显示时钟")
        wc.setClockDisplay(.auto)
        XCTAssertTrue(wc.transitionPanel.isClockShown, "旧排布自动 = 今天的样子（带时钟）")
    }

    // MARK: M7 很宽的画布监看上下叠放

    /// 5760×1080 四种窗口都叠放（PVW 在上、PGM 在下，中间那一列挪到右边），尺寸照规则；2460×1080 不叠放；窗口连续缩放时不在两种摆法之间来回跳。
    func testM7_wideCanvasStacksMonitors() throws {
        for row in SpecTables.triple { checkSpecRow(row) }
        let session = try AppTest.freshSession()
        try AppTest.addLightInputs(session, count: 16)
        try AppTest.setCanvas(width: 5760, height: 1080)
        for row in SpecTables.triple {
            AppTest.setExactWindowSize(row.window)
            for mixer in [true, false] {
                setMixer(mixer)
                let m = AppTest.measureArrangement()
                let L = checkApp(m, window: row.window, canvas: row.canvas, mixer: mixer, spec: row, test: "M7")
                let label = "[\(size(row.window)) 5760×1080 调音台\(mixer ? "开" : "收")]"
                XCTAssertEqual(m.mode, .stacked, "\(label) 叠放")
                let root = wc.layoutView
                let pvw = root.convert(wc.previewMonitor.bounds, from: wc.previewMonitor)
                let pgm = root.convert(wc.programMonitor.bounds, from: wc.programMonitor)
                let column = root.convert(wc.transitionPanel.bounds, from: wc.transitionPanel)
                XCTAssertEqual(pvw.minY, 0, accuracy: 0.5, "\(label) PVW 在上")
                XCTAssertGreaterThanOrEqual(pgm.minY, pvw.maxY, "\(label) PGM 在下")
                XCTAssertEqual(pvw.midX, pgm.midX, accuracy: 0.5, "\(label) 上下对齐")
                XCTAssertGreaterThanOrEqual(column.minX, max(pvw.maxX, pgm.maxX), "\(label) 中间那一列挪到右边")
                XCTAssertEqual(column.height, L.topH, accuracy: 1)
                XCTAssertGreaterThan(m.picture.width * m.picture.height, L.sideIw * L.sideIh, "\(label) 叠放比并排大")
                // 叠放时下边一行至少留两行输入（这四种窗口并排时都不止一行）
                XCTAssertGreaterThanOrEqual(m.rows, 2, "\(label) 叠放时下边一行至少两行输入")
                XCTAssertEqual(m.rows, L.rows, "\(label) 输入几行")
            }
        }
        setMixer(true)
        try AppTest.setCanvas(width: 2460, height: 1080)
        for window in SpecTables.windows {
            AppTest.setExactWindowSize(window)
            XCTAssertEqual(AppTest.measureArrangement().mode, .sideBySide, "[\(size(window))] 2460×1080 不叠放")
        }
        // 连续缩放：对角拉大、只拉宽（高 900）两条路上，摆法最多换一次，不来回跳
        func switches(along path: [NSSize]) -> (count: Int, at: [String]) {
            var last: ArrangementMeasure.Mode?, count = 0, at: [String] = []
            for s in path {
                AppTest.resizeMainWindowQuickly(s)
                let mode = AppTest.measureArrangement().mode
                if let last, last != mode { count += 1; at.append("\(size(s))→\(mode.rawValue)") }
                last = mode
            }
            return (count, at)
        }
        let diagonal = (0...73).map { i -> NSSize in
            let f = CGFloat(i) / 73
            return NSSize(width: (1100 + f * 1460).rounded(), height: (720 + f * 720).rounded())
        }
        let wide = stride(from: CGFloat(1100), through: 2560, by: 20).map { NSSize(width: $0, height: 900) }
        for canvas in [(5760, 1080), (2460, 1080)] {
            try AppTest.setCanvas(width: canvas.0, height: canvas.1)
            for (name, path) in [("对角", diagonal), ("只拉宽", wide)] {
                let up = switches(along: path), down = switches(along: path.reversed())
                print("W6表 M7 连续缩放 \(canvas.0)×\(canvas.1) \(name)：拉大换 \(up.count) 次 \(up.at)，缩小换 \(down.count) 次 \(down.at)")
                XCTAssertLessThanOrEqual(up.count, 1, "[\(canvas.0)×\(canvas.1) \(name)] 拉大时不来回跳：\(up.at)")
                XCTAssertLessThanOrEqual(down.count, 1, "[\(canvas.0)×\(canvas.1) \(name)] 缩小时不来回跳：\(down.at)")
            }
        }
        // 32:9 只记数（方案的门槛在这一种画布上会在两处边界来回跳，报告 §4）
        try AppTest.setCanvas(width: 3840, height: 1080)
        let up32 = switches(along: diagonal)
        print("W6表 M7 连续缩放 3840×1080 对角（只记数）：换 \(up32.count) 次 \(up32.at)")
    }

    // MARK: 旧排布开关（规则 8）

    /// "窗口 › 排布 › 旧排布"：回到今天的样子（调音台在右侧通高、监看区自由高度），原来的布局断言照过；存本机；切回新排布。
    func testW6A_legacyArrangementMenuKeepsOldLayout() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let windowMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == L("menu.window") }?.submenu)
        let arrangement = try XCTUnwrap(windowMenu.items.first { $0.title == L("menu.window.arrangement") }?.submenu, "窗口 › 排布 ▸")
        XCTAssertEqual(arrangement.items.map(\.title), [L("arrangement.new"), L("arrangement.legacy")])
        for item in arrangement.items { _ = AppTest.delegate.validateMenuItem(item) }
        XCTAssertEqual(arrangement.items.map(\.state), [.on, .off], "默认新排布")
        defer { if wc.arrangement != .adaptive { wc.setArrangement(.adaptive) } }
        _ = NSApp.sendAction(arrangement.items[1].action!, to: nil, from: arrangement.items[1])
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(wc.arrangement, .legacy)
        XCTAssertEqual(AppTest.controller.layoutPreferences.arrangement, .legacy, "存本机")
        XCTAssertEqual(AppTest.controller.defaults.string(forKey: MainLayoutPreferences.Keys.arrangement), "legacy")
        for item in arrangement.items { _ = AppTest.delegate.validateMenuItem(item) }
        XCTAssertEqual(arrangement.items.map(\.state), [.off, .on])
        // 原来 MainWindowLayoutTests.testUI_splitKeepsInputStripMinimum 的断言（旧排布下照过）
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let content = try XCTUnwrap(wc.window?.contentView)
        let strip900 = wc.inputStrip.frame.height
        XCTAssertEqual(strip900, Theme.inputStripInitialHeight, accuracy: 1, "输入条 197（W5-A 原型实测）")
        XCTAssertGreaterThanOrEqual(strip900, 190)
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 1, "调音台 340")
        XCTAssertEqual(wc.mixerPanel.frame.height, content.bounds.height - Theme.bottomBarHeight, accuracy: 1, "调音台在右侧通高")
        XCTAssertEqual(wc.transitionPanel.tier, .full, "旧排布：中间那一列是今天的样子")
        XCTAssertNil(wc.previewMonitor.canvasAspect, "旧排布：监看区自由高度（画面在框里等比缩、四周黑）")
        XCTAssertEqual(wc.inputStrip.flow, .row, "旧排布：输入条一行、横向滚动")
        AppTest.setMainWindowSize(AppTest.minimumMainWindowSize)
        XCTAssertGreaterThanOrEqual(wc.inputStrip.frame.height, 190, "最小窗口时输入条不低于 190")
        XCTAssertGreaterThanOrEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth - 1, "最小窗口时调音台不窄于 340")
        XCTAssertGreaterThanOrEqual(wc.transitionPanel.frame.height, wc.transitionPanel.fittingSize.height - 0.5, "上半区放得下转场列")
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        XCTAssertEqual(wc.inputStrip.frame.height, strip900, accuracy: 1, "窗口放大的差额给上半区，输入条保持原高")
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 1, "调音台保持原宽")
        // 收起 / 展开调音台在旧排布里照旧
        wc.toggleMixerPanel()
        AppTest.pump(seconds: 0.1)
        XCTAssertFalse(wc.isMixerPanelVisible)
        wc.toggleMixerPanel()
        AppTest.pump(seconds: 0.1)
        XCTAssertTrue(wc.isMixerPanelVisible)
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 1)
        // 切回新排布
        _ = NSApp.sendAction(arrangement.items[0].action!, to: nil, from: arrangement.items[0])
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(wc.arrangement, .adaptive)
        XCTAssertEqual(AppTest.controller.layoutPreferences.arrangement, .adaptive)
        XCTAssertEqual(wc.inputStrip.flow, .wrap, "新排布：输入区折行")
        let m = AppTest.measureArrangement()
        XCTAssertEqual(m.mode, .sideBySide)
        XCTAssertEqual(m.mixerHeight, m.bottom, accuracy: 0.5, "新排布：调音台在下边一行")
    }

    // MARK: 节目格式页（§2.4）

    /// 分辨率预设加 1080×1920、720×1280、2160×3840；"横 ⇄ 竖"互换宽高（自定义照样换；换完超出自定义范围的不让换）。
    func testW6A_formatPagePortraitPresetsAndSwap() throws {
        _ = try AppTest.freshSession()
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        panels.showSettings(page: .showFormat)
        let prefs = try XCTUnwrap(panels.settingsWindow).model.preferences
        for r in [(1080, 1920), (720, 1280), (2160, 3840)] {
            XCTAssertTrue(PreferencesModel.resolutions.contains { $0 == r }, "预设有 \(r.0)×\(r.1)")
        }
        for r in [(1920, 1080), (1280, 720), (2560, 1440), (3840, 2160)] {
            XCTAssertTrue(PreferencesModel.resolutions.contains { $0 == r }, "原来的预设还在：\(r.0)×\(r.1)")
        }
        XCTAssertEqual(prefs.programFormat.width, 1920)
        XCTAssertTrue(prefs.canSwapOrientation)
        prefs.swapOrientation()
        XCTAssertEqual(prefs.formatWidth, 1080)
        XCTAssertEqual(prefs.formatHeight, 1920)
        XCTAssertFalse(prefs.isCustomResolution, "1080×1920 是预设")
        XCTAssertEqual(prefs.pendingRestart, [.format], "换了格式 = 待应用")
        prefs.swapOrientation()
        XCTAssertEqual(prefs.programFormat.width, 1920)
        XCTAssertEqual(prefs.programFormat.height, 1080)
        XCTAssertTrue(prefs.pendingRestart.isEmpty, "换回来就不算")
        prefs.setCustomResolution(width: 1000, height: 600)
        prefs.swapOrientation()
        XCTAssertEqual(prefs.formatWidth, 600)
        XCTAssertEqual(prefs.formatHeight, 1000)
        XCTAssertTrue(prefs.isCustomResolution)
        prefs.selectFormatPreset(ProgramFormat(width: 3840, height: 2160, frameRate: .fps30))
        prefs.swapOrientation()
        XCTAssertEqual(prefs.formatWidth, 2160)
        XCTAssertEqual(prefs.formatHeight, 3840, "2160×3840 是预设")
        XCTAssertFalse(prefs.isCustomResolution)
        prefs.setCustomResolution(width: 7680, height: 4320)
        XCTAssertFalse(prefs.canSwapOrientation, "7680 高超出自定义范围（240–4320）：不让换")
        prefs.swapOrientation()
        XCTAssertEqual(prefs.formatWidth, 7680, "不让换就不动")
        XCTAssertFalse(L("settings.format.swap").isEmpty)
        XCTAssertFalse(L("settings.format.swapTip").isEmpty)
    }
}
