// W3-E prompt 测试第 2 条：Show 往返——所有设置保存再打开后完全一致（Codable 快照比对）。
// 夹具把契约里每个可设置的字段都填成非默认值（八种输入来源、裁切 / 变换 / 音频 / 效果链 / 抠像、转场参数、叠加位置与动画、
// 四总线 + 效果链 + AFV + 监听、六种输出的全部设置、布局键），走三条路：Show.save/load、ShowDocuments、App 打开再 makeShow。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

enum ShowFixtures {
    /// 每个字段都非默认的节目（瞬态字段保持 0 / nil，makeState 不会改它们）。
    static func fullyPopulated(recordDirectory: String) -> Show {
        let effects = [
            AudioEffectParams.parametricEQ(centerHz: 250, q: 0.8, gainDb: -2.5),
            AudioEffectParams.parametricEQ(centerHz: 2500, q: 1.4, gainDb: 3),
            AudioEffectParams.dynamicsProcessor(thresholdDb: -18, headroomDb: 4, expansionRatio: 1.5, attackSeconds: 0.002, releaseSeconds: 0.08, overallGainDb: 1, enabled: false),
            AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.03, preGainDb: 2),
        ]
        let audio = InputAudioSettings(routing: BusRouting(master: true, busA: true, busB: false, headphones: true), gainDb: -6.5, muted: true, solo: true, pan: 0.25, delayMs: 120)
        let full = InputSettings(crop: CropInsets(left: 0.1, top: 0.05, right: 0.2, bottom: 0.1),
                                 transform: Transform2D(scale: 0.8, offsetX: 0.1, offsetY: -0.05, rotationDegrees: 12, flipHorizontal: true, flipVertical: true),
                                 audio: audio, effects: effects,
                                 keyer: KeyerSettings(enabled: true, keyColor: RGB8(red: 10, green: 250, blue: 20), tolerance: 0.4, softness: 0.2, spillSuppression: 0.6))
        let synthetic = SyntheticSourceSettings(frameRate: .fps5994, width: 1280, height: 720, background: .noise(level: 100, amplitude: 20, seed: 9),
                                                patternID: 5, jitterMs: 2, dropEveryN: 100, clockDriftPpm: 50, audio: true, audioDriftPpm: -30)
        let inputs = [
            InputConfig(number: 1, name: "机位一", source: .camera(uniqueID: "cam-uid-1"), settings: full),
            InputConfig(number: 2, name: "SDI", source: .decklink(deviceID: "decklink-0"), settings: InputSettings(audio: InputAudioSettings(delayMs: 40))),
            InputConfig(number: 3, name: "窗口", source: .screen(target: .window(id: 4242), frameRate: .fps30, captureAudio: true)),
            InputConfig(number: 4, name: "片头", source: .file(path: "/tmp/intro.mov", endAction: .holdLastFrame, rate: 1.5)),
            InputConfig(number: 5, name: "台标", source: .image(path: "/tmp/logo.png"), settings: InputSettings(transform: Transform2D(scale: 0.25, offsetX: 0.35, offsetY: -0.4))),
            InputConfig(number: 6, name: "NDI", source: .ndi(sourceName: "MACHINE (Cam)")),
            InputConfig(number: 7, name: "话筒", source: .audio(deviceUID: "AppleUSBAudioEngine:1"), settings: InputSettings(audio: InputAudioSettings(gainDb: 12, pan: -1))),
            InputConfig(number: 8, name: "合成", source: .synthetic(settings: synthetic)),
        ]
        let transition = TransitionState(type: .wipe, durationTicks: 45, progress: 0, source: .auto, startTick: nil,
                                         wipe: WipeParams(direction: .diagonal, softness: 0.15), stinger: StingerParams(input: 4, cutAtTick: 12))
        let overlays = [
            OverlayState(input: 5, on: true, rect: NormalizedRect(x: 0.7, y: 0.05, width: 0.25, height: 0.25), animProgress: 1, animation: OverlayAnimation(kind: .fade, durationTicks: 15)),
            OverlayState(input: 3, on: false, rect: .bottomRightQuarter, animProgress: 0, animation: OverlayAnimation(kind: .slide, durationTicks: 30)),
            OverlayState(input: nil, on: false, rect: NormalizedRect(x: 0, y: 0.75, width: 1, height: 0.25), animProgress: 0, animation: OverlayAnimation(kind: .zoom, durationTicks: 10)),
            OverlayState(input: 1, on: false, rect: .full, animProgress: 0, animation: OverlayAnimation(kind: .cut, durationTicks: 0)),
        ]
        let mixer = MixerSettings(format: .hd720p60, program: 1, preview: 2, transition: transition, ftb: FadeToBlack(on: true, durationTicks: 45, level: 1, startTick: nil), overlays: overlays)
        let buses = [
            BusState(bus: .master, gainDb: -1.5, muted: false, effects: [AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0)]),
            BusState(bus: .busA, gainDb: -12, muted: true, effects: [AudioEffectParams.parametricEQ(centerHz: 120, q: 1, gainDb: -6)]),
            BusState(bus: .busB, gainDb: 3, muted: false, effects: []),
            BusState(bus: .headphones, gainDb: -20, muted: false, effects: [AudioEffectParams.dynamicsProcessor(thresholdDb: -10, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.001, releaseSeconds: 0.05, overallGainDb: 0)]),
        ]
        let audioState = AudioState(buses: buses, afv: true, monitorMode: .pfl)
        let video = VideoEncodeSettings(codec: .hevc, bitrateBps: 12_000_000, keyframeIntervalFrames: 60, width: 1280, height: 720)
        let audioEnc = AudioEncodeSettings(codec: .pcm, bitrateBps: 256_000)
        let record = RecordSettings(directory: recordDirectory, fileNamePattern: "{show}-{output}-{date}", container: .mp4, fragmentIntervalSeconds: 2, remuxToMP4: true)
        let outputs = [
            OutputState(number: 1, kind: .record, name: "主录", enabled: true, settings: OutputSettings(source: .program, video: video, audio: audioEnc, record: record)),
            OutputState(number: 2, kind: .record, name: "ISO 1", enabled: true,
                        settings: OutputSettings(source: .input(number: 1), video: VideoEncodeSettings(codec: .prores422), audio: AudioEncodeSettings(), record: record)),
            OutputState(number: 3, kind: .stream, name: "平台 A", enabled: true,
                        settings: OutputSettings(source: .program, video: VideoEncodeSettings(codec: .h264, bitrateBps: 4_500_000, keyframeIntervalFrames: 120),
                                                 audio: AudioEncodeSettings(codec: .aac, bitrateBps: 128_000),
                                                 stream: StreamSettings(url: "srt://127.0.0.1:9000?streamid=x", streamKey: "key-1", reconnectMaxSeconds: 60))),
            OutputState(number: 4, kind: .ndi, name: "Switcher PGM", enabled: true,
                        settings: OutputSettings(source: .program, extra: [OutputExtras.ndiGroups: .string("public"), "ndi.conversion": .string("cpu")])),
            OutputState(number: 5, kind: .externalDisplay, name: "投影", enabled: true,
                        settings: OutputSettings(source: .multiview, extra: [OutputExtras.displayNumber: .number(2)])),
            OutputState(number: 6, kind: .virtualCamera, name: "虚拟摄像头", enabled: true, settings: OutputSettings(source: .preview)),
            OutputState(number: 7, kind: .multiview, name: "多画面", enabled: true, settings: OutputSettings(source: .multiview, extra: ["layout": .string("3x3")])),
        ]
        let layout = ShowLayout(values: ["mixerPanelVisible": .bool(false), "mainWindowFrame": .string("{{0, 0}, {1440, 900}}"), "multiviewWindowFrame": .string("{{10, 10}, {800, 450}}")])
        return Show(name: "全字段", inputs: inputs, mixer: mixer, audio: audioState, outputs: outputs, layout: layout)
    }
}

