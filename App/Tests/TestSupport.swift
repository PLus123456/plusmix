// App 测试的公共工具：真的跑事件循环（display link、遮挡状态、sheet 都靠它）、等条件、合成按键、拿到 AppDelegate / session、
// 读回 PGM 纹理并解测试图案、外部工具（ffprobe / frameprobe）、进程 RSS。
import AppKit
import Metal
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import Switcher

@MainActor
enum AppTest {
    /// 像真正的 App 一样跑事件循环一段时间。
    static func pump(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// 泵事件直到条件成立或超时；返回是否成立。
    @discardableResult
    static func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump(seconds: 0.01)
        }
        return condition()
    }

    static var delegate: AppDelegate {
        guard let d = NSApp.delegate as? AppDelegate else { preconditionFailure("main.swift 应把 AppDelegate 挂到 NSApplication 上") }
        return d
    }

    static var controller: AppController { delegate.controller }

    /// 等 App 起好一个跑着的 session（applicationDidFinishLaunching 里异步起引擎）。
    static func runningSession(timeout: Double = 15) throws -> SwitcherSession {
        NSApp.activate(ignoringOtherApps: true)
        guard waitUntil(timeout, { controller.session?.isRunning == true }) else {
            throw XCTSkip("引擎 \(timeout) s 内没起来：\(String(describing: controller.lastError))")
        }
        return controller.session!
    }

    /// 换一个空节目（每个测试从干净状态开始）。
    static func freshSession() throws -> SwitcherSession {
        _ = try runningSession()
        let done = expectationBox()
        Task { await controller.newShow(); done.value = true }
        guard waitUntil(15, { done.value && controller.session?.isRunning == true }) else { throw XCTSkip("新建节目没起来") }
        return controller.session!
    }

    final class Box { var value = false }
    static func expectationBox() -> Box { Box() }

    /// 合成源配置（灰底、1080p，默认不带音频）。
    static func syntheticConfig(number: Int, frameRate: FrameRate = .fps60, gray: UInt8 = 96, audio: Bool = false) -> InputConfig {
        InputConfig(number: number, name: "合成 \(number)",
                    source: .synthetic(settings: SyntheticSourceSettings(frameRate: frameRate, width: 1920, height: 1080,
                                                                        background: .gray(level: gray), audio: audio)))
    }

    /// 等某路进 live；返回最终的运行状态。
    @discardableResult
    static func waitLive(_ session: SwitcherSession, input number: Int, timeout: Double) -> InputState? {
        waitUntil(timeout) { session.inputs.runtimeState(of: number) == .live }
        return session.inputs.runtimeState(of: number)
    }

    /// 仓库根：从源文件路径往上找 CLAUDE.md。
    static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) { return url }
        }
        throw XCTSkip("找不到仓库根（CLAUDE.md）")
    }

    /// 读回最新的 PGM（或 PVW / 多画面）纹理：私有存储的纹理先 blit 到共享的暂存纹理再 getBytes（BGRA）。
    struct Readback {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let tick: Tick
        /// 读测试图案（帧号 / 时间戳 / 输入 ID / 闪光）。
        func decodePattern() -> TestPattern.Decoded {
            var copy = bytes
            return copy.withUnsafeMutableBytes { raw in
                TestPattern.decode(.bgra(base: raw.baseAddress!, bytesPerRow: width * 4), width: width, height: height)
            }
        }
        /// 某点的 (B, G, R)。
        func pixel(x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        /// 亮度统计（按 R+G+B 均值抽样，步长 step）。
        func lumaStats(step: Int = 8) -> (mean: Double, max: Int, distinct: Int) {
            var sum = 0.0, n = 0, mx = 0
            var seen = Set<Int>()
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let p = pixel(x: x, y: y)
                    let l = (p.r + p.g + p.b) / 3
                    sum += Double(l); n += 1; mx = max(mx, l)
                    seen.insert(l / 8)
                    x += step
                }
                y += step
            }
            return (n == 0 ? 0 : sum / Double(n), mx, seen.count)
        }
    }

    static func readback(_ session: SwitcherSession, target: DisplayTarget = .program) -> Readback? {
        guard let frame = session.displaySource.latestDisplayFrame(for: target) else { return nil }
        let texture = frame.texture
        let device = texture.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let staging = device.makeTexture(descriptor: d), let cb = session.displaySource.displayCommandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, to: staging)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            staging.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return Readback(bytes: bytes, width: texture.width, height: texture.height, tick: frame.tick)
    }

    /// 外部进程（ffprobe / frameprobe）。
    struct ProcessOutput { let stdout: Data; let stderr: String; let code: Int32 }
    static func run(_ path: String, _ args: [String]) throws -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessOutput(stdout: outData, stderr: String(decoding: errData, as: UTF8.self), code: p.terminationStatus)
    }

    static let ffprobePath = "/opt/homebrew/bin/ffprobe"
    static func requireFFprobe() throws {
        if !FileManager.default.isExecutableFile(atPath: ffprobePath) { throw XCTSkip("BLOCKED-工具：没有 \(ffprobePath)（brew install ffmpeg）") }
    }

    /// ffprobe 的流信息（codec_type / duration / nb_frames）；stderr 非空或退出码非 0 = 文件有错。
    struct ProbedStream { let type: String; let duration: Double; let frames: Int? }
    static func ffprobeStreams(_ url: URL) throws -> (streams: [ProbedStream], errors: String) {
        let o = try run(ffprobePath, ["-v", "error", "-print_format", "json", "-show_entries", "stream=codec_type,duration,nb_frames", url.path])
        let obj = (try? JSONSerialization.jsonObject(with: o.stdout) as? [String: Any]) ?? [:]
        let arr = obj["streams"] as? [[String: Any]] ?? []
        let streams = arr.map { s in
            ProbedStream(type: s["codec_type"] as? String ?? "?", duration: (s["duration"] as? String).flatMap(Double.init) ?? 0,
                         frames: (s["nb_frames"] as? String).flatMap(Int.init))
        }
        return (streams, o.stderr.trimmingCharacters(in: .whitespacesAndNewlines) + (o.code == 0 ? "" : " (exit \(o.code))"))
    }

    /// frameprobe（先 `swift build -c release --package-path Tools/frameprobe`）。
    static func frameprobe() throws -> URL {
        let root = try repoRoot()
        for c in ["release", "debug"] {
            let u = root.appendingPathComponent("Tools/frameprobe/.build/\(c)/frameprobe")
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        throw XCTSkip("BLOCKED-工具：没有编好的 frameprobe（swift build -c release --package-path Tools/frameprobe）")
    }

    /// 同步 HTTP（边泵事件边等；测试在主线程上）。
    struct HTTPResult {
        let status: Int
        let data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    }
    static func http(_ method: String, _ url: String, body: String? = nil, timeout: Double = 5) throws -> HTTPResult {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        final class Box: @unchecked Sendable { var result: HTTPResult?; var error: (any Error)? }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { box.error = error }
            box.result = HTTPResult(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data ?? Data())
        }.resume()
        guard waitUntil(timeout, { box.result != nil }) else { throw XCTSkip("HTTP \(method) \(url) \(timeout) s 没有应答") }
        if let e = box.error { throw e }
        return box.result!
    }

    /// 本进程 RSS（MB）。
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// 加 count 路合成源并等它们 live。
    static func addSynthetics(_ session: SwitcherSession, count: Int) throws {
        for n in 1...count { session.send(.addInput(config: syntheticConfig(number: n, gray: UInt8(64 + 32 * n)))) }
        guard waitUntil(10, { session.state.inputs.count == count && (1...count).allSatisfy { session.inputs.runtimeState(of: $0) == .live } }) else {
            throw XCTSkip("合成源没起来：\(session.state.inputs.map(\.number))，运行状态 \((1...count).map { session.inputs.runtimeState(of: $0) })")
        }
    }

    /// 往主窗口发一个按键（走 NSWindow.sendEvent → 响应链 → MainWindow.keyDown）。
    static func press(_ characters: String, keyCode: UInt16, shift: Bool = false) {
        guard let window = controller.windowController.window else { return }
        let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
        let chars = shift ? characters.uppercased() : characters
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(e)
        }
    }

    static let keyCodes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, " ": 49, "\r": 36, "f": 3]

    static func press(_ key: String, shift: Bool = false) {
        press(key, keyCode: keyCodes[key] ?? 0, shift: shift)
    }

    /// 把一个视图（AppKit 内容；CAMetalLayer 的画面不在里面）存成 PNG。整窗截图用 shell 的 screencapture -l<窗口号>。
    static func screenshot(_ view: NSView, to url: URL) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    /// 测试产物目录（不入库）。
    static var outputDirectory: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".build/app-test-output", isDirectory: true)
    }

    /// 打印视图树的 frame（调布局用）。
    static func dumpFrames(_ view: NSView, depth: Int = 0) {
        let name = String(describing: type(of: view))
        print(String(repeating: "  ", count: depth) + "\(name) \(view.frame) hidden=\(view.isHidden)")
        for sub in view.subviews { dumpFrames(sub, depth: depth + 1) }
    }
}


