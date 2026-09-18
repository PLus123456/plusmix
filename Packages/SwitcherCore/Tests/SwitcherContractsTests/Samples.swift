import Foundation
@testable import SwitcherContracts

/// 测试用的样例数据：尽量把每个字段都填成非默认值，往返测试才有意义。
enum Samples {
    static func inputs() -> [InputConfig] {
        var s1 = InputSettings()
        s1.crop = CropInsets(left: 0.1, top: 0.05, right: 0.1, bottom: 0.05)
        s1.transform = Transform2D(scale: 0.5, offsetX: 0.25, offsetY: -0.25, rotationDegrees: 90, flipHorizontal: true, flipVertical: false)
        s1.audio = InputAudioSettings(routing: BusRouting(master: true, busA: true, busB: false, headphones: true), gainDb: -6, muted: false, solo: true, pan: -0.5, delayMs: 120)
        s1.effects = [EffectSlot(id: "parametricEQ", enabled: true, params: ["band1Hz": 1000, "band1Gain": -3])]
        s1.keyer = KeyerSettings(enabled: true, keyColor: RGB8(red: 0, green: 255, blue: 0), tolerance: 0.25, softness: 0.1, spillSuppression: 0.4)
        return [
            InputConfig(number: 1, name: "机位 1", source: .camera(uniqueID: "0x1234-uvc"), settings: s1),
            InputConfig(number: 2, name: "屏幕", source: .screen(target: .display(id: 1), frameRate: .fps30, captureAudio: true), settings: InputSettings()),
            InputConfig(number: 3, name: "片头", source: .file(path: "/Movies/intro.mov", endAction: .holdLastFrame, rate: 1), settings: InputSettings()),
            InputConfig(number: 4, name: "台标", source: .image(path: "/Pictures/logo.png"), settings: InputSettings()),
            InputConfig(number: 5, name: "SDI", source: .decklink(deviceID: "DeckLink Mini Recorder#0"), settings: InputSettings()),
            InputConfig(number: 6, name: "远端", source: .ndi(sourceName: "STUDIO (Cam A)"), settings: InputSettings()),
            InputConfig(number: 7, name: "话筒", source: .audio(deviceUID: "AppleUSBAudioEngine:1"), settings: InputSettings()),
            InputConfig(number: 8, name: "合成", source: .synthetic(settings: SyntheticSourceSettings(frameRate: .fps5994, width: 1280, height: 720, background: .noise(level: 192, amplitude: 24, seed: 7), patternID: 3, jitterMs: 2, dropEveryN: 20, clockDriftPpm: -100, audio: true, audioDriftPpm: 50)), settings: InputSettings()),
        ]
    }

