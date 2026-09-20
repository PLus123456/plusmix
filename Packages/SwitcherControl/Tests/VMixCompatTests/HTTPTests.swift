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

    func testC5_http_onlyHTTPWhenTCPDisabled() async throws {
        let f = try await CompatFixture.start { $0.tcpEnabled = false }
        defer { Task { await f.stop() } }
        XCTAssertNil(f.server.boundTCPPort)
        XCTAssertNotNil(f.server.boundHTTPPort)
        let r = try await get(f.httpBase, "/api/?Function=Cut")
        XCTAssertEqual(r.status, 200)
    }
}
