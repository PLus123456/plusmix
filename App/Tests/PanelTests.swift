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
        /// 等字段变的时限（换 session 的那几条要长一点）。
        var timeout: Double = 3
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

        // W3-E2 / 提案 008：Add Input 的 NDI 页选带宽模式 / 抖动缓冲（源不在也照样加：noSignal 等它出现）
        cases.append(Case(name: "添加输入 sheet：NDI 带宽最低 + 抖动缓冲 2 帧 → 4 号", change: {
                wc.presentAddInput()
                let sheet = try XCTUnwrap(wc.window?.attachedSheet?.windowController as? AddInputSheetController, "应弹出 sheet")
                sheet.form.model.kind = .ndi
                sheet.form.model.number = 4
                sheet.form.model.ndiSourceName = "不存在的机器 (Nope)"
                sheet.form.model.ndiBandwidth = .lowest
                sheet.form.model.ndiJitterBufferFrames = 2
                sheet.confirmForTesting()
            }, verify: { session.state.input(4)?.source == .ndi(sourceName: "不存在的机器 (Nope)", bandwidth: .lowest, jitterBufferFrames: 2) },
               describe: { "\(String(describing: session.state.input(4)))" }))

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
                // 窗口是 W3-C 的 AuxOutputRuntime 跟快照开的（G4 合并：键名 displayID 与 W3-C 运行表一致）
                return o.settings.source == .preview && OutputExtras.displayNumber(of: o) == screen && session.aux.external.windows[externalNumber] != nil
            }, describe: { "\(session.state.outputs) 窗口 \(session.aux.external.windows.keys.sorted())" }))

        cases.append(Case(name: "NDI 发送设置", change: {
                let w = panels.showOutputSettings(tab: .ndi)
                _ = w.model.addNDI(name: "Switcher PGM", groups: "public", conversion: "gpu", source: .program)
            }, verify: {
                guard let o = session.state.outputs.first(where: { $0.kind == .ndi }) else { return false }
                return o.name == "Switcher PGM" && o.settings.extra[OutputExtras.ndiGroups] == .string("public") && o.settings.extra["ndi.conversion"] == .string("gpu")
            }, describe: { "\(session.state.outputs)" }))

        cases.append(Case(name: "虚拟摄像头：开", change: {
                let w = panels.showOutputSettings(tab: .virtualCamera)
                w.model.setVirtualCamera(enabled: true)
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
        cases.append(Case(name: "调音台：监听 PFL（setMonitorMode，提案 012）", change: { wc.mixerPanel.model.setMonitorMode(.pfl) },
                 verify: { session.state.audio.monitorMode == .pfl && session.state.inputs.count == 4 },
                 describe: { "\(session.state.audio.monitorMode) 输入 \(session.state.inputs.count)" }))
        cases.append(Case(name: "调音台：Master 效果链（限幅）", change: {
                wc.mixerPanel.model.setBusEffects(.master, [AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.02, preGainDb: 1)])
            }, verify: { session.state.audio.buses[0].effects.first?.id == AudioEffectParams.peakLimiterID },
               describe: { "\(session.state.audio.buses[0].effects)" }))

        // W3-E2：切换面板的参数…（W5-M 起按槽编辑、发 setTransitionSlot；转场 1 是当前槽，当前那组同时按槽重拷）
        cases.append(Case(name: "切换面板：Wipe 参数（上 → 下、软边 0.2）", change: {
                let m = wc.transitionPanel.params
                m.slot = 1
                m.setWipeDirection(.topToBottom)
                m.setWipeSoftness(0.2)
            }, verify: { session.state.transition.wipe == WipeParams(direction: .topToBottom, softness: 0.2) && session.state.transition.slots[0].wipe == session.state.transition.wipe },
               describe: { "\(session.state.transition.wipe)" }))
        cases.append(Case(name: "切换面板：Stinger 参数（2 号、第 12 拍换底）", change: {
                let m = wc.transitionPanel.params
                m.setStingerInput(2)
                m.setStingerCutTick(12)
            }, verify: { session.state.transition.stinger == StingerParams(input: 2, cutAtTick: 12) && session.state.transition.wipe.direction == .topToBottom },
               describe: { "\(session.state.transition)" }))

        cases.append(Case(name: "叠加设置窗：通道 1 → 输入 2、右下 1/4、淡入 15 拍", change: {
                wc.bottomBar.overlayButton.performClick(nil)   // W5-K：底栏"叠加…"开叠加设置独立窗（原来是浮层）
                let m = try XCTUnwrap(panels.overlaySettingsWindow?.model, "叠加设置窗应打开")
                m.setInput(channel: 1, input: 2)
                m.setPreset(channel: 1, .bottomRight)
                m.setAnimation(channel: 1, kind: .fade, durationTicks: 15)
            }, verify: {
                let o = session.state.overlays[0]
                return o.input == 2 && o.rect == .bottomRightQuarter && o.animation == OverlayAnimation(kind: .fade, durationTicks: 15)
            }, describe: { "\(session.state.overlays[0])" }))
        // W3-E2 / 提案 010：每通道 PVW 预览、边框、锚点、滑入方向（前三项走 setOverlayDecoration，滑入方向走 setOverlay）
        cases.append(Case(name: "叠加设置窗：通道 1 PVW 预览", change: {
                let m = try XCTUnwrap(panels.overlaySettingsWindow?.model, "叠加设置窗应还开着")
                m.setPreviewOn(channel: 1, on: true)
            }, verify: { session.state.overlays[0].previewOn && !session.state.overlays[1].previewOn && session.state.overlays[0].input == 2 },
               describe: { "\(session.state.overlays[0])" }))
        cases.append(Case(name: "叠加设置窗：通道 1 边框（宽 0.01、红）", change: {
                let m = try XCTUnwrap(panels.overlaySettingsWindow?.model)
                m.setBorderEnabled(channel: 1, on: true)
                m.setBorderWidth(channel: 1, 0.01)
                m.setBorderColor(channel: 1, RGB8(red: 255, green: 0, blue: 0))
            }, verify: { session.state.overlays[0].border == OverlayBorder(width: 0.01, color: RGB8(red: 255, green: 0, blue: 0)) && session.state.overlays[0].previewOn },
               describe: { "\(String(describing: session.state.overlays[0].border))" }))
        cases.append(Case(name: "叠加设置窗：通道 2 锚点右下 + 从左滑入", change: {
                let m = try XCTUnwrap(panels.overlaySettingsWindow?.model)
                m.setAnchor(channel: 2, .bottomRight)
                m.setAnimation(channel: 2, kind: .slide, durationTicks: 20)
                m.setSlideFrom(channel: 2, .left)
            }, verify: {
                let o = session.state.overlays[1]
                return o.anchor == .bottomRight && o.animation == OverlayAnimation(kind: .slide, durationTicks: 20, slideFrom: .left)
            }, describe: { "\(session.state.overlays[1])" }))

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
                 verify: { controller.windowController.isMultiviewWindowVisible && controller.windowController.multiviewWindow?.displayView.target == .multiview },
                 describe: { "\(String(describing: controller.windowController.multiviewWindow))" }))

        // W3-E2 / 提案 007：对齐延迟与监听点存在 Show.audio 里，改了要重建音频引擎 = 换 session（放最后：后面的用例不再用旧 session）
        cases.append(Case(name: "偏好设置：对齐延迟 4096 帧 + 监听点延迟线后（换 session 重建音频引擎）", change: {
                let p = panels.showPreferences()
                XCTAssertEqual(p.model.alignmentFrames, AudioState.defaultAlignmentFrames)
                XCTAssertEqual(p.model.monitorPoint, .preDelayLine)
                p.model.alignmentFrames = 4096
                p.model.monitorPoint = .postDelayLine
                XCTAssertTrue(p.model.applyShowAudio(), "变了应换 session")
            }, verify: {
                guard let s = controller.session, s !== session, s.isRunning else { return false }
                return s.state.audio.alignmentFrames == 4096 && s.state.audio.monitorPoint == .postDelayLine && s.state.inputs.count == 4
                    && s.audio.engine.configuration.alignmentFrames == 4096 && s.audio.engine.configuration.monitorPoint == .postDelayLine
            }, describe: { "\(String(describing: controller.session?.state.audio)) 引擎 \(String(describing: controller.session?.audio.engine.configuration.alignmentFrames))" },
               timeout: 20))

        for c in cases {
            do {
                try c.change()
            } catch {
                XCTFail("\(c.name)：\(error)")
                continue
            }
            let ok = AppTest.waitUntil(c.timeout, c.verify)
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
        panels.showMultiview()
        panels.closeAll()
        XCTAssertFalse(controller.windowController.isMultiviewWindowVisible, "closeAll 应关掉多画面窗口")
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

    /// W3-E2 交付第 6 条（提案 012）：确认 P3 只改了调用的几处已经发新命令——调音台的监听方式 / 总线效果链（setMonitorMode / setBusEffects），
    /// 输出设置的开关 / 改名（setOutputEnabled / renameOutput）；不再 loadShow 整体替换、不再删了重加。看命令日志。
    func testPanels_p3RewiredCallsUseNewCommands() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        wc.mixerPanel.model.setMonitorMode(.pfl)
        wc.mixerPanel.model.setBusEffects(.busA, [AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.02, preGainDb: 1)])
        let page = AppTest.controller.panels.showOutputSettings(tab: .virtualCamera).model
        page.setVirtualCamera(enabled: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.contains { $0.kind == .virtualCamera && $0.enabled } })
        let number = try XCTUnwrap(session.state.outputs.first { $0.kind == .virtualCamera }?.number)
        page.setVirtualCamera(enabled: false)
        page.rename(number, "虚拟摄像头 · 副")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(number)?.enabled == false && session.state.output(number)?.name == "虚拟摄像头 · 副"
            && session.state.audio.monitorMode == .pfl && session.state.audio.buses[Bus.busA.rawValue].effects.count == 1 })
        let commands = session.control.bus.recentEntries().filter { $0.sequence > since }.map(\.command)
        XCTAssertTrue(commands.contains(.setMonitorMode(mode: .pfl)), "\(commands)")
        XCTAssertTrue(commands.contains { if case .setBusEffects(.busA, _) = $0 { return true } else { return false } })
        XCTAssertTrue(commands.contains(.setOutputEnabled(output: number, on: false)))
        XCTAssertTrue(commands.contains(.renameOutput(output: number, name: "虚拟摄像头 · 副")))
        XCTAssertFalse(commands.contains { if case .loadShow = $0 { return true } else { return false } }, "不再 loadShow 整体替换")
        XCTAssertFalse(commands.contains { if case .removeOutput = $0 { return true } else { return false } }, "不再删了重加")
        page.removeOutput(number)
        AppTest.controller.panels.closeAll()
    }

    /// 偏好设置里的"PVW 预览全部叠加"总开关（W3-E2 交付第 3 条）→ MetalRendererOptions.overlaysInPreview：渲染器的选项在 init 定死，
    /// 所以存进 UserDefaults、换 session 才生效；与每通道的 OverlayState.previewOn 取或（渲染器那边）。
    func testPanels_preferencesOverlaysInPreviewTakesEffectOnNextSession() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        XCTAssertFalse(session.renderer.options.overlaysInPreview, "默认关（v8-preview-pvw.png 的口径）")
        let p = controller.panels.showPreferences()
        XCTAssertFalse(p.model.overlaysInPreview)
        p.model.overlaysInPreview = true
        p.model.apply()
        XCTAssertTrue(controller.defaults.bool(forKey: AppSettings.Keys.overlaysInPreview))
        XCTAssertTrue(controller.settings.overlaysInPreview)
        XCTAssertFalse(session.renderer.options.overlaysInPreview, "跑着的 session 不变（渲染器选项在 init 定死）")
        let done = AppTest.expectationBox()
        Task { await controller.restartSession(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { done.value && controller.session?.isRunning == true && controller.session !== session })
        XCTAssertEqual(controller.session?.renderer.options.overlaysInPreview, true, "换 session 后生效")
        // 还原（别的测试按默认关断言 PVW）
        let p2 = controller.panels.showPreferences()
        p2.model.overlaysInPreview = false
        p2.model.apply()
        XCTAssertFalse(controller.defaults.bool(forKey: AppSettings.Keys.overlaysInPreview))
        _ = try AppTest.freshSession()
        XCTAssertEqual(controller.session?.renderer.options.overlaysInPreview, false)
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

    /// 外部显示页（W3-E2 交付第 6 条 / 提案 013、015）：保存后快照 outputs[n].settings.display?.displayID 变了、extra 里没有 displayID 键
    /// （API 直接 addOutput 带过渡键的由 reducer 搬迁——P4；页上只写正式字段，W3-E4 起不再自己搬）；fallbackToMain 默认 false 不再显式写；启用开关走 setOutputEnabled。
    func testPanels_externalDisplayPageWritesFormalDisplayFields() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let page = AppTest.controller.panels.showOutputSettings(tab: .external).model
        guard let screen = NSScreen.main?.displayNumber else { throw XCTSkip("没有主屏") }
        // 1. 新加一路：正式字段、默认不退回主屏（提案 015 起默认就是 false）
        let added = page.addExternalDisplay(screenNumber: screen, source: .preview)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(added)?.settings.display == DisplayOutputSettings(displayID: screen) }, "\(String(describing: session.state.output(added)?.settings))")
        XCTAssertEqual(session.state.output(added)?.settings.extra, [:])
        // 2. 带过渡键的内存状态（API 直接 addOutput 的老写法）：P4 起 reducer 先按 Show.load 同一套规则把旧键搬进正式字段（W3-E3 起 App 读时也不再认过渡键，
        //    与包、契约一致；G4 第三批合入时这条曾断言"读不到"，P4 之后前提变了），页上改显示器 → 只写正式字段、旧键早没了
        let legacyNumber = page.nextOutputNumber()
        session.send(.addOutput(config: OutputState(number: legacyNumber, kind: .externalDisplay, name: "legacy", enabled: false,
                                                     settings: OutputSettings(source: .program, extra: ["displayID": .number(Double(screen)), "fallbackToMain": .bool(false)]))))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(legacyNumber) != nil })
        XCTAssertEqual(session.state.output(legacyNumber)?.settings.display?.displayID, screen, "过渡键被 reducer 搬进正式字段（P4）")
        XCTAssertNil(session.state.output(legacyNumber)?.settings.extra["displayID"], "搬完旧键清掉（P4）")
        XCTAssertEqual(OutputExtras.displayNumber(of: try XCTUnwrap(session.state.output(legacyNumber))), screen, "App 读的是正式字段、不认过渡键（W3-E3 交付第 6 条）")
        let missing: UInt32 = 0x0BAD_F00D   // 不存在的显示器：窗口（若启用）只会等它接上，不会盖住任何一块屏
        page.setExternalDisplay(legacyNumber, screenNumber: missing, source: nil)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(legacyNumber)?.settings.display?.displayID == missing },
                      "\(String(describing: session.state.output(legacyNumber)?.settings))")
        XCTAssertNil(session.state.output(legacyNumber)?.settings.extra["displayID"], "extra 里不应再有 displayID 键")
        XCTAssertNil(session.state.output(legacyNumber)?.settings.extra["fallbackToMain"])
        page.setExternalFallback(legacyNumber, on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(legacyNumber)?.settings.display == DisplayOutputSettings(displayID: missing, fallbackToMain: true) })
        // 3. 启用开关：setOutputEnabled（提案 012），同一个输出翻 enabled，不删了重加
        page.setOutputEnabled(added, on: false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(added)?.enabled == false && session.aux.external.windows[added] == nil }, "关掉后窗口应收起")
        XCTAssertEqual(session.state.output(added)?.settings.display?.displayID, screen, "设置留着")
        page.removeOutput(added)
        page.removeOutput(legacyNumber)
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.outputs.contains { $0.kind == .externalDisplay } })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        AppTest.controller.panels.closeAll()
    }

    /// 外部显示：输出设置面板加一路 = 快照多一个 externalDisplay 输出 → W3-C 的 AuxOutputRuntime 跟着开窗口；用户关窗口 = 移除该输出。
    /// （W3-E 原来的窗口菜单 / 窗口实现在 G4 合并时换成 W3-C 的：菜单 = MainWindowController.externalOutputMenu，窗口 = ExternalDisplayManager。）
    func testPanels_externalDisplayMenuAndWindowLifecycle() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let controller = AppTest.controller
        let panels = controller.panels
        let menu = try XCTUnwrap(controller.windowController.externalOutputMenu())
        XCTAssertGreaterThanOrEqual(AppTest.menuSections(menu).count, 1, "每块屏一段（W5-A 起拍平，不用子菜单）")
        let screenSection = try XCTUnwrap(AppTest.menuSections(menu).first)
        XCTAssertGreaterThanOrEqual(screenSection.filter { $0.action != nil }.count, 3 + 1, "PGM / PVW / 多画面 + 每路输入")
        guard let screen = NSScreen.main?.displayNumber else { throw XCTSkip("没有主屏") }
        let number = panels.showOutputSettings(tab: .external).model.addExternalDisplay(screenNumber: screen, source: .input(number: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[number] != nil }, "应开一个外部显示窗口")
        XCTAssertEqual(session.state.output(number)?.kind, .externalDisplay)
        XCTAssertEqual(session.state.output(number)?.settings.source, .input(number: 1))
        let w = try XCTUnwrap(session.aux.external.windows[number])
        XCTAssertEqual(w.spec.source, .input(number: 1), "任一输入 = 多画面纹理里那一格（Aux 语义）")
        XCTAssertEqual(w.spec.displayID, screen)
        w.onCloseRequested?()   // = 用户在外部窗口按 Esc（W3-C：组装方收到后删输出；closeOutput 是管理器按快照关窗口用的）
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(number) == nil && session.aux.external.windows.isEmpty }, "用户关窗口应移除输出")
    }


    @MainActor final class SentCommands { var list: [Command] = [] }

    /// W3-E4 交付第 2 条（P4 报告 §3 第 5 条 / §5 第 5 条；问题单 P4-w3-app-4-legacy-layout-thumbnail-test"顺带"一节）：外部显示页改显示器 / 退回主屏
    /// 只写它要改的那一项——App 里不再调 `migratingLegacyKeys()`：状态机里的状态不会带输出的过渡键（P4 起 addOutput / setOutputSettings / loadShow
    /// 进 reducer 都先搬迁），那两处调用是死路径。
    func testW3E4_2_externalDisplayPageWritesOnlyTheChangedField_noLegacyMigrationInApp() throws {
        // 1. 源码：App/Sources 里没有 migratingLegacyKeys 的调用（注释里提到不算）——搬迁是 Show.load / reducer 的事
        let root = try AppTest.repoRoot().appendingPathComponent("App/Sources")
        var callers: [String] = []
        for file in try AppTest.swiftFiles(in: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() where AppTest.stripLineComment(raw).contains("migratingLegacyKeys") {
                callers.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(callers, [], "App 不该再调 migratingLegacyKeys")

        // 2. 模型级：故意给模型一份带过渡键的状态（App 里不会出现——只为证明页面不再碰它）：改显示器只改 display.displayID、改退回只改 fallbackToMain、
        //    改来源只改 source，extra 原样发出去（原来的 migratingLegacyKeys 会顺手把两个旧键剥掉）
        let extra: [String: JSONValue] = ["displayID": .number(1), "fallbackToMain": .bool(false), "someOtherKey": .string("x")]
        var show = ShowDocuments.emptyShow()
        show.outputs.append(OutputState(number: 5, kind: .externalDisplay, name: "legacy", enabled: false,
                                        settings: OutputSettings(source: .program, display: DisplayOutputSettings(displayID: 1), extra: extra)))
        let model = OutputSettingsModel(state: show.makeState(), tab: .external, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        let sent = SentCommands()
        model.send = { sent.list.append($0) }
        model.setExternalDisplay(5, screenNumber: 7, source: nil)
        model.setExternalFallback(5, on: true)
        model.setExternalDisplay(5, screenNumber: nil, source: .preview)
        XCTAssertEqual(sent.list, [
            .setOutputSettings(output: 5, settings: OutputSettings(source: .program, display: DisplayOutputSettings(displayID: 7), extra: extra)),
            .setOutputSettings(output: 5, settings: OutputSettings(source: .program, display: DisplayOutputSettings(displayID: 7, fallbackToMain: true), extra: extra)),
            .setOutputSettings(output: 5, settings: OutputSettings(source: .preview, display: DisplayOutputSettings(displayID: 7, fallbackToMain: true), extra: extra)),
        ], "页面只写它要改的那一项，extra 原样：搬迁不是它的事")

        // 3. 端到端：API 直接 addOutput 一个带过渡键的外部显示输出 → 页面拿到的状态里旧键已经被 reducer 搬走（删掉那两处调用的前提，P4）
        let session = try AppTest.freshSession()
        let page = AppTest.controller.panels.showOutputSettings(tab: .external).model
        let n = page.nextOutputNumber()
        session.send(.addOutput(config: OutputState(number: n, kind: .externalDisplay, name: "legacy", enabled: false,
                                                    settings: OutputSettings(source: .program, extra: ["displayID": .number(3), "fallbackToMain": .bool(true)]))))
        XCTAssertTrue(AppTest.waitUntil(3) { page.state.output(n) != nil })
        XCTAssertEqual(page.state.output(n)?.settings.display, DisplayOutputSettings(displayID: 3, fallbackToMain: true), "reducer 搬进正式字段")
        XCTAssertEqual(page.state.output(n)?.settings.extra, [:], "页面看到的状态里没有过渡键")
        page.removeOutput(n)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) == nil })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        AppTest.controller.panels.closeAll()
    }
}
