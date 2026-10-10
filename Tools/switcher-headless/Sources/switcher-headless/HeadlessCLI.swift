import AppKit
import Foundation
import SwitcherContracts
import SwitcherControl
import SwitcherRender
import SwitcherAudioIntegration
import VMixCompat

/// 子命令分发。run 子命令构造 `HeadlessSession`（同步部分），装 Ctrl-C，起 Task 跑引擎，然后主线程进 run loop（--preview 时是 NSApp 的）。
enum HeadlessCLI {
    static let usage = """
    用法：
      switcher-headless [run] --show show.json --script scenario.json --duration 600 --stats stats.jsonl [--record out.mov]
                        [--preview] [--audio-device null|default|<设备名>] [--lead-ms 1000] [--input-lead-ms 8.33] [--stop-timeout 60] [--no-gpu-stats]
                        [--api] [--api-listen 127.0.0.1:8765] [--api-token <token>] [--iso-audio N]
                        [--compat] [--compat-listen 127.0.0.1] [--compat-tcp-port 8099] [--compat-http-port 8088] [--tally-port N]
                        [--ndi-send <名字>] [--ndi-jitter-frames 1] [--stream <rtmp/srt 地址>]… [--av-compensation videoDelay|audioPTS]
      switcher-headless make-show --out scenarios/m0-show.json [--width 1920 --height 1080] [--preset m0|g3|g4|g4-ndi|soak|perf-e4] [--ndi-name <名字>]
                        [--camera auto|none|<uniqueID>] [--file <片段路径>]
      switcher-headless make-scenario --out scenarios/m0.json [--minutes 60] [--fps 60] [--inputs 8] [--preset m0|g3|g4|soak]
      switcher-headless summarize --stats stats.jsonl [--baseline baselines/m0-m5max.json] [--write-baseline out.json]
                        [--v1-avg-ms 2] [--json] [--meta key=value]…
    --duration 是秒；场景文件更短时以场景为准。--audio-device 默认 default（系统默认输出设备，会出声），gate 用 null。
    --input-lead-ms：合成源第 k 帧的 pts = 拍点 − 提前量（默认半个节目帧），模拟真设备帧先于拍点到达；音频 click 不带提前量。
    --api：起本地 HTTP + WebSocket API（W2-C；默认 127.0.0.1:8765，--api-listen 改地址 / 端口，--api-token 开鉴权）；每秒一行 Stats 同时推给 API。
    --iso-audio N：另起 N 个录制器（PGM 视频 + 前 N 路带音频输入各自的 ISO 音轨，A4 用），文件名 <record 去扩展名>.iso<编号>.mov。
    --preset g3：G3 检查点的节目 / 场景（scenarios/g3-show.json、g3.json；第 1000 拍 Cut、第 3000 拍 Fade 30、T-bar 25/50/75、之后每 5 s 切一次、每 30 s 开关 Overlay 1）。
    --preset g4：G4 检查点（scenarios/g4-show.json + g4-stinger.png、g4.json；前 2 分钟同 g3，之后每 5 s 按 Cut / Fade / Wipe / Zoom / Stinger 轮流、每 15 s 翻一路叠加；
                5–8 号开抠像、多画面自定义布局）。--preset g4-ndi：NDI 回环 L1 的两路节目（2 号 = NDI 输入，名字给 --ndi-name，默认 "Switcher G4 loop"）。
    --compat：起 W3-D 的第三方 API 兼容层（默认关；TCP 8099 / HTTP 8088，只听 --compat-listen 的地址）；--tally-port N：起 tally 流（WS /tally、GET /tally）。
    --ndi-send <名字>：把 PGM（+ Master 音频）用 W2-D 的 NDISender 发出去；节目里 ndi 输入的名字不含 "(" 时按本机发送端解析（NDI 回环）。
    --stream <地址>（W4-A，可给多次）：每个地址一路 W2-D 的 StreamOutput（PGM + Master 音频，HaishinKit 连接）；第 i 个对节目里第 i 个推流输出
                （编号进 Stats.encoder[].output、编码参数取它的，没有就按默认）。Stats.encoder[] 的顺序：录制、ISO 音轨、NDI 发送、推流。
    节目里的摄像头 / 文件输入（W4-A）：摄像头只接画面（不开麦克风：长稳里不采环境声、也不弹麦克风授权）；文件路径相对节目文件所在目录，声音进混音器（路由按节目）。
    --preset soak（W4-A 长稳）：G4 节目 + 10 号摄像头（--camera auto = 内置那台，none = 不要）+ 11 号文件（--file，循环）；1 录制、2 多画面、3 / 4 推流、5 NDI；
                场景每 30 s 一次转场（Cut / Fade / Wipe / Zoom / Stinger 轮流），每 5 min 翻一路叠加，PGM 只轮 1–8 号（A2 / A3 的闪光配对）。
    --preset perf-e4（W4-A L5 的 E4）：只有一路文件输入（--file）在 PGM 上，录制；片段放完停在末帧。
    --av-compensation（W1-B4，提案 028）：总线效果（压缩 / 限幅的前瞻）让声音晚 L 时补在哪一侧。videoDelay（默认）= 画面也晚 L（引擎按拍点 + L 派发、
                音频 PTS 不前移，监听与画面同步，PGM 多 L 延迟）；audioPTS = W5-C 的做法（音频 PTS 前移 L，画面不动，监听晚 L），留作对照。
                场景 / 节目不带效果时两者结果相同（L = 0）。
    Ctrl-C：停时钟 → 渲染器排空 → 录制封口 → 退出；再按一次立即退出。
    """

