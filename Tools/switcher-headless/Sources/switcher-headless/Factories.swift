import Foundation
import SwitcherContracts

/// M0 标准负载的节目文件与场景（G2 prompt 第 2、3 条），用子命令生成后入库，改了这里要在检查点报告里说明（scenarios/README.md）。
enum M0Factory {
    /// 8 路合成源：2 路 30、2 路 59.94、4 路 60，其中 5 号 +100 ppm、6 号 −100 ppm 漂移，7 号 ±3 ms 抖动；
    /// 1 号带合成音频（click 与它的闪光共用 t0）。底色灰度按编号错开，肉眼能看出 Cut。
    static func show(width: Int = 1920, height: Int = 1080) -> Show {
        struct Spec { let rate: FrameRate; let drift: Double; let jitter: Double; let audio: Bool }
        let specs: [Spec] = [
            Spec(rate: .fps30, drift: 0, jitter: 0, audio: true),
            Spec(rate: .fps30, drift: 0, jitter: 0, audio: false),
            Spec(rate: .fps5994, drift: 0, jitter: 0, audio: false),
            Spec(rate: .fps5994, drift: 0, jitter: 0, audio: false),
            Spec(rate: .fps60, drift: 100, jitter: 0, audio: false),
            Spec(rate: .fps60, drift: -100, jitter: 0, audio: false),
            Spec(rate: .fps60, drift: 0, jitter: 3, audio: false),
            Spec(rate: .fps60, drift: 0, jitter: 0, audio: false),
        ]
        let inputs = specs.enumerated().map { i, s -> InputConfig in
            let number = i + 1
            let settings = SyntheticSourceSettings(frameRate: s.rate, width: width, height: height,
                                                   background: .gray(level: UInt8(32 + 20 * i)), patternID: nil,
                                                   jitterMs: s.jitter, dropEveryN: 0, clockDriftPpm: s.drift,
                                                   audio: s.audio, audioDriftPpm: 0)
            var name = "合成 \(number) · \(s.rate)"
            if s.drift != 0 { name += String(format: " %+.0f ppm", s.drift) }
            if s.jitter != 0 { name += " ±\(Int(s.jitter)) ms" }
            if s.audio { name += " +音频" }
            return InputConfig(number: number, name: name, source: .synthetic(settings: settings))
        }
        let mixer = MixerSettings(format: .hd1080p60, program: 1, preview: 2,
                                  transition: TransitionState(type: .fade, durationTicks: 30),
                                  ftb: FadeToBlack(), overlays: Array(repeating: OverlayState(), count: MixerState.overlayCount))
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: ".", fileNamePattern: "{show}-{date}-{time}")))
        return Show(name: "m0", inputs: inputs, mixer: mixer, audio: AudioState(), outputs: [record])
    }

    /// 每 30 s 切一次：第 k 次在第 k × 30 s 拍，k 是 10 的倍数（每 5 分钟）时用 Fade（30 拍），其余 Cut；
    /// 切完后把 PVW 推到下一路（Cut 后 1 拍、Fade 后 31 拍，避开转场进行中）。PGM 顺序 1 → 2 → … → 8 → 1。
    /// 60 分钟版一共 120 次切换；--duration 更短时后面的事件自然不触发。
    static func scenario(minutes: Int = 60, fps: Double = 60, inputs: Int = 8, fadeTicks: Int = 30) -> Scenario {
        let ticksPer30s = Int((30 * fps).rounded())
        let switches = minutes * 2
        var events: [ScenarioEvent] = []
        for k in 1...switches {
            let at = Tick(Int64(k * ticksPer30s))
            let nextPreview = ((k + 1) % inputs) + 1          // 切换 k 之后 PGM = (k mod 8) + 1，PVW 该指向再下一路
            if k % 10 == 0 {
                events.append(ScenarioEvent(tick: at, command: .fade(durationTicks: fadeTicks)))
                events.append(ScenarioEvent(tick: at + (fadeTicks + 1), command: .setPreview(input: nextPreview)))
            } else {
                events.append(ScenarioEvent(tick: at, command: .cut))
                events.append(ScenarioEvent(tick: at + 1, command: .setPreview(input: nextPreview)))
            }
        }
        return Scenario(durationTicks: Int((Double(minutes) * 60 * fps).rounded()), events: events)
    }
}

