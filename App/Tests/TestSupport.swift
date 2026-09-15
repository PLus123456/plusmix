// App 测试的公共工具：真的跑事件循环（display link、遮挡状态、sheet 都靠它）、等条件、合成按键、拿到 AppDelegate / session。
import AppKit
import XCTest
import SwitcherContracts
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

    /// 合成源配置（灰底、1080p、不带音频）。
    static func syntheticConfig(number: Int, frameRate: FrameRate = .fps60, gray: UInt8 = 96) -> InputConfig {
        InputConfig(number: number, name: "合成 \(number)",
                    source: .synthetic(settings: SyntheticSourceSettings(frameRate: frameRate, width: 1920, height: 1080,
                                                                        background: .gray(level: gray), audio: false)))
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
