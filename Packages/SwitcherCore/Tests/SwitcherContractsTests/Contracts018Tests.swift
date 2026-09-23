import XCTest
@testable import SwitcherContracts

/// 提案 018（用户 2026-09-23 批，W3-C2 落地）：`Stats.DisplayEntry` 加 `undelivered`（不在呈现 / 发布时没送出去的帧），与 dropped 不重叠。
/// 钉四件事：键名与位置、往返、013 的老条目缺键按 0 解、不带 undelivered 的老调用点照样能建（默认 0）。
final class Contracts018Tests: XCTestCase {
    func test018_displayEntryUndeliveredKeyRoundTripAndDefaults() throws {
        XCTAssertEqual(Stats.DisplayEntry.jsonKeys, ["output", "kind", "frames", "dropped", "undelivered", "state"])
        let e = Stats.DisplayEntry(output: 5, kind: "virtualCamera", frames: 100, dropped: 2, undelivered: 600, state: "publishing")
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(e), as: UTF8.self),
                       #"{"dropped":2,"frames":100,"kind":"virtualCamera","output":5,"state":"publishing","undelivered":600}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.DisplayEntry.self, from: try Stats.lineEncoder.encode(e)), e)

        // 013 写的老条目没有 undelivered：解出来 0，其余照旧
        let old = try JSONDecoder().decode(Stats.DisplayEntry.self,
                                           from: Data(#"{"dropped":4,"frames":35900,"kind":"virtualCamera","output":5,"state":"waitingExtension"}"#.utf8))
        XCTAssertEqual(old, Stats.DisplayEntry(output: 5, kind: "virtualCamera", frames: 35_900, dropped: 4, undelivered: 0, state: "waitingExtension"))

        // 不带 undelivered 的调用点（App 的监视器 / 多画面窗口两项）照样编得过，默认 0；写出总是写全
        let monitor = Stats.DisplayEntry(output: 0, kind: "monitor", frames: 1, dropped: 0, state: "presenting")
        XCTAssertEqual(monitor.undelivered, 0)
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Stats.lineEncoder.encode(monitor)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set(Stats.DisplayEntry.jsonKeys))
    }

    /// 整行 Stats 往返时 undelivered 不丢（display[] 嵌在 Stats 里走的是同一个 Codable）。
    func test018_statsLineCarriesUndelivered() throws {
        let s = Samples.stats()
        let cam = try XCTUnwrap(s.display.first { $0.kind == "virtualCamera" })
        XCTAssertGreaterThan(cam.undelivered, 0, "样例里给了非默认值，往返才有意义")
        let back = try Stats.parse(line: try s.jsonLine())
        XCTAssertEqual(back.display, s.display)
    }
}
