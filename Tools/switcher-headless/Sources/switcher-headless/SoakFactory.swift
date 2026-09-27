import AVFoundation
import Foundation
import SwitcherContracts
import SwitcherInputs

/// W4-A 的节目文件与场景（prompt 70 第 1、3 条；测试标准 §3 S1 / S2 / A3、§5 L4 / L5）。
/// scenarios/ 不归 W4-A，这两个预设由 scripts/soak/soak.sh、scripts/perf/perf-baseline.sh 在跑的时候生成进各自的输出目录（摄像头 uniqueID 是本机的）。
///
/// soak（make soak / soak-1h）：G4 的节目（8 路噪声底纹合成源、5–8 号抠像、9 号 Stinger PNG、Overlay 1–4、多画面自定义布局、五种转场）
/// + 10 号内置摄像头 + 11 号文件（E4 的测试片段，循环）；输出 = 1 录制、2 多画面、3 / 4 推流（本地 MediaMTX，地址由 run 的 --stream 给）、5 NDI 发送（--ndi-send）。
/// - Overlay 1 / 2 换成摄像头 / 文件（画中画位置沿用 G4：避开图案行、闪光块、中心采样区和 ID 下方的背景带），3 / 4 仍是 7 / 8 号抠像。
/// - **PGM 只在 1–8 号之间轮**：A2 / A3 靠 PGM 的闪光帧（右上角 64×64 全白）配 1 号的 click；摄像头 / 文件 / PNG 放上 PGM，
///   右上角亮起来会被 frameprobe 当成闪光、配出几百毫秒的假偏移。摄像头 / 文件经叠加和多画面进合成（每拍都在画）。
/// - 摄像头 / 文件的声音不进 Master（路由 master 关，仍走混音器、仍出表）：Master 里只有 1 号的正弦 + click，A2 / A3 的配对才干净。
/// - 场景：第 30 s 起每 30 s 一次转场，按 Cut → Fade → Wipe → Zoom → Stinger 轮流（非 Cut 24 拍）；第 15 s 起每 5 min 翻一路叠加（1 → 2 → 3 → 4 循环，
///   每路开 20 min 关 20 min），与切换点错开 15 s。
///
/// perf-e4（make perf-baseline 的 E4）：只有一路文件输入放在 PGM 上，录制；片段放完停在末帧。
enum SoakFactory {
    static let cameraInput = 10
    static let fileInput = 11
    /// 非 Cut 转场的时长（拍），同 G4。
    static let transitionTicks = G4Factory.transitionTicks
    static let rotation = G4Factory.rotation
    static let switchPeriodSeconds = 30.0
    static let overlayPeriodSeconds = 300.0
    static let overlayPhaseSeconds = 15.0
    /// 本地 MediaMTX 的 RTMP 端口（scripts/soak/soak.sh 起的那个实例；避开 W2-D 测试用的 1935–1937）。节目里只作说明，真正的地址由 run 的 --stream 给。
    static let defaultRTMPPort = 19350

    struct CameraDevice: Hashable, Sendable {
        var uniqueID: String
        var name: String
    }

    // MARK: 节目