/// G3 检查点的节目文件与场景（G3 prompt 第 2 条 b；测试标准 §3 V6 / V7 / A4 的做法）。
/// 与 M0 的差别：底纹是灰底 + 噪声（G4 起；M0 / G2 保留纯灰底，基线不可比），1 号灰度 64、2 号灰度 192（V7 的 A / B），1–4 号带合成音频（A4 的四路 ISO 音轨；2–4 号不送 Master，
/// 免得四个满幅 click 叠在一起削波、A2 只看 1 号的 click），Overlay 1 预配成右下角画中画（不盖住测试图案和中心采样区）。
enum G3Factory {
    /// 噪声底纹幅度（full-range 电平）：W1-A2 报告 §2 用 24 时 E2 6.002 Mbps / 峰值 1.08×；64 ± 24 与 192 ± 24 都不越界，V7 的中心均值不偏。
    static let noiseAmplitude: UInt8 = 24

    /// 灰度按 V7 要求：A = 64（1 号）、B = 192（2 号）；其余错开 ≥ 16 级，frameprobe 的标称灰度容差是 6。
    static func show(width: Int = 1920, height: Int = 1080) -> Show {
        struct Spec { let rate: FrameRate; let gray: UInt8; let drift: Double; let jitter: Double; let audio: Bool; let audioDrift: Double; let toMaster: Bool }
        let specs: [Spec] = [
            Spec(rate: .fps30, gray: 64, drift: 0, jitter: 0, audio: true, audioDrift: 0, toMaster: true),
            Spec(rate: .fps60, gray: 192, drift: 0, jitter: 0, audio: true, audioDrift: 100, toMaster: false),
            Spec(rate: .fps5994, gray: 96, drift: 0, jitter: 0, audio: true, audioDrift: -100, toMaster: false),
            Spec(rate: .fps5994, gray: 128, drift: 0, jitter: 0, audio: true, audioDrift: 50, toMaster: false),
            Spec(rate: .fps60, gray: 144, drift: 100, jitter: 0, audio: false, audioDrift: 0, toMaster: true),
            Spec(rate: .fps60, gray: 160, drift: -100, jitter: 0, audio: false, audioDrift: 0, toMaster: true),
            Spec(rate: .fps60, gray: 176, drift: 0, jitter: 3, audio: false, audioDrift: 0, toMaster: true),
            Spec(rate: .fps60, gray: 208, drift: 0, jitter: 0, audio: false, audioDrift: 0, toMaster: true),
        ]
        let inputs = specs.enumerated().map { i, s -> InputConfig in
            let number = i + 1
            // 底纹：灰度 s.gray 上叠 ±24 的零均值噪声（提案 006 / W1-A2；G4 起换上，prompt 60 末节第 2 条）——纯灰底压不出设定码率，E2 无法在
            // 长跑里判；噪声只动亮度、四样解码块不加噪、中心 1/4 均值仍 = level（V6 / V7 不受影响）。seed = 输入号，每路噪声不同。
            let settings = SyntheticSourceSettings(frameRate: s.rate, width: width, height: height,
                                                   background: .noise(level: s.gray, amplitude: noiseAmplitude, seed: UInt64(number)), patternID: nil,
                                                   jitterMs: s.jitter, dropEveryN: 0, clockDriftPpm: s.drift,
                                                   audio: s.audio, audioDriftPpm: s.audioDrift)
            var name = "合成 \(number) · \(s.rate) 灰 \(s.gray)±\(noiseAmplitude)"
            if s.drift != 0 { name += String(format: " %+.0f ppm", s.drift) }
            if s.jitter != 0 { name += " ±\(Int(s.jitter)) ms" }
            if s.audio { name += s.toMaster ? " +音频" : String(format: " +音频(ISO %+.0f ppm)", s.audioDrift) }
            var inputSettings = InputSettings()
            inputSettings.audio = InputAudioSettings(routing: BusRouting(master: s.toMaster))
            return InputConfig(number: number, name: name, source: .synthetic(settings: settings), settings: inputSettings)
        }
        var overlays = Array(repeating: OverlayState(), count: MixerState.overlayCount)
        // Overlay 1：8 号画中画放右下角 28%，cut 进出；测试图案在左上、闪光块在右上、frameprobe 的灰度采样区是中心 1/4，都不被盖
        overlays[0] = OverlayState(input: 8, on: false, rect: NormalizedRect(x: 0.70, y: 0.70, width: 0.28, height: 0.28),
                                   animation: OverlayAnimation(kind: .cut, durationTicks: 0))
        let mixer = MixerSettings(format: .hd1080p60, program: 1, preview: 2,
                                  transition: TransitionState(type: .fade, durationTicks: 30),
                                  ftb: FadeToBlack(), overlays: overlays)
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: ".", fileNamePattern: "{show}-{date}-{time}")))
        return Show(name: "g3", inputs: inputs, mixer: mixer, audio: AudioState(), outputs: [record])
    }

    /// 时间线（60 fps 拍数）：
    ///   1000  Cut（PGM 1 → 2；V6：新 ID 恰在第 1000 拍出现且无混合帧）
    ///   3000  Fade 30 拍（PGM 2 → 1；V7 曲线：frameprobe fade --fade-at 3000 --duration 30 --gray-a 64 --gray-b 192）
    ///   3600 / 3660 / 3720  T-bar 0.25 / 0.5 / 0.75 各停 60 拍（V7 映射：PVW = 2 号 192 盖在 PGM = 1 号 64 上，
    ///                       灰度应为 64 + 128 × 进度；gate3-report 按 frameprobe frames 的中心灰度核），3780 推到 1（提交，PGM 2 / PVW 1）
    ///   7200 起  每 5 s 一次 Cut、切完 1 拍把 PVW 推到下一路（PGM 1 → 2 → … → 8 → 1 循环）；
    ///   7350 起  每 30 s 开 / 关一次 Overlay 1（与 Cut 错开 2.5 s）
    /// C 系列客户端（scripts/apitest）从 150 s 起插自己的 cut（相位避开 5 s 切换点），不碰 V6 / V7 那段。
    static func scenario(minutes: Int = 10, fps: Double = 60, inputs: Int = 8) -> Scenario {
        let duration = Int((Double(minutes) * 60 * fps).rounded())
        var events: [ScenarioEvent] = []
        func add(_ tick: Int, _ command: Command) { events.append(ScenarioEvent(tick: Tick(Int64(tick)), command: command)) }
        add(1000, .cut)
        add(3000, .fade(durationTicks: 30))
        add(3600, .tbar(progress: 0.25))
        add(3660, .tbar(progress: 0.5))
        add(3720, .tbar(progress: 0.75))
        add(3780, .tbar(progress: 1))
        var pgm = 2, pvw = 1
        let ticksPer5s = Int((5 * fps).rounded())
        var tick = Int((120 * fps).rounded())
        while tick < duration {
            add(tick, .cut)
            (pgm, pvw) = (pvw, pgm)
            let next = (pgm % inputs) + 1
            if next != pvw {
                add(tick + 1, .setPreview(input: next))
                pvw = next
            }
            tick += ticksPer5s
        }
        var on = true
        var overlayTick = Int((122.5 * fps).rounded())
        let ticksPer30s = Int((30 * fps).rounded())
        while overlayTick < duration {
            add(overlayTick, .overlay(channel: 1, on: on, input: nil))
            on.toggle()
            overlayTick += ticksPer30s
        }
        return Scenario(durationTicks: duration, events: events.sorted { $0.tick.rawValue < $1.tick.rawValue })
    }
}
