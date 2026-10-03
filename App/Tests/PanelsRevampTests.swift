// W5-K（prompt 97）面板改版的八条用例：添加输入（记住上次的类型与设备 / 路径、分组图标、权限横幅）、输入设置（本路画面、在画面上取色、跟随视频）、
// 叠加设置独立窗（点格子的 1 不关）、音频设置窗（开着按空格照样 Cut）、音频设备页给每条总线选声道（BusChannelMap 进引擎配置、2 声道设备提示没有耳机声道）。
// 面板都是 SwiftUI 表单：测试驱动它们的模型（ObservableObject），模型只发 Command，"改了"就看 session.state；窗口 / 按钮 / 菜单这些 AppKit 部分直接点。
import AppKit
import Metal
import XCTest
import SwitcherContracts
import SwitcherAudio
import SwitcherInputs
import SwitcherRender
@testable import Switcher

@MainActor
final class PanelsRevampTests: XCTestCase {
    // MARK: 1. 添加输入：记住上次的类型与设备 / 路径（G2 / G3）

    func testPanels_addInputRemembersLastTypeAndDevice() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        let window = try XCTUnwrap(wc.window)
        let history = controller.addInputHistory

        // 类型分组 + 系统符号图标；合成测试源挪到最后单独成"测试"组（Q58）
        XCTAssertEqual(AddInputModel.Kind.displayOrder, [.camera, .decklink, .audio, .ndi, .screen, .file, .image, .synthetic])
        XCTAssertEqual(Set(AddInputModel.Kind.displayOrder), Set(AddInputModel.Kind.allCases), "八种都列、不重不漏")
        XCTAssertEqual(AddInputKindGroup.allCases.map(\.title), ["设备", "网络", "屏幕", "媒体", "测试"])
        XCTAssertEqual(AddInputKindGroup.allCases.flatMap(\.kinds), AddInputModel.Kind.displayOrder, "分组按显示顺序排")
        XCTAssertEqual(AddInputKindGroup.test.kinds, [.synthetic])
        for kind in AddInputModel.Kind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil), "\(kind) 的图标 \(kind.symbolName) 在本机的 SF Symbols 里没有")
        }

        // 第一次打开：停在摄像头 / 采集卡（不再停在合成测试源）
        XCTAssertEqual(history.lastKind, .camera)
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil }, "应弹出添加面板")
        var sheet = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertEqual(sheet.model.kind, .camera, "第一次停在摄像头 / 采集卡")

        // 加一路视频文件 → 再开：停在视频文件页、路径带着、进了最近文件
        let movie = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov").path
        sheet.selectKindForTesting(.file)
        sheet.form.model.filePath = movie
        sheet.confirmForTesting()
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.count == 1 && window.attachedSheet == nil }, "应加了一路视频文件")
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        sheet = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertEqual(sheet.model.kind, .file, "停在上次的类型")
        XCTAssertEqual(sheet.model.filePath, movie, "带上次的路径")
        XCTAssertEqual(sheet.form.recentFiles.map(\.path), [movie], "最近文件里有它")

        // 换成 NDI®（源名 + 带宽）→ 再开：停在 NDI 页、源名带着；切回视频文件页，路径照样带着
        sheet.selectKindForTesting(.ndi)
        sheet.form.model.ndiSourceName = "演播室 (PGM)"
        sheet.form.model.ndiBandwidth = .lowest
        sheet.confirmForTesting()
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.count == 2 && window.attachedSheet == nil }, "应加了一路 NDI")
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        sheet = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertEqual(sheet.model.kind, .ndi)
        XCTAssertEqual(sheet.model.ndiSourceName, "演播室 (PGM)", "带上次的源")
        XCTAssertEqual(sheet.model.ndiBandwidth, .lowest)
        XCTAssertEqual(sheet.model.number, 3, "编号仍取空号")
        sheet.selectKindForTesting(.file)
        XCTAssertEqual(sheet.model.filePath, movie, "切回视频文件页：路径还带着")
        sheet.cancelForTesting()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet == nil })
        XCTAssertEqual(session.state.inputs.count, 2, "取消不加")

        // 存本机：用同一个 UserDefaults 重新读（= 下次启动）
        let reread = AddInputHistory(defaults: controller.defaults)
        XCTAssertEqual(reread.lastKind, .ndi)
        XCTAssertEqual(reread.lastSource(for: .file), .file(path: movie, endAction: .loop, rate: 1))
        XCTAssertEqual(reread.lastSource(for: .ndi), .ndi(sourceName: "演播室 (PGM)", bandwidth: .lowest, jitterBufferFrames: InputSource.defaultNDIJitterBufferFrames))
        XCTAssertEqual(reread.recentFiles(for: .file), [movie])

        // 设备类按上次的标识填（模型口径：测试机上不真加摄像头）；填一类不动别的类
        var m = AddInputModel()
        m.fill(from: .camera(uniqueID: "cam-42"))
        m.fill(from: .audio(deviceUID: "uid-7", channels: [2, 3]))
        XCTAssertEqual(m.cameraUniqueID, "cam-42")
        XCTAssertEqual(m.audioDeviceUID, "uid-7")
        XCTAssertEqual(m.audioChannels, [2, 3])
        XCTAssertEqual(m.kind, .synthetic, "fill 只填字段、不换当前页")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 2. 添加输入：权限被拒 / SDK 没编进来 / 驱动没装 → 页顶横幅（G6）

    func testPanels_addInputPermissionBannerOffersSystemSettings() throws {
        final class Calls { var urls: [URL] = []; var help: [String] = [] }
        let calls = Calls()
        var env = AddInputEnvironment.live
        env.cameraPermission = { .denied }
        env.microphonePermission = { .denied }
        env.screenRecordingAllowed = { false }
        env.ndiAvailable = { false }
        env.decklinkSDKAvailable = { true }
        env.decklinkDriverPresent = { false }
        env.openURL = { calls.urls.append($0) }
        env.openHelp = { calls.help.append($0) }
        let form = AddInputFormModel(state: MixerState(), maxInputs: 16, environment: env)
        defer { form.close() }

        form.model.kind = .camera
        let camera = try XCTUnwrap(form.banner, "摄像头权限被拒：页顶要有横幅")
        XCTAssertTrue(camera.title.contains("摄像头"), camera.title)
        XCTAssertEqual(camera.actionTitle, "打开系统设置…")
        XCTAssertEqual(camera.action, .openSystemSettings(AddInputEnvironment.privacyURL(.camera)))
        XCTAssertEqual(AddInputEnvironment.privacyURL(.camera).absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        form.perform(camera.action)
        XCTAssertEqual(calls.urls, [AddInputEnvironment.privacyURL(.camera)], "点了直达隐私与安全性的摄像头页")
        XCTAssertEqual(form.addNote, "加上后先显示错误，授权后自动恢复")
        XCTAssertTrue(form.canAdd, "照样能加")

        form.model.kind = .audio
        XCTAssertEqual(form.banner?.action, .openSystemSettings(AddInputEnvironment.privacyURL(.microphone)))
        XCTAssertEqual(AddInputEnvironment.privacyURL(.microphone).absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        form.model.kind = .screen
        XCTAssertEqual(form.banner?.action, .openSystemSettings(AddInputEnvironment.privacyURL(.screenRecording)))
        XCTAssertEqual(AddInputEnvironment.privacyURL(.screenRecording).absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

        form.model.kind = .ndi
        let ndi = try XCTUnwrap(form.banner, "NDI® 运行库不在：要有横幅")
        XCTAssertEqual(ndi.actionTitle, "看说明")
        guard case .showHelp = ndi.action else { return XCTFail("NDI 那条给'看说明'：\(ndi.action)") }
        form.perform(ndi.action)
        XCTAssertEqual(calls.help.count, 1)
        form.model.kind = .decklink
        let decklink = try XCTUnwrap(form.banner, "DeckLink 驱动没装：要有横幅")
        XCTAssertTrue(decklink.title.contains("驱动"), decklink.title)
        XCTAssertEqual(decklink.actionTitle, "看说明")

        form.model.kind = .synthetic
        XCTAssertNil(form.banner)
        XCTAssertNil(form.addNote)
        form.model.kind = .file
        XCTAssertNil(form.banner, "文件不要权限")

        // 都正常：没有横幅；摄像头还没问过（notDetermined）不是"被拒"——不挂红横幅，第一次加的时候系统会问
        var fine = env
        fine.cameraPermission = { .authorized }
        fine.ndiAvailable = { true }
        fine.decklinkDriverPresent = { true }
        let ok = AddInputFormModel(state: MixerState(), maxInputs: 16, environment: fine)
        defer { ok.close() }
        for kind in [AddInputModel.Kind.camera, .ndi, .decklink] {
            ok.model.kind = kind
            XCTAssertNil(ok.banner, "\(kind)")
        }
        fine.cameraPermission = { .notDetermined }
        let undetermined = AddInputFormModel(state: MixerState(), maxInputs: 16, environment: fine)
        defer { undetermined.close() }
        undetermined.model.kind = .camera
        XCTAssertNil(undetermined.banner, "还没问过不挂横幅")
    }

    // MARK: 3. 输入设置：右栏下方嵌本路实时画面（裁多画面纹理这一格，Q55）、标题行 tally（H3）

    func testPanels_inputSettingsShowsLivePreviewFromMultiview() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, gray: 40)))
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2, gray: 200)))
        XCTAssertTrue(AppTest.waitUntil(10) { (1...2).allSatisfy { session.inputs.runtimeState(of: $0) == .live } }, "两路合成源应 live")
        let controller = AppTest.controller
        let strip = controller.windowController.inputStrip
        defer { controller.panels.closeAll() }
        let w = try XCTUnwrap(controller.panels.showInputSettings(input: 2))
        let first = try XCTUnwrap(strip.cells[2]?.display.sourceRect)
        XCTAssertEqual(w.model.previewRect, first, "裁多画面纹理里这一格（与输入条缩略图同一算法）")
        XCTAssertEqual(w.previewView.target, .multiview)
        XCTAssertTrue(w.previewView.source === session.displaySource, "画面来源 = 本 session 的渲染器")
        XCTAssertEqual(w.previewView.sourceRect, first)

        // 纹理非空：这一格的平均亮度 ≈ 2 号的灰（200），和 1 号（40）分得开
        var luma: Double?
        XCTAssertTrue(AppTest.waitUntil(5) { luma = Self.meanLuma(session, in: first); return (luma ?? 0) > 120 },
                      "预览那一格应是 2 号的画面（亮），实际平均亮度 \(String(describing: luma))")

        // 随快照变化：删掉 1 号 → 默认布局按输入顺序排，2 号挪到第一格，预览跟着挪
        session.send(.removeInput(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1) == nil })
        XCTAssertTrue(AppTest.waitUntil(3) { w.model.previewRect != first && w.model.previewRect == strip.cells[2]?.display.sourceRect },
                      "预览格子应跟着布局变：\(String(describing: w.model.previewRect)) / 条子 \(String(describing: strip.cells[2]?.display.sourceRect))")
        let moved = try XCTUnwrap(w.model.previewRect)
        XCTAssertEqual(w.previewView.sourceRect, moved)
        XCTAssertTrue(AppTest.waitUntil(5) { luma = Self.meanLuma(session, in: moved); return (luma ?? 0) > 120 },
                      "挪格之后预览仍是 2 号的画面，实际 \(String(describing: luma))")

        // 标题行显示这一路的 tally
        XCTAssertEqual(w.model.tallyText, "")
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(3) { w.model.tallyText == "在 PVW" }, w.model.tallyText)
        session.send(.cut)
        XCTAssertTrue(AppTest.waitUntil(3) { w.model.tallyText == "在 PGM" }, w.model.tallyText)

        // 窗口在屏上时预览真的在出帧（被盖住时 display link 停，这一项只打印）
        if w.window?.occlusionState.contains(.visible) == true {
            let before = w.previewView.presentedFrames
            XCTAssertTrue(AppTest.waitUntil(3) { w.previewView.presentedFrames > before + 5 }, "预览应在出帧：\(w.previewView.skipCounters)")
        } else {
            print("输入设置窗被盖住，跳过出帧计数（\(w.previewView.skipCounters)）")
        }
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 4. 抠像：在画面上取色（3×3 平均，H6）

    func testPanels_keyerPickColorFromPreview() throws {
        // 取色器本身：纹理上 (x, y) 周围 3×3 的平均
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: d))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<8 {
                let i = (y * 8 + x) * 4
                pixels[i] = UInt8(10 * x)          // B
                pixels[i + 1] = UInt8(20 * y)      // G
                pixels[i + 2] = 90                 // R
                pixels[i + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 8 * 4)
        XCTAssertEqual(PixelSampler.average3x3(texture: texture, queue: queue, x: 4, y: 3), RGB8(red: 90, green: 60, blue: 40), "以 (4, 3) 为中心的 9 个像素平均")
        XCTAssertEqual(PixelSampler.average3x3(texture: texture, queue: queue, x: 0, y: 0), RGB8(red: 90, green: 10, blue: 5), "贴边只平均落在纹理里的那几个")

        // 端到端：纯色图片输入（30, 200, 60）→ 输入设置 › 抠像 › 在画面上取色 → 点预览正中
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("keyer-\(UUID().uuidString).png")
        try InputWiringTests.writeSolidPNG(to: png, width: 1920, height: 1080, red: 30, green: 200, blue: 60)
        defer { try? FileManager.default.removeItem(at: png) }
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "绿幕", source: .image(path: png.path))))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "图片输入应 live")
        let controller = AppTest.controller
        defer { controller.panels.closeAll() }
        let w = try XCTUnwrap(controller.panels.showInputSettings(input: 1))
        w.model.section = .keyer
        let rect = try XCTUnwrap(w.model.previewRect)
        XCTAssertTrue(AppTest.waitUntil(5) { (Self.meanLuma(session, in: rect) ?? 0) > 60 }, "多画面里这一格应有画面")
        XCTAssertFalse(w.model.isPickingKeyColor)
        w.model.startPickingKeyColor()
        XCTAssertTrue(w.model.isPickingKeyColor)
        let container = w.previewContainer
        container.layoutSubtreeIfNeeded()
        AppTest.click(container, at: NSPoint(x: container.bounds.midX, y: container.bounds.midY))
        let picked = try XCTUnwrap(w.model.lastPickedColor, "点预览应取到颜色")
        XCTAssertLessThanOrEqual(abs(Int(picked.red) - 30), 12, "\(picked)")
        XCTAssertLessThanOrEqual(abs(Int(picked.green) - 200), 12, "\(picked)")
        XCTAssertLessThanOrEqual(abs(Int(picked.blue) - 60), 12, "\(picked)")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.keyer.keyColor == picked }, "键色应写进这一路的抠像设置：\(String(describing: session.state.input(1)?.settings.keyer))")
        XCTAssertFalse(w.model.isPickingKeyColor, "取完一次就退出取色")
        // 不在取色时点预览不改键色
        session.send(.setInputSettings(input: 1, settings: { var s = session.state.input(1)!.settings; s.keyer.keyColor = RGB8(red: 1, green: 2, blue: 3); return s }()))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.keyer.keyColor == RGB8(red: 1, green: 2, blue: 3) })
        AppTest.click(container, at: NSPoint(x: container.bounds.midX, y: container.bounds.midY))
        AppTest.pump(seconds: 0.2)
        XCTAssertEqual(session.state.input(1)?.settings.keyer.keyColor, RGB8(red: 1, green: 2, blue: 3), "没进取色就不取")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 5. 叠加设置独立窗：开着点格子的 1 不关（I1–I3 / X21）

    func testPanels_overlayWindowStaysOpenWhileSwitching() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let wc = controller.windowController
        let panels = controller.panels
        defer { panels.closeAll() }

        // 底栏"叠加"= 打开叠加设置窗（独立窗、不挡主窗口：不是 sheet、不是主窗口的子窗口）
        wc.bottomBar.overlayButton.performClick(nil)
        let w = try XCTUnwrap(panels.overlaySettingsWindow, "底栏叠加按钮应打开叠加设置窗")
        let overlayWindow = try XCTUnwrap(w.window)
        XCTAssertTrue(AppTest.waitUntil(2) { overlayWindow.isVisible })
        XCTAssertNil(overlayWindow.sheetParent)
        XCTAssertNil(overlayWindow.parent, "不挂在主窗口上")
        XCTAssertNil(wc.window?.attachedSheet)
        XCTAssertTrue(overlayWindow.styleMask.contains(.titled) && overlayWindow.styleMask.contains(.closable))
        XCTAssertEqual(w.model.channel, 1)

        // 开着窗点格子 2 的"1"：叠加 1 换成输入 2 并打开，窗还开着
        let cell = try XCTUnwrap(wc.inputStrip.cells[2])
        cell.overlayButtons[0].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[0].on && session.state.overlays[0].input == 2 })
        AppTest.pump(seconds: 0.2)
        XCTAssertTrue(overlayWindow.isVisible, "点格子的 1 不关叠加设置窗")
        // 点主窗口（主窗口变 key）、按快捷键切换：窗还开着
        wc.window?.makeKeyAndOrderFront(nil)
        session.send(.setPreview(input: 1))
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 })
        AppTest.pump(seconds: 0.2)
        XCTAssertTrue(overlayWindow.isVisible, "切换不关叠加设置窗")
        XCTAssertTrue(panels.showOverlaySettings(channel: nil) === w, "只有一个叠加设置窗")

        // 顶部选通道：只显示当前通道，改了即时生效（时长按秒，按节目帧率换拍）
        w.model.channel = 3
        XCTAssertEqual(w.model.channel, 3)
        w.model.setInput(channel: 3, input: 1)
        w.model.setDurationSeconds(channel: 3, 1.0)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[2].input == 1 && session.state.overlays[2].animation.durationTicks == 60 },
                      "1 s @ 60p = 60 拍：\(session.state.overlays[2])")
        XCTAssertEqual(w.model.durationSeconds(channel: 3), 1.0, accuracy: 0.0001)
        XCTAssertEqual(OverlaySettingsModel.quickDurations, [0.5, 1, 2])

        // 整幅 / 画中画二选一
        w.model.setMode(channel: 3, .fullscreen)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[2].rect == .full })
        XCTAssertEqual(w.model.mode(channel: 3), .fullscreen)
        w.model.setMode(channel: 3, .pictureInPicture)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[2].rect != .full })
        XCTAssertEqual(w.model.mode(channel: 3), .pictureInPicture)

        // 转场列 Overlay k、格子 k 的右键"叠加设置…"直达第 k 路
        let columnItem = try XCTUnwrap(wc.transitionPanel.overlayButtons[1].menu?.items.first { $0.title == "叠加设置…" }, "转场列 Overlay 2 的右键菜单")
        Self.perform(columnItem)
        XCTAssertTrue(AppTest.waitUntil(2) { panels.overlaySettingsWindow?.model.channel == 2 })
        XCTAssertTrue(panels.overlaySettingsWindow === w)
        let cellItem = try XCTUnwrap(cell.overlayButtons[3].menu?.items.first { $0.title == "叠加设置…" }, "格子 4 的右键菜单")
        Self.perform(cellItem)
        XCTAssertTrue(AppTest.waitUntil(2) { panels.overlaySettingsWindow?.model.channel == 4 })
        XCTAssertTrue(overlayWindow.isVisible)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 6. 音频设置窗：开着按空格照样 Cut（J2–J4 / X12）

    func testPanels_busAudioWindowDoesNotStealHotkeys() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 && session.state.preview == 2 })
        let controller = AppTest.controller
        let wc = controller.windowController
        let panels = controller.panels
        defer { panels.closeAll() }

        // 总线条的齿轮：独立的"音频设置 — Master"窗（去掉挂在主窗口上的 sheet）
        wc.mixerPanel.model.openAudioSettings(.bus(.master))
        let w = try XCTUnwrap(panels.audioSettingsWindows[.bus(.master)], "Master 条的齿轮应打开音频设置窗")
        let audioWindow = try XCTUnwrap(w.window)
        XCTAssertTrue(AppTest.waitUntil(2) { audioWindow.isVisible })
        XCTAssertEqual(audioWindow.title, "音频设置 — Master")
        XCTAssertNil(audioWindow.sheetParent, "不是 sheet")
        XCTAssertNil(wc.window?.attachedSheet, "主窗口上没挂东西")
        XCTAssertTrue(panels.showAudioSettings(.bus(.master)) === w, "同一条只开一个窗")

        // 音频设置窗在前（key）时按空格：照样 Cut
        audioWindow.makeKeyAndOrderFront(nil)
        AppTest.press(" ", in: audioWindow)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 2 }, "音频设置窗在前时空格应 Cut：PGM \(session.state.program)")
        // 主窗口照常收键（不是模态窗），音频设置窗不因切换而关
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 }, "主窗口按空格应 Cut 回 1")
        XCTAssertTrue(audioWindow.isVisible)

        // 输入条的齿轮："音频设置 — 输入 1"另一扇窗；分页：总线有限幅，输入没有
        wc.mixerPanel.model.openAudioSettings(.input(1))
        let wi = try XCTUnwrap(panels.audioSettingsWindows[.input(1)])
        XCTAssertEqual(wi.window?.title, "音频设置 — 输入 1")
        XCTAssertFalse(wi === w)
        XCTAssertEqual(w.model.pages, [.general, .eq, .compressor, .limiter])
        XCTAssertEqual(wi.model.pages, [.general, .eq, .compressor])
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 7. 音频设备页：每条总线选声道对（J8 / X08 / X09 / V07）

    func testAudio_busChannelMapReachesDevice() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        defer {
            // 还原：本机设置不带声道映射（别的用例按设备默认映射断言）
            var s = controller.settings
            s.busOutputMap = nil
            s.borrowMasterForMonitor = false
            controller.updateSettings(s)
            controller.panels.closeAll()
        }
        let p = controller.panels.showPreferences()
        let audio = p.model.audioOutput
        audio.devicesProvider = { [AudioOutputSettingsModel.DeviceInfo(name: "测试接口 8 出", outputChannels: 8),
                                   AudioOutputSettingsModel.DeviceInfo(name: "测试耳机 2 出", outputChannels: 2)] }
        audio.reloadDevices()

        // 8 声道设备：Bus A → 声道 3/4
        audio.selectDevice(.named("测试接口 8 出"))
        XCTAssertEqual(audio.outputChannels, 8)
        XCTAssertEqual(audio.pairChoices.map(\.title), ["不输出", "1/2", "3/4", "5/6", "7/8"])
        audio.setPair(.busA, first: 2)
        XCTAssertEqual(audio.map.busA, 2)
        XCTAssertNil(audio.headphonesHint, "8 声道设备有耳机声道可选")
        p.model.apply()
        XCTAssertEqual(controller.settings.busOutputMap?.busA, 2, "存本机（AppSettings / UserDefaults）")
        XCTAssertEqual(AppSettings.load(arguments: [], defaults: controller.defaults).busOutputMap, controller.settings.busOutputMap, "UserDefaults 读得回来")

        // 建引擎时传进 AudioEngineConfiguration（换 session 生效）
        let done = AppTest.expectationBox()
        Task { await controller.restartSession(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { done.value && controller.session?.isRunning == true && controller.session !== session })
        let map = try XCTUnwrap(controller.session?.audio.engine.configuration.outputChannelMap, "引擎配置里应有声道映射")
        XCTAssertTrue(map.busA.map { $0 == (2, 3) } ?? false, "Bus A → 设备声道 3/4（下标 2、3）：\(map)")
        XCTAssertTrue(map.master.map { $0 == (0, 1) } ?? false, "Master 仍是 1/2：\(map)")
        XCTAssertEqual(map, controller.settings.busOutputMap?.busChannelMap)

        // 2 声道设备：明确提示没有耳机声道，并给"监听时临时占用 Master 声道"的选项；调音台头部同样提示
        let p2 = controller.panels.showPreferences()
        let audio2 = p2.model.audioOutput
        audio2.devicesProvider = audio.devicesProvider
        audio2.reloadDevices()
        audio2.selectDevice(.named("测试耳机 2 出"))
        XCTAssertEqual(audio2.outputChannels, 2)
        XCTAssertEqual(audio2.headphonesHint, "当前设备没有耳机声道")
        XCTAssertTrue(audio2.offersBorrowMasterForMonitor)
        XCTAssertEqual(audio2.pairChoices.map(\.title), ["不输出", "1/2"])
        XCTAssertNil(audio2.map.busA, "这台设备没有 3/4：Bus A 退回不输出")
        XCTAssertEqual(MixerModel.headphonesHint(outputChannels: 2, map: audio2.map), "当前设备没有耳机声道")
        XCTAssertNil(MixerModel.headphonesHint(outputChannels: 8, map: BusOutputMap.standard(outputChannels: 8)))
        let mixer = controller.windowController.mixerPanel.model
        mixer.setOutputInfo(outputChannels: 2, map: audio2.map)
        XCTAssertEqual(mixer.headerHint, "当前设备没有耳机声道")
        mixer.setOutputInfo(outputChannels: nil, map: nil)
        XCTAssertNil(mixer.headerHint, "空设备不提示")
    }

    // MARK: 8. 输入设置的音频一节："跟随视频"开关绑 audio.afv（X55）

    func testPanels_inputAFVToggleWritesAudioSettings() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let controller = AppTest.controller
        defer { controller.panels.closeAll() }
        let w = try XCTUnwrap(controller.panels.showInputSettings(input: 1))
        XCTAssertTrue(w.model.settings.audio.afv, "契约默认跟随视频")
        let toggle = w.model.followVideoBinding
        XCTAssertTrue(toggle.wrappedValue)
        toggle.wrappedValue = false
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.audio.afv == false }, "开关写进 InputAudioSettings.afv")
        XCTAssertTrue(AppTest.waitUntil(3) { controller.windowController.mixerPanel.model.state.input(1)?.settings.audio.afv == false }, "调音台条子读同一份")
        XCTAssertFalse(w.model.followVideoBinding.wrappedValue)
        toggle.wrappedValue = true
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.audio.afv == true })
        XCTAssertTrue(w.model.followVideoBinding.wrappedValue)
        // 文案：开关叫"跟随视频（AFV）"，"延迟补偿"改叫"音频延迟补偿"（免得和按帧的视频延迟混）
        XCTAssertEqual(L10n.string("inputSettings.audio.afv", language: "zh-Hans"), "跟随视频（AFV）")
        XCTAssertTrue(L("inputSettings.audio.delay", 120).hasPrefix("音频延迟补偿"), L("inputSettings.audio.delay", 120))
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 工具

    /// 多画面纹理里某块（归一化）中间 60% 的平均亮度（BGRA 读回，步长 4）。
    static func meanLuma(_ session: SwitcherSession, in rect: NormalizedRect) -> Double? {
        guard let rb = AppTest.readback(session, target: .multiview) else { return nil }
        let x0 = Int((rect.x + rect.width * 0.2) * Double(rb.width)), x1 = Int((rect.x + rect.width * 0.8) * Double(rb.width))
        let y0 = Int((rect.y + rect.height * 0.2) * Double(rb.height)), y1 = Int((rect.y + rect.height * 0.8) * Double(rb.height))
        guard x1 > x0, y1 > y0 else { return nil }
        var sum = 0.0, n = 0.0
        for y in stride(from: y0, to: y1, by: 4) {
            for x in stride(from: x0, to: x1, by: 4) {
                let p = rb.pixel(x: x, y: y)
                sum += Double(p.r + p.g + p.b) / 3
                n += 1
            }
        }
        return n > 0 ? sum / n : nil
    }

    /// 点一个菜单项（不弹菜单：直接按它的 target / action 发）。
    static func perform(_ item: NSMenuItem) {
        guard let action = item.action else { return XCTFail("\(item.title) 没有动作") }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

extension AppTest {
    /// 往某个窗口发一个按键（音频设置窗 / 叠加设置窗在前时；走 NSWindow.sendEvent → 响应链 → PanelWindow.keyDown）。
    static func press(_ characters: String, in window: NSWindow) {
        let keyCode = keyCodes[characters] ?? 0
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(e)
        }
    }

    /// 在视图的某点（视图自己的坐标）点一下：直接调 mouseDown / mouseUp（测试宿主不在前台时窗口收不到真点击）。
    static func click(_ view: NSView, at point: NSPoint) {
        guard let window = view.window else { return XCTFail("视图不在窗口里") }
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
        }
    }
}