    /// 带值的参数；其余 -- 开头的都是开关。
    static let valueKeys: Set<String> = [
        "show", "script", "duration", "stats", "record", "audio-device", "lead-ms", "input-lead-ms", "stop-timeout",
        "out", "width", "height", "minutes", "fps", "inputs", "baseline", "write-baseline", "v1-avg-ms", "meta",
        "api-listen", "api-token", "iso-audio", "preset",
        "compat-listen", "compat-tcp-port", "compat-http-port", "tally-port", "ndi-send", "ndi-jitter-frames", "ndi-name",
        "stream", "camera", "file", "av-compensation",
    ]

    static func dispatch(_ args: [String]) throws {
        var rest = args
        var command = "run"
        if let first = rest.first, !first.hasPrefix("--") {
            command = first
            rest.removeFirst()
        }
        let p = ParsedArguments(rest, valueKeys: valueKeys)
        switch command {
        case "run": try runCommand(p)
        case "make-show": try makeShow(p)
        case "make-scenario": try makeScenario(p)
        case "summarize": try Summarize.run(p)
        case "help", "-h", "--help": print(usage)
        default: throw CLIError("不认识的子命令：\(command)\n\(usage)")
        }
    }

    // MARK: run

    static func runCommand(_ p: ParsedArguments) throws {
        guard let showURL = p.url("show") else { throw CLIError("run 需要 --show <节目文件>\n\(usage)") }
        guard let duration = try p.double("duration"), duration > 0 else { throw CLIError("run 需要 --duration <秒>（> 0）") }
        let options = RunOptions(showURL: showURL, scriptURL: p.url("script"), durationSeconds: duration,
                                 statsURL: p.url("stats"), recordURL: p.url("record"), preview: p.has("preview"),
                                 audioDevice: p.string("audio-device") ?? "default",
                                 leadMs: try p.double("lead-ms") ?? 1000, gpuStats: !p.has("no-gpu-stats"),
                                 inputLeadMs: try p.double("input-lead-ms"), stopTimeoutSeconds: try p.double("stop-timeout") ?? 60,
                                 api: try apiOptions(p), isoAudio: try p.int("iso-audio") ?? 0,
                                 compat: try compatOptions(p), tallyPort: try p.int("tally-port"),
                                 ndiSend: p.string("ndi-send"), ndiJitterFrames: try p.int("ndi-jitter-frames") ?? 1,
                                 streamURLs: p.repeated["stream"] ?? [], avCompensation: try avCompensation(p))
        guard (0...2).contains(options.ndiJitterFrames) else { throw CLIError("--ndi-jitter-frames 只能是 0–2") }
        let session = try HeadlessSession(options: options)
        SignalHandling.install(session)
        if options.preview {
            MainActor.assumeIsolated { PreviewSetup.open(source: session.renderer) }
        }
        Task.detached(priority: .userInitiated) {
            var code: Int32 = 0
            do {
                try await session.run()
                code = session.exitCode
            } catch {
                FileHandle.standardError.write(Data("switcher-headless: \(error)\n".utf8))
                code = 1
            }
            exit(code)
        }
        if options.preview {
            MainActor.assumeIsolated { NSApplication.shared.run() }
        } else {
            dispatchMain()
        }
    }

