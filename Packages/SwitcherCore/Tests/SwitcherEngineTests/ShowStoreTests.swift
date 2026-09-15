import Foundation
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 节目文件读写与 schemaVersion 迁移框架。
final class ShowStoreTests: XCTestCase {
    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("w1core-\(UUID().uuidString)-\(name)")
    }

    func testW1B_showStore_saveLoadRoundTrip() throws {
        let store = ShowStore()
        let show = Show(name: "周日", state: ReducerTests.baseState())
        let url = tempURL("show.json")
        try store.save(show, to: url)
        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded, show)
        XCTAssertEqual(loaded.schemaVersion, Show.currentSchemaVersion)
        // 覆盖保存是原子的：文件要么旧要么新
        var changed = show; changed.name = "周一"
        try store.save(changed, to: url)
        XCTAssertEqual(try store.load(from: url).name, "周一")
        try? FileManager.default.removeItem(at: url)
    }

    /// 迁移框架：注册 v0 → v1 的一步，v0 文档（顶层 programInput / previewInput，没有 mixer 一节）能读进来。
    func testW1B_showStore_migrationChain_oldVersionUpgradesStepByStep() throws {
        let v0Doc: JSONValue = [
            "schemaVersion": 0,
            "name": "老文件",
            "programInput": 2,
            "previewInput": 1,
            "inputs": [],
            "outputs": [],
        ]
        let v0ToV1 = ShowMigration(fromVersion: 0) { doc in
            guard case .object(var o) = doc else { throw ShowError.malformed("v0 不是对象") }
            let current = Show(name: "", state: MixerState())
            let template = try JSONDecoder().decode(JSONValue.self, from: try Show.fileEncoder.encode(current))
            guard case .object(var t) = template, case .object(var mixer) = t["mixer"]! else { throw ShowError.malformed("模板") }
            mixer["program"] = o.removeValue(forKey: "programInput") ?? 0
            mixer["preview"] = o.removeValue(forKey: "previewInput") ?? 0
            t["mixer"] = .object(mixer)
            for (k, v) in o where k != "schemaVersion" { t[k] = v }
            t["schemaVersion"] = .number(1)
            return .object(t)
        }
        let store = ShowStore(migrations: [v0ToV1])
        let data = try JSONEncoder().encode(v0Doc)
        let show = try store.load(data: data)
        XCTAssertEqual(show.schemaVersion, 1)
        XCTAssertEqual(show.name, "老文件")
        XCTAssertEqual(show.mixer.program, 2)
        XCTAssertEqual(show.mixer.preview, 1)
        XCTAssertEqual(store.migrationPath(from: 0), [0])
        // 没注册迁移的旧版本：明确报不支持
        XCTAssertThrowsError(try ShowStore().load(data: data)) { error in
            XCTAssertEqual(error as? ShowError, .unsupportedSchemaVersion(0))
        }
    }

    func testW1B_showStore_rejectsUnknownAndMalformed() throws {
        let store = ShowStore()
        let future = Data(#"{"schemaVersion": 99, "name": "x"}"#.utf8)
        XCTAssertThrowsError(try store.load(data: future)) { XCTAssertEqual($0 as? ShowError, .unsupportedSchemaVersion(99)) }
        XCTAssertThrowsError(try store.load(data: Data("not json".utf8)))
        XCTAssertThrowsError(try store.load(data: Data(#"{"name": "no version"}"#.utf8))) { XCTAssertEqual($0 as? ShowError, .malformed("缺少 schemaVersion")) }
        XCTAssertThrowsError(try store.load(from: tempURL("missing.json")))
        // 迁移链缺一环（0 → 1 有、但当前版本是 1 时只需一环；模拟注册了 fromVersion 5 的无用迁移不影响）
        let odd = ShowStore(migrations: [ShowMigration(fromVersion: 5) { $0 }])
        XCTAssertNil(odd.migrationPath(from: 0))
        XCTAssertEqual(odd.migrationPath(from: Show.currentSchemaVersion), [])
    }
}
