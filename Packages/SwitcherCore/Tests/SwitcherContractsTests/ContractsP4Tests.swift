import XCTest
@testable import SwitcherContracts

/// P4（prompt 67）：`Show.migratingLegacyKeys()` 顺手清掉搬迁遗留的死数据。
/// - 输入效果链里的 "border" 格：过渡读取 W3-B2 删了，搬完一律清（没有叠加通道用到的、停用的也清；用户 2026-09-27 定全清）；
/// - P4 之前 removeInput 不清 `transition.stinger.input`，存下来的节目文件里可能指向不存在的输入：置 nil（validate() 不查引用，用户同日定）。
final class ContractsP4Tests: XCTestCase {
    private static func border(width: Double, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: OverlayBorder.legacyEffectID, enabled: enabled, params: ["width": .number(width), "color": .array([1, 2, 3])])
    }

    private static func state(effects: [Int: [EffectSlot]]) -> MixerState {
        var s = MixerState(format: .hd1080p60)
        s.inputs = (1...5).map { n in
            var settings = InputSettings()
            settings.effects = effects[n] ?? []
            return InputConfig(number: n, name: "输入 \(n)", source: .image(path: "/\(n).png"), settings: settings)
        }
        return s
    }

    func testP4_migrationClearsDeadBorderEffectSlots() throws {
        var s = Self.state(effects: [
            1: [EffectSlot(id: "parametricEQ"), Self.border(width: 0.02), Self.border(width: 0.09, enabled: false)],   // 叠加 1 用：搬第一个启用的，两格都清
            2: [Self.border(width: 0.03)],                                                                           // 没有叠加通道用它
            3: [Self.border(width: 0.04, enabled: false), EffectSlot(id: "peakLimiter")],                           // 叠加 2 用，但格是停用的
            4: [Self.border(width: 0.05), EffectSlot(id: "dynamicsProcessor", enabled: false)],                     // 叠加 3 用，通道已有正式边框
            5: [EffectSlot(id: "parametricEQ", params: ["gainDb": 3])],                                              // 没有 border 格
        ])
        s.overlays[0].input = 1
        s.overlays[1].input = 3
        s.overlays[2].input = 4
        s.overlays[2].border = OverlayBorder(width: 0.01, color: RGB8(red: 9, green: 9, blue: 9))

        let migrated = Show(name: "P3 之前", state: s).migratingLegacyKeys()
        XCTAssertEqual(migrated.mixer.overlays[0].border, OverlayBorder(width: 0.02, color: RGB8(red: 1, green: 2, blue: 3)), "启用的搬进用到它的通道（规则不变）")
        XCTAssertNil(migrated.mixer.overlays[1].border, "停用的不搬：关着的边框 = 不画")
        XCTAssertEqual(migrated.mixer.overlays[2].border, OverlayBorder(width: 0.01, color: RGB8(red: 9, green: 9, blue: 9)), "正式字段已有值的不被覆盖")
        XCTAssertNil(migrated.mixer.overlays[3].border)

        let ids = migrated.inputs.map { $0.settings.effects.map(\.id) }
        XCTAssertEqual(ids, [["parametricEQ"], [], ["peakLimiter"], ["dynamicsProcessor"], ["parametricEQ"]],
                       "border 格一个不剩（没人用的、停用的、没搬的都清），别的格原样、顺序不变")
        XCTAssertEqual(migrated.inputs[3].settings.effects, [EffectSlot(id: "dynamicsProcessor", enabled: false)])
        XCTAssertEqual(migrated.inputs[4].settings, s.inputs[4].settings, "没有 border 格的输入一个字节不动")

        XCTAssertEqual(migrated.migratingLegacyKeys(), migrated, "幂等")

        // Show.load 走同一条路：文件里带着 border 格（不搬迁直接解能看到），读进来就没有了；再写出、再读回不变
        let file = try Show(name: "P3 之前", state: s).save()
        XCTAssertEqual(try Show.fileDecoder.decode(Show.self, from: file).inputs[1].settings.effects.map(\.id), [OverlayBorder.legacyEffectID])
        let loaded = try Show.load(from: file)
        XCTAssertEqual(loaded, migrated)
        XCTAssertEqual(try Show.load(from: try loaded.save()), loaded)
    }

    func testP4_migrationClearsDanglingStingerReference() throws {
        var s = Self.state(effects: [:])
        s.transition.type = .stinger
        s.transition.stinger = StingerParams(input: 9, cutAtTick: 12)   // P4 之前"先设 stinger 再删那一路"留下的
        XCTAssertNoThrow(try s.validate(), "validate() 只查结构不变量，不查输入引用（用户 2026-09-27 定）")

        let migrated = Show(name: "悬空", state: s).migratingLegacyKeys()
        XCTAssertEqual(migrated.mixer.transition.stinger, StingerParams(input: nil, cutAtTick: 12), "悬空的置 nil，换底拍不动")
        XCTAssertEqual(migrated.mixer.transition.type, .stinger, "只动引用，不改转场类型")
        XCTAssertEqual(migrated.migratingLegacyKeys(), migrated, "幂等")

        var live = s
        live.transition.stinger.input = 5
        XCTAssertEqual(Show(name: "有效", state: live).migratingLegacyKeys().mixer.transition.stinger, StingerParams(input: 5, cutAtTick: 12), "指向存在的输入不动")

        let loaded = try Show.load(from: try Show(name: "悬空", state: s).save())
        XCTAssertNil(loaded.mixer.transition.stinger.input, "读老文件时清掉")
        XCTAssertNil(loaded.makeState().transition.stinger.input)
    }
}