    /// --av-compensation videoDelay|audioPTS（W1-B4）：没给 = videoDelay。
    static func avCompensation(_ p: ParsedArguments) throws -> AVCompensation {
        guard let s = p.string("av-compensation") else { return .videoDelay }
        guard let mode = AVCompensation(rawValue: s) else { throw CLIError("--av-compensation 只能是 videoDelay / audioPTS，收到 \(s)") }
        return mode
    }

    /// --api / --api-listen / --api-token → 服务配置；没给 --api（也没给另外两个）就不起。
    static func apiOptions(_ p: ParsedArguments) throws -> APIServerConfiguration? {
        guard p.has("api") || p.has("api-listen") || p.has("api-token") else { return nil }
        var config = APIServerConfiguration()
        if let listen = p.string("api-listen") {
            guard let parsed = APIServerConfiguration.parseListen(listen) else { throw CLIError("--api-listen 要 host:port，收到 \(listen)") }
            config.host = parsed.host
            config.port = parsed.port
        }
        config.token = p.string("api-token")
        return config
    }

    /// --compat [--compat-listen host] [--compat-tcp-port N] [--compat-http-port N] → 兼容层配置；没给 --compat 就不起（W3-D：默认关）。
    static func compatOptions(_ p: ParsedArguments) throws -> VMixCompatConfiguration? {
        guard p.has("compat") else { return nil }
        var config = VMixCompatConfiguration()
        config.enabled = true
        if let host = p.string("compat-listen") { config.host = host }
        if let port = try p.int("compat-tcp-port") { config.tcpPort = port }
        if let port = try p.int("compat-http-port") { config.httpPort = port }
        return config
    }

    // MARK: make-show / make-scenario

