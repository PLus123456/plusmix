// W5-A（prompt 86）用例的公共工具：摆主窗口尺寸、量弹出菜单的真实位置（CGWindowList，只看本进程的窗口边界，不要屏幕录制权限）、
// 按段拆外部输出菜单、算对比度、在视图树里找控件、把 SwiftUI 视图渲成位图量排版（cacheDisplay 截不到 SwiftUI 的内容，探针见 reports/w5-app-visual.md §5）。
import AppKit
import SwiftUI
import XCTest
@testable import Switcher

@MainActor
extension AppTest {
    /// 第一次 freshSession 时主窗口的位置（之后每条用例开始时摆回这里）。
    private static var initialMainWindowFrame: NSRect?

    /// 主窗口界面回到初始样子：调音台展开、主窗口回到第一次见到时的位置和大小（W5-A 起打开节目会读回 Show.layout，
    /// 前面的用例开过"调音台收起 / 主窗口在 (0, 0)"的节目，例如 ShowRoundTripTests 的全字段夹具）。
    static func resetMainWindowUI() {
        let wc = controller.windowController
        guard let window = wc.window else { return }
        if initialMainWindowFrame == nil { initialMainWindowFrame = window.frame }
        if !wc.isMixerPanelVisible { wc.toggleMixerPanel() }
        if let frame = initialMainWindowFrame, window.frame != frame {
            window.setFrame(frame, display: true)
            pump(seconds: 0.05)
        }
    }

    /// 主窗口改成给定尺寸、摆在它所在屏幕的可见区正中，泵一下让布局跟上。返回新 frame。
    @discardableResult
    static func setMainWindowSize(_ size: NSSize) -> NSRect {
        guard let window = controller.windowController.window else { return .zero }
        let screen = window.screen ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        pump(seconds: 0.2)
        window.contentView?.layoutSubtreeIfNeeded()
        return window.frame
    }

    /// 主窗口能缩到的最小尺寸（W5-G：工具条那一行算在窗口外框里，最小窗口从 1100×700 变成"内容区仍是原来 1100×700 时那么大"的外框，
    /// macOS 27 上 1100×720；测"最小窗口时布局还在"的用例用它，不再写死 700——setFrame 不受 minSize 约束，写死就会量到用户拖不到的尺寸）。
    static var minimumMainWindowSize: NSSize {
        controller.windowController.window?.minSize ?? NSSize(width: 1100, height: 700)
    }

    /// 加 n 路合成源并等它们 live（AppTest.addSynthetics 的灰度是 UInt8(64 + 32 × n)，6 路时溢出崩溃；这里灰度按路数摊开，最多 16 路）。
    static func addSyntheticInputs(_ session: SwitcherSession, count: Int) throws {
        for n in 1...count { session.send(.addInput(config: syntheticConfig(number: n, gray: UInt8(48 + (200 * n) / max(count, 1))))) }
        guard waitUntil(10, { session.state.inputs.count == count && (1...count).allSatisfy { session.inputs.runtimeState(of: $0) == .live } }) else {
            throw XCTSkip("合成源没起来：\(session.state.inputs.map(\.number))")
        }
    }

    /// 本进程屏上的弹出菜单窗口（层 = popUpMenuWindow），换成 Cocoa 屏幕坐标（原点在主屏左下）。
    static func popUpMenuWindowFrames() -> [NSRect] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { w -> NSRect? in
            guard (w[kCGWindowOwnerPID as String] as? Int) == pid, (w[kCGWindowLayer as String] as? Int) == level,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
    }

    /// 窗口服务器眼里这个窗口的边界（Cocoa 屏幕坐标）。测试宿主不在前台、窗口所在的屏被别的 App 盖着时，setFrame 之后 AppKit 的 window.frame
    /// 已经是新值，窗口服务器里还是"保留左上角、只改了大小"的中间值，菜单按窗口服务器的位置摆——量菜单时拿同一个来源比。
    static func windowServerFrame(of window: NSWindow) -> NSRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let dict = list.first?[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 弹一次模态菜单（open 里调 popUp），菜单开着时量本进程的弹出菜单窗口，量完 cancel 掉。菜单没真弹出来（测试宿主不在前台等）返回空。
    static func measurePoppedMenu(open: () -> Void, menu: @escaping @MainActor () -> NSMenu?) -> [NSRect] {
        var frames: [NSRect] = []
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                frames = popUpMenuWindowFrames()
                menu()?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        open()
        timer.invalidate()
        pump(seconds: 0.1)
        return frames
    }

    /// 外部输出菜单按分隔线拆成段（拍平以后每块显示器一段，段首是这块屏的段标题；最后一段是已有输出的删除 / 全部关闭）。
    static func menuSections(_ menu: NSMenu) -> [[NSMenuItem]] {
        var out: [[NSMenuItem]] = [[]]
        for item in menu.items {
            if item.isSeparatorItem { out.append([]) } else { out[out.count - 1].append(item) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// WCAG 相对亮度的对比度（sRGB）。
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let s = c.usingColorSpace(.sRGB) ?? c
            func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 视图树里所有满足条件的视图（深度优先）。
    static func descendants<T: NSView>(of root: NSView, as type: T.Type, where match: (T) -> Bool = { _ in true }) -> [T] {
        var out: [T] = []
        func walk(_ v: NSView) {
            if let t = v as? T, match(t) { out.append(t) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// 视图在 ancestor 坐标里的对齐矩形（自动布局按它排；推按钮 / 分段控件的对齐矩形 = 画出来的边框）。
    static func alignmentFrame(_ view: NSView, in ancestor: NSView) -> NSRect {
        guard let superview = view.superview else { return .zero }
        return ancestor.convert(view.alignmentRect(forFrame: view.frame), from: superview)
    }

    /// 把 SwiftUI 视图按给定尺寸渲成位图，返回第一行有不透明像素的 y（从上量，pt）。平台控件渲成占位，只看排版不看控件长相。
    static func firstOpaqueRow<V: View>(of view: V, size: CGSize) -> Int? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        for y in 0..<rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { return y }
        }
        return nil
    }
}
