// W2-B2 接缝 1：InputFactory 接 W2-A 的四种输入。内置摄像头 5 s 内 live 且画面不黑；pattern.mov 循环播放帧号在走；图片每拍刷新同一帧。
// 摄像头 / 麦克风要 TCC：从 Terminal.app 跑 xcodebuild test；从 Claude 的 Bash 起的进程系统不弹提示直接拒 → XCTSkip（BLOCKED-权限）。
import AppKit
import AVFoundation
import XCTest
import SwitcherContracts
import SwitcherInputs
@testable import Switcher

@MainActor
final class InputWiringTests: XCTestCase {
    /// 内置摄像头 → 5 s 内 live；PGM 上有画面（亮度不是一片黑）；缩略图格子在画；顺手记 L1 现象（到达余量归 W1-B2，这里只记录）。
    func testInputs_builtInCameraLiveWithin5sAndPictureShows() throws {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            throw XCTSkip("BLOCKED-硬件：没有内置摄像头")
        }
        let permission = CapturePermission.status(for: .video)
        if permission == .denied || permission == .restricted || permission == .deniedWithoutPrompt {
            throw XCTSkip("BLOCKED-权限：摄像头 \(permission)。从 Terminal.app 跑 xcodebuild test 并在系统设置里允许 Switcher")
        }
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        session.send(.addInput(config: InputConfig(number: 1, name: "内置摄像头", source: .camera(uniqueID: cam.uniqueID))))
        session.send(.setProgram(input: 1))
        let started = Date()
        let state = AppTest.waitLive(session, input: 1, timeout: 5)
        if case .error(let m)? = state, m.contains("权限") {
            throw XCTSkip("BLOCKED-权限：\(m)")
        }
        XCTAssertEqual(state, .live, "内置摄像头应在 5 s 内 live")
        let liveAfter = Date().timeIntervalSince(started)
        // 起流后头几秒可能黑（W2-A 报告：引擎到达余量把第一帧的 d 当抖动全额预留），再等最多 6 s 看 PGM 不是黑
        var luma: (mean: Double, max: Int, distinct: Int) = (0, 0, 0)
        let pictureShown = AppTest.waitUntil(6) {
            guard let rb = AppTest.readback(session) else { return false }
            luma = rb.lumaStats()
            return luma.max > 40 && luma.distinct >= 4
        }
        let pictureAfter = Date().timeIntervalSince(started)
        XCTAssertTrue(pictureShown, "PGM 上应有摄像头画面（亮度统计 \(luma)）")
        XCTAssertTrue(AppTest.waitUntil(3) { (wc.inputStrip.cells[1]?.display.presentedFrames ?? 0) > 0 }, "缩略图格子应在画")
        AppTest.pump(seconds: 2)
        // L1 现象：Stats.per_input[1].latency_ms（W1-B2 之前引擎写 0）+ 引擎的到达余量
        let pacing = session.engine.pacingStats(forInput: 1)
        let perInput = session.stats?.perInput[1]
        print("摄像头：live 用时 \(String(format: "%.2f", liveAfter)) s，出画面 \(String(format: "%.2f", pictureAfter)) s，亮度 \(luma)；"
              + "到达余量 \(pacing.map { String(format: "%.2f ms（窗口最大到达延迟 %.2f ms，迟到 %d）", $0.margin.milliseconds, $0.windowMaxLatency.milliseconds, $0.lateFrames) } ?? "—")；"
              + "Stats latency_ms \(perInput.map { "\($0.latencyMs) / max \($0.latencyMaxMs)" } ?? "—")，fps \(perInput?.fps ?? 0)，dup \(perInput?.dup ?? 0)，drop \(perInput?.drop ?? 0)；"
              + "音频环已注册 \(session.audio.registeredInputs)")
        XCTAssertEqual(session.audio.registeredInputs, [1], "摄像头带音频环（自带麦克风），应注册进音频引擎")
    }

    /// Tests/Fixtures/pattern.mov（1080p60 10 s 测试图案）循环播放：PGM 上解出的帧号 1 s 后前进约 60，Stats.per_input fps ≈ 60。
    func testInputs_patternMovLoopFrameNumbersAdvance() throws {
        let fixture = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("没有 Tests/Fixtures/pattern.mov") }
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "pattern", source: .file(path: fixture.path, endAction: .loop, rate: 1))))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "文件输入应 live")
        XCTAssertEqual(session.audio.registeredInputs, [1], "文件带音频环，应注册进音频引擎")
        var first: UInt32?
        XCTAssertTrue(AppTest.waitUntil(5) {
            first = AppTest.readback(session)?.decodePattern().frameNumber
            return first != nil
        }, "PGM 上应能解出 pattern.mov 的帧号")
        AppTest.pump(seconds: 1)
        let second = AppTest.readback(session)?.decodePattern().frameNumber
        let f1 = Int(first ?? 0), f2 = Int(second ?? 0)
        let delta = ((f2 - f1) % 600 + 600) % 600   // 600 帧循环，回绕按模算
        print("pattern.mov：帧号 \(f1) → \(f2)（1 s 走了 \(delta) 帧）")
        XCTAssertNotNil(second, "1 s 后仍应解出帧号")
        XCTAssertTrue((40...80).contains(delta), "1 s 应走约 60 帧，实际 \(delta)")
        // Stats：这一路 fps ≈ 60（1 Hz 的窗口）
        var fps = 0.0
        XCTAssertTrue(AppTest.waitUntil(3) {
            fps = session.stats?.perInput[1]?.fps ?? 0
            return fps > 50
        }, "Stats.per_input[1].fps 应 ≈ 60，实际 \(fps)")
        // 循环：把播放位置定到末尾附近，帧号应回绕到开头（endAction = loop）
        if let file = session.inputs.entries[1]?.input as? FileInput {
            file.seek(toSeconds: 9.6)
            var wrapped: UInt32?
            XCTAssertTrue(AppTest.waitUntil(4) {
                wrapped = AppTest.readback(session)?.decodePattern().frameNumber
                return wrapped.map { $0 < 120 } ?? false
            }, "定位到 9.6 s 后 1 s 内应循环回开头，帧号 \(String(describing: wrapped))")
            print("pattern.mov：循环 \(file.fileCountersSnapshot.loops) 次，定位 \(file.fileCountersSnapshot.seeks) 次")
        } else {
            XCTFail("输入 1 应是 FileInput")
        }
    }

    /// 图片：PGM 中心像素 = 图片颜色；同一帧每拍刷新（帧槽 push 计数 1 s 涨约 60）。
    func testInputs_imageRefreshesEveryTick() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("solid-\(UUID().uuidString).png")
        try Self.writeSolidPNG(to: png, width: 1280, height: 720, red: 200, green: 40, blue: 90)
        defer { try? FileManager.default.removeItem(at: png) }
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "图片", source: .image(path: png.path))))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "图片输入应 live")
        XCTAssertEqual(session.audio.registeredInputs, [], "图片没有音频环")
        var p: (b: Int, g: Int, r: Int) = (0, 0, 0)
        XCTAssertTrue(AppTest.waitUntil(5) {
            guard let rb = AppTest.readback(session) else { return false }
            p = rb.pixel(x: rb.width / 2, y: rb.height / 2)
            return abs(p.r - 200) <= 12 && abs(p.g - 40) <= 12 && abs(p.b - 90) <= 12
        }, "PGM 中心应是图片的颜色 (200, 40, 90)，实际 (\(p.r), \(p.g), \(p.b))")
        // 每拍刷新：帧槽 push 数 1 s 涨约 60（图片输入每拍推同一个像素缓冲、pts = 拍点）
        let slot = try XCTUnwrap(session.inputs.entries[1]?.slot)
        let before = slot.stats.pushed
        AppTest.pump(seconds: 1)
        let pushed = Int(slot.stats.pushed - before)
        print("图片：1 s push \(pushed) 帧，帧槽 \(slot.stats)")
        XCTAssertTrue((50...70).contains(pushed), "图片应每拍 push 一次（≈ 60/s），实际 \(pushed)")
    }

    /// 纯音频设备输入（W2-A2 的 AudioDeviceInput；W3-E2 交付第 7 条）：工厂不再给占位；环注册进音频引擎（生产者块 1024）；帧槽照旧建
    /// （videoSlot 是 nil，引擎挑不到帧、画黑，是定下来的口径）；缩略图格子画占位（名字 + 电平表 + 话筒），不显示成"无信号"；
    /// 麦克风权限被拒时是 W2-A2 那句文案。能被选进 PGM（画面按没帧画黑场）。
    func testInputs_audioDeviceInputWiredAsAudioOnly() throws {
        guard AudioInputDevices.list().contains(where: { $0.inputChannels > 0 }) else { throw XCTSkip("BLOCKED-硬件：没有带输入声道的音频设备") }
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        session.send(.addInput(config: InputConfig(number: 1, name: "话筒", source: .audio(deviceUID: ""))))   // 空串 = 系统默认输入
        XCTAssertTrue(AppTest.waitUntil(3) { session.inputs.entries[1] != nil })
        let entry = try XCTUnwrap(session.inputs.entries[1])
        XCTAssertTrue(entry.input is AudioDeviceInput, "工厂应建 AudioDeviceInput 而不是占位：\(type(of: entry.input))")
        XCTAssertNil(entry.input.videoSlot, "纯音频输入没有画面")
        XCTAssertEqual(entry.made.audioBlockFrames, 1024)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.registeredInputs.contains(1) }, "音频环应注册进音频引擎：\(session.audio.registeredInputs)")
        AppTest.waitUntil(5) {
            if case .error? = session.inputs.runtimeState(of: 1) { return true }
            return session.inputs.runtimeState(of: 1) == .live
        }
        let state = session.inputs.runtimeState(of: 1)
        print("纯音频输入：状态 \(String(describing: state))，设备 \(String(describing: (entry.input as? AudioDeviceInput)?.deviceName))")
        let cell = try XCTUnwrap(wc.inputStrip.cells[1])
        if case .error(let message)? = state {
            // 权限文案是 W2-A2 的 CapturePermission.message（被拒 = 报告 §2 那句；从 Claude 的 Bash 起的测试宿主弹不出 TCC 提示，是"尚未授权"那句）
            XCTAssertTrue(message.hasPrefix("麦克风权限"), "权限问题的文案来自 W2-A2（CapturePermission.message）：\(message)")
            XCTAssertTrue(AppTest.waitUntil(2) { cell.displayedStatus == message }, "格子上照样显示权限文案：\(cell.displayedStatus)")
            print("纯音频输入：BLOCKED-权限（麦克风 TCC），live 的路径要从 Terminal.app 跑 make test-app 才测得到")
        }
        XCTAssertTrue(AppTest.waitUntil(2) { cell.isAudioOnly }, "纯音频输入的格子应画占位")
        XCTAssertTrue(cell.display.isHidden, "没有画面：不画多画面格子")
        XCTAssertNotEqual(cell.displayedStatus, L("input.noSignal"), "不显示成\"无信号\"")
        session.send(.setProgram(input: 1))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 }, "能被选进 PGM")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        session.send(.removeInput(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.inputs.entries[1] == nil && !session.audio.registeredInputs.contains(1) })
    }

    /// 输入设置窗"来源"一节可编辑（W3-E2 交付第 6 条 / 提案 012）：合成源换成文件路径 → setInputSource；编号 / 名字 / 叠加引用 / PGM / PVW 保留，
    /// InputRuntime.reconcile 按"编号 + 来源变了"重建了那一路（运行对象换成 FileInput 并 live）；摘要跟着变。
    func testInputSettings_sourceEditSetsInputSource_keepsReferences_rebuildsRuntime() throws {
        let fixture = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("没有 Tests/Fixtures/pattern.mov") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.renameInput(input: 1, name: "机位一"))
        session.send(.overlay(channel: 1, on: true, input: 1))
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.name == "机位一" && session.state.overlays[0].input == 1 && session.state.program == 1 && session.state.preview == 2 })
        let before = try XCTUnwrap(session.inputs.entries[1]?.input)
        let window = try XCTUnwrap(AppTest.controller.panels.showInputSettings(input: 1))
        window.model.section = .source
        let form = window.model.sourceFormModel()
        XCTAssertEqual(form.model.kind, .synthetic, "表单从现有来源填回")
        XCTAssertFalse(window.model.sourceChanged)
        form.model.kind = .file
        form.model.filePath = fixture.path
        form.model.fileEndAction = .loop
        XCTAssertTrue(window.model.sourceChanged)
        window.model.applySource()
        let wanted = InputSource.file(path: fixture.path, endAction: .loop, rate: 1)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.source == wanted }, "\(String(describing: session.state.input(1)?.source))")
        XCTAssertEqual(session.state.inputs.map(\.number), [1, 2], "编号不变")
        XCTAssertEqual(session.state.input(1)?.name, "机位一", "名字保留")
        XCTAssertEqual(session.state.overlays[0].input, 1, "叠加引用保留")
        XCTAssertTrue(session.state.overlays[0].on)
        XCTAssertEqual(session.state.program, 1)
        XCTAssertEqual(session.state.preview, 2)
        XCTAssertTrue(session.control.bus.recentEntries().contains { if case .setInputSource(1, wanted) = $0.command { return true } else { return false } },
                      "走 setInputSource，不是 removeInput + addInput")
        XCTAssertFalse(session.control.bus.recentEntries().contains { if case .removeInput = $0.command { return true } else { return false } })
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.entries[1]?.input is FileInput && session.inputs.entries[1]?.input !== before },
                      "运行表应按新来源重建这一路：\(String(describing: session.inputs.entries[1]?.input))")
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        XCTAssertTrue(window.model.sourceSummary.contains("pattern.mov"), window.model.sourceSummary)
        XCTAssertFalse(window.model.sourceChanged, "应用后表单与快照一致")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        AppTest.controller.panels.closeAll()
        XCTAssertFalse(form.isObservingAudioDevices, "窗口关掉摘掉设备订阅")
    }

    /// W3-E5 交付 1（reports/issues/W4C-app-relative-media-paths.md）：图片 / 视频文件输入的相对路径按**节目文件所在目录**解析（与 headless
    /// HeadlessRun 同一条规则：以 / 开头原样，否则挂到节目文件所在目录下），不再相对进程工作目录（Finder / Dock 起的 App 工作目录是 /）；
    /// 节目没保存过退到默认录制目录 ~/Movies/PlusMix（与录制目录的相对路径同一口径）。只改交给输入对象的路径，MixerState / 节目文件仍存相对路径。
    /// 节目在临时目录 A、图片在 A/assets/，进程 cwd 在别处（B）：打开后该路 live、fps > 0（修前：占位"图片不存在：assets/…"、fps = 0）。
    func testW3E5_relativeMediaPathResolvesAgainstShowFile() throws {
        // 1. 纯规则：相对路径挂到 base 下；文件输入的 endAction / rate 不动；绝对路径与别的来源原样
        let base = URL(fileURLWithPath: "/tmp/节目目录", isDirectory: true)
        let image = InputConfig(number: 5, name: "台标", source: .image(path: "assets/logo.png"))
        XCTAssertEqual(InputRuntime.resolvingMediaPaths(image, against: base).source, .image(path: "/tmp/节目目录/assets/logo.png"))
        let file = InputConfig(number: 6, name: "片头", source: .file(path: "clips/intro.mov", endAction: .loop, rate: 1.5))
        XCTAssertEqual(InputRuntime.resolvingMediaPaths(file, against: base).source, .file(path: "/tmp/节目目录/clips/intro.mov", endAction: .loop, rate: 1.5))
        XCTAssertEqual(InputRuntime.resolvingMediaPaths(file, against: base).number, 6)
        let absolute = InputConfig(number: 7, name: "绝对", source: .image(path: "/Volumes/素材/a.png"))
        XCTAssertEqual(InputRuntime.resolvingMediaPaths(absolute, against: base), absolute)
        let synthetic = AppTest.syntheticConfig(number: 8)
        XCTAssertEqual(InputRuntime.resolvingMediaPaths(synthetic, against: base), synthetic)
        // 节目没保存过：退到默认录制目录（OutputRuntime.startRecordings 对相对录制目录也是挂到这里）
        let suite = "com.plusmix.switcher.tests.mediabase-\(UUID().uuidString)"
        let docs = ShowDocuments(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertEqual(docs.mediaBaseDirectory.standardizedFileURL.path, URL(fileURLWithPath: ShowDocuments.defaultRecordDirectory, isDirectory: true).standardizedFileURL.path)

        // 2. 经 App：节目在 A、图片在 A/assets/、进程 cwd 在 B
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let tmp = FileManager.default.temporaryDirectory
        let dirA = tmp.appendingPathComponent("switcher-relpath-A-\(UUID().uuidString)", isDirectory: true)
        let dirB = tmp.appendingPathComponent("switcher-relpath-B-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        try FileManager.default.createDirectory(at: dirA.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Self.writeSolidPNG(to: dirA.appendingPathComponent("assets/logo.png"), width: 640, height: 360, red: 30, green: 180, blue: 220)
        let previousCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(dirB.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previousCwd) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "assets/logo.png"), "cwd 下没有这张图：按 cwd 解析必然建不出来")
        var show = ShowDocuments.emptyShow(name: "相对路径", recordDirectory: dirA.path)
        show.inputs = [InputConfig(number: 1, name: "台标", source: .image(path: "assets/logo.png"))]
        show.mixer.program = 1
        let url = dirA.appendingPathComponent("相对路径.\(ShowDocuments.fileExtension)")
        try show.save().write(to: url)
        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { opened.value && controller.session?.isRunning == true }, "节目应能打开：\(String(describing: controller.lastError))")
        let session = try XCTUnwrap(controller.session)
        XCTAssertEqual(controller.documents.mediaBaseDirectory.standardizedFileURL.path, dirA.standardizedFileURL.path, "打开后素材目录 = 节目文件所在目录")
        XCTAssertEqual(session.mediaBaseDirectory.standardizedFileURL.path, dirA.standardizedFileURL.path)
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 10), .live,
                       "图片应按节目文件所在目录找到，实际 \(String(describing: session.inputs.runtimeState(of: 1)))")
        XCTAssertTrue(AppTest.waitUntil(8) { (session.stats?.perInput[1]?.fps ?? 0) > 0 }, "该路 fps 应 > 0：\(String(describing: session.stats?.perInput[1]))")
        var p: (b: Int, g: Int, r: Int) = (0, 0, 0)
        XCTAssertTrue(AppTest.waitUntil(5) {
            guard let rb = AppTest.readback(session) else { return false }
            p = rb.pixel(x: rb.width / 2, y: rb.height / 2)
            return abs(p.r - 30) <= 12 && abs(p.g - 180) <= 12 && abs(p.b - 220) <= 12
        }, "PGM 中心应是图片的颜色 (30, 180, 220)，实际 (\(p.r), \(p.g), \(p.b))")

        // 3. 快照 / 节目文件仍存相对路径；另存到别处后文件里还是相对路径（素材要跟着搬，Samples/README.md §2），之后新加的素材按新位置找
        XCTAssertEqual(session.state.inputs.first?.source, .image(path: "assets/logo.png"), "MixerState 存相对路径")
        XCTAssertEqual(session.makeShow().inputs.first?.source, .image(path: "assets/logo.png"))
        let url2 = dirB.appendingPathComponent("另存.\(ShowDocuments.fileExtension)")
        controller.write(session.makeShow(), to: url2)
        XCTAssertEqual(try controller.documents.load(from: url2).inputs.first?.source, .image(path: "assets/logo.png"), "节目文件存相对路径")
        XCTAssertEqual(session.mediaBaseDirectory.standardizedFileURL.path, dirB.standardizedFileURL.path, "另存后素材目录跟到新位置")
        XCTAssertEqual(session.inputs.runtimeState(of: 1), .live, "另存不重建已在跑的输入")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 纯色 PNG（sRGB）。
    static func writeSolidPNG(to url: URL, width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "png", code: 1) }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw NSError(domain: "png", code: 2) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "png", code: 3) }
        try data.write(to: url)
    }
}
