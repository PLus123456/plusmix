// 输入工厂（W2-B2 接缝 1）：把一路 InputConfig 变成活的 Input 对象。
// 摄像头 / 屏幕 / 文件 / 图片用 W2-A 的四种输入（`init(config:timing:videoSlot:audioRing:)`），合成源用 TestKit 的 SyntheticVideoInput；
// 帧槽与音频环由组装方（InputRuntime）建（CONTRACTS.md §2.3 注入规则），带音频的路把 `CAudioRing` 交给输入、再注册进 AudioEngine。
// DeckLink / NDI / 纯音频设备的实现在 W3-A，这里建成占位（格子上有文案）。
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherAudio
import SwitcherTestKit

/// 工厂产物：输入对象 + 它往里写的音频环（没有音频的路为 nil）。
struct MadeInput {
    let input: any Input
    let audioRing: CAudioRing?
    /// 生产者一次写多少帧（AudioInputHints.producerBlockFrames：决定混音器的就绪门限）。
    let audioBlockFrames: Int
}

/// 把一路输入配置变成运行对象。
protocol InputFactory {
    /// - Parameters:
    ///   - slot: 组装方建好的帧槽（W3-C 起是 InputFrameTee：主槽给引擎，分支给 ISO 录制），实现只往里 push。
    ///   - timing: 节目时钟（格式 + 拍点）。引擎 start 前 t0 = 引擎的 t0；引擎已起时 = "现在之后第 3 拍"（见 SwitcherSession.programTiming）。
    func makeInput(config: InputConfig, slot: any FrameSlot, timing: ProgramTiming) throws -> MadeInput
}

enum InputFactoryError: Error, CustomStringConvertible {
    /// 这种输入还没有实现（DeckLink / NDI 在 W3-A）。
    case unsupported(InputKind)
    var description: String {
        switch self {
        case .unsupported(let kind): L("input.unsupported", L("addInput.kind.\(kind.rawValue)"))
        }
    }
}

/// 默认工厂：五种能跑的输入。
struct DefaultInputFactory: InputFactory {
    /// 合成源视频比拍点提前半个节目帧（headless 的 --input-lead-ms 默认值，理由见 HeadlessRun.swift 第 1 步）；音频（click）不提前。
    static func syntheticLead(_ timing: ProgramTiming) -> HostDuration {
        HostDuration(seconds: timing.format.frameDuration.doubleValue / 2)
    }

    func makeInput(config: InputConfig, slot: any FrameSlot, timing: ProgramTiming) throws -> MadeInput {
        switch config.source {
        case .synthetic(let settings):
            let videoTimeline = SyntheticTimeline(t0: timing.clock.t0 - Self.syntheticLead(timing), frameRate: settings.frameRate)
            let video = try SyntheticVideoInput(number: config.number, name: config.name, settings: settings, videoSlot: slot,
                                                audioRing: nil, timeline: videoTimeline, seed: UInt64(config.number))
            guard settings.audio else { return MadeInput(input: video, audioRing: nil, audioBlockFrames: AudioFormat.defaultBlockFrames) }
            // 音频用不带提前量的时间线：第 k 个 click 在 t0 + k s，与第 60k 拍的闪光同刻（A2 = 0 才对）
            let ring = CAudioRing(channelCount: 2)
            let audio = SyntheticAudioInput(number: config.number, name: L("input.audioName", config.name), frameRate: timing.format.frameRate,
                                            driftPpm: settings.audioDriftPpm, audioRing: ring,
                                            timeline: SyntheticTimeline(t0: timing.clock.t0, frameRate: timing.format.frameRate))
            return MadeInput(input: SyntheticPairInput(video: video, audio: audio), audioRing: ring, audioBlockFrames: audio.blockFrames)
        case .camera:
            // 设备自带麦克风（需要麦克风权限；没有就只出视频）：AVCaptureAudioDataOutput 一次 512–1024 帧
            let ring = CAudioRing(channelCount: 2)
            let input = try CameraInput(config: config, timing: timing, videoSlot: slot, audioRing: ring)
            return MadeInput(input: input, audioRing: ring, audioBlockFrames: 1024)
        case .screen(_, _, let captureAudio):
            let ring = captureAudio ? CAudioRing(channelCount: 2) : nil
            let input = try ScreenInput(config: config, timing: timing, videoSlot: slot, audioRing: ring)
            return MadeInput(input: input, audioRing: ring, audioBlockFrames: 960)   // SCK 音频块 960 帧（20 ms）
        case .file:
            let ring = CAudioRing(channelCount: 2)
            let options = FileInput.Options()
            let input = try FileInput(config: config, timing: timing, videoSlot: slot, audioRing: ring, options: options)
            return MadeInput(input: input, audioRing: ring, audioBlockFrames: options.audioChunkFrames)
        case .image:
            let input = try ImageInput(config: config, timing: timing, videoSlot: slot)
            return MadeInput(input: input, audioRing: nil, audioBlockFrames: AudioFormat.defaultBlockFrames)
        case .decklink, .ndi, .audio:
            throw InputFactoryError.unsupported(config.kind)
        }
    }
}

/// 合成源的视频 + 音频两个对象合成一路 Input（视频时间线带半帧提前量、音频不带，见 DefaultInputFactory）。
final class SyntheticPairInput: Input, @unchecked Sendable {
    let video: SyntheticVideoInput
    let audio: SyntheticAudioInput
    init(video: SyntheticVideoInput, audio: SyntheticAudioInput) {
        self.video = video
        self.audio = audio
    }
    var number: Int { video.number }
    var name: String { video.name }
    var kind: InputKind { .synthetic }
    var state: InputState { video.state }
    var videoSlot: (any FrameSlot)? { video.videoSlot }
    var audioRing: (any AudioRing)? { audio.audioRing }
    func start() throws {
        try video.start()
        try audio.start()
    }
    func stop() {
        audio.stop()
        video.stop()
    }
}

/// 建不出来的输入占位：编号占着、帧槽为空（画黑），state 带文案给 UI 显示。
final class PlaceholderInput: Input, @unchecked Sendable {
    let number: Int
    let name: String
    let kind: InputKind
    let state: InputState
    let videoSlot: (any FrameSlot)? = nil
    let audioRing: (any AudioRing)? = nil
    init(config: InputConfig, message: String) {
        number = config.number
        name = config.name
        kind = config.kind
        state = .error(message: message)
    }
    func start() throws {}
    func stop() {}
}
