import AppKit
import Foundation
import ImageIO
import SwitcherContracts

/// G4 检查点的节目文件与场景（prompt 60 第 2 条 L2：五种转场轮流、Overlay 1–4 动画、抠像开、多画面开；测试标准 §3 V6 / V7 / A4 的做法）。
///
/// 与 G3 的差别（1–4 号、V6 / V7 锚点、C 系列相位全部沿用 G3，基线可与 g3 场景的 V1 相比只差新负载）：
/// - 5–8 号输入开抠像（契约 `InputSettings.keyer`，键色红：灰噪声底纹与这四路的 ID 色上都没有红，画面不变但着色器按 W3-B 的口径逐采样点算，
///   量的是抠像的代价；真绿幕的抠像质量由 W3-B 的 IoU 用例和 docs/checklists/G4.md 的人工项看）。
/// - Overlay 1–4 各挂 5–8 号（fade 15 / slide 20 / zoom 20 / cut），位置避开测试图案（左上）、闪光块（右上）和 frameprobe 的中心采样区（宽高各 1/4）。
/// - 9 号是带 alpha 的静态 PNG（`stingerFileName`，make-show 时写在节目文件旁边；路径相对节目文件），做 Stinger 的叠层：
///   图形只占下 20% 与左右两侧（不碰顶部图案行、闪光块、中心采样区），Stinger 期间帧号 / ID 照常可解。
/// - 多画面输出带自定义布局（提案 010 的正式字段 `OutputSettings.multiview`：PGM / PVW 上半 + 8 路 4×2，安全框 + 真实电平表（W3-B2 起；headless 在 Stats 消费者里每秒 setMeters）；
///   P3 之前写的是过渡键 `extra["layout"]`，格子几何逐字相同）。
/// - 转场：Wipe 从左到右、软边 0.1；Stinger 用 9 号、第 12 拍换底。
/// - 场景：120 s 起每 5 s 一次转场，按 Cut → Fade → Wipe → Zoom → Stinger 轮流（非 Cut 都 24 拍 = 0.4 s，在 C1 客户端 x.7 s 的 cut 之前结束），
///   122.5 s 起每 15 s 开 / 关一路叠加（1 → 2 → 3 → 4 循环，每路 60 s 翻一次）。
///   frameprobe 对转场中间帧（帧号行与 ID 块在不同拍翻转、混合色）判不出输入身份，gate4 把每次非 Cut 转场的 [t + 1, t + d] 拍标成不可解码
///   （`frameprobe --blank-ticks`，V4 的引擎侧计数 stats.jsonl 全程照算），第 t 拍（progress 0 = 纯旧画面，也是整秒闪光帧）保留。
enum G4Factory {
    static let noiseAmplitude: UInt8 = G3Factory.noiseAmplitude
    /// 非 Cut 转场的时长（拍）。
    static let transitionTicks = 24
    /// Stinger 换底的拍。
    static let stingerCutAtTick = 12
    /// 叠加 PNG 的文件名（与节目文件同目录）。
    static let stingerFileName = "g4-stinger.png"
    /// Stinger 输入的编号。
    static let stingerInput = 9
    /// 非 Cut 转场轮流的顺序。
    static let rotation: [TransitionType] = [.cut, .fade, .wipe, .zoom, .stinger]

