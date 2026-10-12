import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 020（用户 2026-10-11 批，P5-2 落地）：转场槽——`TransitionSlot{type, durationTicks, wipe, stinger}`、`TransitionState.slots`（恰好 4）/ `currentSlot`（1–4 或 nil）；
/// 出厂四槽按帧率换拍；搬迁补出厂槽（槽 1 = 原来那组）；`validate()` 两条新不变量；三条命令 `setTransitionSlot` / `useTransitionSlot` / `setFTBDuration`。
/// reducer 规则见 ReducerTests.test020_*。
final class Contracts020Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try sortedEncoder.encode(v), as: UTF8.self) }
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private static let factory60: [TransitionSlot] = [
        TransitionSlot(type: .fade, durationTicks: 30),
        TransitionSlot(type: .wipe, durationTicks: 60, wipe: WipeParams(direction: .leftToRight, softness: 0)),
        TransitionSlot(type: .zoom, durationTicks: 60),
        TransitionSlot(type: .stinger, durationTicks: 60, stinger: StingerParams(input: nil, cutAtTick: 0)),
    ]

    func test020_factoryDefaults_perFrameRate_andTransitionStateDefaults() {
        XCTAssertEqual(TransitionSlot.count, 4)
        XCTAssertEqual(TransitionSlot.jsonKeys, ["type", "durationTicks", "wipe", "stinger"])
        XCTAssertEqual(TransitionSlot.factoryDefaults(for: .hd1080p60), Self.factory60, "1 = Fade 0.5 s、2 = Wipe 1 s、3 = Zoom 1 s、4 = Stinger 1 s")
        XCTAssertEqual(TransitionSlot.factoryDefaults(for: .hd1080p5994).map(\.durationTicks), [30, 60, 60, 60])
        XCTAssertEqual(TransitionSlot.factoryDefaults(for: .hd1080p30).map(\.durationTicks), [15, 30, 30, 30])
        XCTAssertEqual(TransitionSlot.factoryDefaults(for: ProgramFormat(width: 1920, height: 1080, frameRate: .fps25)).map(\.durationTicks), [13, 25, 25, 25], "round，与叠加默认淡入一致")
        XCTAssertEqual(TransitionSlot.factoryDefaults(for: ProgramFormat(width: 1920, height: 1080, frameRate: .fps24)).map(\.durationTicks), [12, 24, 24, 24])
        let t = TransitionState()
        XCTAssertEqual(t.slots, Self.factory60, "TransitionState() 不知道帧率，按 60 fps 给")
        XCTAssertEqual(t.currentSlot, 1, "当前那组（fade 30）= 槽 1")
        XCTAssertEqual(t.currentGroup, Self.factory60[0])
        XCTAssertNil(TransitionState(type: .cut, durationTicks: 0).currentSlot, "当前那组不对应任何槽 → nil（测试 / 脚本的裸状态）")
        XCTAssertEqual(TransitionState(type: .wipe, durationTicks: 60).currentSlot, 2)
        XCTAssertEqual(TransitionState(type: .wipe, durationTicks: 45, currentSlot: 2).currentSlot, 2, "显式给的照收（validate 不查对不对得上）")
        XCTAssertEqual(TransitionState.jsonKeys, ["type", "durationTicks", "progress", "source", "startTick", "wipe", "stinger", "slots", "currentSlot"])
        // MixerState.newShow 按节目帧率重算四槽，当前那组 = 槽 1；裸状态 MixerState() 仍是 60 fps 的出厂槽
        let new30 = MixerState.newShow(format: .hd1080p30)
        XCTAssertEqual(new30.transition.slots.map(\.durationTicks), [15, 30, 30, 30])
        XCTAssertEqual(new30.transition.currentSlot, 1)
        XCTAssertEqual(new30.transition.type, .fade); XCTAssertEqual(new30.transition.durationTicks, 15)
        XCTAssertEqual(MixerState.newShow().transition, TransitionState(), "60 fps 下与裸状态相同")
        XCTAssertEqual(MixerState(format: .hd1080p30).transition.slots, Self.factory60)
    }

    func test020_select_apply_matching() {
        var t = TransitionState()
        t.select(slot: 3)
        XCTAssertEqual(t.type, .zoom); XCTAssertEqual(t.durationTicks, 60); XCTAssertEqual(t.currentSlot, 3)
        t.slots[0] = TransitionSlot(type: .fade, durationTicks: 90)
        XCTAssertEqual(t.slotIndexMatchingCurrentGroup(), 3)
        t.currentGroup = TransitionSlot(type: .fade, durationTicks: 90)
        XCTAssertEqual(t.slotIndexMatchingCurrentGroup(), 1)
        t.currentGroup = TransitionSlot(type: .fade, durationTicks: 7)
        XCTAssertNil(t.slotIndexMatchingCurrentGroup())
        // 两个槽一样时优先给出 preferring
        t.slots[3] = t.slots[2]
        t.currentGroup = t.slots[2]
        XCTAssertEqual(t.slotIndexMatchingCurrentGroup(), 3)
        XCTAssertEqual(t.slotIndexMatchingCurrentGroup(preferring: 4), 4)
        XCTAssertEqual(t.slotIndexMatchingCurrentGroup(preferring: 1), 3, "preferring 对不上就按顺序找")
    }

    func test020_jsonShape_currentSlotNilNotWritten_slotsAlwaysWritten() throws {
        let t = TransitionState(type: .stinger, durationTicks: 40, wipe: WipeParams(direction: .rightToLeft, softness: 0.1), stinger: StingerParams(input: 3, cutAtTick: 12))
        XCTAssertNil(t.currentSlot)
        let s = try json(t)
        XCTAssertEqual(s, #"{"durationTicks":40,"progress":0,"slots":[{"durationTicks":30,"stinger":{"cutAtTick":0},"type":"fade","wipe":{"direction":"leftToRight","softness":0}},{"durationTicks":60,"stinger":{"cutAtTick":0},"type":"wipe","wipe":{"direction":"leftToRight","softness":0}},{"durationTicks":60,"stinger":{"cutAtTick":0},"type":"zoom","wipe":{"direction":"leftToRight","softness":0}},{"durationTicks":60,"stinger":{"cutAtTick":0},"type":"stinger","wipe":{"direction":"leftToRight","softness":0}}],"source":"auto","stinger":{"cutAtTick":12,"input":3},"type":"stinger","wipe":{"direction":"rightToLeft","softness":0.1}}"#)
        XCTAssertEqual(try JSONDecoder().decode(TransitionState.self, from: Data(s.utf8)), t)
        var with = t
        with.currentSlot = 4
        XCTAssertTrue(try json(with).contains(#""currentSlot":4"#))
        XCTAssertEqual(try JSONDecoder().decode(TransitionState.self, from: try sortedEncoder.encode(with)), with)
        // 020 之前的 JSON（没有 slots / currentSlot）：裸解码 slots = []、currentSlot = nil，由搬迁补齐
        let old = #"{"durationTicks":40,"progress":0,"source":"auto","stinger":{"cutAtTick":12,"input":3},"type":"stinger","wipe":{"direction":"rightToLeft","softness":0.1}}"#
        let raw = try JSONDecoder().decode(TransitionState.self, from: Data(old.utf8))
        XCTAssertEqual(raw.slots, [])
        XCTAssertNil(raw.currentSlot)
        XCTAssertEqual(raw.type, .stinger)
        // 有 slots 没 currentSlot → nil
        let noCurrent = try JSONDecoder().decode(TransitionState.self, from: Data(s.utf8))
        XCTAssertNil(noCurrent.currentSlot)
        XCTAssertEqual(noCurrent.slots.count, 4)
    }

    func test020_validate_slotCountAndCurrentSlotRange() {
        var s = MixerState(format: .hd1080p60)
        XCTAssertNoThrow(try s.validate())
        s.transition.slots.removeLast()
        XCTAssertThrowsError(try s.validate()) { XCTAssertEqual($0 as? MixerStateError, .transitionSlotCount(3)) }
        s.transition.slots = []
        XCTAssertThrowsError(try s.validate()) { XCTAssertEqual($0 as? MixerStateError, .transitionSlotCount(0)) }
        s = MixerState(format: .hd1080p60)
        s.transition.slots.append(s.transition.slots[0])
        XCTAssertThrowsError(try s.validate()) { XCTAssertEqual($0 as? MixerStateError, .transitionSlotCount(5)) }
        s = MixerState(format: .hd1080p60)
        s.transition.currentSlot = 0
        XCTAssertThrowsError(try s.validate()) { XCTAssertEqual($0 as? MixerStateError, .transitionSlotIndex(0)) }
        s.transition.currentSlot = 5
        XCTAssertThrowsError(try s.validate()) { XCTAssertEqual($0 as? MixerStateError, .transitionSlotIndex(5)) }
        s.transition.currentSlot = nil
        XCTAssertNoThrow(try s.validate())
        s.transition.currentSlot = 4
        XCTAssertNoThrow(try s.validate())
    }

    /// 020 之前写的节目文件：按 mixer.format 补出厂四槽，槽 1 换成文件里原来那组、currentSlot = 1；原来是 cut 的槽 1 用 Fade 0.5 s、currentSlot = nil（当前那组仍是 cut，行为不变）；
    /// 槽里指向不存在输入的 stinger.input 置 nil；幂等；loadShow / Show.load 都走它。
    func test020_migration_addsFactorySlotsWithSlotOneFromFile() throws {
        func oldShow(type: TransitionType, duration: Int, format: ProgramFormat = .hd1080p60, stingerInput: Int? = nil) throws -> Data {
            var state = MixerState(format: format)
            state.inputs = [InputConfig(number: 1, name: "a", source: .image(path: "/a.png")), InputConfig(number: 2, name: "b", source: .image(path: "/b.png"))]
            state.transition = TransitionState(type: type, durationTicks: duration, wipe: WipeParams(direction: .diagonal, softness: 0.3), stinger: StingerParams(input: stingerInput, cutAtTick: 5))
            let data = try Show(name: "老", state: state).save()
            // 去掉 slots / currentSlot 两个键 = 020 之前的文件
            var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var mixer = obj["mixer"] as! [String: Any]
            var transition = mixer["transition"] as! [String: Any]
            transition["slots"] = nil; transition["currentSlot"] = nil
            mixer["transition"] = transition; obj["mixer"] = mixer
            return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        }
        // 非 cut：槽 1 = 原来那组，currentSlot = 1
        let wipe = try Show.load(from: try oldShow(type: .wipe, duration: 45, stingerInput: 2))
        let group = TransitionSlot(type: .wipe, durationTicks: 45, wipe: WipeParams(direction: .diagonal, softness: 0.3), stinger: StingerParams(input: 2, cutAtTick: 5))
        XCTAssertEqual(wipe.mixer.transition.slots, [group] + Array(Self.factory60[1...]))
        XCTAssertEqual(wipe.mixer.transition.currentSlot, 1)
        XCTAssertEqual(wipe.mixer.transition.currentGroup, group, "当前那组一个字节不动")
        XCTAssertEqual(wipe.migratingLegacyKeys(), wipe, "幂等")
        XCTAssertEqual(try Show.load(from: try wipe.save()), wipe)
        // 按节目帧率补出厂槽
        let thirty = try Show.load(from: try oldShow(type: .fade, duration: 30, format: .hd1080p30))
        XCTAssertEqual(thirty.mixer.transition.slots.map(\.durationTicks), [30, 30, 30, 30], "槽 1 = 文件里的 fade 30，其余按 30 fps")
        XCTAssertEqual(thirty.mixer.transition.currentSlot, 1)
        // cut：槽 1 = Fade 0.5 s，currentSlot = nil，当前那组仍是 cut
        let cut = try Show.load(from: try oldShow(type: .cut, duration: 0))
        XCTAssertEqual(cut.mixer.transition.slots.map(\.type), [.fade, .wipe, .zoom, .stinger])
        XCTAssertEqual(cut.mixer.transition.slots[0].durationTicks, 30)
        XCTAssertNil(cut.mixer.transition.currentSlot)
        XCTAssertEqual(cut.mixer.transition.type, .cut)
        XCTAssertEqual(cut.makeState().transition.type, .cut)
        // 悬空的 stinger 引用：当前那组（P4 的规则）与槽里的都清
        let dangling = try Show.load(from: try oldShow(type: .stinger, duration: 40, stingerInput: 9))
        XCTAssertNil(dangling.mixer.transition.stinger.input)
        XCTAssertNil(dangling.mixer.transition.slots[0].stinger.input)
        XCTAssertEqual(dangling.mixer.transition.slots[0].type, .stinger)
        var withSlots = wipe
        withSlots.mixer.transition.slots[3].stinger.input = 9
        XCTAssertNil(withSlots.migratingLegacyKeys().mixer.transition.slots[3].stinger.input, "已有 slots 的文件也清槽里的悬空引用")
        // 老场景节目：出厂四槽 + 槽 1 = 工厂里的那组（fade 30；g4 的那组还带着 Wipe 软边 0.1 与 Stinger 输入 9，照搬）
        for name in ["scenarios/g3-show.json", "scenarios/g4-show.json", "scenarios/m0-show.json", "scenarios/g4-ndi-show.json"] {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(name)))
            XCTAssertEqual(show.mixer.transition.slots[0], show.mixer.transition.currentGroup, name)
            XCTAssertEqual(show.mixer.transition.slots[0].type, .fade, name); XCTAssertEqual(show.mixer.transition.slots[0].durationTicks, 30, name)
            XCTAssertEqual(Array(show.mixer.transition.slots[1...]), Array(Self.factory60[1...]), name)
            XCTAssertEqual(show.mixer.transition.currentSlot, 1, name)
            XCTAssertNoThrow(try show.makeState().validate(), name)
            XCTAssertEqual(try Show.load(from: try show.save()), show, name)
        }
        // 文件里 slots 不是 4 个：读不进来（validate）
        var broken = try JSONSerialization.jsonObject(with: try wipe.save()) as! [String: Any]
        var mixer = broken["mixer"] as! [String: Any]
        var transition = mixer["transition"] as! [String: Any]
        transition["slots"] = Array((transition["slots"] as! [Any]).prefix(3))
        mixer["transition"] = transition; broken["mixer"] = mixer
        XCTAssertThrowsError(try Show.load(from: try JSONSerialization.data(withJSONObject: broken)))
    }

    func test020_commands_jsonShape() throws {
        let slot = TransitionSlot(type: .fade, durationTicks: 30)
        XCTAssertEqual(try json(Command.setTransitionSlot(slot: 1, config: slot)),
                       #"{"setTransitionSlot":{"config":{"durationTicks":30,"stinger":{"cutAtTick":0},"type":"fade","wipe":{"direction":"leftToRight","softness":0}},"slot":1}}"#)
        XCTAssertEqual(try json(Command.useTransitionSlot(slot: 2, start: true)), #"{"useTransitionSlot":{"slot":2,"start":true}}"#)
        XCTAssertEqual(try json(Command.setFTBDuration(ticks: 15)), #"{"setFTBDuration":{"ticks":15}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"useTransitionSlot":{"slot":4,"start":false}}"#.utf8)), .useTransitionSlot(slot: 4, start: false))
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setTransitionSlot":{"slot":3,"config":{"type":"zoom","durationTicks":20,"wipe":{"direction":"topToBottom","softness":0.5},"stinger":{"cutAtTick":0}}}}"#.utf8)),
                       .setTransitionSlot(slot: 3, config: TransitionSlot(type: .zoom, durationTicks: 20, wipe: WipeParams(direction: .topToBottom, softness: 0.5), stinger: StingerParams())))
        XCTAssertEqual(Samples.commandCaseCount, 42, "35 + 3（020）+ 2（021）+ 1（023 四）+ 1（023 五）")
        XCTAssertEqual(Set(Samples.commands().map(Samples.caseName(of:))).count, 42)
    }

    // MARK: 提案 029（用户 2026-10-12 定，P5-3）：没选输入的 Stinger 槽拒收——契约这一层只有"什么叫没选输入的 Stinger"一条判定，
    // 拒收本身在 reducer（ReducerTests.test029_*）与校验器（CommandBusTests）；不加字段、不加命令、JSON 形态不变。

    /// `TransitionSlot.isStingerWithoutInput` = 效果是 Stinger 且 `stinger.input == nil`：出厂槽 4 就是；选了输入的 Stinger、别的效果（不管 stinger 参数）都不是。
    /// useTransitionSlot(start: true) 看的是槽、autoTransition 看的是当前那组（`currentGroup`），两处用同一条判定。
    func test029_isStingerWithoutInput_definition_factorySlot4AndCurrentGroup() {
        XCTAssertEqual(Self.factory60.map(\.isStingerWithoutInput), [false, false, false, true], "出厂槽 4 = Stinger、没选输入")
        XCTAssertFalse(TransitionSlot(type: .stinger, durationTicks: 60, stinger: StingerParams(input: 3, cutAtTick: 0)).isStingerWithoutInput)
        XCTAssertTrue(TransitionSlot(type: .stinger, durationTicks: 0, stinger: StingerParams(input: nil, cutAtTick: 9)).isStingerWithoutInput, "时长 / 换底拍不影响")
        for type in [TransitionType.cut, .fade, .wipe, .zoom] {
            XCTAssertFalse(TransitionSlot(type: type, durationTicks: 30).isStingerWithoutInput, "\(type) 不看 stinger 参数")
        }
        var t = TransitionState()
        XCTAssertFalse(t.currentGroup.isStingerWithoutInput, "新状态当前那组 = 槽 1 Fade")
        t.select(slot: 4)
        XCTAssertTrue(t.currentGroup.isStingerWithoutInput, "选中槽 4（只选中是合法的）")
        t.stinger.input = 2
        XCTAssertFalse(t.currentGroup.isStingerWithoutInput)
        t = TransitionState(type: .stinger, durationTicks: 45)
        XCTAssertNil(t.currentSlot)
        XCTAssertTrue(t.currentGroup.isStingerWithoutInput, "不对应任何槽的当前那组（setTransition 直接给的）同一条判定")
    }

    /// 029 不加字段、不加命令：判定是计算属性、不进 JSON（槽与 TransitionState 的键不变）；useTransitionSlot / autoTransition 的 wire 形态不变；命令数仍 42。
    func test029_noNewFieldsOrCommands_wireShapeUnchanged() throws {
        let unset = TransitionSlot(type: .stinger, durationTicks: 60)
        XCTAssertEqual(try json(unset), #"{"durationTicks":60,"stinger":{"cutAtTick":0},"type":"stinger","wipe":{"direction":"leftToRight","softness":0}}"#)
        XCTAssertEqual(TransitionSlot.jsonKeys, ["type", "durationTicks", "wipe", "stinger"])
        var t = TransitionState()
        t.select(slot: 4)
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(t)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set(TransitionState.jsonKeys).subtracting(["startTick"]))
        XCTAssertEqual(try json(Command.useTransitionSlot(slot: 4, start: true)), #"{"useTransitionSlot":{"slot":4,"start":true}}"#)
        XCTAssertEqual(try json(Command.autoTransition), #"{"autoTransition":{}}"#)
        XCTAssertEqual(Samples.commandCaseCount, 42)
    }
}
