import XCTest
@testable import SwitcherContracts

/// 提案 024 (b)（用户 2026-10-03 批，P5 落契约）：`EffectSlot` 键表加自写压缩器 id `compressor` 与 `peakLimiter.ceilingDb`。
/// 键表是自由 JSON，没有新类型；这里把文档里的 id / 键名钉成字面量，改了名字这里先红（C 实现与延迟自检归 W1-D3 / prompt 102）。
final class Contracts024Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }

    func test024_compressorSlotKeysRoundTripAndMatchDocumentedNames() throws {
        let slot = EffectSlot(id: "compressor", enabled: true,
                              params: ["thresholdDb": -20, "ratio": 4, "kneeDb": 6, "attackSeconds": 0.005, "releaseSeconds": 0.1, "makeupGainDb": 0])
        let data = try sortedEncoder.encode(slot)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"enabled":true,"id":"compressor","params":{"attackSeconds":0.005,"kneeDb":6,"makeupGainDb":0,"ratio":4,"releaseSeconds":0.1,"thresholdDb":-20}}"#)
        XCTAssertEqual(try JSONDecoder().decode(EffectSlot.self, from: data), slot)
        // 文档键表（CONTRACTS.md §2.4 / EffectSlot 注释）的六个键一个不多不少
        XCTAssertEqual(Set(slot.params.keys), ["thresholdDb", "ratio", "kneeDb", "attackSeconds", "releaseSeconds", "makeupGainDb"])
    }

    func test024_peakLimiterCeilingKeyIsOptional() throws {
        // 老形态（W5-C 写的三个键）照解，没有 ceilingDb
        let legacy = try JSONDecoder().decode(EffectSlot.self, from: Data(#"{"enabled":true,"id":"peakLimiter","params":{"attackSeconds":0.012,"decaySeconds":0.024,"preGainDb":0}}"#.utf8))
        XCTAssertEqual(legacy.id, "peakLimiter")
        XCTAssertNil(legacy.params["ceilingDb"], "缺键 = 默认 0 dBFS，由实现补")
        // 新形态多一个 ceilingDb，往返不丢
        var withCeiling = legacy
        withCeiling.params["ceilingDb"] = -1
        let back = try JSONDecoder().decode(EffectSlot.self, from: try sortedEncoder.encode(withCeiling))
        XCTAssertEqual(back, withCeiling)
        XCTAssertEqual(back.params["ceilingDb"], .number(-1))
    }
}
