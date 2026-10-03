// W5-K（prompt 97 交付 1）添加输入的其余几条：sheet 可缩放并记住尺寸（G4）、摄像头协商结果与帧率不一致标黄（G8）、NDI® 页持续刷新 / 双击直接加（G9）、
// 视频 / 图片最近 10 个文件与文件信息（G11 / G12）、纯音频文件按纯音频格子显示（Q57）、音频设备下拉不写四字码（V-16）。主用例在 PanelsRevampTests。
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import XCTest
import SwitcherContracts
import SwitcherInputs
@testable import Switcher

@MainActor
final class AddInputRevampTests: XCTestCase {
    /// 每条用例自己的 UserDefaults（本机记忆不串到别的用例）。
    private func isolatedHistory() -> (AddInputHistory, UserDefaults) {
        let suite = "com.plusmix.switcher.tests.addinput-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return (AddInputHistory(defaults: defaults), defaults)
    }

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/addinput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: G4

    func testPanels_addInputSheetResizableAndRemembersSize() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        var sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.styleMask.contains(.resizable), "添加面板可以缩放")
        let controller = try XCTUnwrap(sheet.windowController as? AddInputSheetController)
        let clamped = controller.windowWillResize(sheet, to: NSSize(width: 200, height: 150))
        XCTAssertEqual(sheet.contentRect(forFrameRect: NSRect(origin: .zero, size: clamped)).size, AddInputSheetController.minimumSize, "缩不到最小尺寸以下")
        XCTAssertEqual(sheet.contentRect(forFrameRect: sheet.frame).size, AddInputSheetController.defaultSize, "第一次用默认尺寸")
        sheet.setContentSize(NSSize(width: 980, height: 640))
        try XCTUnwrap(sheet.windowController as? AddInputSheetController).cancelForTesting()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet == nil })
        XCTAssertEqual(AppTest.controller.addInputHistory.sheetSize, NSSize(width: 980, height: 640), "关掉时记下尺寸（本机）")
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.contentRect(forFrameRect: sheet.frame).size, NSSize(width: 980, height: 640), "下次照这个尺寸开")
        try XCTUnwrap(sheet.windowController as? AddInputSheetController).cancelForTesting()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet == nil })
        XCTAssertEqual(session.state.inputs.count, 0)
    }

    // MARK: G8

    func testPanels_addInputCameraNegotiationFlagsFrameRateMismatch() {
        func candidate(_ i: Int, _ w: Int, _ h: Int, _ rates: [ClosedRange<Double>]) -> CameraFormatNegotiation.Candidate {
            CameraFormatNegotiation.Candidate(index: i, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: w, height: h, frameRateRanges: rates)
        }
        let fine = CameraNegotiationSummary.make(candidates: [candidate(0, 1920, 1080, [1...60])], program: .hd1080p60)
        XCTAssertEqual(fine, CameraNegotiationSummary(text: "将以 1920×1080 · 60 fps 采集（与节目帧率一致）", frameRateMismatch: false))
        let ntsc = CameraNegotiationSummary.make(candidates: [candidate(0, 1920, 1080, [1...60])], program: .hd1080p5994)
        XCTAssertEqual(ntsc?.text, "将以 1920×1080 · 59.94 fps 采集（与节目帧率一致）")
        let slow = CameraNegotiationSummary.make(candidates: [candidate(0, 1920, 1080, [30...30])], program: .hd1080p60)
        XCTAssertEqual(slow, CameraNegotiationSummary(text: "将以 1920×1080 · 30 fps 采集：节目是 60 fps，比节目慢，会重复帧", frameRateMismatch: true), "帧率对不上标黄")
        let fast = CameraNegotiationSummary.make(candidates: [candidate(0, 1280, 720, [120...120])], program: .hd1080p60)
        XCTAssertEqual(fast?.frameRateMismatch, true)
        XCTAssertEqual(fast?.text, "将以 1280×720 · 120 fps 采集：节目是 60 fps，比节目快，会丢帧（缩放到 1920×1080）")
        XCTAssertNil(CameraNegotiationSummary.make(candidates: [], program: .hd1080p60), "设备没报格式：不写")
    }

    // MARK: G9

    func testPanels_addInputNDIPageRefreshesAndDoubleClickAdds() throws {
        final class Counter: @unchecked Sendable { let lock = NSLock(); var calls = 0 }
        let counter = Counter()
        var env = AddInputEnvironment.live
        env.ndiAvailable = { true }
        env.discoverNDI = {
            counter.lock.lock(); counter.calls += 1; counter.lock.unlock()
            return ["机位 B (PGM)", "机位 A (摄像机)"]
        }
        let (history, _) = isolatedHistory()
        let form = AddInputFormModel(state: MixerState(), maxInputs: 16, history: history, environment: env)
        defer { form.close() }
        var confirmed = 0
        form.onConfirm = { confirmed += 1 }
        form.ndiRefreshInterval = 0.2
        form.model.kind = .ndi
        XCTAssertTrue(AppTest.waitUntil(3) { form.ndiSources == ["机位 A (摄像机)", "机位 B (PGM)"] }, "进页就找、按名字排：\(form.ndiSources)")
        XCTAssertEqual(form.ndiStatus, "找到 2 个源")
        XCTAssertTrue(AppTest.waitUntil(3) { form.ndiSearchCount >= 3 }, "开着这一页持续重找：\(form.ndiSearchCount) 次")
        form.activateNDISource("机位 B (PGM)")
        XCTAssertEqual(form.model.ndiSourceName, "机位 B (PGM)")
        XCTAssertEqual(confirmed, 1, "双击 = 直接加")
        // 离开 NDI 页：不再找
        form.model.kind = .file
        AppTest.pump(seconds: 0.3)
        let after = form.ndiSearchCount
        AppTest.pump(seconds: 0.6)
        XCTAssertEqual(form.ndiSearchCount, after, "离开 NDI 页就停")
        // 输入设置的"来源"一节：双击只选上，不加
        let edit = AddInputFormModel(editing: InputConfig(number: 3, name: "n", source: .ndi(sourceName: "x")))
        defer { edit.close() }
        var editConfirmed = 0
        edit.onConfirm = { editConfirmed += 1 }
        edit.activateNDISource("机位 A (摄像机)")
        XCTAssertEqual(edit.model.ndiSourceName, "机位 A (摄像机)")
        XCTAssertEqual(editConfirmed, 0)
    }

    // MARK: G11 / G12

    func testPanels_addInputRecentFilesAndFileInfo() throws {
        let dir = try scratchDirectory()
        let (history, _) = isolatedHistory()
        var paths: [String] = []
        for i in 0..<12 {
            let url = dir.appendingPathComponent("clip\(i).mov")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            paths.append(url.path)
            history.noteAdded(InputConfig(number: 1, name: "f", source: .file(path: url.path, endAction: .loop, rate: 1)))
        }
        try FileManager.default.removeItem(atPath: paths[11])   // 最新那个不在了
        let form = AddInputFormModel(state: MixerState(), maxInputs: 16, history: history)
        defer { form.close() }
        var confirmed = 0
        form.onConfirm = { confirmed += 1 }
        form.model.kind = .file
        let recents = form.recentFiles
        XCTAssertEqual(recents.map(\.path), Array(paths.reversed().prefix(10)), "最近 10 个，新的在前")
        XCTAssertEqual(recents.map(\.exists), [false] + Array(repeating: true, count: 9), "不在了的照列（灰着）")
        XCTAssertEqual(recents[0].name, "clip11.mov")
        form.addRecentFile(recents[0])
        XCTAssertEqual(confirmed, 0, "不在了的不能直接加")
        form.selectRecentFile(recents[1])
        XCTAssertEqual(form.model.filePath, paths[10], "单击填入")
        form.addRecentFile(recents[2])
        XCTAssertEqual(form.model.filePath, paths[9])
        XCTAssertEqual(confirmed, 1, "双击直接加")
        form.model.kind = .image
        XCTAssertEqual(form.recentFiles, [], "视频和图片各记各的")
        form.model.kind = .file
        form.clearRecentFiles()
        XCTAssertEqual(form.recentFiles, [], "清空")
        XCTAssertEqual(history.recentFiles(for: .file), [])

        // 文件信息：视频（编码 · 尺寸 · 帧率 · 时长）
        let movie = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov").path
        form.model.filePath = movie
        XCTAssertTrue(AppTest.waitUntil(5) { form.fileInfo != nil }, "选好文件就读信息")
        XCTAssertEqual(form.fileInfo?.summary, "H.264 · 1920×1080 · 60 fps · 0:10")
        XCTAssertEqual(form.fileInfo?.isAudioOnly, false)
        // 图片：格式 · 尺寸 · 含透明通道
        let png = dir.appendingPathComponent("logo.png")
        try InputWiringTests.writeSolidPNG(to: png, width: 64, height: 32, red: 1, green: 2, blue: 3)
        form.model.kind = .image
        form.model.imagePath = png.path
        XCTAssertEqual(form.fileInfo?.summary, "PNG · 64×32 · 含透明通道")
        form.model.imagePath = dir.appendingPathComponent("nope.png").path
        XCTAssertEqual(form.fileInfo?.summary, "文件不在了")
    }

    // MARK: Q57

    func testPanels_addInputAcceptsAudioFilesShownAsAudioOnly() throws {
        XCTAssertTrue(MediaFileInfo.isAudioFile("/x/song.MP3"))
        XCTAssertTrue(MediaFileInfo.isAudioFile("/x/a.wav") && MediaFileInfo.isAudioFile("/x/a.m4a") && MediaFileInfo.isAudioFile("/x/a.aac"))
        XCTAssertFalse(MediaFileInfo.isAudioFile("/x/a.mov"))
        let types = MediaFileInfo.movieContentTypes
        for t in [UTType.mp3, .wav, .mpeg4Audio, .movie] { XCTAssertTrue(types.contains(t), "视频文件页的打开面板收 \(t)") }

        // 纯音频文件的信息：纯音频 · 编码 · 采样率 · 声道 · 时长
        let dir = try scratchDirectory()
        let wav = dir.appendingPathComponent("bed.wav")
        do {   // 出了作用域 AVAudioFile 才把文件头写完
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 2))
            buffer.frameLength = 48_000 * 2
            try file.write(from: buffer)
        }
        let info = try XCTUnwrap(Self.load(wav.path))
        XCTAssertTrue(info.isAudioOnly)
        XCTAssertEqual(info.summary, "纯音频 · PCM · 48 kHz · 2 声道 · 0:02")

        // 加出来按纯音频格子显示（话筒 + 表），不是"无信号"的黑块
        let cell = InputCellView(config: InputConfig(number: 1, name: "背景音乐", source: .file(path: wav.path, endAction: .loop, rate: 1)))
        XCTAssertTrue(cell.isAudioOnly)
        let video = InputCellView(config: InputConfig(number: 2, name: "片子", source: .file(path: "/x/a.mov", endAction: .loop, rate: 1)))
        XCTAssertFalse(video.isAudioOnly)
        XCTAssertTrue(L("addInput.file.audioOnlyNote").contains("W5K-w2-inputs-file-audio-only"), "页上写明这一版加上会报错、问题单号")
    }

    private static func load(_ path: String) -> MediaFileInfo? {
        var result: MediaFileInfo?
        Task { @MainActor in result = await MediaFileInfo.loadMovie(path: path) }
        AppTest.waitUntil(5) { result != nil }
        return result
    }

    // MARK: V-16

    func testPanels_addInputAudioDeviceLineHasNoFourCC() {
        XCTAssertEqual(AddInputFormModel.audioDeviceTitle(name: "MacBook Pro 麦克风", channels: 1, transport: "bltn"), "MacBook Pro 麦克风（1 声道 · 内建）")
        XCTAssertEqual(AddInputFormModel.audioDeviceTitle(name: "声卡", channels: 2, transport: "usb "), "声卡（2 声道 · USB）")
        XCTAssertEqual(AddInputFormModel.audioDeviceTitle(name: "虚拟", channels: 2, transport: "????"), "虚拟（2 声道）", "不认识的连接方式不写")
        let form = AddInputFormModel(state: MixerState(), maxInputs: 16)
        defer { form.close() }
        for d in form.audioDevices { XCTAssertFalse(d.title.contains("bltn") || d.title.contains("usb ") || d.title.contains("????"), d.title) }
        let detail = form.audioDeviceDetail(for: "")
        if !detail.isEmpty { XCTAssertTrue(detail.contains("\n"), "说明拆两行：\(detail)") }
    }
}
