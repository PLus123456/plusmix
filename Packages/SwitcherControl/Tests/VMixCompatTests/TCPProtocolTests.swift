import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherControl
@testable import VMixCompat

/// TCP 文本协议（默认 8099）：FUNCTION / TALLY / XML / ACTS / SUBSCRIBE / PING / VERSION / QUIT。测试 ID：C5。
final class TCPProtocolTests: XCTestCase {

    func testC5_tcp_greetingPingVersionTallyXMLAndQuit() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let c = try LineClient(port: f.tcpPort)
        let greeting = try XCTUnwrap(try c.readLine())
        XCTAssertEqual(greeting, "VERSION OK \(f.server.configuration.reportedVersion)", "连上先报版本")
        try c.send("PING")
        XCTAssertEqual(try c.readLine(), "PING OK PONG")
        try c.send("VERSION")
        XCTAssertEqual(try c.readLine(), "VERSION OK \(f.server.configuration.reportedVersion)")
        try c.send("TALLY")
        XCTAssertEqual(try c.readLine(), "TALLY OK 1200")
        try c.send("XML")
        let (n, body) = try readXML(c)
        XCTAssertEqual(n, body.utf8.count + 2)
        let doc = try StatusDocument(body)
        XCTAssertEqual(doc.rootName, StatusXML.rootElement)
        XCTAssertEqual(try doc.text("/*/active"), "1")
        XCTAssertEqual(try doc.text("/*/preview"), "2")
        // 两条命令一个包里到达（粘包）
        try c.sendRaw("PING\r\nTALLY\r\n")
        XCTAssertEqual(try c.readLine(), "PING OK PONG")
        XCTAssertEqual(try c.readLine(), "TALLY OK 1200")
        // 只用 \n 结尾也认
        try c.sendRaw("PING\n")
        XCTAssertEqual(try c.readLine(), "PING OK PONG")
        // 不认识的命令
        try c.send("BOGUS 1 2")
        XCTAssertEqual(try c.readLine(), "BOGUS ER UnknownCommand: BOGUS")
        try c.send("XMLTEXT foo/bar")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("XMLTEXT ER NotImplemented"))
        try c.send("QUIT")
        XCTAssertEqual(try c.readLine(), "QUIT OK Bye")
        XCTAssertTrue(try c.waitForClose(), "QUIT 后服务端关连接")
        XCTAssertEqual(f.server.counters.tcpConnectionsAccepted, 1)
    }

    func testC5_tcp_functionsChangeStateAndReportErrors() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let c = try LineClient(port: f.tcpPort)
        _ = try c.readLine()
        try c.send("FUNCTION Cut")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK Cut")
        var state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
        XCTAssertEqual(state.preview, 1)
        try c.send("FUNCTION PreviewInput Input=3")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK PreviewInput")
        state = await f.stateMachine.state
        XCTAssertEqual(state.preview, 3)
        try c.send("FUNCTION PreviewInput Input=3")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK PreviewInput (no change)", "reducer 忽略 → 仍 OK，但说明没变化")
        try c.send("FUNCTION OverlayInput1 Input=4")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK OverlayInput1")
        state = await f.stateMachine.state
        XCTAssertEqual(state.overlays[0].input, 4)
        XCTAssertTrue(state.overlays[0].on)
        try c.send("FUNCTION StartRecording")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK StartRecording")
        try c.send("FUNCTION StartStreaming")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK StartStreaming")
        state = await f.stateMachine.state
        XCTAssertTrue(state.outputs[0].enabled)
        XCTAssertTrue(state.outputs[1].enabled)
        try c.send("FUNCTION SetMasterVolume Value=50")
        XCTAssertEqual(try c.readLine(), "FUNCTION OK SetMasterVolume")
        state = await f.stateMachine.state
        XCTAssertEqual(state.audio.buses[0].gainDb, 80 * log10(0.5), accuracy: 1e-9)
        // 错误：明确的码和文案，不静默
        try c.send("FUNCTION Merge")
        let notImpl = try XCTUnwrap(try c.readLine())
        XCTAssertTrue(notImpl.hasPrefix("FUNCTION ER NotImplemented: "), notImpl)
        XCTAssertTrue(notImpl.contains("Merge"))
        try c.send("FUNCTION Nope")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("FUNCTION ER UnknownFunction: "))
        try c.send("FUNCTION PreviewInput Input=9")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("FUNCTION ER InputNotFound: "))
        try c.send("FUNCTION SetFader Value=999")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("FUNCTION ER BadParameter: "))
        try c.send("FUNCTION")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("FUNCTION ER BadParameter: "))
        // 走总线的命令都记了来源
        XCTAssertEqual(f.bus.counters.applied, 7)
        XCTAssertEqual(f.bus.counters.rejected, 0, "翻译层已经挡掉了结构性非法")
        XCTAssertTrue(f.bus.recentEntries().allSatisfy { $0.source == .api })
        XCTAssertEqual(f.server.counters.functions, 11)
        XCTAssertEqual(f.server.counters.functionErrors, 5)
    }

    func testC5_tcp_subscribeTallyPushesOnChange() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let c = try LineClient(port: f.tcpPort)
        _ = try c.readLine()
        try c.send("SUBSCRIBE TALLY")
        XCTAssertEqual(try c.readLine(), "SUBSCRIBE OK TALLY")
        XCTAssertEqual(try c.readLine(), "TALLY OK 1200", "订阅后立刻给一份当前值")
        _ = try await f.bus.submit(.cut, source: .ui)
        XCTAssertEqual(try c.readLine(), "TALLY OK 2100")
        // 与 tally 无关的变化不推
        _ = try await f.bus.submit(.renameInput(input: 3, name: "x"), source: .ui)
        _ = try await f.bus.submit(.audioGain(input: 3, dB: -3), source: .ui)
        XCTAssertNil(try c.readLine(timeout: 0.3), "不该有 TALLY 推送")
        _ = try await f.bus.submit(.setPreview(input: 3), source: .ui)
        XCTAssertEqual(try c.readLine(), "TALLY OK 0120", "PGM 2、PVW 3")
        // 转场中：PVW 也算 PGM（C3 口径）
        await f.stateMachine.schedule(.fade(durationTicks: 30), at: Tick(10))
        await f.stateMachine.prepare(upTo: Tick(20))
        XCTAssertEqual(try c.readLine(), "TALLY OK 0110")
        await f.stateMachine.prepare(upTo: Tick(40))
        XCTAssertEqual(try c.readLine(), "TALLY OK 0210", "转场完成：对调，PGM 3、PVW 2")
        try c.send("UNSUBSCRIBE TALLY")
        XCTAssertEqual(try c.readLine(), "UNSUBSCRIBE OK TALLY")
        _ = try await f.bus.submit(.cut, source: .ui)
        XCTAssertNil(try c.readLine(timeout: 0.3), "退订后不推")
        try c.send("SUBSCRIBE FOO")
        XCTAssertEqual(try c.readLine(), "SUBSCRIBE ER BadParameter: unknown event FOO (TALLY | ACTS)")
        XCTAssertGreaterThanOrEqual(f.server.counters.tallyEvents, 4)
    }

    func testC5_tcp_subscribeActsEventsAndQueries() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let c = try LineClient(port: f.tcpPort)
        _ = try c.readLine()
        try c.send("SUBSCRIBE ACTS")
        XCTAssertEqual(try c.readLine(), "SUBSCRIBE OK ACTS")
        _ = try await f.bus.submit(.cut, source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK Input 1 0")
        XCTAssertEqual(try c.readLine(), "ACTS OK Input 2 1")
        XCTAssertEqual(try c.readLine(), "ACTS OK InputPreview 2 0")
        XCTAssertEqual(try c.readLine(), "ACTS OK InputPreview 1 1")
        _ = try await f.bus.submit(.startRecord(output: 1), source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK Recording 1")
        _ = try await f.bus.submit(.startStream(output: 2), source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK Streaming 1")
        _ = try await f.bus.submit(.ftb(on: true), source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK FadeToBlack 1")
        _ = try await f.bus.submit(.mute(input: 3, on: true), source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK InputAudio 3 0")
        _ = try await f.bus.submit(.busGain(bus: .master, dB: -6.0206), source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK MasterVolume 0.5")
        _ = try await f.bus.submit(.overlay(channel: 2, on: true, input: 4), source: .ui)
        XCTAssertEqual(try c.readLine(), "ACTS OK Overlay2 4 1")
        _ = try await f.bus.submit(.renameInput(input: 3, name: "x"), source: .ui)
        XCTAssertNil(try c.readLine(timeout: 0.3), "改名没有激活器事件")
        // 查询（Companion 连上时会问一串 BusXSolo）
        try c.send("ACTS Input")
        XCTAssertEqual(try c.readLine(), "ACTS OK Input 2 1")
        try c.send("ACTS Input 3")
        XCTAssertEqual(try c.readLine(), "ACTS OK Input 3 0")
        try c.send("ACTS InputPreview")
        XCTAssertEqual(try c.readLine(), "ACTS OK InputPreview 1 1")
        try c.send("ACTS Recording")
        XCTAssertEqual(try c.readLine(), "ACTS OK Recording 1")
        try c.send("ACTS BusASolo")
        XCTAssertEqual(try c.readLine(), "ACTS OK BusASolo 0")
        try c.send("ACTS Overlay2")
        XCTAssertEqual(try c.readLine(), "ACTS OK Overlay2 4 1")
        try c.send("ACTS InputAudio 3")
        XCTAssertEqual(try c.readLine(), "ACTS OK InputAudio 3 0")
        try c.send("ACTS InputAudio")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("ACTS ER BadParameter"))
        try c.send("ACTS Nope")
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("ACTS ER UnknownActivator"))
        try c.send("UNSUBSCRIBE ACTS")
        XCTAssertEqual(try c.readLine(), "UNSUBSCRIBE OK ACTS")
        _ = try await f.bus.submit(.cut, source: .ui)
        XCTAssertNil(try c.readLine(timeout: 0.3))
        XCTAssertGreaterThanOrEqual(f.server.counters.actsEvents, 10)
    }

    func testC5_tcp_threeConnectionsLikeCompanion() async throws {
        // Companion 开三条连接：命令 / 激活器订阅 / 每 250 ms 轮询 XML；互不干扰
        let f = try await CompatFixture.start(ticking: true)
        defer { Task { await f.stop() } }
        let functions = try LineClient(port: f.tcpPort)
        let activators = try LineClient(port: f.tcpPort)
        let xml = try LineClient(port: f.tcpPort)
        for c in [functions, activators, xml] { XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("VERSION OK")) }
        try activators.send("SUBSCRIBE ACTS")
        XCTAssertEqual(try activators.readLine(), "SUBSCRIBE OK ACTS")
        try functions.send("FUNCTION Fade Duration=200")
        XCTAssertEqual(try functions.readLine(), "FUNCTION OK Fade")
        // 转场进行中 XML 仍能轮询，完成后对调
        var sawSwap = false
        for _ in 0..<40 {
            try xml.send("XML")
            let (_, body) = try readXML(xml)
            let doc = try StatusDocument(body)
            if try doc.text("/*/active") == "2" { sawSwap = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawSwap, "200 ms 的 Fade 应在 2 s 内完成")
        XCTAssertEqual(try activators.readLine(), "ACTS OK Input 1 0")
        XCTAssertEqual(try activators.readLine(), "ACTS OK Input 2 1")
        XCTAssertEqual(try activators.readLine(), "ACTS OK InputPreview 2 0", "转场完成对调：PVW 也变了")
        XCTAssertEqual(try activators.readLine(), "ACTS OK InputPreview 1 1")
        try functions.send("PING")
        XCTAssertEqual(try functions.readLine(), "PING OK PONG")
        try activators.send("PING")
        XCTAssertEqual(try activators.readLine(), "PING OK PONG")
        XCTAssertEqual(f.server.counters.tcpConnectionsAccepted, 3)
        functions.closeNow()
        activators.closeNow()
        xml.closeNow()
        let allClosed = await waitUntil { f.server.counters.tcpConnectionsOpen == 0 }
        XCTAssertTrue(allClosed, "客户端断开后连接计数归零")
    }

    func testC5_disabledLayerListensOnNoPort() async throws {
        let tcpPort = freeLocalPort()
        let httpPort = freeLocalPort()
        let sm = StateMachine(initialState: TestStates.base())
        sm.start()
        defer { sm.stop() }
        let bus = CommandBus(stateMachine: sm)
        let feed = StateFeed(stateMachine: sm) { nil }
        await feed.start()
        defer { Task { await feed.stop() } }
        var config = VMixCompatConfiguration()
        XCTAssertFalse(config.enabled, "默认关")
        config.host = "127.0.0.1"
        config.tcpPort = tcpPort
        config.httpPort = httpPort
        let server = VMixCompatServer(bus: bus, feed: feed, configuration: config)
        try await server.start()
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.boundTCPPort)
        XCTAssertNil(server.boundHTTPPort)
        XCTAssertThrowsError(try LineClient(port: tcpPort), "关着时端口不监听")
        XCTAssertThrowsError(try LineClient(port: httpPort))
        await server.stop()
        // 打开后监听；只开 TCP 也行
        config.enabled = true
        config.httpEnabled = false
        let on = VMixCompatServer(bus: bus, feed: feed, configuration: config)
        try await on.start()
        XCTAssertTrue(on.isRunning)
        XCTAssertEqual(on.boundTCPPort, tcpPort)
        XCTAssertNil(on.boundHTTPPort)
        let c = try LineClient(port: tcpPort)
        XCTAssertTrue(try XCTUnwrap(try c.readLine()).hasPrefix("VERSION OK"))
        XCTAssertThrowsError(try LineClient(port: httpPort))
        await on.stop()
        XCTAssertFalse(on.isRunning)
        XCTAssertNil(on.boundTCPPort)
        let released = await waitUntil { (try? LineClient(port: tcpPort)) == nil }
        XCTAssertTrue(released, "stop 之后端口释放")
    }
}
