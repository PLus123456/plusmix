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
        resetMainWindowUI()   // W5-A：打开节目会按 Show.layout 收起调音台 / 搬主窗口，每条用例从同样的界面开始
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

// MARK: - W3-E：无障碍树遍历、本地化扫描

extension AppTest {
    /// 需要 label 的角色（按钮类、输入类）。
    static let labeledRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .textField, .comboBox, .incrementor, .textArea,
        .colorWell, .disclosureTriangle, .link, .radioGroup,
    ]

    /// 沿 NSAccessibility 树走一遍，返回缺 label / title 的控件（"角色 @ 路径"）。
    /// "有 label"按辅助功能的实际口径：自己的 label / title，或 titleUIElement（AppKit 表单里控件左边那个标签），或（cell 型控件）所属 NSControl 的 label / title。
    /// 只查 AppKit 那一层：NSHostingView 不把 SwiftUI 自己的辅助功能元素暴露给进程内遍历（新式 accessibilityChildren() 和老式 AXChildren 属性都只给
    /// 底下的 AppKit 视图；AXUIElement 对本进程返回 kAXErrorNotImplemented，探针见 reports/w3-app2.md §5），SwiftUI 控件的 label 由源码扫描
    /// （swiftUIControlLabelViolations）保证。宿主视图里只查我们自己放进去的 NSViewRepresentable（竖推子 NSSlider）。滚动条的箭头不算。
    static func accessibilityViolations(in root: Any) -> [String] {
        var out: [String] = []
        walkAccessibility(root, path: "", depth: 0) { element, role, path in
            guard labeledRoles.contains(role), !path.contains("AXScrollBar(") else { return }
            if path.contains("NSHostingView<"), !isOwnRepresentable(element) { return }
            if !hasAccessibleName(element) { out.append("\(role.rawValue) @ \(path) | \(legacyAttributes(element))") }
        }
        return out
    }

    /// 宿主视图里由我们自己的 NSViewRepresentable 建的 AppKit 控件（VerticalFader 的 NSSlider）。
    static func isOwnRepresentable(_ element: Any) -> Bool {
        if let cell = element as? NSSliderCell { return type(of: cell) == NSSliderCell.self }
        if let slider = element as? NSSlider { return type(of: slider) == NSSlider.self }
        return false
    }

    /// 老式属性 API 看到的东西（SwiftUI 桥接的控件有些只实现这一套）。
    static func legacyAttributes(_ element: Any) -> String {
        guard let obj = element as? NSObject else { return "-" }
        func attr(_ a: NSAccessibility.Attribute) -> String {
            let v = obj.accessibilityAttributeValue(a)
            if let s = v as? String { return s }
            if let v { return "<\(type(of: v))>" }
            return "nil"
        }
        return "desc=\(attr(.description)) title=\(attr(.title)) titleUI=\(attr(.titleUIElement)) help=\(attr(.help)) value=\(attr(.value).prefix(20))"
    }

    static func hasAccessibleName(_ node: Any) -> Bool {
        func nonEmpty(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if let element = node as? any NSAccessibilityProtocol, nonEmpty(element.accessibilityLabel()) || nonEmpty(element.accessibilityTitle()) { return true }
        if let obj = node as? NSObject {
            if nonEmpty(obj.accessibilityAttributeValue(.description) as? String) || nonEmpty(obj.accessibilityAttributeValue(.title) as? String) { return true }
            if let titleElement = obj.accessibilityAttributeValue(.titleUIElement) as? NSObject,
               nonEmpty(titleElement.accessibilityAttributeValue(.value) as? String) || nonEmpty(titleElement.accessibilityAttributeValue(.title) as? String) {
                return true
            }
        }
        if let element = node as? any NSAccessibilityProtocol, let titleElement = element.accessibilityTitleUIElement() as? any NSAccessibilityProtocol,
           nonEmpty(titleElement.accessibilityValue() as? String) || nonEmpty(titleElement.accessibilityTitle()) || nonEmpty(titleElement.accessibilityLabel()) {
            return true
        }
        if let cell = node as? NSCell, let control = cell.controlView as? any NSAccessibilityProtocol {
            if nonEmpty(control.accessibilityLabel()) || nonEmpty(control.accessibilityTitle()) { return true }
            if let titleElement = control.accessibilityTitleUIElement() as? any NSAccessibilityProtocol,
               nonEmpty(titleElement.accessibilityValue() as? String) || nonEmpty(titleElement.accessibilityTitle()) { return true }
        }
        return false
    }

    /// 整棵树的文字（排错用）。
    static func accessibilityDump(_ root: Any) -> String {
        var lines: [String] = []
        walkAccessibility(root, path: "", depth: 0, visitAll: true) { element, role, path in
            lines.append("\(role.rawValue) \(legacyAttributes(element)) @ \(path.suffix(90))")
        }
        return lines.joined(separator: "\n")
    }

    /// 遍历到的（需要 label 的角色的、会被检查的）控件数。
    static func accessibilityControlCount(in root: Any) -> Int {
        var n = 0
        walkAccessibility(root, path: "", depth: 0) { element, role, path in
            guard labeledRoles.contains(role), !path.contains("AXScrollBar(") else { return }
            if path.contains("NSHostingView<"), !isOwnRepresentable(element) { return }
            n += 1
        }
        return n
    }

    /// 子元素：先走老式属性 API（SwiftUI 的宿主视图只在这一套上返回它自己的元素），再走新式 accessibilityChildren()，都没有就看子视图。
    static func axChildren(_ node: Any) -> [Any] {
        if let obj = node as? NSObject, let kids = obj.accessibilityAttributeValue(.children) as? [Any], !kids.isEmpty { return kids }
        if let e = node as? any NSAccessibilityProtocol, let kids = e.accessibilityChildren(), !kids.isEmpty { return kids }
        if let v = node as? NSView { return v.subviews }
        return []
    }

    static func axString(_ node: Any, _ attribute: NSAccessibility.Attribute) -> String? {
        (node as? NSObject)?.accessibilityAttributeValue(attribute) as? String
    }

    static func axRole(_ node: Any) -> NSAccessibility.Role {
        if let r = axString(node, .role) { return NSAccessibility.Role(rawValue: r) }
        if let e = node as? any NSAccessibilityProtocol, let r = e.accessibilityRole() { return r }
        return NSAccessibility.Role(rawValue: "?")
    }

    private static func walkAccessibility(_ node: Any, path: String, depth: Int, visitAll: Bool = false,
                                          visit: (Any, NSAccessibility.Role, String) -> Void) {
        guard depth < 80 else { return }
        let role = axRole(node)
        let name = axString(node, .description) ?? axString(node, .title) ?? String(describing: type(of: node))
        let here = path.isEmpty ? "\(role.rawValue)(\(name))" : "\(path) > \(role.rawValue)(\(name))"
        let ignored: Bool
        if let e = node as? any NSAccessibilityProtocol {
            ignored = !e.isAccessibilityElement()
        } else if let obj = node as? NSObject, obj.responds(to: Selector(("accessibilityIsIgnored"))) {
            ignored = obj.accessibilityIsIgnored()
        } else {
            ignored = false
        }
        if !ignored || visitAll { visit(node, role, here) }
        for child in axChildren(node) { walkAccessibility(child, path: here, depth: depth + 1, visitAll: visitAll, visit: visit) }
    }

    /// 格式串里的占位符（%d、%@、%.1f、%2$@ …）按顺序。
    static func formatSpecifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[-+ 0#]*\d*(\.\d+)?(ld|lld|d|u|f|s|@|%)"#)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.filter { $0 != "%%" }
    }

    /// 目录下所有 .swift 文件。
    static func swiftFiles(in directory: URL) throws -> [URL] {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in e where url.pathExtension == "swift" { files.append(url) }
        return files.sorted { $0.path < $1.path }
    }

    /// 源码里 L("键") / L10n.string("键" 的键。
    static func localizationKeysUsed(in directory: URL) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\b(?:L|L10n\.string|L10n\.format)\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in try swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                // 动态拼的键（"addInput.kind.\(kind.rawValue)"）不算：它们的展开值在表里（LocalizationTests 打印"没直接引用的键"时人工看）
                if let r = Range(m.range(at: 1), in: text), !text[r].contains("\\(") { keys.insert(String(text[r])) }
            }
        }
        return keys
    }

    /// 写死在字符串字面量里的中文（CJK）文案；注释、日志 / 断言行、带 `// l10n-exempt` 标记的行不算。
    /// 标记在整行（剥行尾注释之前）找——W3-E4 之前是剥完注释再找，标记又总写在行尾注释里，所以从来不起作用（reports/w3-outputs-4.md §5 第 6 条）。
    static func chineseLiteralViolations(in directory: URL) throws -> [String] {
        let cjk = try NSRegularExpression(pattern: #"[一-鿿　-〿！-～]"#)
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        let exempt = ["NSLog(", "print(", "preconditionFailure(", "fatalError(", "assertionFailure(", "os_log", "Logger("]
        var out: [String] = []
        for file in try swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            var inBlockString = false
            for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
                if rawLine.contains("\"\"\"") { inBlockString.toggle(); continue }
                if inBlockString { continue }
                if rawLine.contains("l10n-exempt") { continue }   // 显式豁免：整行看，剥注释之前
                let line = stripLineComment(rawLine)
                if exempt.contains(where: { line.contains($0) }) { continue }
                for m in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let r = Range(m.range, in: line) else { continue }
                    let s = String(line[r])
                    if cjk.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                        out.append("\(file.lastPathComponent):\(i + 1) \(s)")
                    }
                }
            }
        }
        return out
    }

    /// 去掉行尾 // 注释（引号外的 //）。
    static func stripLineComment(_ line: String) -> String {
        var inString = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == "\"" && previous != "\\" { inString.toggle() }
            if !inString && c == "/" && line.index(after: index) < line.endIndex && line[line.index(after: index)] == "/" {
                return String(line[..<index])
            }
            previous = c
            index = line.index(after: index)
        }
        return line
    }
}