    static func show(width: Int = 1920, height: Int = 1080) -> Show {
        var inputs = G3Factory.show(width: width, height: height).inputs
        for i in inputs.indices where inputs[i].number >= 5 {
            // 键色用红（255,0,0）而不是默认绿：7 号的 ID 块是调色板 6 号黄绿（128,255,0），绿键会把它抠成透明，frameprobe 就认不出输入 7 了
            // （G4 第一次 10 分钟跑就是这样：ID 6 在播 0 帧）。红离 5–8 号的 ID 色（品红 / 金 / 黄绿 / 天蓝）与灰噪声底都远，画面不变，只付着色器代价。
            inputs[i].settings.keyer = KeyerSettings(enabled: true, keyColor: RGB8(red: 255, green: 0, blue: 0))   // 容差 0.3、柔化 0.1、溢色 0.5（提案 009 的口径）
            inputs[i].name += " 抠像"
            // 溢色抑制 0.5 会把"红分量最高"的 ID 色往灰里拉：5 号的品红（4）、6 号的金（5）在播时 ID 块离标称色 40 > 契约阈值 24，frameprobe 整段解不出
            // （W1-A3 对照跑发现，reports/issues/W1A3-g4-keyer-spill-breaks-pattern-id.md）。换成调色板里没有红分量的两色：深绿（9）、蓝绿（15）；
            // 7 号黄绿（6）/ 8 号天蓝（7）本来就不受影响。抠像负载不变，只是 ID 块换了颜色；基线不受影响。
            if case .synthetic(var s) = inputs[i].source, s.patternID == nil {
                switch inputs[i].number {
                case 5: s.patternID = 9
                case 6: s.patternID = 15
                default: break
                }
                inputs[i].source = .synthetic(settings: s)
            }
        }
        inputs.append(InputConfig(number: stingerInput, name: "Stinger PNG（带 alpha）", source: .image(path: stingerFileName)))
        var overlays = Array(repeating: OverlayState(), count: MixerState.overlayCount)
        overlays[0] = OverlayState(input: 5, on: false, rect: NormalizedRect(x: 0.02, y: 0.70, width: 0.28, height: 0.28),
                                   animation: OverlayAnimation(kind: .fade, durationTicks: 15))
        overlays[1] = OverlayState(input: 6, on: false, rect: NormalizedRect(x: 0.70, y: 0.70, width: 0.28, height: 0.28),
                                   animation: OverlayAnimation(kind: .slide, durationTicks: 20))
        overlays[2] = OverlayState(input: 7, on: false, rect: NormalizedRect(x: 0.02, y: 0.36, width: 0.24, height: 0.26),
                                   animation: OverlayAnimation(kind: .zoom, durationTicks: 20))
        overlays[3] = OverlayState(input: 8, on: false, rect: NormalizedRect(x: 0.74, y: 0.36, width: 0.24, height: 0.26),
                                   animation: OverlayAnimation(kind: .cut, durationTicks: 0))
        let transition = TransitionState(type: .fade, durationTicks: 30,
                                         wipe: WipeParams(direction: .leftToRight, softness: 0.1),
                                         stinger: StingerParams(input: stingerInput, cutAtTick: stingerCutAtTick))
        let mixer = MixerSettings(format: .hd1080p60, program: 1, preview: 2, transition: transition, ftb: FadeToBlack(), overlays: overlays)
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: ".", fileNamePattern: "{show}-{date}-{time}")))
        let multiview = OutputState(number: 2, kind: .multiview, name: "多画面（自定义布局）", enabled: true,
                                    settings: OutputSettings(source: .multiview, multiview: multiviewLayout(inputNumbers: (1...8).map { $0 })))
        return Show(name: "g4", inputs: inputs, mixer: mixer, audio: AudioState(), outputs: [record, multiview])
    }

    /// 自定义多画面布局（提案 010 的正式字段）：上半 PVW / PGM，下半 4×2 输入格，安全框 + 电平表占位。
    /// 格子几何与 P3 之前写 `extra["layout"]` 时逐字相同（`MultiviewLayoutTable` 两条解析路径同一套钳位）。
    static func multiviewLayout(inputNumbers: [Int]) -> MultiviewLayoutSettings {
        let m = 0.005
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect {
            NormalizedRect(x: x, y: y, width: w, height: h)
        }
        var cells: [MultiviewCell] = [
            MultiviewCell(source: .preview, rect: rect(m, m, 0.5 - 1.5 * m, 0.5 - 1.5 * m)),
            MultiviewCell(source: .program, rect: rect(0.5 + 0.5 * m, m, 0.5 - 1.5 * m, 0.5 - 1.5 * m)),
        ]
        let columns = 4, rows = 2
        let cellW = (1 - Double(columns + 1) * m) / Double(columns)
        let cellH = (0.5 - Double(rows + 1) * m) / Double(rows)
        for (i, n) in inputNumbers.prefix(columns * rows).enumerated() {
            let col = i % columns, row = i / columns
            cells.append(MultiviewCell(source: .input(number: n),
                                       rect: rect(m + Double(col) * (cellW + m), 0.5 + m + Double(row) * (cellH + m), cellW, cellH)))
        }
        return MultiviewLayoutSettings(custom: cells, safeArea: true, meters: true)
    }

    /// 时间线（60 fps 拍数）：前 2 分钟与 G3 相同（1000 Cut、3000 Fade 30、3600–3780 T-bar），120 s 起每 5 s 一次转场按 `rotation` 轮流，
    /// 切完把 PVW 推到下一路（Cut 后 1 拍、其它后 d + 1 拍）；122.5 s 起每 15 s 翻一路叠加的开关（1 → 2 → 3 → 4 循环）。
    /// C 系列客户端从 150 s 起在 x.7 s 相位插自己的 cut（gate4.sh 给 --c1-phase 0.7），非 Cut 转场在 x.4 s 已经结束。
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
        var k = 0
        let d = transitionTicks
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
            tick += ticksPer5s
            k += 1
        }
        var on = [false, false, false, false]
        var overlayTick = Int((122.5 * fps).rounded())
        let ticksPer15s = Int((15 * fps).rounded())
        var channel = 0
        while overlayTick < duration {
            on[channel].toggle()
            add(overlayTick, .overlay(channel: channel + 1, on: on[channel], input: nil))
            channel = (channel + 1) % 4
            overlayTick += ticksPer15s
        }
        // 同一拍的两个事件（setTransition 在 t − 1、autoTransition 在 t）不会同拍；sorted 不稳定所以按 (tick, 序号) 排
        let indexed = events.enumerated().sorted { a, b in
            a.element.tick.rawValue != b.element.tick.rawValue ? a.element.tick.rawValue < b.element.tick.rawValue : a.offset < b.offset
        }
        return Scenario(durationTicks: duration, events: indexed.map(\.element))
    }

    /// 非 Cut 转场的中间拍 [t + 1, t + d]（frameprobe 判不出输入身份的帧；gate4.sh 也能从场景 JSON 自己算，这里给 make-scenario 打印用）。
    static func compositeWindows(_ scenario: Scenario, fromTick: Int = 7200) -> [ClosedRange<Int64>] {
        var windows: [ClosedRange<Int64>] = []
        var pendingDuration: Int?
        for e in scenario.events where e.tick.rawValue >= Int64(fromTick) {
            switch e.command {
            case .fade(let d): windows.append((e.tick.rawValue + 1)...(e.tick.rawValue + Int64(d)))
            case .setTransition(_, let d): pendingDuration = d
            case .autoTransition:
                if let d = pendingDuration { windows.append((e.tick.rawValue + 1)...(e.tick.rawValue + Int64(d))) }
                pendingDuration = nil
            default: break
            }
        }
        return windows
    }

    /// Stinger 用的 PNG：预乘 BGRA，透明底；下 20% 一条深蓝半透明横幅（带一道亮色斜线），左右两侧 22%–78% 高度各一根半透明立柱。
    /// 不碰顶部 20%（帧号 / 时间戳 / ID 块 / 闪光块）和中心采样区（x、y 各 37.5%–62.5%）。
    static func writeStingerImage(to url: URL, width: Int = 1920, height: Int = 1080) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CLIError("建不出 CGContext") }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // CoreGraphics 原点在左下：图像顶部 = y 接近 h
        let band = CGRect(x: 0, y: 0, width: w, height: 0.20 * h)                       // 图像下 20%
        ctx.setFillColor(CGColor(red: 0.10, green: 0.14, blue: 0.45, alpha: 0.85))
        ctx.fill(band)
        ctx.setFillColor(CGColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 0.95))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0.05 * w, y: 0.02 * h))
        ctx.addLine(to: CGPoint(x: 0.09 * w, y: 0.02 * h))
        ctx.addLine(to: CGPoint(x: 0.34 * w, y: 0.18 * h))
        ctx.addLine(to: CGPoint(x: 0.30 * w, y: 0.18 * h))
        ctx.closePath()
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.10, green: 0.14, blue: 0.45, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: 0.22 * h, width: 0.30 * w, height: 0.56 * h))           // 左立柱：图像 22%–78% 高度
        ctx.fill(CGRect(x: 0.70 * w, y: 0.22 * h, width: 0.30 * w, height: 0.56 * h))    // 右立柱
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.fill(CGRect(x: 0.14 * w, y: 0.22 * h, width: 0.006 * w, height: 0.56 * h))
        ctx.fill(CGRect(x: 0.854 * w, y: 0.22 * h, width: 0.006 * w, height: 0.56 * h))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CLIError("写不出 \(url.path)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError("PNG 写入失败：\(url.path)") }
    }

    /// NDI 回环 L1 的节目（gate4-ndi.sh）：1 号 60 fps 灰 128 噪声 +音频 作 PGM，2 号是 NDI 输入、名字给 `--ndi-send` 的发送端
    /// （不含 "(" 的名字由 headless 在本机发现列表里按后缀 " (名字)" 解析），放在 PVW 上让引擎每拍挑它的帧。
    static func ndiLoopShow(senderName: String, width: Int = 1920, height: Int = 1080) -> Show {
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: width, height: height,
                                               background: .noise(level: 128, amplitude: noiseAmplitude, seed: 1), patternID: nil,
                                               jitterMs: 0, dropEveryN: 0, clockDriftPpm: 0, audio: true, audioDriftPpm: 0)
        let inputs = [
            InputConfig(number: 1, name: "合成 1 · 60 灰 128±\(noiseAmplitude) +音频", source: .synthetic(settings: settings)),
            InputConfig(number: 2, name: "NDI 回环（\(senderName)）", source: .ndi(sourceName: senderName)),
        ]
        let mixer = MixerSettings(format: .hd1080p60, program: 1, preview: 2,
                                  transition: TransitionState(type: .fade, durationTicks: 30), ftb: FadeToBlack(),
                                  overlays: Array(repeating: OverlayState(), count: MixerState.overlayCount))
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: true,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: ".", fileNamePattern: "{show}-{date}-{time}")))
        return Show(name: "g4-ndi", inputs: inputs, mixer: mixer, audio: AudioState(), outputs: [record])
    }
}