/// 一个 MediaMTX 实例（scripts/mediamtx.yml + 环境变量改端口和录制目录；抄 W2-D 的 StreamingTests/MediaMTXSupport）。
/// 端口用 23935 / 28893 / 29993，不碰用户手动起的 1935 和 W2-D 测试的 21935+。
@MainActor
final class MediaMTXHarness {
    static let binary = "/opt/homebrew/bin/mediamtx"
    static func requireAvailable() throws {
        if !FileManager.default.isExecutableFile(atPath: binary) { throw XCTSkip("BLOCKED-工具：没有 \(binary)（brew install mediamtx）") }
    }
    let rtmpPort: Int
    let apiPort: Int
    let recordDir: URL
    private let process = Process()

    init(rtmpPort: Int = 23935, srtPort: Int = 28893, apiPort: Int = 29993, recordDir: URL) throws {
        self.rtmpPort = rtmpPort
        self.apiPort = apiPort
        self.recordDir = recordDir
        try? FileManager.default.removeItem(at: recordDir)
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        let config = try AppTest.repoRoot().appendingPathComponent("scripts/mediamtx.yml")
        let logURL = recordDir.appendingPathComponent("mediamtx.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.executableURL = URL(fileURLWithPath: Self.binary)
        process.arguments = [config.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MTX_RTMPADDRESS": ":\(rtmpPort)", "MTX_SRTADDRESS": "0.0.0.0:\(srtPort)", "MTX_APIADDRESS": "127.0.0.1:\(apiPort)",
            "MTX_PATHDEFAULTS_RECORDPATH": recordDir.appendingPathComponent("%path/%Y-%m-%d_%H-%M-%S-%f").path,
        ]) { $1 }
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while Date() < deadline {
            if (try? AppTest.http("GET", "http://127.0.0.1:\(apiPort)/v3/paths/list", timeout: 1))?.status == 200 { ready = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !ready { stop(); throw XCTSkip("MediaMTX（RTMP \(rtmpPort)）10 s 内没起来，日志 \(logURL.path)") }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    func rtmpURL(_ path: String) -> String { "rtmp://127.0.0.1:\(rtmpPort)/\(path)" }

    /// 该 path 的录制文件（按名字排序 = 按时间）。
    func recordings(_ path: String) -> [URL] {
        let dir = recordDir.appendingPathComponent(path)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