    static func makeShow(_ p: ParsedArguments) throws {
        guard let out = p.url("out") else { throw CLIError("make-show 需要 --out <路径>") }
        let width = try p.int("width") ?? 1920, height = try p.int("height") ?? 1080
        let show: Show
        switch p.string("preset") ?? "m0" {
        case "m0": show = M0Factory.show(width: width, height: height)
        case "g3": show = G3Factory.show(width: width, height: height)
        case "g4":
            show = G4Factory.show(width: width, height: height)
            let png = out.deletingLastPathComponent().appendingPathComponent(G4Factory.stingerFileName)
            try G4Factory.writeStingerImage(to: png, width: width, height: height)
            print("写入 \(png.path)（Stinger 用的 alpha PNG，\(width)×\(height)）")
        case "g4-ndi": show = G4Factory.ndiLoopShow(senderName: p.string("ndi-name") ?? "Switcher G4 loop", width: width, height: height)
        case "soak":
            // G4 节目依赖旁边的 Stinger PNG（路径相对节目文件），一起写
            let png = out.deletingLastPathComponent().appendingPathComponent(G4Factory.stingerFileName)
            try G4Factory.writeStingerImage(to: png, width: width, height: height)
            let camera = try SoakFactory.resolveCamera(p.string("camera") ?? "auto")
            let file = p.string("file").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if let file, !FileManager.default.fileExists(atPath: file) { throw CLIError("--file \(file) 不存在（scripts/perf/make-e4-clip.sh 生成）") }
            show = SoakFactory.show(camera: camera, filePath: file, width: width, height: height)
            print("摄像头：\(camera.map { "\($0.name)（\($0.uniqueID)）" } ?? "不要")；文件：\(file ?? "不要")；写入 \(png.path)")
        case "perf-e4":
            guard let file = p.string("file").map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else {
                throw CLIError("--preset perf-e4 需要 --file <测试片段>（scripts/perf/make-e4-clip.sh 生成）")
            }
            guard FileManager.default.fileExists(atPath: file) else { throw CLIError("--file \(file) 不存在") }
            show = SoakFactory.perfE4Show(filePath: file, width: width, height: height)
        case let other: throw CLIError("不认识的 --preset \(other)（m0 / g3 / g4 / g4-ndi / soak / perf-e4）")
        }
        try show.save().write(to: out, options: .atomic)
        print("写入 \(out.path)：\(show.inputs.count) 路输入，\(show.mixer.format.width)×\(show.mixer.format.height)@\(show.mixer.format.frameRate)")
    }

    static func makeScenario(_ p: ParsedArguments) throws {
        guard let out = p.url("out") else { throw CLIError("make-scenario 需要 --out <路径>") }
        let scenario: Scenario
        switch p.string("preset") ?? "m0" {
        case "m0": scenario = M0Factory.scenario(minutes: try p.int("minutes") ?? 60, fps: try p.double("fps") ?? 60, inputs: try p.int("inputs") ?? 8)
        case "g3": scenario = G3Factory.scenario(minutes: try p.int("minutes") ?? 10, fps: try p.double("fps") ?? 60, inputs: try p.int("inputs") ?? 8)
        case "g4":
            scenario = G4Factory.scenario(minutes: try p.int("minutes") ?? 10, fps: try p.double("fps") ?? 60, inputs: try p.int("inputs") ?? 8)
            let windows = G4Factory.compositeWindows(scenario)
            print("非 Cut 转场的中间拍（frameprobe --blank-ticks）：\(windows.count) 段，共 \(windows.reduce(0) { $0 + Int($1.count) }) 拍，例如 \(windows.prefix(3).map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ","))")
        case "soak": scenario = SoakFactory.scenario(minutes: try p.int("minutes") ?? 480, fps: try p.double("fps") ?? 60, inputs: try p.int("inputs") ?? 8)
        case let other: throw CLIError("不认识的 --preset \(other)（m0 / g3 / g4 / soak）")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(scenario).write(to: out, options: .atomic)
        print("写入 \(out.path)：\(scenario.durationTicks) 拍，\(scenario.events.count) 个事件")
    }
}

/// --preview：主线程上开一个 PreviewWindow（1 / 2 / 3 切 PGM / PVW / 多画面）。窗口对象要活到进程结束。
@MainActor
enum PreviewSetup {
    static var window: PreviewWindow?

    static func open(source: any DisplayFrameSource) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = PreviewWindow(source: source, target: .program, title: "Switcher 预览 — program")
        w.show()
        app.activate(ignoringOtherApps: true)
        window = w
    }
}

/// Ctrl-C / SIGTERM：第一次请求干净停止（session 里的等待循环看到后走正常收尾），第二次立即退出。
enum SignalHandling {
    nonisolated(unsafe) static var sources: [any DispatchSourceSignal] = []

    static func install(_ session: HeadlessSession) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { session.requestStop(signal: sig) }
            src.resume()
            sources.append(src)
        }
    }
}
