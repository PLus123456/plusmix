// frameprobe —— 分析输出文件里的帧号 / 闪光 / click（测试标准 §2.3）。逻辑全在 SwitcherTestKit.FrameProbe，这里只解析参数。
//
// 用法：
//   frameprobe frames   <file|dir> [--limit N]
//   frameprobe stats    <file|dir> [--fps 60] [--input-fps 0=30,1=60] [--max-events N]        V4 / V5
//   frameprobe switches <file|dir> [--start-tick N] [--gray-tolerance 6] [--fps N]             V6（拍号按 pts，漏帧单独列）
//   frameprobe fade     <file|dir> [--gray-a 64 --gray-b 192] [--duration D] [--fade-at S] [--fade-tolerance 2] [--fps N]   V7
//   frameprobe wipe     <file|dir> --at S --duration D [--wipe-direction leftToRight]                            V7
//   frameprobe zoom     <file|dir> --at S --duration D                                                           V7
//   frameprobe av       <file> [<file2> ...] [--fps 60] [--start-tick N] [--aac-priming auto|0|N] [--discontinuities]   A2 / A3（多文件 = A4）、A1 第三项
//   frameprobe synth    --out x.mov [--seconds 20] [--width 1920 --height 1080] [--fps 60|59.94|30] [--bitrate 2000000]
//                       [--audio aac|pcm|none] [--noise N] [--software] [--no-events] [--cut T] [--fade T:D]
//                       [--wipe T:D:dir[:softness]] [--zoom T:D] [--raw-dir DIR --raw-frames N]
// 通用：--size WxH（目录输入）、--markdown、--out PATH（把 JSON 写到文件）、--version
import Foundation
import SwitcherContracts
import SwitcherTestKit

