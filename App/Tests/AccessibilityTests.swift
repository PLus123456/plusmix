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

        func check(_ name: String, _ root: Any?) {
            guard let root else { violations.append("\(name)：没有视图"); return }
            AppTest.pump(seconds: 0.15)
            let v = AppTest.accessibilityViolations(in: root)
            let counted = AppTest.accessibilityControlCount(in: root)
            print("无障碍：\(name) 控件 \(counted) 个，缺 label \(v.count) 个")
            XCTAssertGreaterThan(counted, 0, "\(name)：应至少遍历到一个控件（树没走进去？）")
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
        wc.presentOverlayPanel(relativeTo: wc.bottomBar.overlayButton)
        check("叠加面板", wc.overlayPanelController?.view)
        panels.closeAll()

        XCTAssertEqual(violations, [], "缺 accessibility label 的控件：\n" + violations.joined(separator: "\n"))
    }
}
