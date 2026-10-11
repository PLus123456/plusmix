// W3-E prompt 测试第 3 条：无障碍——所有控件有 accessibility label（脚本检查）。
// "脚本"= 这里的遍历：打开每个面板，沿 NSAccessibility 树（AppKit 视图 + NSHostingView 里 SwiftUI 的元素）走一遍，
// 按钮 / 复选框 / 单选 / 弹出菜单 / 滑杆 / 文本框 / 步进器 / 颜色井 每一个都要有 label 或 title。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class AccessibilityTests: XCTestCase {
    func testAccessibility_allPanelControlsHaveLabels() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let wc = controller.windowController
        let panels = controller.panels
        var violations: [String] = []
        var counts: [String: Int] = [:]

        func check(_ name: String, _ root: Any?) {
            guard let root else { violations.append("\(name)：没有视图"); return }
            AppTest.pump(seconds: 0.3)
            let v = AppTest.accessibilityViolations(in: root)
            let counted = AppTest.accessibilityControlCount(in: root)
            print("无障碍：\(name) AppKit 层控件 \(counted) 个，缺 label \(v.count) 个")
            let window = String(name.split(separator: " ").first ?? Substring(name))
            counts[window, default: 0] += counted
            violations += v.map { "\(name)：\($0)" }
        }

        // 主窗口的各区（底栏、转场列、缩略图条、调音台）
        check("主窗口", wc.window?.contentView)

        wc.presentAddInput()
        let sheet = try XCTUnwrap(wc.window?.attachedSheet?.windowController as? AddInputSheetController)
        for kind in AddInputModel.Kind.allCases {
            sheet.selectKindForTesting(kind)
            check("添加输入 · \(kind)", sheet.window?.contentView)
        }
        sheet.cancelForTesting()

        let input = try XCTUnwrap(panels.showInputSettings(input: 1))
        for section in InputSettingsModel.Section.allCases {
            input.model.section = section
            check("输入设置 · \(section)", input.window?.contentView)
        }
        let output = panels.showOutputSettings(tab: .record)
        _ = output.model.addStream(url: "rtmp://127.0.0.1/live", key: "k")
        for tab in OutputSettingsModel.Tab.allCases {
            output.model.tab = tab
            check("输出设置 · \(tab)", output.window?.contentView)
        }
        check("偏好设置", panels.showPreferences().window?.contentView)
        check("快捷键编辑器", panels.showHotkeyEditor().window?.contentView)
        check("MIDI 映射", panels.showMIDIMapping().window?.contentView)
        // W5-K：叠加从底栏浮层改成独立的叠加设置窗（I1）；音频设置窗（J2）同样查一遍
        let overlay = panels.showOverlaySettings(channel: 1)
        for channel in 1...MixerState.overlayCount {
            overlay.model.channel = channel
            check("叠加设置 · \(channel)", overlay.window?.contentView)
        }
        for strip in [AudioStrip.bus(.master), .input(1)] {
            check("音频设置 · \(strip)", panels.showAudioSettings(strip)?.window?.contentView)
        }
        wc.transitionPanel.showSlotParams(slot: 2)   // W3-E2：转场参数弹出面板（W5-M 起在每个槽的 ▾ 里，按槽编辑）
        check("转场参数", wc.transitionPanel.paramsPopoverContentView)
        wc.transitionPanel.closeSlotParams()
        panels.closeAll()

        // 纯 SwiftUI 的窗口在 AppKit 层可能一个控件都没有（MIDI 映射），只要求总数 > 0（主窗口 + 调音台的竖推子）且主窗口 > 0
        XCTAssertGreaterThan(counts.values.reduce(0, +), 0, "应至少遍历到一个控件（树没走进去？）：\(counts)")
        XCTAssertGreaterThan(counts["主窗口"] ?? 0, 10, "主窗口的 AppKit 控件应都遍历到：\(counts)")
        XCTAssertEqual(violations, [], "缺 accessibility label 的控件：\n" + violations.joined(separator: "\n"))
    }
}

@MainActor
final class AccessibilitySourceScanTests: XCTestCase {
    /// SwiftUI 那一层的 label 在源码里就能查：每个控件构造带文案（NSHostingView 不把 SwiftUI 自己的辅助功能元素暴露给进程内的 NSAccessibility 遍历，
    /// 运行期只能查到 AppKit 那一层，见 testAccessibility_allPanelControlsHaveLabels）。
    func testAccessibility_swiftUIControlsDeclareLabels() throws {
        let root = try AppTest.repoRoot().appendingPathComponent("App/Sources")
        let violations = try AppTest.swiftUIControlLabelViolations(in: root)
        XCTAssertEqual(violations, [], "SwiftUI 控件缺 label：\n" + violations.joined(separator: "\n"))
    }
}