    static func outputs() -> [OutputState] {
        [
            OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                        settings: OutputSettings(source: .program,
                                                 video: VideoEncodeSettings(codec: .hevc, bitrateBps: 12_000_000, keyframeIntervalFrames: 120, width: nil, height: nil),
                                                 audio: AudioEncodeSettings(codec: .aac, bitrateBps: 192_000),
                                                 record: RecordSettings(directory: "/Movies/Switcher", fileNamePattern: "{show}-{date}-{time}", container: .mov, fragmentIntervalSeconds: 1, remuxToMP4: true),
                                                 stream: nil, extra: ["prores": .bool(false)])),
            OutputState(number: 2, kind: .stream, name: "推流 A", enabled: false,
                        settings: OutputSettings(source: .program,
                                                 video: VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000, keyframeIntervalFrames: 120, width: 1280, height: 720),
                                                 audio: AudioEncodeSettings(codec: .aac, bitrateBps: 160_000),
                                                 record: nil,
                                                 stream: StreamSettings(url: "rtmp://127.0.0.1/live", streamKey: "abc", reconnectMaxSeconds: 30), extra: [:])),
            OutputState(number: 3, kind: .multiview, name: "多画面", enabled: true, settings: OutputSettings(source: .multiview)),
            OutputState(number: 4, kind: .externalDisplay, name: "外接屏", enabled: true, settings: OutputSettings(source: .input(number: 2))),
        ]
    }

    static func audio() -> AudioState {
        var a = AudioState()
        a.afv = true
        a.monitorMode = .pfl
        a.buses[Bus.master.rawValue].gainDb = -3
        a.buses[Bus.busA.rawValue].muted = true
        a.buses[Bus.headphones.rawValue].effects = [EffectSlot(id: "peakLimiter", enabled: true, params: [:])]
        return a
    }

    static func mixerState() -> MixerState {
        var s = MixerState(format: .hd1080p5994)
        s.inputs = inputs()
        s.program = 1
        s.preview = 2
        s.transition = TransitionState(type: .wipe, durationTicks: 45, progress: 0.5, source: .auto, startTick: Tick(1000),
                                       wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 3, cutAtTick: 12))
        s.ftb = FadeToBlack(on: true, durationTicks: 15, level: 0.4, startTick: Tick(990))
        s.overlays[0] = OverlayState(input: 4, on: true, rect: NormalizedRect(x: 0.05, y: 0.8, width: 0.9, height: 0.15), animProgress: 1,
                                     animation: OverlayAnimation(kind: .slide, durationTicks: 20), startTick: nil)
        s.overlays[2] = OverlayState(input: 2, on: false, rect: .bottomRightQuarter, animProgress: 0.3,
                                     animation: OverlayAnimation(kind: .fade, durationTicks: 10), startTick: Tick(1001))
        s.audio = audio()
        s.outputs = outputs()
        return s
    }

    static func show() -> Show {
        var show = Show(name: "主日崇拜", state: mixerState())
        show.layout = ShowLayout(values: ["mainWindow": .object(["x": 0, "y": 0, "w": 1920, "h": 1080]), "mixerVisible": true])
        return show
    }

    /// P2 之后每个新字段都填非默认值（latency、frames / dropped / disk_free_mb / reconnects / state、discontinuities / meters）。
    static func stats() -> Stats {
        Stats(ts: 1_757_690_000.5, tick: Tick(216_000), renderMs: 1.75, missedRender: 0, jitterMs: 0.42,
              perInput: [1: Stats.PerInput(fps: 30, dup: 30, drop: 0, latencyMs: 33.4, latencyMaxMs: 41.7),
                         2: Stats.PerInput(fps: 60, dup: 0, drop: 1, latencyMs: 16.7, latencyMaxMs: 18.2)],
              encoder: [Stats.EncoderEntry(skipped: 0, bitrate: 6_000_000, frames: 215_990, dropped: 0, diskFreeMb: 40_960.5, reconnects: 0, state: "recording"),
                        Stats.EncoderEntry(skipped: 3, bitrate: 2_500_000, frames: 215_000, dropped: 12, diskFreeMb: 0, reconnects: 2, state: "publishing")],
              audio: Stats.AudioCounters(dropouts: 0, underruns: 1, discontinuities: 2, meters: meters()),
              rssMb: 512.25, cpuPct: 12.5, gpuPct: 30)
    }

    /// 四条总线（顺序 = Bus.allCases）+ 两路输入的表读数；A / B 总线静音（下限 −120）。
    static func meters() -> Stats.AudioCounters.Meters {
        typealias BM = Stats.AudioCounters.BusMeter
        let silent = [-120.0, -120.0]
        return Stats.AudioCounters.Meters(
            buses: [
                BM(bus: Bus.master.name, peakDb: [-6.5, -7], truePeakDb: [-6.2, -6.8], lufsM: -18.3, lufsS: -19.1, lufsI: -20, lra: 4.5),
                BM(bus: Bus.busA.name, peakDb: silent, truePeakDb: silent, lufsM: -120, lufsS: -120, lufsI: -120, lra: 0),
                BM(bus: Bus.busB.name, peakDb: silent, truePeakDb: silent, lufsM: -120, lufsS: -120, lufsI: -120, lra: 0),
                BM(bus: Bus.headphones.name, peakDb: [-9, -9], truePeakDb: [-8.9, -8.9], lufsM: -21, lufsS: -21.5, lufsI: -22, lra: 3),
            ],
            inputs: [1: Stats.AudioCounters.InputMeter(peakDb: [-12, -12.5]), 3: Stats.AudioCounters.InputMeter(peakDb: silent)])
    }

    static func scenario() -> Scenario {
        Scenario(durationTicks: 3600 * 60, events: [
            ScenarioEvent(tick: Tick(1000), command: .cut),
            ScenarioEvent(tick: Tick(3000), command: .fade(durationTicks: 30)),
            ScenarioEvent(tick: Tick(5000), command: .setPreview(input: 3)),
            ScenarioEvent(tick: Tick(6000), command: .overlay(channel: 1, on: true, input: 4)),
            ScenarioEvent(tick: Tick(9000), command: .startRecord(output: 1)),
        ])
    }

    /// 每个 Command case 至少一个样例。`caseName(of:)` 的 switch 没有 default：加了 case 而没加样例，这里编译就红。
    static func commands() -> [Command] {
        [
            .cut,
            .fade(durationTicks: 30),
            .setTransition(type: .stinger, durationTicks: 40),
            .autoTransition,
            .setPreview(input: 2),
            .setProgram(input: 3),
            .tbar(progress: 0.75),
            .ftb(on: true),
            .overlay(channel: 2, on: true, input: 4),
            .overlay(channel: 3, on: false, input: nil),
            .setOverlay(channel: 1, rect: .bottomRightQuarter, animation: OverlayAnimation(kind: .zoom, durationTicks: 12)),
            .audioGain(input: 1, dB: -6.5),
            .mute(input: 1, on: true),
            .busGain(bus: .busA, dB: 2),
            .busMute(bus: .headphones, on: false),
            .setAFV(on: true),
            .startRecord(output: 1),
            .stopRecord(output: 1),
            .startStream(output: 2),
            .stopStream(output: 2),
            .setInputSettings(input: 1, settings: inputs()[0].settings),
            .renameInput(input: 1, name: "讲台"),
            .addInput(config: inputs()[7]),
            .removeInput(input: 8),
            .addOutput(config: outputs()[1]),
            .removeOutput(output: 2),
            .setOutputSettings(output: 1, settings: outputs()[0].settings),
            .loadShow(show: show()),
        ]
    }

    static func caseName(of c: Command) -> String {
        switch c {
        case .cut: "cut"
        case .fade: "fade"
        case .setTransition: "setTransition"
        case .autoTransition: "autoTransition"
        case .setPreview: "setPreview"
        case .setProgram: "setProgram"
        case .tbar: "tbar"
        case .ftb: "ftb"
        case .overlay: "overlay"
        case .setOverlay: "setOverlay"
        case .audioGain: "audioGain"
        case .mute: "mute"
        case .busGain: "busGain"
        case .busMute: "busMute"
        case .setAFV: "setAFV"
        case .startRecord: "startRecord"
        case .stopRecord: "stopRecord"
        case .startStream: "startStream"
        case .stopStream: "stopStream"
        case .setInputSettings: "setInputSettings"
        case .renameInput: "renameInput"
        case .addInput: "addInput"
        case .removeInput: "removeInput"
        case .addOutput: "addOutput"
        case .removeOutput: "removeOutput"
        case .setOutputSettings: "setOutputSettings"
        case .loadShow: "loadShow"
        }
    }
    static let commandCaseCount = 27
}