// MARK: - W3-E：SwiftUI 控件的 label 静态扫描（源码层面：每个控件构造都带 label 文案或 accessibilityLabel）

extension AppTest {
    /// App/Sources 里 SwiftUI 控件构造缺 label 的地方（"文件:行 片段"）。规则：
    /// - Slider / Stepper：同一语句（本行或下两行）要有 `{ Text(`（label 闭包）或 `.accessibilityLabel(`；
    /// - TextField / SecureField / Picker / Toggle / ColorPicker / DatePicker：第一个参数是 `L(`（本地化文案）或非空字面量；
    /// - Button：`Button(L(…` / `Button(<表达式含 L(> ) {` 形式，或 `.accessibilityLabel(`；`Button {`（无标题）不行；
    /// - NSViewRepresentable 的 makeNSView：要调 setAccessibilityLabel。
    static func swiftUIControlLabelViolations(in directory: URL) throws -> [String] {
        var out: [String] = []
        let labeledFirstArg = ["TextField(", "SecureField(", "Picker(", "Toggle(", "ColorPicker(", "DatePicker("]
        for file in try swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("import SwiftUI") else { continue }
            let lines = text.components(separatedBy: "\n")
            /// 控件名前面不能是标识符字符或点（排除 resolutionPicker( / NSSlider( 之类）。
            func controlRange(_ ctrl: String, in line: String) -> Range<String.Index>? {
                var search = line.startIndex
                while let r = line.range(of: ctrl, range: search..<line.endIndex) {
                    if r.lowerBound == line.startIndex { return r }
                    let before = line[line.index(before: r.lowerBound)]
                    if !(before.isLetter || before.isNumber || before == "_" || before == ".") { return r }
                    search = r.upperBound
                }
                return nil
            }
            for (i, raw) in lines.enumerated() {
                let line = stripLineComment(raw)
                let window = lines[i..<min(i + 3, lines.count)].map { stripLineComment($0).trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                func report(_ what: String) { out.append("\(file.lastPathComponent):\(i + 1) \(what)：\(line.trimmingCharacters(in: .whitespaces).prefix(90))") }
                for ctrl in ["Slider(", "Stepper("] where controlRange(ctrl, in: line) != nil {
                    if !(window.contains("{ Text(") || window.contains(".accessibilityLabel(")) { report(ctrl + " 没有 label 闭包") }
                }
                for ctrl in labeledFirstArg {
                    guard let r = controlRange(ctrl, in: line) else { continue }
                    let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    // 文案：L(…)、非空字面量，或按约定叫 label 的变量（值来自 L(…)）
                    let ok = rest.hasPrefix("L(") || (rest.hasPrefix("\"") && !rest.hasPrefix("\"\"")) || rest.hasPrefix("label,") || rest.hasPrefix("label)")
                    if !ok && !window.contains(".accessibilityLabel(") { report(ctrl + " 第一个参数不是文案") }
                }
                if let r = controlRange("Button(", in: line) ?? controlRange("Button {", in: line) {
                    let head = line[r.lowerBound...]
                    let titled = head.contains("Button(L(") || (head.hasPrefix("Button(") && head.contains("L(")) || window.contains(".accessibilityLabel(")
                    if !titled { report("Button 没有标题文案") }
                }
                if line.contains("func makeNSView(") {
                    let body = lines[i..<min(i + 25, lines.count)].joined(separator: "\n")
                    if !body.contains("setAccessibilityLabel(") { report("makeNSView 没有 setAccessibilityLabel") }
                }
            }
        }
        return out
    }
}