@main
struct FrameprobeCLI {
    static let usage = """
    frameprobe \(SwitcherVersion.current)
    用法：frameprobe <frames|stats|switches|fade|wipe|zoom|av|synth> [选项] <文件或目录…>
      frames    每帧 {index, frameNumber, inputID, genTimeMs, flash, gray}      [--limit N]
      stats     每输入重复 / 丢弃序列与比例（V4）、总帧数 vs 时长 × 帧率（V5）   [--fps N] [--input-fps id=fps,…] [--max-events N]
      switches  输入 ID 变化的帧、Cut 前后有无混合帧（V6）                       [--start-tick N] [--gray-tolerance N] [--fps N]
      fade      Fade 逐帧混合比例与线性曲线的最大偏差帧数（V7）                   [--gray-a N --gray-b N] [--duration D] [--fade-at S] [--fade-tolerance N] [--fps N]
                switches / fade 的拍号 = --start-tick + round((pts − 第一帧 pts) × fps)，文件里漏的帧单独列（missingFrames），不挪后面的转场落点；
                fps 只认 --fps，没给按相邻帧 pts 差估（容器的标称帧率是"样本数 / 时长"，漏了帧就偏低，不用它）
      wipe      Wipe 逐帧擦边位置（软边取 50% 点）与线性曲线的偏差帧数（V7）       --at S --duration D [--wipe-direction leftToRight|rightToLeft|topToBottom|bottomToTop|diagonal]
      zoom      Zoom 逐帧新画面宽度（中心行带）与线性曲线的偏差帧数（V7）          --at S --duration D
                wipe / zoom 的拍号 = --start-tick + round(pts × fps)，窗口里漏的帧单独列；fps 不给时用容器标称帧率，漏了帧的文件要给 --fps
      av        闪光帧 ↔ 最近 click 的时间差（A2、A3；按整秒拍配对判，全部配对另报）；多个文件比较同一事件（A4：click 以第一个文件 / PGM 配上的为锚，
                闪光落在半秒的事件只列不判）
                [--start-tick N] 文件第一帧的节目拍，默认 0。开录起点已按节目输出时间线（G8b），开着 Master 效果录的文件也从第 0 拍起，默认 0 就对；
                                 只在录制中途改了 Master 效果（L 变了：之后的拍号整体错开 ΔL，给了也只对改了之后那段有效）时才要给。
                                 文件本来就不从第 0 拍起（推流落盘从关键帧起录、soak 切段）照旧给第一帧的拍号
                [--aac-priming auto|0|N] 音轨 priming：auto = 有编辑列表信 AVFoundation、没有按 ffmpeg 口径加回；0 = 不加回；N = 加回 N 样本
                [--discontinuities] 顺带做波形不连续检测（A1 第三项：跳变 > 0.5 满幅、click ±1 ms 排除） [--click-margin-ms 1]
      synth     生成合成源样例 .mov（VideoToolbox H.264）或原始 NV12 帧目录       --out x.mov [--seconds 20] [--width W --height H] [--fps 60] [--bitrate B] [--audio aac|pcm|none] [--noise N] [--software] [--no-events] [--cut T] [--fade T:D] [--wipe T:D:dir[:softness]] [--zoom T:D] [--raw-dir DIR --raw-frames N]
    通用：--size WxH（原始 NV12 目录的尺寸，默认 1920x1080）  --markdown（人读表）  --out PATH（JSON 写到文件）  --version
          --blank-ticks a-b,c-d,…（这些拍的帧当作解不出：转场中间帧没有单一输入身份，G4 的 gate4.sh 从场景文件算出来；tick = --start-tick + 序号）
          --no-self-check（关掉自证解码，回到只按契约解码的老口径）  --id-tolerance 12  --rhythm-tolerance-ms 3  --self-check-gray-tolerance 5
    """

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, !["-h", "--help"].contains(command) else {
            print(usage)
            exit(args.isEmpty ? 0 : 2)
        }
        if command == "--version" || command == "-v" {
            print("frameprobe \(SwitcherVersion.current)")
            return
        }
        do {
            var parsed = try Parsed(Array(args.dropFirst()))
            switch command {
            case "frames", "stats", "switches", "fade", "wipe", "zoom", "av":
                try await analyze(command, &parsed)
            case "synth":
                try await synth(&parsed)
            default:
                throw CLIError("不认识的子命令：\(command)\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write("frameprobe: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    struct CLIError: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }

    /// 极简参数表：--key value / --flag / 位置参数。
    struct Parsed {
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        static let flagNames: Set<String> = ["markdown", "software", "no-events", "help", "discontinuities", "no-self-check"]

        init(_ args: [String]) throws {
            var i = 0
            while i < args.count {
                let a = args[i]
                if a.hasPrefix("--") {
                    let name = String(a.dropFirst(2))
                    if Parsed.flagNames.contains(name) {
                        flags.insert(name)
                    } else {
                        guard i + 1 < args.count else { throw CLIError("--\(name) 缺参数") }
                        options[name] = args[i + 1]
                        i += 1
                    }
                } else {
                    positional.append(a)
                }
                i += 1
            }
        }

        func int(_ k: String) throws -> Int? {
            guard let v = options[k] else { return nil }
            guard let n = Int(v) else { throw CLIError("--\(k) 要整数，给的是 \(v)") }
            return n
        }
        func double(_ k: String) throws -> Double? {
            guard let v = options[k] else { return nil }
            guard let n = Double(v) else { throw CLIError("--\(k) 要数字，给的是 \(v)") }
            return n
        }
    }

    static func probeOptions(_ p: Parsed) throws -> FrameProbe.Options {
        var o = FrameProbe.Options()
        o.fps = try p.double("fps")
        if let s = p.options["input-fps"] {
            for pair in s.split(separator: ",") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2, let id = Int(kv[0]), let fps = Double(kv[1]) else { throw CLIError("--input-fps 形如 0=30,1=60") }
                o.inputFps[id] = fps
            }
        }
        if let v = try p.int("start-tick") { o.startTick = Int64(v) }
        if let v = try p.double("gray-a") { o.grayA = v }
        if let v = try p.double("gray-b") { o.grayB = v }
        if let v = try p.double("gray-tolerance") { o.grayTolerance = v }
        if let v = try p.double("fade-tolerance") { o.fadeTolerance = v }
        o.fadeDuration = try p.int("duration")
        o.transitionDuration = try p.int("duration")
        if let v = try p.int("fade-at") { o.fadeAt = Int64(v) }
        if let v = try p.int("at") { o.transitionAt = Int64(v) }
        if let v = p.options["wipe-direction"] {
            guard let d = WipeDirection(rawValue: v) else { throw CLIError("--wipe-direction 只认 leftToRight / rightToLeft / topToBottom / bottomToTop / diagonal，给的是 \(v)") }
            o.wipeDirection = d
        }
        o.selfCheck.enabled = !p.flags.contains("no-self-check")
        if let v = try p.double("id-tolerance") { o.selfCheck.idDistance = v }
        if let v = try p.double("rhythm-tolerance-ms") { o.selfCheck.rhythmToleranceMs = v }
        if let v = try p.double("self-check-gray-tolerance") { o.selfCheck.grayTolerance = v }
        if let v = try p.int("max-events") { o.maxEvents = v }
        o.limit = try p.int("limit")
        if let v = p.options["aac-priming"] {
            guard let m = PrimingMode(v) else { throw CLIError("--aac-priming 只认 auto / 0 / N（样本数），给的是 \(v)") }
            o.aacPriming = m
        }
        o.discontinuities = p.flags.contains("discontinuities")
        if let v = try p.double("click-margin-ms") { o.discontinuityMarginMs = v }
        if let s = p.options["blank-ticks"], !s.isEmpty {
            for part in s.split(separator: ",") {
                let ab = part.split(separator: "-")
                guard ab.count == 2, let a = Int64(ab[0]), let b = Int64(ab[1]), a <= b else { throw CLIError("--blank-ticks 形如 7201-7224,7501-7524（拍号闭区间，逗号分隔）") }
                o.blankTicks.append(a...b)
            }
        }
        if let s = p.options["size"] {
            let wh = s.lowercased().split(separator: "x")
            guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { throw CLIError("--size 形如 1920x1080") }
            o.rawWidth = w
            o.rawHeight = h
        }
        return o
    }

    static func emit<T: Encodable>(_ report: T, markdown: String, _ p: Parsed) throws {
        let json = try ProbeJSON.string(report)
        if let out = p.options["out"] {
            try json.write(toFile: out, atomically: true, encoding: .utf8)
            if p.flags.contains("markdown") { print(markdown) } else { print("JSON 已写到 \(out)") }
        } else if p.flags.contains("markdown") {
            print(markdown)
        } else {
            print(json)
        }
    }

    static func analyze(_ command: String, _ p: inout Parsed) async throws {
        guard !p.positional.isEmpty else { throw CLIError("要一个文件或目录\n\(usage)") }
        let options = try probeOptions(p)
        let urls = p.positional.map { URL(fileURLWithPath: $0) }
        for u in urls where !FileManager.default.fileExists(atPath: u.path) { throw CLIError("找不到 \(u.path)") }
        switch command {
        case "frames":
            let r = try await FrameProbe.frames(urls[0], options: options)
            try emit(r, markdown: FrameProbe.markdown(r), p)
        case "stats":
            let r = try await FrameProbe.stats(urls[0], options: options)
            try emit(r, markdown: FrameProbe.markdown(r), p)
        case "switches":
            let r = try await FrameProbe.switches(urls[0], options: options)
            try emit(r, markdown: FrameProbe.markdown(r), p)
        case "fade":
            let r = try await FrameProbe.fade(urls[0], options: options)
            try emit(r, markdown: FrameProbe.markdown(r), p)
        case "wipe", "zoom":
            guard options.transitionAt != nil, let d = options.transitionDuration, d >= 2 else {
                throw CLIError("\(command) 要 --at S（发命令的拍）和 --duration D（≥ 2 拍）")
            }
            let r = command == "wipe" ? try await FrameProbe.wipe(urls[0], options: options) : try await FrameProbe.zoom(urls[0], options: options)
            try emit(r, markdown: FrameProbe.markdown(r), p)
        case "av":
            if urls.count == 1 {
                let r = try await FrameProbe.av(urls[0], options: options)
                try emit(r, markdown: FrameProbe.markdown(r), p)
            } else {
                let r = try await FrameProbe.avMulti(urls, options: options)
                try emit(r, markdown: FrameProbe.markdown(r), p)
            }
        default:
            break
        }
    }

    static func synth(_ p: inout Parsed) async throws {
        var spec = SampleMovieWriter.Spec()
        if let v = try p.double("seconds") { spec.seconds = v }
        if let v = try p.int("width") { spec.width = v }
        if let v = try p.int("height") { spec.height = v }
        if let v = try p.double("fps") {
            switch v {
            case 60: spec.frameRate = .fps60
            case 30: spec.frameRate = .fps30
            case 59.94: spec.frameRate = .fps5994
            case 29.97: spec.frameRate = .fps2997
            default: throw CLIError("--fps 只认 60 / 59.94 / 30 / 29.97")
            }
        }
        if let v = try p.int("bitrate") { spec.bitrate = v }
        if let v = try p.int("noise") { spec.noise = v }
        spec.softwareEncoder = p.flags.contains("software")
        switch p.options["audio"] ?? "aac" {
        case "aac": spec.audio = .aac(bitrate: 128_000)
        case "pcm": spec.audio = .pcm16
        case "none": spec.audio = .none
        default: throw CLIError("--audio 只认 aac / pcm / none")
        }
        spec.sourceA.frameRate = spec.frameRate
        spec.sourceB.frameRate = spec.frameRate == .fps60 ? .fps30 : spec.frameRate
        spec.sourceA.width = spec.width; spec.sourceA.height = spec.height
        spec.sourceB.width = spec.width; spec.sourceB.height = spec.height
        if p.flags.contains("no-events") { spec.events = [] }
        if let cut = try p.int("cut") { spec.events = [.cut(tick: cut)] + spec.events.filter { if case .cut = $0 { false } else { true } } }
        if let s = p.options["fade"] {
            let parts = s.split(separator: ":")
            guard parts.count == 2, let t = Int(parts[0]), let d = Int(parts[1]) else { throw CLIError("--fade 形如 700:30") }
            spec.events = spec.events.filter { if case .fade = $0 { false } else { true } } + [.fade(tick: t, durationTicks: d)]
        }
        if let s = p.options["wipe"] {
            // T:D:方向[:软边]
            let parts = s.split(separator: ":")
            guard parts.count >= 3, let t = Int(parts[0]), let d = Int(parts[1]), let dir = WipeDirection(rawValue: String(parts[2])) else {
                throw CLIError("--wipe 形如 700:24:leftToRight 或 700:24:topToBottom:0.1")
            }
            let softness = parts.count > 3 ? Double(parts[3]) ?? 0 : 0
            spec.events = spec.events.filter { if case .wipe = $0 { false } else { true } } + [.wipe(tick: t, durationTicks: d, direction: dir, softness: softness)]
        }
        if let s = p.options["zoom"] {
            let parts = s.split(separator: ":")
            guard parts.count == 2, let t = Int(parts[0]), let d = Int(parts[1]) else { throw CLIError("--zoom 形如 700:24") }
            spec.events = spec.events.filter { if case .zoom = $0 { false } else { true } } + [.zoom(tick: t, durationTicks: d)]
        }
        if let raw = p.options["raw-dir"] {
            let n = try p.int("raw-frames") ?? 60
            try SampleMovieWriter.writeRawFrames(spec: spec, to: URL(fileURLWithPath: raw), frames: n)
            print("已写 \(n) 帧 NV12 到 \(raw)（\(spec.width)×\(spec.height)）")
            return
        }
        guard let out = p.options["out"] else { throw CLIError("synth 要 --out x.mov 或 --raw-dir DIR") }
        let url = URL(fileURLWithPath: out)
        let report = try await SampleMovieWriter.write(spec: spec, to: url) { n in
            FileHandle.standardError.write("  \(n) 帧\r".data(using: .utf8)!)
        }
        print("已写 \(url.path)：\(report.frames) 帧 \(spec.width)×\(spec.height) @ \(spec.frameRate)，目标 \(spec.bitrate / 1000) kbps → 实际 \(Int(report.averageKbps)) kbps，文件 \(report.fileBytes) 字节，音频 \(report.audioSamples) 样本，编码 \(String(format: "%.2f", report.encodeSeconds)) s")
    }
}
