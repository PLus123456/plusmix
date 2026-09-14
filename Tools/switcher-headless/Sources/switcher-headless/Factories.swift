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