@MainActor
final class ShowRoundTripTests: XCTestCase {
    /// Codable：save → load 逐字段相等；JSON 里键排序，再编码一次字节相同。
    func testShow_allSettingsRoundTripExact() throws {
        let show = ShowFixtures.fullyPopulated(recordDirectory: "/tmp/rec")
        try show.makeState().validate()
        let data = try show.save()
        let back = try Show.load(from: data)
        XCTAssertEqual(back, show, "保存再读回应逐字段相等")
        XCTAssertEqual(try back.save(), data, "再编码一次应逐字节相同（键排序）")
        // 每一节单独对一遍，出错时好定位
        XCTAssertEqual(back.inputs, show.inputs)
        XCTAssertEqual(back.mixer, show.mixer)
        XCTAssertEqual(back.audio, show.audio)
        XCTAssertEqual(back.outputs, show.outputs)
        XCTAssertEqual(back.layout, show.layout)
        print("全字段节目文件 \(data.count) 字节")
    }

    /// ShowDocuments：文件里来的节目只清录制 / 推流的 enabled（G3 定），其余原样。
    func testShow_documentsRoundTripKeepsEverythingButOutputTargets() throws {
        let suite = "com.example.switcher.tests.roundtrip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let docs = ShowDocuments(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let show = ShowFixtures.fullyPopulated(recordDirectory: dir.path)
        let url = dir.appendingPathComponent("full.\(ShowDocuments.fileExtension)")
        try docs.save(show, to: url)
        let loaded = try docs.load(from: url)
        XCTAssertEqual(loaded, ShowDocuments.stoppingOutputs(show))
        XCTAssertEqual(loaded.outputs.map(\.enabled), [false, false, false, true, true, true, true], "只清 record / stream")
    }

