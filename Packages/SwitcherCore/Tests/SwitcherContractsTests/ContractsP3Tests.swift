import XCTest
@testable import SwitcherContracts

/// P3（提案 007 / 008 / 009 / 010 / 012 / 013 + 每路 AFV 开关）新加的字段 / case：
/// 缺键解码给默认值、老节目文件语义不变、过渡键一次性搬进正式字段、命令键名快照。
final class ContractsP3Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }

    /// 仓库根（Tests/SwitcherContractsTests/ → Tests/ → SwitcherCore/ → Packages/ → 根）。
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    // MARK: 007 AudioState

    func testP3_007_audioStateAlignmentAndMonitorPoint() throws {
        XCTAssertEqual(AudioState.jsonKeys, ["buses", "afv", "monitorMode", "alignmentFrames", "monitorPoint"])
        let a = AudioState()
        XCTAssertEqual(a.alignmentFrames, 2048)
        XCTAssertEqual(a.monitorPoint, .preDelayLine)
        // 往返
        var custom = a
        custom.alignmentFrames = 512
        custom.monitorPoint = .postDelayLine
        XCTAssertEqual(try JSONDecoder().decode(AudioState.self, from: try sortedEncoder.encode(custom)), custom)
        // 老快照缺键 → 默认值
        let old = #"{"afv":true,"buses":[{"bus":0,"effects":[],"gainDb":0,"muted":false},{"bus":1,"effects":[],"gainDb":0,"muted":false},{"bus":2,"effects":[],"gainDb":0,"muted":false},{"bus":3,"effects":[],"gainDb":0,"muted":false}],"monitorMode":"afl"}"#
        let back = try JSONDecoder().decode(AudioState.self, from: Data(old.utf8))
        XCTAssertEqual(back.alignmentFrames, AudioState.defaultAlignmentFrames)
        XCTAssertEqual(back.monitorPoint, .preDelayLine)
        XCTAssertTrue(back.afv)
        // 写出总是写全
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(back)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(AudioState.jsonKeys))
    }

    // MARK: 008 InputSource

    func testP3_008_inputSourceDeckLinkAndNDIParameters() throws {
        // 新形态往返
        let dl = InputSource.decklink(deviceID: "peid:42", connection: .opticalSDI)
        XCTAssertEqual(String(decoding: try sortedEncoder.encode(dl), as: UTF8.self), #"{"decklink":{"connection":"opticalSDI","deviceID":"peid:42"}}"#)
        XCTAssertEqual(try JSONDecoder().decode(InputSource.self, from: try sortedEncoder.encode(dl)), dl)
        let ndi = InputSource.ndi(sourceName: "STUDIO (A)", bandwidth: .lowest, jitterBufferFrames: 2)
        XCTAssertEqual(String(decoding: try sortedEncoder.encode(ndi), as: UTF8.self),
                       #"{"ndi":{"bandwidth":"lowest","jitterBufferFrames":2,"sourceName":"STUDIO (A)"}}"#)
        XCTAssertEqual(try JSONDecoder().decode(InputSource.self, from: try sortedEncoder.encode(ndi)), ndi)

        // 老形态：缺键按默认解
        let oldNDI = try JSONDecoder().decode(InputSource.self, from: Data(#"{"ndi":{"sourceName":"x"}}"#.utf8))
        XCTAssertEqual(oldNDI, .ndi(sourceName: "x", bandwidth: .highest, jitterBufferFrames: 1))
        let oldDL = try JSONDecoder().decode(InputSource.self, from: Data(#"{"decklink":{"deviceID":"DeckLink Mini#0"}}"#.utf8))
        XCTAssertEqual(oldDL, .decklink(deviceID: "DeckLink Mini#0", connection: nil))
        // connection nil 不写键（老文件读进来再写出去形态不变）
        XCTAssertEqual(String(decoding: try sortedEncoder.encode(oldDL), as: UTF8.self), #"{"decklink":{"deviceID":"DeckLink Mini#0"}}"#)

        // 其它 case 的 JSON 形态一个字节不变（键名快照）
        let unchanged: [(InputSource, String)] = [
            (.camera(uniqueID: "0x1234"), #"{"camera":{"uniqueID":"0x1234"}}"#),
            (.screen(target: .display(id: 1), frameRate: .fps30, captureAudio: true),
             #"{"screen":{"captureAudio":true,"frameRate":{"denominator":1,"numerator":30},"target":{"display":{"id":1}}}}"#),
            (.file(path: "/a.mov", endAction: .loop, rate: 1), #"{"file":{"endAction":"loop","path":"/a.mov","rate":1}}"#),
            (.image(path: "/a.png"), #"{"image":{"path":"/a.png"}}"#),
            (.audio(deviceUID: "uid"), #"{"audio":{"deviceUID":"uid"}}"#),
        ]
        for (source, json) in unchanged {
            XCTAssertEqual(String(decoding: try sortedEncoder.encode(source), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(InputSource.self, from: Data(json.utf8)), source)
        }
        // synthetic 只对往返，形态里有整个设置结构
        let syn = InputSource.synthetic(settings: SyntheticSourceSettings())
        XCTAssertEqual(try JSONDecoder().decode(InputSource.self, from: try sortedEncoder.encode(syn)), syn)
        // 认不出的 case 仍然抛错
        XCTAssertThrowsError(try JSONDecoder().decode(InputSource.self, from: Data(#"{"nope":{}}"#.utf8)))
        // kind 由 source 推出
        XCTAssertEqual(dl.kind, .decklink)
        XCTAssertEqual(ndi.kind, .ndi)
    }

    // MARK: 每路 AFV 开关

    func testP3_inputAudioSettingsAFVDefaultsToTrue() throws {
        XCTAssertEqual(InputAudioSettings.jsonKeys, ["routing", "gainDb", "muted", "solo", "pan", "delayMs", "afv"])
        XCTAssertTrue(InputAudioSettings().afv)
        let old = #"{"delayMs":0,"gainDb":0,"muted":false,"pan":0,"routing":{"busA":false,"busB":false,"headphones":false,"master":true},"solo":false}"#
        let back = try JSONDecoder().decode(InputAudioSettings.self, from: Data(old.utf8))
        XCTAssertTrue(back.afv, "没有 afv 键的老文件按 true 解（= 加这一位之前的行为）")
        XCTAssertEqual(back, InputAudioSettings())
        var off = InputAudioSettings()
        off.afv = false
        XCTAssertEqual(try JSONDecoder().decode(InputAudioSettings.self, from: try sortedEncoder.encode(off)), off)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(off)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(InputAudioSettings.jsonKeys), "写出总是写全")
        // clamped() 不碰 afv
        var settings = InputSettings()
        settings.audio.afv = false
        XCTAssertFalse(settings.clamped().audio.afv)
    }

    // MARK: 010 叠加装饰 / 多画面布局

    func testP3_010_overlayDecorationAndMultiviewFields() throws {
        XCTAssertEqual(OverlayState.jsonKeys, ["input", "on", "rect", "animProgress", "animation", "startTick", "border", "anchor", "previewOn"])
        XCTAssertEqual(OverlayAnimation.jsonKeys, ["kind", "durationTicks", "slideFrom"])
        // 默认值
        let o = OverlayState()
        XCTAssertNil(o.border)
        XCTAssertEqual(o.anchor, .center)
        XCTAssertFalse(o.previewOn)
        XCTAssertNil(OverlayAnimation().slideFrom)
        // 老 Show 的叠加：缺键按默认解
        let old = #"{"animProgress":1,"animation":{"durationTicks":20,"kind":"slide"},"input":4,"on":true,"rect":{"height":0.15,"width":0.9,"x":0.05,"y":0.8}}"#
        let back = try JSONDecoder().decode(OverlayState.self, from: Data(old.utf8))
        XCTAssertNil(back.border)
        XCTAssertEqual(back.anchor, .center)
        XCTAssertFalse(back.previewOn)
        XCTAssertNil(back.animation.slideFrom)
        XCTAssertEqual(back.input, 4)
        XCTAssertEqual(back.animation.kind, .slide)
        // 往返
        var full = back
        full.border = OverlayBorder(width: 0.01, color: RGB8(red: 1, green: 2, blue: 3))
        full.anchor = .topRight
        full.previewOn = true
        full.animation.slideFrom = .top
        XCTAssertEqual(try JSONDecoder().decode(OverlayState.self, from: try sortedEncoder.encode(full)), full)

        // 多画面布局：缺键的对象也能解
        XCTAssertEqual(MultiviewLayoutSettings.jsonKeys, ["preset", "custom", "safeArea", "meters"])
        let partial = try JSONDecoder().decode(MultiviewLayoutSettings.self, from: Data(#"{"safeArea":true}"#.utf8))
        XCTAssertEqual(partial.preset, MultiviewLayoutSettings.defaultPreset)
        XCTAssertTrue(partial.safeArea)
        XCTAssertFalse(partial.meters)
        XCTAssertTrue(partial.custom.isEmpty)
        let mv = MultiviewLayoutSettings(preset: "3x3", custom: [MultiviewCell(source: .input(number: 3), rect: .bottomRightQuarter)], safeArea: true, meters: true)
        XCTAssertEqual(try JSONDecoder().decode(MultiviewLayoutSettings.self, from: try sortedEncoder.encode(mv)), mv)
        // OutputSettings 的两个新字段缺省为 nil
        let os = try JSONDecoder().decode(OutputSettings.self, from: Data(#"{"extra":{},"source":{"program":{}}}"#.utf8))
        XCTAssertNil(os.multiview)
        XCTAssertNil(os.display)
    }

    /// 锚点的归一化位置（缩放动画绕它缩）。
    func testP3_010_overlayAnchorUnitPoints() {
        XCTAssertEqual(OverlayAnchor.allCases.count, 9)
        XCTAssertEqual(OverlayAnchor.center.unitPoint.u, 0.5)
        XCTAssertEqual(OverlayAnchor.center.unitPoint.v, 0.5)
        XCTAssertEqual(OverlayAnchor.topLeft.unitPoint.u, 0)
        XCTAssertEqual(OverlayAnchor.topLeft.unitPoint.v, 0)
        XCTAssertEqual(OverlayAnchor.bottomRight.unitPoint.u, 1)
        XCTAssertEqual(OverlayAnchor.bottomRight.unitPoint.v, 1)
        XCTAssertEqual(OverlayAnchor.top.unitPoint.u, 0.5)
        XCTAssertEqual(OverlayAnchor.top.unitPoint.v, 0)
    }

    // MARK: 013 显示类输出

    func testP3_013_displayEntryAndDisplaySettings() throws {
        XCTAssertEqual(DisplayOutputSettings.jsonKeys, ["displayID", "fallbackToMain"])
        XCTAssertFalse(DisplayOutputSettings().fallbackToMain, "提案 015：默认不退回主显示器（与 ExternalDisplaySpec 一致）")
        XCTAssertNil(DisplayOutputSettings().displayID)
        let d = DisplayOutputSettings(displayID: 7, fallbackToMain: false)
        XCTAssertEqual(String(decoding: try sortedEncoder.encode(d), as: UTF8.self), #"{"displayID":7,"fallbackToMain":false}"#)
        XCTAssertEqual(try JSONDecoder().decode(DisplayOutputSettings.self, from: try sortedEncoder.encode(d)), d)
        // fallbackToMain 缺键 = false（提案 015）；显式 true 照解
        XCTAssertFalse(try JSONDecoder().decode(DisplayOutputSettings.self, from: Data(#"{"displayID":3}"#.utf8)).fallbackToMain)
        XCTAssertTrue(try JSONDecoder().decode(DisplayOutputSettings.self, from: Data(#"{"displayID":3,"fallbackToMain":true}"#.utf8)).fallbackToMain)

        let e = Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 36_000, dropped: 0, state: "presenting")
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(e), as: UTF8.self),
                       #"{"dropped":0,"frames":36000,"kind":"externalDisplay","output":3,"state":"presenting"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.DisplayEntry.self, from: Data(#"{"kind":"monitor","output":0}"#.utf8)),
                       Stats.DisplayEntry(output: 0, kind: "monitor"))
        XCTAssertEqual(Stats.DisplayEntry.kinds, ["externalDisplay", "virtualCamera", "multiviewWindow", "monitor"])
        XCTAssertTrue(Stats.DisplayEntry.states.contains(e.state))
    }

    // MARK: 命令键名快照（27 → 33）

    func testP3_012_commandCaseCountAndJsonShapes() throws {
        XCTAssertEqual(Samples.commandCaseCount, 33)
        XCTAssertEqual(Set(Samples.commands().map(Samples.caseName(of:))).count, 33)
        func json(_ c: Command) throws -> String { String(decoding: try sortedEncoder.encode(c), as: UTF8.self) }
        XCTAssertEqual(try json(.setMonitorMode(mode: .pfl)), #"{"setMonitorMode":{"mode":"pfl"}}"#)
        XCTAssertEqual(try json(.setBusEffects(bus: .busA, effects: [])), #"{"setBusEffects":{"bus":1,"effects":[]}}"#)
        XCTAssertEqual(try json(.setOutputEnabled(output: 3, on: true)), #"{"setOutputEnabled":{"on":true,"output":3}}"#)
        XCTAssertEqual(try json(.renameOutput(output: 3, name: "大屏")), #"{"renameOutput":{"name":"大屏","output":3}}"#)
        XCTAssertEqual(try json(.setInputSource(input: 1, source: .image(path: "/a.png"))),
                       #"{"setInputSource":{"input":1,"source":{"image":{"path":"/a.png"}}}}"#)
        XCTAssertEqual(try json(.setOverlayDecoration(channel: 2, border: nil, anchor: .center, previewOn: false)),
                       #"{"setOverlayDecoration":{"anchor":"center","channel":2,"previewOn":false}}"#)
        XCTAssertEqual(try json(.setOverlayDecoration(channel: 2, border: OverlayBorder(width: 0.006, color: RGB8(red: 255, green: 255, blue: 255)),
                                                      anchor: .bottomLeft, previewOn: true)),
                       #"{"setOverlayDecoration":{"anchor":"bottomLeft","border":{"color":{"blue":255,"green":255,"red":255},"width":0.006},"channel":2,"previewOn":true}}"#)
        // 老命令的形态一个字节不变
        XCTAssertEqual(try json(.setOverlay(channel: 1, rect: .full, animation: OverlayAnimation(kind: .fade, durationTicks: 15))),
                       #"{"setOverlay":{"animation":{"durationTicks":15,"kind":"fade"},"channel":1,"rect":{"height":1,"width":1,"x":0,"y":0}}}"#)
    }

    // MARK: 老节目文件

    /// `scenarios/g3-show.json`（P2 时代）与 P3 改写前的 `scenarios/g4-show.json` 都能解，语义不变。
    func testP3_oldShowFilesStillLoadWithSameSemantics() throws {
        let g3 = Self.repoRoot.appendingPathComponent("scenarios/g3-show.json")
        let show = try Show.load(from: try Data(contentsOf: g3))
        XCTAssertEqual(show.schemaVersion, 1)
        XCTAssertEqual(show.audio.alignmentFrames, AudioState.defaultAlignmentFrames)
        XCTAssertEqual(show.audio.monitorPoint, .preDelayLine)
        XCTAssertTrue(show.inputs.allSatisfy { $0.settings.audio.afv }, "老文件每路都参与 AFV")
        XCTAssertTrue(show.mixer.overlays.allSatisfy { $0.border == nil && $0.anchor == .center && !$0.previewOn })
        XCTAssertNoThrow(try show.makeState().validate())

        // P3 改写前的 g4：多画面布局在过渡键 extra["layout"] 里，load 之后搬进正式字段
        let legacy = try Show.load(from: try Data(contentsOf: Self.fixtures.appendingPathComponent("g4-show-before-p3.json")))
        let mv = try XCTUnwrap(legacy.outputs.first { $0.kind == .multiview })
        XCTAssertNil(mv.settings.extra[MultiviewLayoutSettings.legacyExtraKey], "过渡键搬完就清掉")
        let layout = try XCTUnwrap(mv.settings.multiview)
        XCTAssertTrue(layout.safeArea)
        XCTAssertTrue(layout.meters)
        XCTAssertEqual(layout.custom.count, 10, "PVW + PGM + 8 路输入格")
        XCTAssertEqual(layout.custom[0].source, .preview)
        XCTAssertEqual(layout.custom[1].source, .program)
        XCTAssertEqual(layout.custom[2].source, .input(number: 1))
        XCTAssertEqual(layout.custom[0].rect, NormalizedRect(x: 0.005, y: 0.005, width: 0.4925, height: 0.4925))

        // 与 P3 之后重新生成的 g4-show.json 逐格相同（改写前后多画面布局不变）
        let current = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent("scenarios/g4-show.json")))
        let currentMV = try XCTUnwrap(current.outputs.first { $0.kind == .multiview }?.settings.multiview)
        XCTAssertEqual(currentMV, layout, "g4 的多画面布局改写成正式字段前后完全一致")
        // 其余部分也不变（除了新字段的默认值）
        XCTAssertEqual(current.inputs.map(\.source), legacy.inputs.map(\.source))
        XCTAssertEqual(current.mixer.overlays, legacy.mixer.overlays)
        XCTAssertEqual(current.audio, legacy.audio)
    }

    /// 过渡键 → 正式字段的一次性搬迁（提案 010 / 013）：幂等、正式字段优先、搬完清键。
    func testP3_migratingLegacyKeysIsIdempotentAndPrefersOfficialFields() throws {
        var state = MixerState(format: .hd1080p60)
        state.inputs = [InputConfig(number: 1, name: "画中画", source: .image(path: "/a.png"),
                                    settings: {
                                        var s = InputSettings()
                                        s.effects = [EffectSlot(id: "parametricEQ"),
                                                     EffectSlot(id: OverlayBorder.legacyEffectID, params: ["width": 0.02, "color": .array([1, 2, 3])])]
                                        return s
                                    }())]
        state.overlays[0].input = 1
        state.outputs = [
            OutputState(number: 1, kind: .multiview, name: "多画面",
                        settings: OutputSettings(source: .multiview, extra: [MultiviewLayoutSettings.legacyExtraKey: .string("3x3")])),
            OutputState(number: 2, kind: .externalDisplay, name: "外屏",
                        settings: OutputSettings(source: .program,
                                                 extra: [DisplayOutputSettings.legacyDisplayIDKey: .number(9),
                                                         DisplayOutputSettings.legacyFallbackKey: .bool(true)])),
        ]
        let migrated = Show(name: "旧", state: state).migratingLegacyKeys()
        XCTAssertEqual(migrated.outputs[0].settings.multiview?.preset, "3x3")
        XCTAssertNil(migrated.outputs[0].settings.extra[MultiviewLayoutSettings.legacyExtraKey])
        XCTAssertEqual(migrated.outputs[1].settings.display, DisplayOutputSettings(displayID: 9, fallbackToMain: true))
        XCTAssertNil(migrated.outputs[1].settings.extra[DisplayOutputSettings.legacyDisplayIDKey])
        XCTAssertNil(migrated.outputs[1].settings.extra[DisplayOutputSettings.legacyFallbackKey])
        // 边框：搬进用到这路输入的叠加通道，效果格清掉，别的效果格留着
        XCTAssertEqual(migrated.mixer.overlays[0].border, OverlayBorder(width: 0.02, color: RGB8(red: 1, green: 2, blue: 3)))
        XCTAssertEqual(migrated.inputs[0].settings.effects.map(\.id), ["parametricEQ"])
        // 幂等
        XCTAssertEqual(migrated.migratingLegacyKeys(), migrated)

        // 正式字段已有值时不被过渡键覆盖
        var mixed = state
        mixed.outputs[0].settings.multiview = MultiviewLayoutSettings(preset: "4x4")
        mixed.outputs[1].settings.display = DisplayOutputSettings(displayID: 1, fallbackToMain: false)
        let kept = Show(name: "混", state: mixed).migratingLegacyKeys()
        XCTAssertEqual(kept.outputs[0].settings.multiview?.preset, "4x4")
        XCTAssertEqual(kept.outputs[1].settings.display, DisplayOutputSettings(displayID: 1, fallbackToMain: false))

        // 非有限 / 越界的数不会崩（JSON 解不出 NaN，但内存里的 JSONValue 可以带）
        var junk = state
        junk.inputs[0].settings.effects = [EffectSlot(id: OverlayBorder.legacyEffectID,
                                                      params: ["width": .number(.nan), "color": .array([.number(.infinity), -5, 999])])]
        junk.outputs[0].settings.extra[MultiviewLayoutSettings.legacyExtraKey] =
            .object(["cells": .array([.object(["source": .number(1e20), "rect": .object(["x": 0, "y": 0, "width": 1, "height": 1])])])])
        let hardened = Show(name: "脏", state: junk).migratingLegacyKeys()
        XCTAssertEqual(hardened.mixer.overlays[0].border?.color, RGB8(red: 0, green: 0, blue: 255), "非有限的分量给 0，越界的钳住")
        XCTAssertEqual(hardened.mixer.overlays[0].border?.width, OverlayBorder.defaultWidth, "NaN 宽度当没给")
        XCTAssertEqual(hardened.outputs[0].settings.multiview?.custom, [], "编号超出范围的格子忽略（不崩）")

        // 没有叠加通道用那路输入时，效果格留着（渲染器的后备路径还认它）
        var unused = state
        unused.overlays[0].input = nil
        let untouched = Show(name: "没用到", state: unused).migratingLegacyKeys()
        XCTAssertEqual(untouched.inputs[0].settings.effects.map(\.id), ["parametricEQ", OverlayBorder.legacyEffectID])
        XCTAssertNil(untouched.mixer.overlays[0].border)
    }

    /// 老 stats.jsonl 每行仍能解（display 缺键 = 空数组）：仓库里留档的 W2 状态行文件 + 本工作树 `.build/gate*/` 里跑过的 gate 输出。
    func testP3_oldStatsLinesStillParse() throws {
        let fm = FileManager.default
        var files: [URL] = []
        // 留档的（跟仓库走，任何机器上都在）
        let artifacts = Self.repoRoot.appendingPathComponent("App/Tests/Artifacts")
        if let e = fm.enumerator(at: artifacts, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "jsonl" { files.append(url) }
        }
        // 本工作树跑过 gate 才有的
        for gate in ["gate2", "gate3", "gate4"] {
            let dir = Self.repoRoot.appendingPathComponent(".build/\(gate)")
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" { files.append(url) }
        }
        guard !files.isEmpty else { throw XCTSkip("BLOCKED-数据：本机没有留存的老 stats.jsonl") }
        var lines = 0
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = try Stats.parse(line: String(line))
                XCTAssertEqual(s.display, [], "老行没有 display 键 → 空数组：\(url.lastPathComponent)")
                lines += 1
            }
        }
        XCTAssertGreaterThan(lines, 0)
        print("P3：\(files.count) 份老 stats.jsonl、\(lines) 行全部可解")
    }
}
