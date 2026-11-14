// W6-A（prompt 144）交付 7 / M5（docs/spec/大屏与时间线方案.md §2.1 规则 6）：调音台的高度跟着位置走。
// 新排布里调音台在下边一行（横屏）或右边一栏的下半（竖屏），高 200–600：推子按可用高度算（行高够就和今天一样 170，更高跟着变长，不够时缩短、最短 60），
// 再不够就把声像、总线送出、跟随视频三行收进条子的齿轮。SwiftUI 的行用条子上报的位置量（MixerModel.reportsLayout，只在用例里开），推子是 AppKit 的 NSSlider 直接量。
import AppKit
import SwiftUI
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class MixerAdaptiveHeightTests: XCTestCase {
    /// 把一块调音台单独摆进一个窗口，量它在给定高度下的样子。
    @MainActor
    private final class Bench {
        let panel: MixerPanelView
        let window: NSWindow
        init(adaptive: Bool, state: MixerState) {
            panel = MixerPanelView(frame: NSRect(x: 0, y: 0, width: Theme.mixerPanelWidth, height: 380))
            panel.adaptiveHeight = adaptive
            panel.model.reportsLayout = true
            panel.apply(state: state)
            window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: Theme.mixerPanelWidth, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: Theme.mixerPanelWidth, height: 380))
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.autoresizingMask = [.width, .height]
            panel.frame = host.bounds
            host.addSubview(panel)
            window.contentView = host
            window.orderFront(nil)
        }
        func resize(height: CGFloat) {
            window.setContentSize(NSSize(width: Theme.mixerPanelWidth, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            AppTest.pump(seconds: 0.25)
            window.contentView?.layoutSubtreeIfNeeded()
            AppTest.pump(seconds: 0.05)
        }
        var frames: [String: CGRect] { panel.model.layoutProbe }
        var faders: [NSSlider] { AppTest.descendants(of: panel, as: NSSlider.self) { $0.isVertical } }
        func close() { window.orderOut(nil); window.close() }
    }

    /// 200、269、317、380、537 五种高度：推子与各行都在面板里（不被裁）、推子点得到、最短 60；放得下整条时整条（声像 / 总线送出 / 跟随视频在条子上），
    /// 放不下时这三行收进条子的齿轮（菜单）；推子随高度变长；高度 = 今天的自然高时推子和今天一样长（170）。
    func testM5_mixerAdaptsHeight() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.inputs.count == 2 })
        let inputs = session.state.inputs.map(\.number)

        // 今天的样子（旧排布，推子写死 170）：量出整条的自然高
        let legacy = Bench(adaptive: false, state: session.state)
        legacy.resize(height: 700)
        let legacyFrames = legacy.frames
        let natural = try XCTUnwrap(legacyFrames["panel.footer"]?.maxY, "旧排布的调音台上报了底行")
        let legacyFader = try XCTUnwrap(legacyFrames["in\(inputs[0]).fader"]?.height)
        legacy.close()
        XCTAssertEqual(legacyFader, 170, accuracy: 0.5, "旧排布推子 170（今天的样子）")
        print("W6表 M5 今天的调音台：自然高 \(natural)，推子 \(legacyFader)")

        let bench = Bench(adaptive: true, state: session.state)
        defer { bench.close() }
        var faderHeights: [(full: Bool, height: CGFloat)] = []
        for h in [200, 269, 317, 380, 537].map(CGFloat.init) {
            bench.resize(height: h)
            let f = bench.frames
            let label = "[调音台高 \(Int(h))]"
            XCTAssertEqual(bench.panel.bounds.height, h, accuracy: 0.5, label)
            func inside(_ key: String, horizontally: Bool = false) {
                guard let r = f[key] else { return XCTFail("\(label) 没有上报 \(key)：\(f.keys.sorted())") }
                XCTAssertGreaterThanOrEqual(r.minY, -0.5, "\(label) \(key) 顶上被裁：\(r)")
                XCTAssertLessThanOrEqual(r.maxY, h + 0.5, "\(label) \(key) 底下被裁：\(r)")
                XCTAssertGreaterThan(r.height, 0, "\(label) \(key) 高 0")
                if horizontally {
                    XCTAssertGreaterThanOrEqual(r.minX, -0.5, "\(label) \(key) 左边被裁")
                    XCTAssertLessThanOrEqual(r.maxX, bench.panel.bounds.width + 0.5, "\(label) \(key) 右边被裁")
                }
            }
            inside("panel.header", horizontally: true)
            inside("panel.footer", horizontally: true)
            // 每路输入条：名字、表和推子、读数、静音与独听总在；声像、总线送出、跟随视频在条子上或收进齿轮
            let full = f["in\(inputs[0]).pan"] != nil
            for n in inputs {
                for row in ["name", "fader", "gain", "muteSolo"] { inside("in\(n).\(row)") }
                if full {
                    for row in ["pan", "routing", "follow"] { inside("in\(n).\(row)") }
                    XCTAssertNil(f["in\(n).menu"], "\(label) 整条时齿轮照旧开音频设置")
                } else {
                    for row in ["pan", "routing", "follow"] { XCTAssertNil(f["in\(n).\(row)"], "\(label) 收起的行不在条子上") }
                    inside("in\(n).menu")
                }
            }
            // Master 条常驻最右：名字、表和推子、读数、静音都在面板里
            for row in ["name", "fader", "gain", "mute"] { inside("bus.master.\(row)", horizontally: true) }
            if !full { inside("bus.master.menu", horizontally: true) }
            // 推子（NSSlider）：在面板里、最短 60、点得到
            let sliders = bench.faders
            XCTAssertGreaterThanOrEqual(sliders.count, 2, "\(label) 至少有输入条和 Master 的推子")
            var shortest = CGFloat.infinity
            for s in sliders {
                let r = bench.panel.convert(s.bounds, from: s)
                guard r.maxX > 0, r.minX < bench.panel.bounds.width else { continue }   // 横向滚出去的输入条
                XCTAssertGreaterThanOrEqual(r.minY, -0.5, "\(label) 推子顶上被裁")
                XCTAssertLessThanOrEqual(r.maxY, h + 0.5, "\(label) 推子底下被裁")
                XCTAssertGreaterThanOrEqual(r.height, 60 - 0.5, "\(label) 推子最短 60：\(r.height)")
                let center = bench.panel.superview!.convert(NSPoint(x: r.midX, y: r.midY), from: bench.panel)
                // 点到推子本身或它里面的视图（macOS 27 的 NSSlider 里面还有一层 _NSCoreHostingView 画滑块）
                let hit = bench.panel.superview?.hitTest(center)
                XCTAssertTrue(hit === s || hit?.isDescendant(of: s) == true, "\(label) 推子点得到：命中 \(String(describing: hit.map { type(of: $0) }))")
                shortest = min(shortest, r.height)
            }
            faderHeights.append((full, shortest))
            // 放得下整条（推子 60）时一定是整条；高度 ≥ 今天的自然高时推子 = 170 + 多出来的高
            let fullFits = h >= natural - legacyFader + 60
            XCTAssertEqual(full, fullFits, "\(label) 放得下整条（需要 \(natural - legacyFader + 60)）就整条，放不下才收进齿轮")
            if let fader = f["in\(inputs[0]).fader"]?.height, full {
                XCTAssertEqual(fader, legacyFader + (h - natural), accuracy: 2, "\(label) 整条时推子 = 170 + (行高 − 今天的自然高 \(natural))")
            }
            print("W6表 M5 调音台高 \(Int(h))：\(full ? "整条" : "紧凑（三行收进齿轮）")，推子 \(f["in\(inputs[0]).fader"]?.height ?? -1)，Master 推子 \(f["bus.master.fader"]?.height ?? -1)")
        }
        // 推子随高度变长（同一种摆法里）。整条 → 紧凑那一下推子反而变长：规则是先缩推子（最短 60），再不够才把三行收进齿轮，收起来的高给推子
        for mode in [true, false] {
            let heights = faderHeights.filter { $0.full == mode }.map(\.height)
            XCTAssertEqual(heights, heights.sorted(), "\(mode ? "整条" : "紧凑")：推子随高度变长 \(heights)")
        }
        XCTAssertEqual(faderHeights.map(\.full), faderHeights.map(\.full).sorted { !$0 && $1 }, "矮的用紧凑、高的用整条，中间只换一次")
    }

    /// 收进齿轮的三行在菜单里还能改：跟随视频、总线送出（发 setInputSettings），声像打开输入设置。
    func testM5_compactStripMenuKeepsHiddenControls() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let model = AppTest.controller.windowController.mixerPanel.model
        XCTAssertTrue(AppTest.waitUntil(3) { model.state.inputs.count == 1 })
        let before = try XCTUnwrap(session.state.input(1)?.settings.audio)
        model.setInputAFV(1, on: !before.afv)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.afv == !before.afv }, "菜单里的跟随视频与条子上的开关同一个动作")
        model.setRouting(1, bus: .busA, on: !before.routing.busA)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.routing.busA == !before.routing.busA }, "总线送出")
        var opened: Int?
        let saved = model.onOpenInputSettings
        defer { model.onOpenInputSettings = saved }
        model.onOpenInputSettings = { opened = $0 }
        model.openPanSettings(1)
        XCTAssertEqual(opened, 1, "声像…打开输入设置（音频一节有声像滑块）")
        XCTAssertEqual(MixerModel.panText(0), L("mixer.pan.center"))
        XCTAssertTrue(MixerModel.panText(-0.3).hasPrefix("L"))
        XCTAssertTrue(MixerModel.panText(0.5).hasPrefix("R"))
    }
}
