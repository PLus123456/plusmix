import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// C5 的自动化版本：scripts/apitest/c5-companion.py 模拟 Companion 的请求序列（三条 TCP 连接 + 六项）对着进程内的兼容层跑；
/// 以及给人手动配 Companion 用的常驻模式。
final class C5CompanionScriptTests: XCTestCase {
    /// 仓库根（Packages/SwitcherControl/Tests/VMixCompatTests/ 往上四级）。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func python3() -> String? {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func testC5_companionRequestSequence_scriptPassesAllSixItems() async throws {
        guard let python = Self.python3() else { throw XCTSkip("BLOCKED-环境：没有 python3") }
        let script = Self.repoRoot.appending(path: "scripts/apitest/c5-companion.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("找不到 \(script.path)") }
        let f = try await CompatFixture.start(ticking: true)
        defer { Task { await f.stop() } }
        let out = FileManager.default.temporaryDirectory.appending(path: "c5-\(UUID().uuidString).json")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path, "--host", "127.0.0.1", "--tcp-port", "\(f.tcpPort)", "--http-port", "\(f.server.boundHTTPPort!)",
                       "--json", out.path, "--poll-ms", "100"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, "脚本退出码 \(p.terminationStatus)：\n\(text)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any], text)
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        let names = items.map { $0["name"] as? String ?? "" }
        for expected in ["Cut", "Fade", "Overlay 1", "Record", "Stream", "Tally"] {
            XCTAssertTrue(names.contains { $0.hasPrefix(expected) }, "六项里缺 \(expected)：\(names)")
        }
        XCTAssertTrue(items.allSatisfy { ($0["passed"] as? Bool) == true }, text)
        XCTAssertEqual(json["passed"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(f.server.counters.tcpConnectionsAccepted, 3, "脚本像 Companion 一样开三条连接")
        XCTAssertGreaterThan(f.server.counters.xmlServed, 5, "XML 轮询在跑")
        try? FileManager.default.removeItem(at: out)
    }

    /// 人工 C5：`SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter C5CompanionScriptTests/testC5_manual`
    /// 在 8099 / 8088（可用 SWITCHER_COMPAT_TCP_PORT / SWITCHER_COMPAT_HTTP_PORT 改）挂一个带拍推进的兼容层，Companion 连 127.0.0.1 点按钮。
    func testC5_manualCompanionSession_servesWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let secondsText = env["SWITCHER_COMPAT_SERVE_SECONDS"], let seconds = Double(secondsText), seconds > 0 else {
            throw XCTSkip("人工 C5 用：设 SWITCHER_COMPAT_SERVE_SECONDS=<秒> 才常驻")
        }
        let f = try await CompatFixture.start(state: TestStates.base(inputs: 8), ticking: true) {
            $0.host = env["SWITCHER_COMPAT_HOST"] ?? "0.0.0.0"
            $0.tcpPort = Int(env["SWITCHER_COMPAT_TCP_PORT"] ?? "") ?? VMixCompatConfiguration.defaultTCPPort
            $0.httpPort = Int(env["SWITCHER_COMPAT_HTTP_PORT"] ?? "") ?? VMixCompatConfiguration.defaultHTTPPort
            if env["SWITCHER_COMPAT_LOG"] == "trace" { $0.logLevel = .trace }
        }
        print("兼容层常驻 \(Int(seconds)) s：TCP \(f.server.boundTCPPort ?? -1)，HTTP \(f.server.boundHTTPPort ?? -1)（8 路输入，PGM 1 / PVW 2）")
        let deadline = Date().addingTimeInterval(seconds)
        var lastSequence: UInt64 = 0
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            let snap = f.stateMachine.publisher.latest
            if let snap, snap.sequence != lastSequence {
                lastSequence = snap.sequence
                print("  seq \(snap.sequence)  PGM \(snap.state.program)  PVW \(snap.state.preview)  overlay1 \(snap.state.overlays[0].on ? "on" : "off")  rec \(snap.state.outputs[0].enabled)  stream \(snap.state.outputs[1].enabled)  ftb \(snap.state.ftb.on)")
            }
        }
        print("命令 \(f.server.counters.functions) 条（\(f.server.counters.functionErrors) 条出错），XML \(f.server.counters.xmlServed) 次，TALLY 事件 \(f.server.counters.tallyEvents)，ACTS 事件 \(f.server.counters.actsEvents)")
        await f.stop()
    }
}
