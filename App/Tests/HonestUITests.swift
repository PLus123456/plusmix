// W5-B（prompt 87）界面不说谎：效果链标"尚未生效"（01a J1 / H2，02 X06 / X07）、"其他命令"不被悄悄改成 Cut（N4，X10 / X41）、
// 录制"文件格式"合成一个单选、不再写 container（K5，X14，04 Q12 (a)）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class HonestUITests: XCTestCase {
    // MARK: 6. 效果链标"尚未生效"

    func testUI_effectChainMarkedNotEffectiveUntilSupported() throws {
        XCTAssertFalse(AudioEffectsSupport.busEffectsApplied, "总线效果还没接（88 接上时翻）")
        XCTAssertFalse(AudioEffectsSupport.inputEffectsApplied, "每路效果还没接（102 接上时翻）")
        // 总线条"效果 (n)"：没接上时计数不亮
        XCTAssertEqual(MixerModel.busEffectsButtonTitle(count: 2, applied: false), "效果")
        XCTAssertEqual(MixerModel.busEffectsButtonTitle(count: 2, applied: true), "效果 (2)", "接上之后照常显示计数")
        XCTAssertEqual(AudioEffectsSupport.banner(applied: false), "效果尚未作用到声音（本版本）")
        XCTAssertNil(AudioEffectsSupport.banner(applied: true))

        let session = try AppTest.freshSession()
        let mixer = AppTest.controller.windowController.mixerPanel.model
        mixer.setBusEffects(.master, [AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 6)])
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.count == 1 }, "设置照样存进快照 / 节目文件")
        XCTAssertEqual(mixer.busEffectsButtonTitle(.master), "效果", "有一格也不亮计数")
        XCTAssertEqual(mixer.busEffectsBanner, "效果尚未作用到声音（本版本）", "总线效果 sheet 顶部的横幅")

        // 输入设置："效果链"改名"音频效果"，那一页顶部同样的横幅
        try AppTest.addSynthetics(session, count: 1)
        let w = try XCTUnwrap(AppTest.controller.panels.showInputSettings(input: 1))
        defer { AppTest.controller.panels.closeAll() }
        XCTAssertEqual(InputSettingsModel.Section.effects.title, "音频效果")
        XCTAssertEqual(w.model.effectsBanner, "效果尚未作用到声音（本版本）")

        // 对外文字按实情：不再说"停用的格旁路"（引擎根本不读效果链）
        for lang in ["zh-Hans", "en"] {
            let hint = L10n.string("mixer.busEffectsHint", language: lang)
            XCTAssertFalse(hint.contains("旁路") || hint.lowercased().contains("bypass"), "\(lang)：\(hint)")
        }
        XCTAssertEqual(L10n.string("inputSettings.section.effects", language: "en"), "Audio effects")
    }

    // MARK: 7. "其他命令"止血

    func testHotkeys_otherCommandNotRewrittenToCut() throws {
        let other = Command.setTransition(type: .wipe, durationTicks: 30)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5b-hotkeys-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hotkeys.json")
        let table = HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo(key: "g"), action: .command(other), note: "Wipe"),
                                           HotkeyBinding(key: KeyCombo(key: "h"), action: .command(.cut))])
        let model = HotkeyEditorModel(table: table, fileURL: url)
        XCTAssertEqual(model.rows[0].kind, .other)

        // 只在这一行本来就是其他命令时才列出"其他命令"（新加的行、普通的行都不列）
        XCTAssertTrue(HotkeyEditorModel.actionChoices(for: model.rows[0]).contains(.other))
        XCTAssertFalse(HotkeyEditorModel.actionChoices(for: model.rows[1]).contains(.other))
        model.addRow(key: "j")
        XCTAssertFalse(HotkeyEditorModel.actionChoices(for: model.rows[2]).contains(.other))

        // 显示：CommandCatalog 的说明 + 参数摘要，不是 Swift 枚举原文
        let text = HotkeyEditorModel.describe(.command(other))
        XCTAssertTrue(text.contains(CommandCatalog.entry(for: .setTransition).summary), text)
        XCTAssertTrue(text.contains("wipe") && text.contains("30"), text)
        XCTAssertFalse(text.contains("setTransition(type:"), text)

        // 改成别的动作再改回来：命令还在
        model.rows[0].kind = .cut
        model.rows[0].kind = .other
        XCTAssertEqual(model.rows[0].action, .command(other))

        // 一行是"其他命令"却没有命令：存不了、报错，绝不悄悄存成 Cut（X10）
        model.rows[2].kind = .other
        XCTAssertNil(model.rows[2].action, "没有命令就没有动作，不兜底成 Cut")
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.errorMessage, "第 3 行选了“其他命令”但没有命令：点“编辑 JSON…”填一条")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "存不了就不写文件")

        // "编辑 JSON…"：校验过才写进这一行
        XCTAssertFalse(model.applyJSON(model.rows[2].id, #"{"nope":{}}"#))
        XCTAssertNotNil(model.jsonError)
        XCTAssertFalse(model.applyJSON(model.rows[2].id, "不是 JSON"))
        XCTAssertNil(model.rows[2].action, "解不出来：这一行不动")
        XCTAssertTrue(model.applyJSON(model.rows[2].id, #"{"setPreview":{"input":4}}"#))
        XCTAssertNil(model.jsonError)
        XCTAssertEqual(model.rows[2].kind, .setPreview, "认得出的命令回到对应的动作")
        XCTAssertEqual(model.rows[2].action, .command(.setPreview(input: 4)))
        XCTAssertTrue(model.applyJSON(model.rows[2].id, #"{"setAFV":{"on":true}}"#))
        XCTAssertEqual(model.rows[2].kind, .other)
        XCTAssertTrue(HotkeyEditorModel.actionChoices(for: model.rows[2]).contains(.other), "这一行现在本来就是其他命令了")
        XCTAssertEqual(model.jsonText(for: model.rows[0].id).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: ""),
                       #"{"setTransition":{"durationTicks":30,"type":"wipe"}}"#, "编辑框里是这一行命令的 JSON")
        XCTAssertTrue(model.save(), model.errorMessage ?? "")
        let saved = try HotkeyTable.load(from: url)
        XCTAssertEqual(saved.action(for: KeyCombo(key: "g")), .command(other), "其他命令原样存回，不变成 Cut")
        XCTAssertEqual(saved.action(for: KeyCombo(key: "h")), .command(.cut))
        XCTAssertEqual(saved.action(for: KeyCombo(key: "j")), .command(.setAFV(on: true)))

        // MIDI 映射面板：这类行的动作下拉不再空白，显示同一句说明
        let midiRow = MIDIMappingModel.Row(trigger: .note(channel: 1, note: 60), action: .action(.command(other)), note: "")
        XCTAssertTrue(MIDIMappingModel.actionChoices(for: midiRow).contains(.other))
        XCTAssertFalse(MIDIMappingModel.actionChoices(for: MIDIMappingModel.Row(trigger: nil, action: .action(.command(.cut)), note: "")).contains(.other))
        XCTAssertEqual(MIDIMappingModel.describe(midiRow.action), text)
        let midiModel = MIDIMappingModel(table: MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(other)))]),
                                         controller: MIDIController(bus: CommandBus(stateMachine: SwitcherSession.detachedStateMachine()), table: MIDIMapTable(mappings: [])),
                                         fileURL: dir.appendingPathComponent("midi.json"))
        defer { midiModel.stopRefreshing() }
        XCTAssertTrue(midiModel.applyJSON(midiModel.rows[0].id, #"{"setTransition":{"type":"zoom","durationTicks":12}}"#))
        XCTAssertEqual(midiModel.rows[0].action, .action(.command(.setTransition(type: .zoom, durationTicks: 12))))
    }

    // MARK: 8. 录制"文件格式"

    func testPanels_recordFormatChoiceWritesRemuxOnly() throws {
        let session = try AppTest.freshSession()
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let page = panels.showOutputSettings(tab: .record).model
        XCTAssertEqual(OutputSettingsModel.RecordFileFormat.allCases.map(\.title), [".mov（边录边存片段，崩溃可恢复）", ".mov，停止后转 .mp4"])
        XCTAssertEqual(page.recordFileFormat, .mov)
        var sent: [Command] = []
        let forward = page.send
        page.send = { c in sent.append(c); forward?(c) }

        page.recordFileFormat = .movThenMP4
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(1)?.settings.record?.remuxToMP4 == true })
        XCTAssertEqual(session.state.output(1)?.settings.record?.container, .mov, "不写 container")
        XCTAssertEqual(page.recordFileFormat, .movThenMP4)
        page.recordFileFormat = .mov
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(1)?.settings.record?.remuxToMP4 == false })

        // 旧节目文件里 container = .mp4（运行时从来不读它）：照读、不改写；格式只看 remuxToMP4，页上说一句它不起作用
        var legacy = try XCTUnwrap(session.state.output(1)?.settings)
        legacy.record?.container = .mp4
        session.send(.setOutputSettings(output: 1, settings: legacy))
        XCTAssertTrue(AppTest.waitUntil(3) { page.state.output(1)?.settings.record?.container == .mp4 })
        XCTAssertEqual(page.recordFileFormat, .mov)
        XCTAssertEqual(page.recordLegacyContainerNote, "节目文件里的“容器 .mp4”不起作用：文件格式以上面这一项为准。")
        sent.removeAll()
        page.recordFileFormat = .movThenMP4
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(1)?.settings.record?.remuxToMP4 == true })
        XCTAssertEqual(session.state.output(1)?.settings.record?.container, .mp4, "container 照读不写：原样留着")
        XCTAssertNil(page.recordLegacyContainerNote, "开了转 .mp4：这句不用说了")
        XCTAssertFalse(sent.isEmpty)
        for c in sent {
            if case .setOutputSettings(_, let s) = c { XCTAssertEqual(s.record?.container, .mp4, "发出去的设置里 container 没被改写") }
        }
    }
}
