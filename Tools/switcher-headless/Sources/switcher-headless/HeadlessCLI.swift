import AppKit
import Foundation
import SwitcherContracts
import SwitcherRender

/// 子命令分发。run 子命令构造 `HeadlessSession`（同步部分），装 Ctrl-C，起 Task 跑引擎，然后主线程进 run loop（--preview 时是 NSApp 的）。
enum HeadlessCLI {
    static let usage = """
    用法：
      switcher-headless [run] --show show.json --script scenario.json --duration 600 --stats stats.jsonl [--record out.mov]
                        [--preview] [--audio-device null|default|<设备名>] [--lead-ms 1000] [--input-lead-ms 8.33] [--stop-timeout 60] [--no-gpu-stats]
      switcher-headless make-show --out scenarios/m0-show.json [--width 1920 --height 1080]
      switcher-headless make-scenario --out scenarios/m0.json [--minutes 60] [--fps 60] [--inputs 8]
      switcher-headless summarize --stats stats.jsonl [--baseline baselines/m0-m5max.json] [--write-baseline out.json]
                        [--v1-avg-ms 2] [--json] [--meta key=value]…
    --duration 是秒；场景文件更短时以场景为准。--audio-device 默认 default（系统默认输出设备，会出声），gate 用 null。
    --input-lead-ms：合成源第 k 帧的 pts = 拍点 − 提前量（默认半个节目帧），模拟真设备帧先于拍点到达；音频 click 不带提前量。
    Ctrl-C：停时钟 → 渲染器排空 → 录制封口 → 退出；再按一次立即退出。
    """

    /// 带值的参数；其余 -- 开头的都是开关。
    static let valueKeys: Set<String> = [
        "show", "script", "duration", "stats", "record", "audio-device", "lead-ms", "input-lead-ms", "stop-timeout",
        "out", "width", "height", "minutes", "fps", "inputs", "baseline", "write-baseline", "v1-avg-ms", "meta",
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
                                 inputLeadMs: try p.double("input-lead-ms"), stopTimeoutSeconds: try p.double("stop-timeout") ?? 60)
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

    // MARK: make-show / make-scenario

    static func makeShow(_ p: ParsedArguments) throws {
        guard let out = p.url("out") else { throw CLIError("make-show 需要 --out <路径>") }
        let show = M0Factory.show(width: try p.int("width") ?? 1920, height: try p.int("height") ?? 1080)
        try show.save().write(to: out, options: .atomic)
        print("写入 \(out.path)：\(show.inputs.count) 路输入，\(show.mixer.format.width)×\(show.mixer.format.height)@\(show.mixer.format.frameRate)")
    }

    static func makeScenario(_ p: ParsedArguments) throws {
        guard let out = p.url("out") else { throw CLIError("make-scenario 需要 --out <路径>") }
        let scenario = M0Factory.scenario(minutes: try p.int("minutes") ?? 60, fps: try p.double("fps") ?? 60, inputs: try p.int("inputs") ?? 8)
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
