// W5-J（prompt 96 交付 2，01a N1 / N3 / N5，04 Q51–Q53）：共用的"选动作"面板——分组 + 搜索 + 我们的动作名 / 一行说明 / API 键名、
// 参数表单按 CommandCatalog / ControlActionKind 的类型化描述生成、"按下时会发什么"、整条替换类默认不列；快捷键表的搜索 / 复制行 / 启用勾；界面动作。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class ActionPickerTests: XCTestCase {
    private func picker(_ context: ActionPickerContext = .hotkey, current: ControlAction? = nil, state: @escaping () -> MixerState?) -> ActionPickerModel {
        ActionPickerModel(context: context, current: current, state: state, defaults: AppTest.controller.defaults)
    }

    /// 默认列表只列面向操作员的命令：整条替换 / 增删类（04 Q51）不在里面，放"高级：手写 JSON"；勾"显示整条替换类"才列出来。
    func testUI_actionPickerListsOnlyOperatorCommandsByDefault() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let p = picker { session.state }
        XCTAssertEqual(p.groups.map(\.title), ["切换", "叠加", "音频", "输出", "输入", "节目", "界面", "全部", "最近用过"])
        p.group = .all
        let listed = p.visibleEntries
        let kinds = Set(listed.compactMap(\.commandKind))
        for kind in CommandKind.allCases where !kind.operatorFacing {
            XCTAssertFalse(kinds.contains(kind), "整条替换类 \(kind) 默认不列")
        }
        for kind in [CommandKind.addInput, .removeInput, .setInputSettings, .setOutputSettings, .loadShow] { XCTAssertFalse(kinds.contains(kind), "Q51：\(kind)") }
        XCTAssertTrue([CommandKind.cut, .setPreview, .setProgram, .autoTransition, .ftb, .overlay, .mute, .busMute, .startRecord, .setOutputEnabled].allSatisfy(kinds.contains))
        XCTAssertFalse(kinds.contains(.fade), "按拍存的 Fade 是旧写法：默认不列（新的按毫秒存，Q52）")
        XCTAssertTrue(listed.contains { $0.id == "action.fadeMs" })
        XCTAssertTrue(listed.contains { $0.id == "json" }, "高级：手写 JSON 一直在")
        XCTAssertTrue(listed.contains { $0.id == "ui.toggleMixer" }, "界面动作进表（Q53）")
        XCTAssertFalse(listed.contains { if case .fader = $0.kind { return true }; return false }, "推杆类只在 CC 时出现")
        // 一项 = 我们的动作名 + 一行说明（命令 = CommandCatalog 的 summary）+ 小字 API 键名
        let setPreview = try XCTUnwrap(p.entry(id: "command.setPreview"))
        XCTAssertEqual(setPreview.title, "选进 PVW")
        XCTAssertEqual(setPreview.summary, CommandCatalog.entry(for: .setPreview).summary)
        XCTAssertEqual(setPreview.apiKey, "setPreview")
        XCTAssertEqual(setPreview.group, .switching)
        let compound = try XCTUnwrap(p.entry(id: "action.previewAndTransition"))
        XCTAssertEqual(compound.title, "选进 PVW 并转场")
        XCTAssertEqual(compound.apiKey, "previewAndTransition → setPreview + autoTransition")
        XCTAssertEqual(try XCTUnwrap(p.entry(id: "action.recordAll")).apiKey, "recordAll → startRecord / stopRecord")
        for entry in p.entries {
            XCTAssertFalse(entry.title.isEmpty || entry.title.contains("actionPicker."), "\(entry.id) 有名字：\(entry.title)")
            XCTAssertFalse(entry.summary.isEmpty || entry.summary.contains("actionPicker."), "\(entry.id) 有说明：\(entry.summary)")
        }
        // 分组：每组只有自己的
        p.group = .overlay
        XCTAssertEqual(Set(p.visibleEntries.map(\.id)), ["command.overlay", "action.toggleOverlay", "action.overlayInput", "action.overlaysOff"])
        p.group = .output
        XCTAssertTrue(p.visibleEntries.contains { $0.id == "action.recordISO" } && p.visibleEntries.contains { $0.id == "action.streamAll" })
        XCTAssertFalse(p.visibleEntries.contains { $0.commandKind == .setOutputSettings })
        // 搜索跨组（动作名 / 说明 / API 键名）
        p.search = "overlayInput"
        XCTAssertEqual(p.visibleEntries.map(\.id), ["action.overlayInput"])
        p.search = "全部"
        XCTAssertTrue(p.visibleEntries.contains { $0.id == "action.overlaysOff" } && p.visibleEntries.contains { $0.id == "action.recordAll" }, p.visibleEntries.map(\.id).description)
        p.search = ""
        // 显示整条替换类：列出来（标"高级"），选中就是手写 JSON（从目录的样例起步）
        p.showsAdvanced = true
        p.group = .all
        XCTAssertTrue(p.visibleEntries.contains { $0.commandKind == .loadShow && $0.advanced })
        p.select("command.setInputSettings")
        XCTAssertEqual(p.builtAction, .command(CommandCatalog.entry(for: .setInputSettings).example))
        // MIDI CC：只有推杆类
        let cc = picker(.midiCC) { session.state }
        XCTAssertEqual(cc.groups, [.fader])
        XCTAssertEqual(cc.visibleEntries.map(\.id), ["fader.tbar", "fader.inputGain", "fader.busGain"])
        XCTAssertEqual(ActionGroup.fader.title, "推杆类")
    }

    /// 参数表单按类型化描述生成：输入 = "编号 · 名字" + 当前 PVW / 当前 PGM，时长按秒，通道 1–4，输出按类型过滤，总线四选一，开 / 关 / 切换；
    /// 表单拼出的就是那条动作（同 hotkeys.json 的写法）；预览"按下时会发什么"按当前快照解析；打开时定位到当前动作；用过的进"最近用过"。
    func testUI_actionPickerBuildsActionsFromTypedFields() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.addOutput(config: OutputState(number: 7, kind: .ndi, name: "NDI 节目", settings: OutputSettings(source: .program))))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.preview == 2 && session.state.output(7) != nil })
        AppTest.controller.defaults.removeObject(forKey: ActionPickerModel.recentsKey)
        let p = picker { session.state }

        // 选进 PVW 并转场：默认输入 = 当前 PVW（2）；改成 3 → 动作与预览
        p.select("action.previewAndTransition")
        XCTAssertEqual(p.selected?.fields.map(\.type), [.inputRef])
        XCTAssertEqual(p.values["input"], .input(.number(2)), "默认用当前 PVW 那一路")
        p.set("input", .input(.number(3)))
        XCTAssertEqual(p.builtAction, .previewAndTransition(input: 3))
        XCTAssertEqual(p.preview, ["setPreview（input: 3）", "autoTransition"], "按下时会发什么：两条、按顺序")
        p.set("input", .input(.program))
        XCTAssertEqual(p.builtAction, .previewAndTransition(input: .program))
        XCTAssertEqual(p.preview, ["setPreview（input: 1）", "autoTransition"], "当前 PGM 按下时才解析")
        XCTAssertEqual(ActionText.summary(.previewAndTransition(input: 3), state: session.state), "选进 PVW 并转场 · 输入 3「合成 3」")

        // Fade：时长按秒（0.5 / 1 / 2 + 自定义），存成毫秒（Q52）
        p.select("action.fadeMs")
        XCTAssertEqual(p.values["durationMs"], .seconds(1))
        p.set("durationMs", .seconds(0.75))
        XCTAssertEqual(p.builtAction, .fadeMs(durationMs: 750))
        XCTAssertEqual(p.preview, ["fade（durationTicks: 45）"], "60p 下 0.75 s = 45 拍")
        XCTAssertEqual(DurationField.presets, [0.5, 1, 2])

        // 叠加 N 换成输入 X 并开：通道 1–4
        p.select("action.overlayInput")
        XCTAssertEqual(p.selected?.fields.map(\.type), [.overlayChannel, .inputRef])
        p.set("channel", .int(4))
        p.set("input", .input(.number(1)))
        XCTAssertEqual(p.builtAction, .overlayInput(channel: 4, input: 1))
        XCTAssertEqual(p.preview, ["overlay（channel: 4, input: 1, on: true）"])

        // 输出开关：只列 NDI / 外部显示 / 虚拟摄像头 / 多画面，默认第一路合适的；三段
        p.select("action.outputSwitch")
        XCTAssertEqual(p.selected?.fields.first?.type, .output(kinds: [.ndi, .externalDisplay, .virtualCamera, .multiview]))
        XCTAssertEqual(p.values["output"], .int(7), "录制输出不在候选里，默认是 NDI 那一路")
        XCTAssertEqual(p.values["mode"], .string("toggle"))
        p.set("mode", .string("on"))
        XCTAssertEqual(p.builtAction, .outputSwitch(output: 7, mode: .on))

        // 总线静音：四选一 + 三段
        p.select("action.busMuteSwitch")
        p.set("bus", .int(Bus.busB.rawValue))
        XCTAssertEqual(p.builtAction, .busMuteSwitch(bus: .busB, mode: .toggle))
        XCTAssertEqual(p.preview, ["busMute（bus: 2, on: true）"])

        // 命令：setTransition 的时长按秒、按节目帧率换拍
        p.select("command.setTransition")
        p.set("type", .string("wipe"))
        p.set("durationTicks", .seconds(2))
        XCTAssertEqual(p.builtAction, .command(.setTransition(type: .wipe, durationTicks: 120)))

        // 界面动作：不发命令
        p.select("ui.toggleMixer")
        XCTAssertEqual(p.builtAction, .ui(name: "toggleMixer"))
        XCTAssertEqual(p.preview, ["界面动作：只在本机的 App 里做，不进命令总线"])

        // 解析不出：预览照实说
        p.select("action.overlayInput")
        p.set("input", .input(.number(9)))
        XCTAssertEqual(p.builtAction, .overlayInput(channel: 1, input: 9))
        XCTAssertEqual(p.preview, ["现在按下不会发命令（引用的输入 / 输出不在，或没有要变的）"])

        // 打开时定位到当前动作（参数也读回来）；按拍存的旧 Fade 照列（只在它是当前动作时）
        let located = picker(current: .busRoute(input: .preview, bus: .headphones, mode: .on)) { session.state }
        XCTAssertEqual(located.selectedID, "action.busRoute")
        XCTAssertEqual(located.group, .audio)
        XCTAssertEqual(located.values["input"], .input(.preview))
        XCTAssertEqual(located.values["bus"], .int(Bus.headphones.rawValue))
        XCTAssertEqual(located.builtAction, .busRoute(input: .preview, bus: .headphones, mode: .on))
        let legacy = picker(current: .command(.fade(durationTicks: 30))) { session.state }
        XCTAssertEqual(legacy.selectedID, "command.fade")
        XCTAssertTrue(legacy.visibleEntries.contains { $0.id == "command.fade" }, "旧写法是当前动作时照列")
        XCTAssertEqual(legacy.builtAction, .command(.fade(durationTicks: 30)), "不动它就原样拼回（不偷偷换成毫秒）")
        XCTAssertEqual(ActionText.summary(.command(.fade(durationTicks: 30))), "Fade 30 拍（旧写法：时长跟着节目帧率变）")

        // 最近用过
        p.select("action.overlaysOff")
        p.noteUsed()
        p.select("action.recordAll")
        p.noteUsed()
        p.group = .recent
        XCTAssertEqual(p.visibleEntries.map(\.id), ["action.recordAll", "action.overlaysOff"])

        // MIDI 音符：同一份动作；CC：推杆类的参数
        let cc = picker(.midiCC) { session.state }
        cc.select("fader.inputGain")
        XCTAssertEqual(cc.builtMIDIAction, .inputGain(input: 2, minDb: -60, maxDb: 12))
        cc.select("fader.tbar")
        XCTAssertEqual(cc.builtMIDIAction, .tbar)
        let note = ActionPickerModel(context: .midiNote, current: MIDIAction.action(.overlaysOff), state: { session.state }, defaults: AppTest.controller.defaults)
        XCTAssertEqual(note.selectedID, "action.overlaysOff")
        XCTAssertEqual(note.builtMIDIAction, .action(.overlaysOff))
    }

    /// W5-M（prompt 100 交付 3）：执行转场 n / 选中转场 n（不执行）进"切换"组；槽号控件列出四个槽现在的效果与时长；
    /// setInputAudio 的总线路由有了勾选控件（P5-2 留下的空视图；可选，不填 = 不动）。
    func testUI_actionPickerTransitionSlotsAndBusRouting() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let p = picker { session.state }
        p.group = .switching
        let ids = p.visibleEntries.map(\.id)
        XCTAssertTrue(ids.contains("action.transitionSlot") && ids.contains("action.selectTransitionSlot"), "两类槽动作在“切换”组：\(ids)")
        let run = try XCTUnwrap(p.entry(id: "action.transitionSlot"))
        XCTAssertEqual(run.title, "执行转场")
        XCTAssertEqual(run.apiKey, "transitionSlot → useTransitionSlot")
        XCTAssertEqual(try XCTUnwrap(p.entry(id: "action.selectTransitionSlot")).title, "选中转场（不执行）")
        p.select("action.transitionSlot")
        XCTAssertEqual(p.selected?.fields.map(\.type), [.transitionSlot])
        XCTAssertEqual(p.values["slot"], .int(1), "默认转场 1")
        p.set("slot", .int(3))
        XCTAssertEqual(p.builtAction, .transitionSlot(slot: 3))
        XCTAssertEqual(p.preview, ["useTransitionSlot（slot: 3, start: true）"], "按下时发一条：选中并开始")
        XCTAssertEqual(ActionText.summary(.transitionSlot(slot: 3), state: session.state), "执行转场 · 转场 3（Zoom 1 秒）")
        XCTAssertEqual(ActionText.summary(.transitionSlot(slot: 3)), "执行转场 · 转场 3", "没有快照时只写槽号")
        p.select("action.selectTransitionSlot")
        p.set("slot", .int(2))
        XCTAssertEqual(p.builtAction, .selectTransitionSlot(slot: 2))
        XCTAssertEqual(p.preview, ["useTransitionSlot（slot: 2, start: false）"])
        // 槽号控件的选项：四个槽现在的效果与时长（原来借的是叠加通道的"1 2 3 4"四段）
        XCTAssertEqual(ActionCatalog.slotChoices(state: session.state).map(\.title),
                       ["转场 1 · Fade 0.5 秒", "转场 2 · Wipe → 1 秒", "转场 3 · Zoom 1 秒", "转场 4 · Stinger（未设）"])
        XCTAssertEqual(ActionCatalog.slotChoices(state: nil).map(\.title), ["转场 1", "转场 2", "转场 3", "转场 4"])
        // 打开时定位到当前动作；包一条 useTransitionSlot 命令的也照常定位
        let located = picker(current: .selectTransitionSlot(slot: 4)) { session.state }
        XCTAssertEqual(located.selectedID, "action.selectTransitionSlot")
        XCTAssertEqual(located.group, .switching)
        XCTAssertEqual(located.values["slot"], .int(4))
        XCTAssertEqual(located.builtAction, .selectTransitionSlot(slot: 4))
        let wrapped = picker(current: .command(.useTransitionSlot(slot: 2, start: true))) { session.state }
        XCTAssertEqual(wrapped.selectedID, "command.useTransitionSlot")
        XCTAssertEqual(wrapped.values["slot"], .int(2))
        XCTAssertEqual(wrapped.builtAction, .command(.useTransitionSlot(slot: 2, start: true)))

        // setInputAudio：总线路由四个勾，可选（不填 = 不动）
        p.select("command.setInputAudio")
        XCTAssertEqual(p.selected?.group, .audio)
        XCTAssertEqual(p.selected?.fields.map(\.type), [.input(allowsBlack: false), .onOff, .onOff, .busRouting])
        p.set("input", .input(.number(2)))
        XCTAssertEqual(p.builtAction, .command(.setInputAudio(input: 2)), "三个可选参数都不填 = 都不动")
        p.set("routing", .routing(BusRouting(master: true, busA: true)))
        XCTAssertEqual(p.builtAction, .command(.setInputAudio(input: 2, routing: BusRouting(master: true, busA: true))))
        XCTAssertEqual(p.preview.count, 1)
        XCTAssertTrue(p.preview[0].hasPrefix("setInputAudio"), p.preview[0])
        let routingField = try XCTUnwrap(p.selected?.fields.last)
        XCTAssertEqual(ActionText.value(routingField, .routing(BusRouting(master: true, busA: true)), state: session.state), "Master + Bus A")
        XCTAssertEqual(ActionText.value(routingField, .routing(BusRouting(master: false)), state: session.state), "不送任何总线")
        p.values["routing"] = nil
        XCTAssertEqual(p.builtAction, .command(.setInputAudio(input: 2)), "清掉路由 = 不动")
        // 读回：路由与独听
        let audio = picker(current: .command(.setInputAudio(input: 1, solo: true, routing: BusRouting(master: false, busB: true)))) { session.state }
        XCTAssertEqual(audio.selectedID, "command.setInputAudio")
        XCTAssertEqual(audio.values["routing"], .routing(BusRouting(master: false, busB: true)))
        XCTAssertEqual(audio.values["solo"], .bool(true))
        XCTAssertEqual(audio.builtAction, .command(.setInputAudio(input: 1, solo: true, routing: BusRouting(master: false, busB: true))), "原样拼回")
    }

    /// 快捷键表（N5）：每行"启用"勾（停用的行存进表、不派发）、复制行（键空着）、搜索；行上的动作是一句话摘要；动作没选存不了。
    func testUI_hotkeyTableSearchDuplicateAndEnable() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let panels = controller.panels
        defer {
            AppTest.dismissConfirmations()
            panels.closeAll()
            try? controller.applyHotkeyTable(.default)
            try? HotkeyTable.default.save(to: controller.hotkeyFileURL)
        }
        let model = panels.showHotkeyEditor().model
        model.resetToDefault()
        XCTAssertTrue(model.save())
        // 行上的摘要：我们的说法
        XCTAssertEqual(model.summary(of: model.rows[0]), "选进 PVW · 输入 1「合成 1」")
        let overlayRow = try XCTUnwrap(model.rows.first { $0.action == .toggleOverlay(channel: 2) })
        XCTAssertEqual(model.summary(of: overlayRow), "叠加开关 · 通道 2")
        // 搜索：键、摘要、备注
        model.search = "⌃2"
        XCTAssertEqual(model.visibleRows.map(\.id), [overlayRow.id])
        model.search = "叠加"
        XCTAssertEqual(model.visibleRows.count, 4)
        model.search = ""
        XCTAssertEqual(model.visibleRows.count, model.rows.count)
        // 复制行：插在下面、键空着、动作照抄；空键存不了
        let copy = try XCTUnwrap(model.duplicateRow(overlayRow.id))
        let index = try XCTUnwrap(model.rows.firstIndex { $0.id == copy })
        XCTAssertEqual(model.rows[index - 1].id, overlayRow.id)
        XCTAssertEqual(model.rows[index].keyText, "")
        XCTAssertEqual(model.rows[index].action, .toggleOverlay(channel: 2))
        XCTAssertFalse(model.save(), "键空着存不了")
        model.setKey(copy, "alt+shift+2")
        // 停用：存进表（enabled = false），派发器不认这个键
        model.setEnabled(copy, false)
        XCTAssertTrue(model.save(), model.errorMessage ?? "")
        let saved = try HotkeyTable.load(from: controller.hotkeyFileURL)
        let binding = try XCTUnwrap(saved.bindings.first { $0.key == KeyCombo("alt+shift+2") })
        XCTAssertFalse(binding.enabled)
        XCTAssertNil(session.control.hotkeys.table.action(for: try XCTUnwrap(KeyCombo("alt+shift+2"))), "停用的行不派发")
        // 停用的行和别的行同键不算冲突；启用了就冲突
        model.setKey(copy, "ctrl+2")
        XCTAssertTrue(model.conflicts.isEmpty)
        model.setEnabled(copy, true)
        XCTAssertEqual(model.conflicts.count, 1)
        XCTAssertFalse(model.save())
        model.revert()
        XCTAssertFalse(model.isDirty)
        // 新行要选动作；选了（面板拼出来的）才存
        model.addRow(key: "k")
        XCTAssertEqual(model.summary(of: model.rows.last!), "选择动作…")
        XCTAssertFalse(model.save())
        let p = model.picker(for: model.rows.last!.id)
        p.select("action.recordAll")
        model.setAction(model.rows.last!.id, try XCTUnwrap(p.builtAction))
        XCTAssertTrue(model.save(), model.errorMessage ?? "")
        XCTAssertEqual(session.control.hotkeys.table.action(for: KeyCombo(key: "k")), .recordAll(mode: .toggle))
    }

    /// 界面动作（Q53）：绑在快捷键上，只在 App 里派发——按下去调音台收起 / 展开，不进命令总线。
    func testHotkeys_uiActionTogglesMixerFromKeyboard() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        defer { try? controller.applyHotkeyTable(.default) }
        var table = HotkeyTable.default
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "m"), action: .ui(name: UIAction.toggleMixer.rawValue)))
        try controller.applyHotkeyTable(table)
        XCTAssertTrue(wc.isMixerPanelVisible)
        let before = session.control.bus.lastSequence
        AppTest.press("m", keyCode: 46)
        XCTAssertTrue(AppTest.waitUntil(2) { !wc.isMixerPanelVisible }, "按 M 收起调音台")
        AppTest.press("m", keyCode: 46)
        XCTAssertTrue(AppTest.waitUntil(2) { wc.isMixerPanelVisible }, "再按展开")
        XCTAssertEqual(session.control.bus.lastSequence, before, "界面动作不进命令总线")
        // 认不出的名字（手写的表）：状态行提示，不崩
        wc.perform(uiAction: "nope")
    }
}