    static func show(camera: CameraDevice?, filePath: String?, width: Int = 1920, height: Int = 1080) -> Show {
        let g4 = G4Factory.show(width: width, height: height)
        var inputs = g4.inputs
        var overlays = g4.mixer.overlays
        var notMaster = InputSettings()
        notMaster.audio = InputAudioSettings(routing: BusRouting(master: false))
        if let camera {
            inputs.append(InputConfig(number: cameraInput, name: "内置摄像头（\(camera.name)）", source: .camera(uniqueID: camera.uniqueID),
                                      settings: notMaster))
            overlays[0].input = cameraInput
        }
        if let filePath {
            let name = URL(fileURLWithPath: filePath).lastPathComponent
            inputs.append(InputConfig(number: fileInput, name: "文件（\(name)，循环）", source: .file(path: filePath, endAction: .loop, rate: 1),
                                      settings: notMaster))
            overlays[1].input = fileInput
        }
        let mixer = MixerSettings(format: g4.mixer.format, program: 1, preview: 2, transition: g4.mixer.transition, ftb: FadeToBlack(), overlays: overlays)
        let cellInputs = inputs.compactMap { cfg -> Int? in
            if case .image = cfg.source { return nil }   // Stinger 的 PNG 不占格
            return cfg.number
        }
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: ".", fileNamePattern: "{show}-{date}-{time}")))
        let multiview = OutputState(number: 2, kind: .multiview, name: "多画面（自定义布局）", enabled: true,
                                    settings: OutputSettings(source: .multiview, multiview: multiviewLayout(inputNumbers: cellInputs)))
        func stream(_ number: Int, _ path: String) -> OutputState {
            OutputState(number: number, kind: .stream, name: "推流 \(path)（本地 MediaMTX）", enabled: true,
                        settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                 stream: StreamSettings(url: "rtmp://127.0.0.1:\(defaultRTMPPort)/\(path)")))
        }
        let ndi = OutputState(number: 5, kind: .ndi, name: "NDI 发送（PGM）", enabled: true, settings: OutputSettings(source: .program))
        return Show(name: "soak", inputs: inputs, mixer: mixer, audio: AudioState(),
                    outputs: [record, multiview, stream(3, "s1"), stream(4, "s2"), ndi])
    }

    /// 多画面：上半 PVW / PGM，下半输入格两行（≤ 8 格 4 列，多了 5 列），格子几何的写法同 G4。
    static func multiviewLayout(inputNumbers: [Int]) -> MultiviewLayoutSettings {
        let m = 0.005
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect { NormalizedRect(x: x, y: y, width: w, height: h) }
        var cells: [MultiviewCell] = [
            MultiviewCell(source: .preview, rect: rect(m, m, 0.5 - 1.5 * m, 0.5 - 1.5 * m)),
            MultiviewCell(source: .program, rect: rect(0.5 + 0.5 * m, m, 0.5 - 1.5 * m, 0.5 - 1.5 * m)),
        ]
        let rows = 2
        let columns = inputNumbers.count > 8 ? 5 : 4
        let cellW = (1 - Double(columns + 1) * m) / Double(columns)
        let cellH = (0.5 - Double(rows + 1) * m) / Double(rows)
        for (i, n) in inputNumbers.prefix(columns * rows).enumerated() {
            let col = i % columns, row = i / columns
            cells.append(MultiviewCell(source: .input(number: n), rect: rect(m + Double(col) * (cellW + m), 0.5 + m + Double(row) * (cellH + m), cellW, cellH)))
        }
        return MultiviewLayoutSettings(custom: cells, safeArea: true, meters: true)
    }

    /// E4：一路文件输入在 PGM 上、只录制（片段放完停在末帧）。PVW 也指它（没有第二路）。
    static func perfE4Show(filePath: String, width: Int = 1920, height: Int = 1080) -> Show {
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        let inputs = [InputConfig(number: 1, name: "E4 测试片段（\(name)）", source: .file(path: filePath, endAction: .holdLastFrame, rate: 1))]
        let mixer = MixerSettings(format: .hd1080p60, program: 1, preview: 1, transition: TransitionState(type: .cut, durationTicks: 0),
                                  ftb: FadeToBlack(), overlays: Array(repeating: OverlayState(), count: MixerState.overlayCount))
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: ".", fileNamePattern: "{show}-{date}-{time}")))
        return Show(name: "perf-e4", inputs: inputs, mixer: mixer, audio: AudioState(), outputs: [record])
    }

    // MARK: 场景

    /// 每 30 s 一次转场（五种轮流），每次切完把 PVW 推到 1–8 号里的下一路；每 5 min 翻一路叠加。
    static func scenario(minutes: Int, fps: Double = 60, inputs: Int = 8) -> Scenario {
        let duration = Int((Double(minutes) * 60 * fps).rounded())
        var events: [ScenarioEvent] = []
        func add(_ tick: Int, _ command: Command) { events.append(ScenarioEvent(tick: Tick(Int64(tick)), command: command)) }
        let period = Int((switchPeriodSeconds * fps).rounded())
        let d = transitionTicks
        var pgm = 1, pvw = 2
        var k = 0
        var tick = period
        while tick < duration {
            let kind = rotation[k % rotation.count]
            let settle: Int
            switch kind {
            case .cut:
                add(tick, .cut)
                settle = 1
            case .fade:
                add(tick, .fade(durationTicks: d))
                settle = d + 1
            case .wipe, .zoom, .stinger:
                add(tick - 1, .setTransition(type: kind, durationTicks: d))
                add(tick, .autoTransition)
                settle = d + 1
            }
            (pgm, pvw) = (pvw, pgm)
            let next = (pgm % inputs) + 1
            if next != pvw {
                add(tick + settle, .setPreview(input: next))
                pvw = next
            }
            tick += period
            k += 1
        }
        var on = [false, false, false, false]
        var channel = 0
        var overlayTick = Int((overlayPhaseSeconds * fps).rounded())
        let overlayPeriod = Int((overlayPeriodSeconds * fps).rounded())
        while overlayTick < duration {
            on[channel].toggle()
            add(overlayTick, .overlay(channel: channel + 1, on: on[channel], input: nil))
            channel = (channel + 1) % on.count
            overlayTick += overlayPeriod
        }
        let indexed = events.enumerated().sorted { a, b in
            a.element.tick.rawValue != b.element.tick.rawValue ? a.element.tick.rawValue < b.element.tick.rawValue : a.offset < b.offset
        }
        return Scenario(durationTicks: duration, events: indexed.map(\.element))
    }

    // MARK: 摄像头

    /// --camera auto | none | <uniqueID>：auto = 第一台内置广角摄像头（笔记本自带的那台）；不挑连续互通（iPhone）/ 外接 / 桌上视角——它们会断开、会被别的设备借走，
    /// 8 小时里掉了就不是"标准负载"了。列设备不需要摄像头权限；真正开采集时没授权，CameraInput 会停在 error 状态并每秒重查（soak 报告里有这路的 fps）。
    static func resolveCamera(_ spec: String) throws -> CameraDevice? {
        let devices = CameraDevices.list()
        func listing() -> String {
            devices.isEmpty ? "没有任何视频设备" : devices.map { "\($0.name)（\($0.uniqueID)，\($0.deviceType)）" }.joined(separator: " / ")
        }
        switch spec.lowercased() {
        case "none", "off", "":
            return nil
        case "auto", "builtin":
            guard let d = devices.first(where: { $0.deviceType == AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue }) else {
                throw CLIError("没找到内置摄像头（--camera auto）。现在有：\(listing())；给 --camera <uniqueID> 或 --camera none")
            }
            return CameraDevice(uniqueID: d.uniqueID, name: d.name)
        default:
            guard let d = devices.first(where: { $0.uniqueID == spec }) else {
                throw CLIError("没有 uniqueID 为 \(spec) 的摄像头。现在有：\(listing())")
            }
            return CameraDevice(uniqueID: d.uniqueID, name: d.name)
        }
    }
}
