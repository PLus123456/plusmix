// W5-A（prompt 86）交付 6 的目视 S3（docs/ui-study/03-目视检查.md §3）：调音台内容顶对齐（V-03）、PVW 标题条对比度（V-06）、
// 偏好设置数字不加千分位（V-12）、文件 / 图片路径为空时有占位（V-17）、声像滑块中点刻度且不填充（V-27）。
// SwiftUI 的排版用 ImageRenderer 渲成位图量（cacheDisplay 截不到 SwiftUI 的内容）；AppKit 自绘的部分直接画进位图看像素。
import AppKit
import SwiftUI
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class VisualDetailTests: XCTestCase {
    /// V-03：调音台内容贴顶，不再垂直居中（原来 1440×900 下上下各空约 250 pt）。
    func testUI_mixerContentTopAligned() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let panel = AppTest.controller.windowController.mixerPanel
        XCTAssertTrue(AppTest.waitUntil(3) { panel.model.state.inputs.count == 2 })
        let top = try XCTUnwrap(AppTest.firstOpaqueRow(of: MixerView(model: panel.model, meters: panel.meters), size: CGSize(width: 340, height: 800)))
        print("调音台 340×800：第一行内容 y = \(top)")
        XCTAssertLessThanOrEqual(top, 16, "调音台内容应贴顶（表头上边距 8），不居中")
    }

    /// V-06：PVW 标题条白字压绿底的对比度 ≥ 4.5:1（原来 3.5:1）；PGM 红底同样。
    func testUI_tallyTitleBarsContrast() {
        let pvw = AppTest.contrastRatio(.white, Theme.tallyPreview)
        let pgm = AppTest.contrastRatio(.white, Theme.tallyProgram)
        print("标题条对比度：PVW \(String(format: "%.2f", pvw)):1，PGM \(String(format: "%.2f", pgm)):1")
        XCTAssertGreaterThanOrEqual(pvw, 4.5, "PVW 标题条白字对比度")
        XCTAssertGreaterThanOrEqual(pgm, 4.5, "PGM 标题条白字对比度")
    }

    /// V-12：偏好设置里分辨率写"1920×1080"、端口写"8098"，不按本地数字格式加千分位。
    func testUI_preferencesNumbersNotGrouped() throws {
        XCTAssertEqual(PreferencesModel.resolutionTitle(width: 1920, height: 1080), "1920×1080")
        XCTAssertEqual(PreferencesModel.resolutionTitle(width: 3840, height: 2160), "3840×2160")
        XCTAssertEqual(PreferencesModel.plainInteger.format(8098), "8098")
        XCTAssertEqual(PreferencesModel.plainInteger.locale(Locale(identifier: "en_US")).format(65535), "65535")
        // 源码里不再有会被 SwiftUI 按本地格式排数字的写法（Text("\(数字)") 走 LocalizedStringKey；TextField 的 .number 默认带千分位）
        let source = try String(contentsOf: AppTest.repoRoot().appendingPathComponent("App/Sources/Settings/PreferencesPanel.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("format: .number)"), "端口 / 数字输入框用 PreferencesModel.plainInteger")
        XCTAssertFalse(source.contains("Text(\"\\("), "数字文字用 Text(verbatim:)")
    }

    /// V-17：添加输入 › 文件 / 图片，路径为空时路径框里有"未选择文件"占位（原来空着、在分组表单里看不见框）。
    func testUI_addInputEmptyPathShowsPlaceholder() throws {
        _ = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        let sheet = try XCTUnwrap(window.attachedSheet)
        let controller = try XCTUnwrap(sheet.windowController as? AddInputSheetController)
        defer {
            controller.cancelForTesting()
            _ = AppTest.waitUntil(3) { window.attachedSheet == nil }
        }
        let placeholder = L("addInput.path.none")
        XCTAssertEqual(placeholder, "未选择文件")
        for kind in [AddInputModel.Kind.file, .image] {
            controller.selectKindForTesting(kind)
            AppTest.pump(seconds: 0.3)
            let fields = AppTest.descendants(of: try XCTUnwrap(sheet.contentView), as: NSTextField.self) { f in
                f.isEditable && (f.placeholderString == placeholder || f.placeholderAttributedString?.string == placeholder)
            }
            XCTAssertEqual(fields.count, 1, "\(kind)：路径框应有\"未选择文件\"占位")
        }
    }

    /// V-27：声像滑块中点有刻度、轨道不填充（系统滑块从左往右填强调色，pan = 0 时显示半条蓝，像是偏了）。
    func testUI_panSliderCenterTickNoFill() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let panel = AppTest.controller.windowController.mixerPanel
        XCTAssertTrue(AppTest.waitUntil(3) { AppTest.descendants(of: panel, as: NSSlider.self) { $0.cell is PanSliderCell }.count == 2 },
                      "每路一个声像滑块（PanSliderCell）")
        let slider = try XCTUnwrap(AppTest.descendants(of: panel, as: NSSlider.self) { $0.cell is PanSliderCell }.first)
        XCTAssertEqual(slider.minValue, -1)
        XCTAssertEqual(slider.maxValue, 1)
        XCTAssertFalse(slider.accessibilityLabel()?.isEmpty ?? true, "有辅助功能标签")

        // 直接把轨道画进位图：把手在 +0.5 时，中点左右两段轨道同色（不填充），中点那一列是刻度（比轨道亮）
        let cell = PanSliderCell()
        let size = NSSize(width: 120, height: 16)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cell.drawBar(inside: NSRect(x: 0, y: 6, width: size.width, height: 4), flipped: true)
        NSGraphicsContext.restoreGraphicsState()
        func color(_ x: Int) -> NSColor? { rep.colorAt(x: x, y: Int(size.height / 2)) }
        let left = try XCTUnwrap(color(20)), right = try XCTUnwrap(color(100)), center = try XCTUnwrap(color(Int(size.width / 2)))
        XCTAssertEqual(left.redComponent, right.redComponent, accuracy: 0.02, "轨道左右同色（不填充）：\(left) / \(right)")
        XCTAssertEqual(left.blueComponent, right.blueComponent, accuracy: 0.02)
        XCTAssertGreaterThan(left.alphaComponent, 0.3, "轨道画出来了")
        XCTAssertGreaterThan(center.redComponent, left.redComponent + 0.1, "中点刻度比轨道亮")
    }
}
