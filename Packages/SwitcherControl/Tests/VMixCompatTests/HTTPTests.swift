import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// HTTP GET /api/?Function=<name>&Input=<n> 与 GET /api 的 XML 状态。测试 ID：C5。
final class HTTPTests: XCTestCase {
    func get(_ base: URL, _ pathAndQuery: String) async throws -> (status: Int, contentType: String, body: String) {
        let url = URL(string: base.absoluteString + pathAndQuery)!
        let (data, resp) = try await URLSession.shared.data(from: url)
        let http = resp as! HTTPURLResponse
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", String(decoding: data, as: UTF8.self))
    }

    func testC5_http_xmlStatusAndFunctions() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        for path in ["/api", "/api/", "/API/", "/API"] {
            let r = try await get(f.httpBase, path)
            XCTAssertEqual(r.status, 200, path)
            XCTAssertTrue(r.contentType.hasPrefix("text/xml"), "\(path): \(r.contentType)")
            let doc = try StatusDocument(r.body)
            XCTAssertEqual(doc.rootName, StatusXML.rootElement)
            XCTAssertEqual(try doc.text("/*/active"), "1")
        }
        let cut = try await get(f.httpBase, "/api/?Function=Cut")
        XCTAssertEqual(cut.status, 200)
        XCTAssertEqual(cut.body, "OK Cut")
        var state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
        let pvw = try await get(f.httpBase, "/API/?Function=PreviewInput&Input=3")
        XCTAssertEqual(pvw.status, 200)
        state = await f.stateMachine.state
        XCTAssertEqual(state.preview, 3)
        let same = try await get(f.httpBase, "/api/?Function=PreviewInput&Input=3")
        XCTAssertEqual(same.status, 200)
        XCTAssertEqual(same.body, "OK PreviewInput (no change)")
        let lower = try await get(f.httpBase, "/api/?function=SetVolume&input=2&value=50")
        XCTAssertEqual(lower.status, 200, "参数名不分大小写")
        let name = try await get(f.httpBase, "/api/?Function=PreviewInput&Input=%E6%9C%BA%E4%BD%8D%204")
        XCTAssertEqual(name.status, 200, "按名字选输入")
        state = await f.stateMachine.state
        XCTAssertEqual(state.preview, 4)
        let overlay = try await get(f.httpBase, "/api/?Function=OverlayInput1&Input=2")
        XCTAssertEqual(overlay.status, 200)
        let xml = try await get(f.httpBase, "/api")
        let doc = try StatusDocument(xml.body)
        XCTAssertEqual(try doc.text("/*/overlays/overlay[@number='1']"), "2")
        XCTAssertEqual(try doc.text("/*/preview"), "4")
        // 错误：状态码 + 文案
        let notImpl = try await get(f.httpBase, "/api/?Function=Merge")
        XCTAssertEqual(notImpl.status, 501)
        XCTAssertTrue(notImpl.body.hasPrefix("NotImplemented: "), notImpl.body)
        let unknown = try await get(f.httpBase, "/api/?Function=Nope")
        XCTAssertEqual(unknown.status, 400)
        XCTAssertTrue(unknown.body.hasPrefix("UnknownFunction: "))
        let missing = try await get(f.httpBase, "/api/?Function=PreviewInput&Input=9")
        XCTAssertEqual(missing.status, 404)
        XCTAssertTrue(missing.body.hasPrefix("InputNotFound: "))
        let bad = try await get(f.httpBase, "/api/?Function=SetFader&Value=999")
        XCTAssertEqual(bad.status, 400)
        XCTAssertTrue(bad.body.hasPrefix("BadParameter: "))
        let empty = try await get(f.httpBase, "/api/?Function=")
        XCTAssertEqual(empty.status, 400)
        let other = try await get(f.httpBase, "/nope")
        XCTAssertEqual(other.status, 404)
        XCTAssertEqual(f.server.counters.xmlServed, 5)
    }

    /// 转场槽经兼容层走一遍（W5-M）：Transition2 = 执行槽 2（出厂 Wipe 1 s）、快照 currentSlot = 2；转场进行中再发 Transition3 = "(no change)"；
    /// 转场中带 Input 的 Cut 回 409、一条命令都不发（PGM 仍落在 Wipe 的目标）；SetTransitionDuration2 进行中也收，完成那一拍按当前槽重拷；
    /// XML 的 transitions 是四个槽。
    func testC5_http_transitionSlotsAndCutDuringTransition() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let t2 = try await get(f.httpBase, "/api/?Function=Transition2")
        XCTAssertEqual(t2.status, 200)
        XCTAssertEqual(t2.body, "OK Transition2")
        var s = await f.stateMachine.state
        XCTAssertEqual(s.transition.currentSlot, 2)
        XCTAssertEqual(s.transition.type, .wipe)
        XCTAssertTrue(s.transition.isActive, "一条命令选中并开始")
        let t3 = try await get(f.httpBase, "/api/?Function=Transition3")
        XCTAssertEqual(t3.status, 200)
        XCTAssertEqual(t3.body, "OK Transition3 (no change)", "转场进行中：状态机忽略")
        let before = f.bus.lastSequence
        let cut = try await get(f.httpBase, "/api/?Function=Cut&Input=3")
        XCTAssertEqual(cut.status, 409)
        XCTAssertTrue(cut.body.hasPrefix("NotConfigured: Cut"), cut.body)
        XCTAssertEqual(f.bus.lastSequence, before, "一条命令都没发")
        let dur = try await get(f.httpBase, "/api/?Function=SetTransitionDuration2&Value=500")
        XCTAssertEqual(dur.status, 200)
        XCTAssertEqual(dur.body, "OK SetTransitionDuration2")
        s = await f.stateMachine.state
        XCTAssertEqual(s.transition.slots[1].durationTicks, 30, "槽 2 改成 0.5 s")
        XCTAssertEqual(s.transition.durationTicks, 60, "进行中的这一次按开始时的 1 s 走")
        await f.stateMachine.prepare(upTo: Tick(70))   // 没有拍推进器：手动推拍把 Wipe 做完
        s = await f.stateMachine.state
        XCTAssertFalse(s.transition.isActive)
        XCTAssertEqual(s.program, 2, "PGM = Wipe 的目标（原 PVW 2），不是 Cut 点名的 3")
        XCTAssertEqual(s.transition.durationTicks, 30, "完成那一拍按当前槽 2 重拷")
        let xml = try StatusDocument(try await get(f.httpBase, "/api").body)
        XCTAssertEqual(try xml.nodes("/*/transitions/transition").count, 4)
        XCTAssertEqual(try xml.attribute("/*/transitions/transition[2]", "duration"), "500")
        let effect = try await get(f.httpBase, "/api/?Function=SetTransitionEffect4&Value=Merge")
        XCTAssertEqual(effect.status, 501, "上游有、我们没有的效果")
    }

    func testC5_http_onlyHTTPWhenTCPDisabled() async throws {
        let f = try await CompatFixture.start { $0.tcpEnabled = false }
        defer { Task { await f.stop() } }
        XCTAssertNil(f.server.boundTCPPort)
        XCTAssertNotNil(f.server.boundHTTPPort)
        let r = try await get(f.httpBase, "/api/?Function=Cut")
        XCTAssertEqual(r.status, 200)
    }
}