    /// 经 App：打开全字段节目 → session 跑起来（不能跑的输入是占位）→ makeShow 与文件一致（enabled 已清、名字 = 文件名）→ 再保存再打开仍一致。
    func testShow_appOpenThenSaveRoundTrip() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-roundtrip-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let show = ShowFixtures.fullyPopulated(recordDirectory: dir.path)
        let url = dir.appendingPathComponent("全字段.\(ShowDocuments.fileExtension)")
        try show.save().write(to: url)

        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { opened.value && controller.session?.isRunning == true }, "全字段节目应能打开并起引擎：\(String(describing: controller.lastError))")
        let session = try XCTUnwrap(controller.session)
        XCTAssertEqual(session.format, .hd720p60)
        XCTAssertEqual(session.state.inputs.count, 8)
        let expected = ShowDocuments.stoppingOutputs(show)
        let back = session.makeShow()
        XCTAssertEqual(back.name, "全字段")
        XCTAssertEqual(back.inputs, expected.inputs)
        XCTAssertEqual(back.mixer, expected.mixer, "瞬态在夹具里就是 0，所以 makeState 不改它们")
        XCTAssertEqual(back.audio, expected.audio)
        XCTAssertEqual(back.outputs, expected.outputs)
        XCTAssertEqual(back.layout, expected.layout, "session 原样带着文件里的布局")

        // 再保存（布局换成当前窗口的）再打开
        let url2 = dir.appendingPathComponent("再存.\(ShowDocuments.fileExtension)")
        controller.write(session.makeShow(), to: url2)
        let reloaded = try controller.documents.load(from: url2)
        XCTAssertEqual(reloaded.name, "再存")
        XCTAssertEqual(reloaded.inputs, expected.inputs)
        XCTAssertEqual(reloaded.mixer, expected.mixer)
        XCTAssertEqual(reloaded.audio, expected.audio)
        XCTAssertEqual(reloaded.outputs, expected.outputs)
        XCTAssertNotNil(reloaded.layout.values["mainWindowFrame"])
        XCTAssertNotNil(reloaded.layout.values["mixerPanelVisible"])
    }
}
