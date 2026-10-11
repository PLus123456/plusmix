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
        XCTAssertTrue(AudioEffectsSupport.busEffectsApplied, "总线效果 W5-C（88）已接进混音器；G6 合并时翻（W5-C 报告 §5 第 8 条）")
        XCTAssertTrue(AudioEffectsSupport.inputEffectsApplied, "每路效果 W1-D3（102）已接进混音器；G8b 合并时翻（reports/w1-audio-3.md §1.4）")
        // 总线条"效果 (n)"：没接上时计数不亮
        XCTAssertEqual(MixerModel.busEffectsButtonTitle(count: 2, applied: false), "效果")
        XCTAssertEqual(MixerModel.busEffectsButtonTitle(count: 2, applied: true), "效果 (2)", "接上之后照常显示计数")
        XCTAssertEqual(AudioEffectsSupport.banner(applied: false), "效果尚未作用到声音（本版本）")
        XCTAssertNil(AudioEffectsSupport.banner(applied: true))

        let session = try AppTest.freshSession()
        let mixer = AppTest.controller.windowController.mixerPanel.model
        mixer.setBusEffects(.master, [AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 6)])
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.count == 1 }, "设置照样存进快照 / 节目文件")
        XCTAssertEqual(mixer.busEffectsButtonTitle(.master), "效果 (1)", "总线已接：计数照常亮")
        XCTAssertNil(mixer.busEffectsBanner, "总线已接：sheet 顶部不再有横幅；每路那一半（下面）仍标")

        // 输入设置："效果链"改名"音频效果"，那一页顶部同样的横幅
        try AppTest.addSynthetics(session, count: 1)
        let w = try XCTUnwrap(AppTest.controller.panels.showInputSettings(input: 1))
        defer { AppTest.controller.panels.closeAll() }
        XCTAssertEqual(InputSettingsModel.Section.effects.title, "音频效果")
        XCTAssertNil(w.model.effectsBanner, "每路效果已接（102）：输入设置的效果页不再有横幅")

        // 对外文字按实情：不再说"停用的格旁路"（引擎根本不读效果链）
        for lang in ["zh-Hans", "en"] {
            let hint = L10n.string("mixer.busEffectsHint", language: lang)
            XCTAssertFalse(hint.contains("旁路") || hint.lowercased().contains("bypass"), "\(lang)：\(hint)")
        }
        XCTAssertEqual(L10n.string("inputSettings.section.effects", language: "en"), "Audio effects")
    }

    // MARK: 7. "其他命令"止血
    // W5-J（01a N4"N1 落地后并进高级组"）：平铺下拉连同"其他命令"那一项换成了共用的选动作面板，这条用例按新界面改写，判据逐条对应：
    // 不在面板默认列表里的命令（整条替换类）走"高级：手写 JSON"、显示用命令目录的说明；新加的行没有动作就存不了、绝不兜底成 Cut；
    // 打开面板看一眼再关不丢命令；"编辑 JSON…"校验过才写；认得出的命令显示成对应的动作；原样存回。

    func testHotkeys_otherCommandNotRewrittenToCut() throws {
        let other = Command.setTransition(type: .wipe, durationTicks: 30)
        let advanced = Command.setInputSettings(input: 1, settings: InputSettings(audio: InputAudioSettings(gainDb: -3)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5b-hotkeys-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hotkeys.json")
        let table = HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo(key: "g"), action: .command(other), note: "Wipe"),
                                           HotkeyBinding(key: KeyCombo(key: "h"), action: .command(.cut)),
                                           HotkeyBinding(key: KeyCombo(key: "i"), action: .command(advanced))])
        let model = HotkeyEditorModel(table: table, fileURL: url)
        XCTAssertEqual(model.rows[0].action, .command(other), "读进来的命令原样在这一行")

        // 显示：人话，不是 Swift 枚举原文；整条替换类（面板默认不列）用命令目录的说明 + 参数摘要
        let text = HotkeyEditorModel.describe(.command(other))
        XCTAssertTrue(text.contains("Wipe") && text.contains("0.5"), text)
        XCTAssertFalse(text.contains("setTransition(type:"), text)
        let advancedText = HotkeyEditorModel.describe(.command(advanced))
        XCTAssertTrue(advancedText.contains(CommandCatalog.entry(for: .setInputSettings).summary), advancedText)
        XCTAssertFalse(advancedText.contains("setInputSettings(input:"), advancedText)
        XCTAssertEqual(model.summary(of: model.rows[2]), advancedText, "行上的按钮写的就是这句")

        // 打开面板看一眼再关：命令还在；面板定位到这一行现在的动作，原样拼得回来（整条替换类落在"高级：手写 JSON"上）
        let picker = model.picker(for: model.rows[0].id)
        XCTAssertEqual(picker.selectedID, "command.setTransition")
        XCTAssertEqual(picker.builtAction, .command(other))
        XCTAssertEqual(model.rows[0].action, .command(other))
        let advancedPicker = model.picker(for: model.rows[2].id)
        XCTAssertEqual(advancedPicker.selectedID, "json")
        XCTAssertEqual(advancedPicker.builtAction, .command(advanced))

        // 新加的行没有动作：面板里不选就拼不出动作；存不了、报错，绝不悄悄存成 Cut（X10）
        model.addRow(key: "j")
        XCTAssertNil(model.rows[3].action, "没有选就没有动作，不兜底成 Cut")
        XCTAssertNil(model.picker(for: model.rows[3].id).builtAction)
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.errorMessage, "第 4 行还没选动作：点动作按钮选一个")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "存不了就不写文件")
        // 面板的"高级：手写 JSON"：解不出来的 JSON 拼不出动作
        let blank = model.picker(for: model.rows[3].id)
        blank.select("json")
        blank.jsonText = #"{"nope":{}}"#
        XCTAssertNil(blank.builtAction)
        XCTAssertNotNil(blank.jsonError)

        // "编辑 JSON…"：校验过才写进这一行
        XCTAssertFalse(model.applyJSON(model.rows[3].id, #"{"nope":{}}"#))
        XCTAssertNotNil(model.jsonError)
        XCTAssertFalse(model.applyJSON(model.rows[3].id, "不是 JSON"))
        XCTAssertNil(model.rows[3].action, "解不出来：这一行不动")
        XCTAssertTrue(model.applyJSON(model.rows[3].id, #"{"setPreview":{"input":4}}"#))
        XCTAssertNil(model.jsonError)
        XCTAssertEqual(model.rows[3].action, .command(.setPreview(input: 4)))
        XCTAssertEqual(model.picker(for: model.rows[3].id).selectedID, "command.setPreview", "认得出的命令回到对应的动作")
        XCTAssertTrue(model.applyJSON(model.rows[3].id, #"{"setAFV":{"on":true}}"#))
        XCTAssertEqual(model.rows[3].action, .command(.setAFV(on: true)))
        XCTAssertEqual(model.jsonText(for: model.rows[0].id).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: ""),
                       #"{"setTransition":{"durationTicks":30,"type":"wipe"}}"#, "编辑框里是这一行命令的 JSON")
        XCTAssertTrue(model.save(), model.errorMessage ?? "")
        let saved = try HotkeyTable.load(from: url)
        XCTAssertEqual(saved.action(for: KeyCombo(key: "g")), .command(other), "其他命令原样存回，不变成 Cut")
        XCTAssertEqual(saved.action(for: KeyCombo(key: "h")), .command(.cut))
        XCTAssertEqual(saved.action(for: KeyCombo(key: "i")), .command(advanced))
        XCTAssertEqual(saved.action(for: KeyCombo(key: "j")), .command(.setAFV(on: true)))

        // MIDI 映射面板：这类行显示同一句说明、面板定位到同一项
        let midiRow = MIDIMappingModel.Row(trigger: .note(channel: 1, note: 60), action: .action(.command(other)), note: "")
        XCTAssertEqual(MIDIMappingModel.describe(try XCTUnwrap(midiRow.action)), text)
        let midiModel = MIDIMappingModel(table: MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(other)))]),
                                         controller: MIDIController(bus: CommandBus(stateMachine: SwitcherSession.detachedStateMachine()), table: MIDIMapTable(mappings: [])),
                                         fileURL: dir.appendingPathComponent("midi.json"))
        defer { midiModel.stopRefreshing() }
        XCTAssertEqual(midiModel.picker(for: midiModel.rows[0].id).selectedID, "command.setTransition")
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
