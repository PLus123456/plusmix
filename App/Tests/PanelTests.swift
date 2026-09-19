// W3-E 表驱动的面板测试（prompt 测试第 1 条）：每个面板能打开、改一项、快照里对应字段变了。
// 面板都是 SwiftUI 表单（NSHostingView），测试驱动它们的模型（ObservableObject），模型只发 Command，所以"字段变了"就看 session.state。
// 偏好设置 / 快捷键 / MIDI 不在 MixerState 里：分别看 UserDefaults 键、HotkeyDispatcher 的表、MIDIController 的表。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class PanelTests: XCTestCase {
    struct Case {
        let name: String
        /// 打开面板并改一项。
        let change: () throws -> Void
        /// 对应字段变了（会被轮询到 3 s）。
        let verify: () -> Bool
        /// 失败时打印的现状。
        let describe: () -> String
    }

    func testPanels_openChangeOneItemSnapshotFieldChanges() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let wc = controller.windowController
        let panels = controller.panels
        let screen = NSScreen.main?.displayNumber ?? 1
        var streamNumber = 0
        var externalNumber = 0

        var cases: [Case] = []
        cases.append(Case(name: "添加输入 sheet：合成源 30 fps → 3 号", change: {
                wc.presentAddInput()
                let sheet = try XCTUnwrap(wc.window?.attachedSheet?.windowController as? AddInputSheetController, "应弹出 sheet")
                sheet.form.model.kind = .synthetic
                sheet.form.model.number = 3
                sheet.form.model.syntheticFrameRate = .fps30
                sheet.confirmForTesting()
            }, verify: {
                if case .synthetic(let s)? = session.state.input(3)?.source { return s.frameRate == .fps30 }
                return false
            }, describe: { "\(session.state.inputs.map(\.number))" }))

        cases.append(Case(name: "输入设置：延迟补偿 120 ms", change: {
                let w = try XCTUnwrap(panels.showInputSettings(input: 1))
                w.model.update { $0.audio.delayMs = 120 }
            }, verify: { session.state.input(1)?.settings.audio.delayMs == 120 },
               describe: { "\(String(describing: session.state.input(1)?.settings.audio))" }))

        cases.append(Case(name: "输入设置：裁切 / 变换", change: {
                let w = try XCTUnwrap(panels.showInputSettings(input: 1))
                w.model.update { $0.crop.left = 0.1; $0.transform.scale = 0.5; $0.transform.flipHorizontal = true }
            }, verify: {
                guard let s = session.state.input(1)?.settings else { return false }
                return s.crop.left == 0.1 && s.transform.scale == 0.5 && s.transform.flipHorizontal
            }, describe: { "\(String(describing: session.state.input(1)?.settings))" }))

        cases.append(Case(name: "输入设置：音频路由 / 增益", change: {
                let w = try XCTUnwrap(panels.showInputSettings(input: 1))
                w.model.update { $0.audio.routing.busA = true; $0.audio.gainDb = -6 }
            }, verify: {
                guard let a = session.state.input(1)?.settings.audio else { return false }
                return a.routing.busA && a.gainDb == -6
            }, describe: { "\(String(describing: session.state.input(1)?.settings.audio))" }))

        cases.append(Case(name: "输入设置：抠像", change: {
                let w = try XCTUnwrap(panels.showInputSettings(input: 1))
                w.model.update { $0.keyer.enabled = true; $0.keyer.tolerance = 0.42 }
            }, verify: { session.state.input(1)?.settings.keyer.enabled == true && session.state.input(1)?.settings.keyer.tolerance == 0.42 },
               describe: { "\(String(describing: session.state.input(1)?.settings.keyer))" }))

        cases.append(Case(name: "输入设置：效果链（EQ）", change: {
                let w = try XCTUnwrap(panels.showInputSettings(input: 1))
                w.model.update { $0.effects = [AudioEffectParams.parametricEQ(centerHz: 1000, q: 1.2, gainDb: 3)] }
            }, verify: {
                guard let e = session.state.input(1)?.settings.effects.first else { return false }
                return e.id == AudioEffectParams.parametricEQID && AudioEffectParams.number(e, "gainDb") == 3
            }, describe: { "\(String(describing: session.state.input(1)?.settings.effects))" }))

        cases.append(Case(name: "输入设置：改名", change: {
                let w = try XCTUnwrap(panels.showInputSettings(input: 2))
                w.model.rename("机位二")
            }, verify: { session.state.input(2)?.name == "机位二" }, describe: { "\(String(describing: session.state.input(2)?.name))" }))

        cases.append(Case(name: "录制设置：HEVC + 转 MP4 + 关键帧 60", change: {
                let w = panels.showOutputSettings(tab: .record)
                w.model.updateRecord { $0.video?.codec = .hevc; $0.video?.keyframeIntervalFrames = 60; $0.record?.remuxToMP4 = true }
            }, verify: {
                guard let r = session.state.outputs.first(where: { $0.kind == .record && $0.settings.source == .program }) else { return false }
                return r.settings.video?.codec == .hevc && r.settings.video?.keyframeIntervalFrames == 60 && r.settings.record?.remuxToMP4 == true
            }, describe: { "\(session.state.outputs)" }))

        cases.append(Case(name: "录制设置：ISO 选 2 号", change: {
                let w = panels.showOutputSettings(tab: .iso)
                w.model.setISO(input: 2, on: true)
            }, verify: { session.state.outputs.contains { $0.kind == .record && $0.settings.source == .input(number: 2) } },
               describe: { "\(session.state.outputs.map { "\($0.number) \($0.kind) \($0.settings.source)" })" }))

        cases.append(Case(name: "推流设置：加目的地", change: {
                let w = panels.showOutputSettings(tab: .stream)
                streamNumber = w.model.addStream(url: "rtmp://127.0.0.1/live", key: "abc")
            }, verify: {
                guard let s = session.state.output(streamNumber), s.kind == .stream else { return false }
                return s.settings.stream?.url == "rtmp://127.0.0.1/live" && s.settings.stream?.streamKey == "abc"
            }, describe: { "\(session.state.outputs)" }))

        cases.append(Case(name: "推流设置：改码率", change: {
                let w = panels.showOutputSettings(tab: .stream)
                w.model.updateOutput(streamNumber) { $0.video?.bitrateBps = 2_500_000 }
            }, verify: { session.state.output(streamNumber)?.settings.video?.bitrateBps == 2_500_000 },
               describe: { "\(String(describing: session.state.output(streamNumber)))" }))

        cases.append(Case(name: "外部输出：加一路 PVW 到主屏", change: {
                let w = panels.showOutputSettings(tab: .external)
                externalNumber = w.model.addExternalDisplay(screenNumber: screen, source: .preview)
            }, verify: {
                guard let o = session.state.output(externalNumber), o.kind == .externalDisplay else { return false }
                return o.settings.source == .preview && OutputExtras.displayNumber(of: o) == screen && panels.externalDisplayWindows[externalNumber] != nil
            }, describe: { "\(session.state.outputs) 窗口 \(panels.externalDisplayWindows.keys.sorted())" }))

        cases.append(Case(name: "NDI 发送设置", change: {
                let w = panels.showOutputSettings(tab: .ndi)
                _ = w.model.addNDI(name: "Switcher PGM", groups: "public", conversion: "gpu", source: .program)
            }, verify: {
                guard let o = session.state.outputs.first(where: { $0.kind == .ndi }) else { return false }
                return o.name == "Switcher PGM" && o.settings.extra[OutputExtras.ndiGroups] == .string("public") && o.settings.extra["ndi.conversion"] == .string("gpu")
            }, describe: { "\(session.state.outputs)" }))

        cases.append(Case(name: "虚拟摄像头：开", change: {
                let w = panels.showOutputSettings(tab: .virtualCamera)
                w.model.setVirtualCamera(enabled: true, source: .program)
            }, verify: { session.state.outputs.first { $0.kind == .virtualCamera }?.enabled == true },
               describe: { "\(session.state.outputs)" }))

        cases.append(Case(name: "调音台：1 号推子 −6 dB", change: { wc.mixerPanel.model.setInputGain(1, dB: -6) },
                 verify: { session.state.input(1)?.settings.audio.gainDb == -6 }, describe: { "\(String(describing: session.state.input(1)?.settings.audio))" }))
        cases.append(Case(name: "调音台：1 号声像 −0.5 / 送 Bus B", change: { wc.mixerPanel.model.setPan(1, value: -0.5); wc.mixerPanel.model.setRouting(1, bus: .busB, on: true) },
                 verify: { session.state.input(1)?.settings.audio.pan == -0.5 && session.state.input(1)?.settings.audio.routing.busB == true },
                 describe: { "\(String(describing: session.state.input(1)?.settings.audio))" }))
        cases.append(Case(name: "调音台：Bus A 推子 −3 dB + 静音", change: { wc.mixerPanel.model.setBusGain(.busA, dB: -3); wc.mixerPanel.model.setBusMute(.busA, on: true) },
                 verify: { session.state.audio.buses[Bus.busA.rawValue].gainDb == -3 && session.state.audio.buses[Bus.busA.rawValue].muted },
                 describe: { "\(session.state.audio.buses)" }))
        cases.append(Case(name: "调音台：AFV 开", change: { wc.mixerPanel.model.setAFV(on: true) },
                 verify: { session.state.audio.afv }, describe: { "\(session.state.audio.afv)" }))
        cases.append(Case(name: "调音台：监听 PFL（经 loadShow 过渡，提案 012）", change: { wc.mixerPanel.model.setMonitorMode(.pfl) },
                 verify: { session.state.audio.monitorMode == .pfl && session.state.inputs.count == 3 },
                 describe: { "\(session.state.audio.monitorMode) 输入 \(session.state.inputs.count)" }))
        cases.append(Case(name: "调音台：Master 效果链（限幅）", change: {
                wc.mixerPanel.model.setBusEffects(.master, [AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.02, preGainDb: 1)])
            }, verify: { session.state.audio.buses[0].effects.first?.id == AudioEffectParams.peakLimiterID },
               describe: { "\(session.state.audio.buses[0].effects)" }))

        cases.append(Case(name: "叠加面板：通道 1 → 输入 2、右下 1/4、淡入 15 拍", change: {
                wc.presentOverlayPanel(relativeTo: wc.bottomBar.overlayButton)
                let m = try XCTUnwrap(wc.overlayPanelController?.model, "叠加面板应打开")
                m.setInput(channel: 1, input: 2)
                m.setPreset(channel: 1, .bottomRight)
                m.setAnimation(channel: 1, kind: .fade, durationTicks: 15)
            }, verify: {
                let o = session.state.overlays[0]
                return o.input == 2 && o.rect == .bottomRightQuarter && o.animation == OverlayAnimation(kind: .fade, durationTicks: 15)
            }, describe: { "\(session.state.overlays[0])" }))

        cases.append(Case(name: "快捷键编辑器：k → Cut", change: {
                let h = panels.showHotkeyEditor()
                h.model.addRow(key: "k", action: .command(.cut))
                XCTAssertTrue(h.model.save(), "\(h.model.errorMessage ?? "")")
            }, verify: { session.control.hotkeys.table.action(for: KeyCombo(key: "k")) == .command(.cut) },
               describe: { "\(session.control.hotkeys.table.bindings.count) 条" }))

        cases.append(Case(name: "MIDI 映射：Note 60 → Cut", change: {
                let m = panels.showMIDIMapping()
                m.model.addRow(trigger: .note(channel: 1, note: 60), action: .action(.command(.cut)))
                XCTAssertTrue(m.model.save(), "\(m.model.errorMessage ?? "")")
            }, verify: { session.control.midi.table.mapping(for: .note(channel: 1, note: 60))?.action == .action(.command(.cut)) },
               describe: { "\(session.control.midi.table.mappings)" }))

        cases.append(Case(name: "偏好设置：API 端口 9123", change: {
                let p = panels.showPreferences()
                p.model.apiPort = 9123
                p.model.apply()
            }, verify: { controller.defaults.string(forKey: AppSettings.Keys.apiListen) == "127.0.0.1:9123" },
               describe: { "\(String(describing: controller.defaults.string(forKey: AppSettings.Keys.apiListen)))" }))

        cases.append(Case(name: "偏好设置：兼容层开关", change: {
                let p = panels.showPreferences()
                p.model.compatLayerEnabled = true
                p.model.compatLayerPort = 8098
                p.model.apply()
            }, verify: { controller.defaults.bool(forKey: AppSettings.Keys.compatLayerEnabled) && controller.defaults.integer(forKey: AppSettings.Keys.compatLayerPort) == 8098 },
               describe: { "\(controller.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("compat") })" }))

        cases.append(Case(name: "多画面窗口", change: { panels.showMultiview() },
                 verify: { panels.multiviewWindow?.window?.isVisible == true && panels.multiviewWindow?.display.target == .multiview },
                 describe: { "\(String(describing: panels.multiviewWindow))" }))

        for c in cases {
            do {
                try c.change()
            } catch {
                XCTFail("\(c.name)：\(error)")
                continue
            }
            let ok = AppTest.waitUntil(3, c.verify)
            XCTAssertTrue(ok, "\(c.name)：字段没变，现状 \(c.describe())")
            AppTest.pump(seconds: 0.05)
        }
        // 收拾：快捷键 / MIDI 表恢复默认（别的测试按默认表断言）
        let h = panels.showHotkeyEditor()
        h.model.resetToDefault()
        XCTAssertTrue(h.model.save())
        let m = panels.showMIDIMapping()
        for r in m.model.rows { m.model.removeRow(r.id) }
        XCTAssertTrue(m.model.save())
        // 面板都开着的时候关掉（换 session 也走同一条路）
        panels.closeAll()
        XCTAssertNil(panels.multiviewWindow?.window?.isVisible == true ? panels.multiviewWindow : nil, "closeAll 应关掉多画面窗口")
    }

    /// 偏好设置里的节目格式：改成 720p60 会换一个 session（引擎格式在 init 定死），新 session 的输入 / 输出原样带过去。
    func testPanels_preferencesProgramFormatReplacesSession() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let controller = AppTest.controller
        let p = controller.panels.showPreferences()
        XCTAssertEqual(p.model.formatWidth, 1920)
        XCTAssertEqual(p.model.frameRate, .fps60)
        p.model.selectFormatPreset(.hd720p60)
        let applied = p.model.applyProgramFormat()
        XCTAssertTrue(applied, "格式变了应触发换 session")
        XCTAssertTrue(AppTest.waitUntil(20) { controller.session?.isRunning == true && controller.session?.format == .hd720p60 },
                      "新 session 的格式应是 720p60：\(String(describing: controller.session?.format))")
        XCTAssertTrue(controller.session !== session)
        XCTAssertEqual(controller.session?.state.inputs.count, 1, "输入应原样带过去")
        XCTAssertTrue(AppTest.waitUntil(10) { controller.session?.inputs.runtimeState(of: 1) == .live })
        // 偏好设置窗口跟着新 session：再改回 1080p60，不变 = 不换
        let p2 = controller.panels.showPreferences()
        p2.model.selectFormatPreset(.hd720p60)
        XCTAssertFalse(p2.model.applyProgramFormat(), "格式没变不换 session")
    }

    /// 偏好设置：法律提示文案、音频输出设备列表、语言选择写 AppleLanguages。
    func testPanels_preferencesLegalNoticeDevicesAndLanguage() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let p = controller.panels.showPreferences()
        XCTAssertFalse(PreferencesModel.compatLegalNotice.isEmpty, "兼容层开关要带法律提示")
        XCTAssertTrue(PreferencesModel.compatLegalNotice.contains("律师") || PreferencesModel.compatLegalNotice.lowercased().contains("legal"))
        XCTAssertGreaterThanOrEqual(p.model.audioDeviceChoices.count, 2, "至少有系统默认 + 空设备：\(p.model.audioDeviceChoices)")
        // AppleLanguages 在全局域也有值（系统语言），所以看本 App 自己的持久域
        func ownLanguages() -> [String]? { controller.defaults.persistentDomain(forName: AppController.testDefaultsSuite)?["AppleLanguages"] as? [String] }
        p.model.language = "en"
        p.model.apply()
        XCTAssertEqual(ownLanguages(), ["en"])
        XCTAssertEqual(controller.defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        p.model.language = PreferencesModel.systemLanguage
        p.model.apply()
        XCTAssertNil(ownLanguages(), "跟随系统 = 去掉覆盖")
        XCTAssertFalse(p.model.updateStatus.isEmpty, "更新一节要有说明文案（W4-B 接 Sparkle）")
    }

    /// 外部显示菜单：窗口菜单里列出每块屏 × 来源；关掉窗口 = 移除该输出。
    func testPanels_externalDisplayMenuAndWindowLifecycle() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let controller = AppTest.controller
        let panels = controller.panels
        let menu = panels.makeExternalDisplayMenu()
        XCTAssertGreaterThanOrEqual(menu.items.count, 1, "每块屏一个子菜单")
        let screenMenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertGreaterThanOrEqual(screenMenu.items.count, 3 + 1, "PGM / PVW / 多画面 + 每路输入")
        guard let screen = NSScreen.main?.displayNumber else { throw XCTSkip("没有主屏") }
        panels.openExternalDisplay(screenNumber: screen, source: .input(number: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { panels.externalDisplayWindows.count == 1 }, "应开一个外部显示窗口")
        let number = try XCTUnwrap(panels.externalDisplayWindows.keys.first)
        XCTAssertEqual(session.state.output(number)?.kind, .externalDisplay)
        XCTAssertEqual(session.state.output(number)?.settings.source, .input(number: 1))
        let w = try XCTUnwrap(panels.externalDisplayWindows[number])
        XCTAssertEqual(w.display.target, .multiview, "任一输入 = 多画面纹理里那一格（Aux 语义）")
        XCTAssertTrue(w.display.sourceRect != .full)
        w.close()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(number) == nil && panels.externalDisplayWindows.isEmpty }, "关窗口应移除输出")
    }
}
