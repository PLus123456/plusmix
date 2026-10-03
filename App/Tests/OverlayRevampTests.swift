// W5-K（prompt 97 交付 3）叠加设置的其余几条：新节目四通道默认淡入 0.5 s、按节目帧率换拍（I3）；整幅时位置 / 锚点 / 边框收起、画中画预设不含整幅（I2）；
// 菜单栏"切换 › Overlay ▸ › 叠加设置…"（规则 5）。主用例（开着窗点格子的 1 不关）在 PanelsRevampTests。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class OverlayRevampTests: XCTestCase {
    func testPanels_newShowOverlaysDefaultHalfSecondFade() throws {
        let show = ShowDocuments.emptyShow()
        XCTAssertEqual(show.mixer.format.frameRate, .fps60)
        XCTAssertEqual(show.mixer.overlays.map(\.animation), Array(repeating: OverlayAnimation(kind: .fade, durationTicks: 30), count: MixerState.overlayCount),
                       "新节目四个通道默认淡入 0.5 s = 30 拍 @60p")
        let session = try AppTest.freshSession()
        XCTAssertTrue(session.state.overlays.allSatisfy { $0.animation == OverlayAnimation(kind: .fade, durationTicks: 30) }, "新建节目就是它")
        // 面板里按秒显示；换算按节目帧率（29.97p：0.5 s ≈ 15 拍、1 s ≈ 30 拍）
        var state = MixerState(format: .hd1080p30)
        state.overlays[0].animation = OverlayAnimation(kind: .fade, durationTicks: 15)
        let model = OverlaySettingsModel(state: state, channel: 1)
        XCTAssertEqual(model.durationSeconds(channel: 1), 0.5, accuracy: 0.001)
        XCTAssertEqual(model.ticks(seconds: 1), 30)
        XCTAssertEqual(OverlaySettingsModel(state: MixerState(format: .hd1080p5994)).ticks(seconds: 0.5), 30, "59.94p：29.97 → 30 拍")
        XCTAssertEqual(L("overlay.durationTicks", 30), "= 30 拍（按节目帧率换算）", "悬停写拍数")
        XCTAssertEqual(OverlaySettingsModel.quickDurations.map { L("overlay.durationQuick", $0) }, ["0.5 秒", "1 秒", "2 秒"])
        // 未保存判定照旧：新建之后没改过就不算改动（基准也是带默认淡入的空节目）
        XCTAssertFalse(AppTest.controller.isDocumentEdited)
    }

    func testPanels_overlayModeFullscreenOrPictureInPicture() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w = panels.showOverlaySettings(channel: 2)
        let m = w.model
        XCTAssertEqual(m.channel, 2)
        XCTAssertEqual(m.mode(channel: 2), .fullscreen, "默认整幅")
        XCTAssertFalse(OverlayPreset.pictureInPicture.contains(.full), "画中画的位置下拉里不再混着整幅")
        m.setMode(channel: 2, .pictureInPicture)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[1].rect == OverlaySettingsModel.defaultPictureInPicture }, "切到画中画放右下 1/4")
        m.setPreset(channel: 2, .topLeft)
        m.setBorderEnabled(channel: 2, on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[1].rect == OverlayPreset.topLeft.rect && session.state.overlays[1].border != nil })
        m.setMode(channel: 2, .fullscreen)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[1].rect == .full }, "整幅 = 位置 .full")
        XCTAssertNotNil(session.state.overlays[1].border, "整幅只是收起边框那几行，设置留着")
        m.setMode(channel: 2, .fullscreen)
        XCTAssertEqual(session.state.overlays[1].rect, .full, "同一模式再点不动")
        // 关掉再从底栏开：停在上次那一路
        w.close()
        XCTAssertTrue(AppTest.waitUntil(2) { panels.overlaySettingsWindow == nil })
        XCTAssertEqual(panels.showOverlaySettings(channel: nil).model.channel, 2)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    func testPanels_overlaySettingsReachableFromMenuBar() throws {
        _ = try AppTest.freshSession()
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let switching = try XCTUnwrap(AppTest.delegate.switchMenu)
        let item = try XCTUnwrap(switching.overlayMenu.items.last)
        XCTAssertEqual(item.title, "叠加设置…")
        XCTAssertEqual(item.action, #selector(AppDelegate.showOverlaySettings(_:)))
        XCTAssertTrue(AppTest.delegate.validateMenuItem(item))
        NSApp.sendAction(try XCTUnwrap(item.action), to: nil, from: item)
        XCTAssertTrue(AppTest.waitUntil(2) { panels.overlaySettingsWindow?.window?.isVisible == true })
    }
}
