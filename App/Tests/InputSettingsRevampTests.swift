// W5-K（prompt 97 交付 2）输入设置的其余几条：分节按使用频率排、"音频延迟补偿"（H1 / H8）、从其他输入复制（H4）、复位 / 恢复默认 / 复制粘贴位置（H5）、
// 名字失焦即改名（H7）、本路画面点击位置的换算（H6，按比例放留黑边）。主用例（本路画面、取色、跟随视频）在 PanelsRevampTests。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import Switcher

@MainActor
final class InputSettingsRevampTests: XCTestCase {
    func testPanels_inputSettingsSectionsOrderedByUse() {
        XCTAssertEqual(InputSettingsModel.Section.allCases, [.general, .keyer, .geometry, .audio, .effects, .source])
        XCTAssertEqual(InputSettingsModel.Section.allCases.map(\.title), ["基本", "抠像", "裁切与位置", "音频", "音频效果", "来源"], "H1：按现场使用频率排；音频效果紧跟音频（G6 追加 ①）")
        XCTAssertTrue(L("inputSettings.audio.delay").hasPrefix("音频延迟补偿"), "H8：免得和按帧的视频延迟混")
        XCTAssertEqual(L10n.string("inputSettings.audio.delay", language: "en"), "Audio delay compensation (ms)")
        XCTAssertEqual(L10n.string("inputSettings.general.applyName", language: "zh-Hans"), "inputSettings.general.applyName", "H7：没有单独的'应用名字'按钮了（键也删了）")
    }

    func testPanels_inputSettingsCopyFromOtherInput() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        var source = try XCTUnwrap(session.state.input(1)).settings
        source.crop = CropInsets(left: 0.1, top: 0.2, right: 0, bottom: 0)
        source.transform.scale = 0.5
        source.keyer = KeyerSettings(enabled: true, keyColor: RGB8(red: 1, green: 200, blue: 3), tolerance: 0.4, softness: 0.2, spillSuppression: 0.7)
        source.audio.gainDb = -9
        source.effects = [AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.02, preGainDb: 2)]
        session.send(.setInputSettings(input: 1, settings: source))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings == source })
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w = try XCTUnwrap(panels.showInputSettings(input: 2))
        XCTAssertEqual(w.model.otherInputs.map(\.number), [1], "来源下拉列别的输入")
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        w.model.copy(from: 1, groups: [.geometry, .keyer])
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(2)?.settings.keyer == source.keyer }, "\(String(describing: session.state.input(2)?.settings.keyer))")
        let target = try XCTUnwrap(session.state.input(2)).settings
        XCTAssertEqual(target.crop, source.crop)
        XCTAssertEqual(target.transform, source.transform)
        XCTAssertEqual(target.audio.gainDb, 0, "没勾的组不动")
        XCTAssertEqual(target.effects, [])
        let commands = session.control.bus.recentEntries().filter { $0.sequence > since }.map(\.command)
        XCTAssertEqual(commands.filter { if case .setInputSettings(2, _) = $0 { return true } else { return false } }.count, 1, "一次 setInputSettings：\(commands)")
        w.model.copy(from: 1, groups: [.audio, .effects])
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(2)?.settings.audio.gainDb == -9 && session.state.input(2)?.settings.effects == source.effects })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    func testPanels_inputSettingsResetsAndPositionClipboard() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w1 = try XCTUnwrap(panels.showInputSettings(input: 1))
        w1.model.update { $0.crop = CropInsets(left: 0.25, top: 0, right: 0.1, bottom: 0); $0.transform = Transform2D(scale: 0.4, offsetX: 0.3, offsetY: -0.2) }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.transform.scale == 0.4 })
        // 复制位置 → 2 号粘贴（App 内剪贴板，不进系统剪贴板）
        w1.model.copyPosition()
        let w2 = try XCTUnwrap(panels.showInputSettings(input: 2))
        XCTAssertTrue(w2.model.canPastePosition)
        w2.model.pastePosition()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(2)?.settings.transform == session.state.input(1)?.settings.transform
            && session.state.input(2)?.settings.crop == session.state.input(1)?.settings.crop })
        // 每组复位
        w1.model.resetCrop()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.crop == CropInsets.none })
        XCTAssertEqual(session.state.input(1)?.settings.transform.scale, 0.4, "复位裁切不动位置")
        w1.model.resetTransform()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.transform == .identity })
        // 抠像恢复默认：开着的还开着，参数回默认
        w1.model.update { $0.keyer = KeyerSettings(enabled: true, keyColor: RGB8(red: 9, green: 9, blue: 9), tolerance: 0.9, softness: 0.9, spillSuppression: 0.1) }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.keyer.tolerance == 0.9 })
        w1.model.restoreKeyerDefaults()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.keyer == KeyerSettings(enabled: true) })
        // 音频整组复位：增益 / 声像 / 延迟回默认，开关不动
        w1.model.update { $0.audio.gainDb = -12; $0.audio.pan = 0.5; $0.audio.delayMs = 80; $0.audio.muted = true }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.audio.delayMs == 80 })
        w1.model.resetAudio()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.audio.gainDb == 0 && session.state.input(1)?.settings.audio.pan == 0
            && session.state.input(1)?.settings.audio.delayMs == 0 })
        XCTAssertEqual(session.state.input(1)?.settings.audio.muted, true)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    func testPanels_inputSettingsNameCommitsOnFocusLoss() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w = try XCTUnwrap(panels.showInputSettings(input: 1))
        // 正在编辑：快照回来不盖掉没提交的字
        w.model.isEditingName = true
        w.model.name = "主机位"
        session.send(.setPreview(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.preview == 1 })
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(w.model.name, "主机位")
        XCTAssertEqual(session.state.input(1)?.name, "合成 1", "还没提交")
        // 失焦 = 提交
        w.model.isEditingName = false
        w.model.commitName()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.name == "主机位" })
        // 关窗也提交
        w.model.name = "主机位 · 近"
        w.close()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.name == "主机位 · 近" })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    func testPanels_inputPreviewClickMapsIntoLetterboxedPicture() {
        // 这一格是 400×200 px（2:1），放进 300×300 的视图：宽撑满 300、高 150，上下各留 75 黑边
        let rect = NormalizedRect(x: 0.25, y: 0.5, width: 0.2, height: 0.2)
        let texture = NSSize(width: 2000, height: 1000)
        let view = NSSize(width: 300, height: 300)
        XCTAssertEqual(InputPreviewContainer.normalizedPoint(NSPoint(x: 150, y: 150), viewSize: view, sourceRect: rect, textureSize: texture), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(InputPreviewContainer.normalizedPoint(NSPoint(x: 0, y: 75), viewSize: view, sourceRect: rect, textureSize: texture), CGPoint(x: 0, y: 0))
        XCTAssertEqual(InputPreviewContainer.normalizedPoint(NSPoint(x: 300, y: 225), viewSize: view, sourceRect: rect, textureSize: texture), CGPoint(x: 1, y: 1))
        XCTAssertNil(InputPreviewContainer.normalizedPoint(NSPoint(x: 150, y: 40), viewSize: view, sourceRect: rect, textureSize: texture), "点到黑边不取")
        XCTAssertNil(InputPreviewContainer.normalizedPoint(NSPoint(x: 150, y: 150), viewSize: .zero, sourceRect: rect, textureSize: texture))
    }
}
