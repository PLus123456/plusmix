import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// XML 状态、TALLY 串、ACTS 值：与快照一致（C3 口径）。
final class StatusXMLTests: XCTestCase {
    let fps = FrameRate.fps60
    var config: VMixCompatConfiguration = {
        var c = VMixCompatConfiguration()
        c.enabled = true
        return c
    }()

    func xml(_ state: MixerState, stats: Stats? = nil) throws -> StatusDocument {
        try StatusDocument(StatusXML.document(state: state, frameRate: fps, stats: stats, configuration: config))
    }

    func testC3_xmlStructure_matchesSnapshot() throws {
        let state = TestStates.base()
        let doc = try xml(state)
        XCTAssertEqual(doc.rootName, StatusXML.rootElement)
        XCTAssertEqual(try doc.text("/*/version"), config.reportedVersion)
        XCTAssertEqual(try doc.text("/*/edition"), config.edition)
        XCTAssertEqual(try doc.nodes("/*/inputs/input").count, 4)
        XCTAssertEqual(try doc.input(1, "title"), "机位 1")
        XCTAssertEqual(try doc.input(1, "shortTitle"), "机位 1")
        XCTAssertEqual(try doc.input(1, "number"), "1")
        XCTAssertEqual(try doc.input(1, "key"), InputReference.key(forInput: 1))
        XCTAssertEqual(try doc.input(1, "type"), "Colour", "合成源 → Colour")
        XCTAssertEqual(try doc.input(1, "state"), "Running")
        XCTAssertEqual(try doc.input(1, "muted"), "False")
        XCTAssertEqual(try doc.input(1, "solo"), "False")
        XCTAssertEqual(try doc.input(1, "volume"), "100", "0 dB → 100")
        XCTAssertEqual(try doc.input(1, "audiobusses"), "M")
        XCTAssertEqual(try doc.input(1, "loop"), "False")
        XCTAssertEqual(try doc.text("/*/inputs/input[@number='1']"), "机位 1", "元素文本 = 标题")
        XCTAssertEqual(try doc.text("/*/preview"), "2")
        XCTAssertEqual(try doc.text("/*/active"), "1")
        XCTAssertEqual(try doc.text("/*/fadeToBlack"), "False")
        XCTAssertEqual(try doc.text("/*/recording"), "False")
        XCTAssertEqual(try doc.text("/*/streaming"), "False")
        XCTAssertEqual(try doc.text("/*/external"), "False")
        XCTAssertEqual(try doc.text("/*/playList"), "False")
        XCTAssertEqual(try doc.text("/*/multiCorder"), "False")
        XCTAssertEqual(try doc.text("/*/fullscreen"), "False")
        XCTAssertEqual(try doc.nodes("/*/overlays/overlay").count, 4)
        XCTAssertEqual(try doc.attribute("/*/overlays/overlay[1]", "number"), "1")
        XCTAssertEqual(try doc.text("/*/overlays/overlay[1]"), "", "没输入 = 空元素")
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[1]", "effect"), "Fade")
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[1]", "duration"), "500", "30 拍 @60 = 500 ms")
        XCTAssertEqual(try doc.attribute("/*/audio/master", "volume"), "100")
        XCTAssertEqual(try doc.attribute("/*/audio/master", "muted"), "False")
        XCTAssertEqual(try doc.attribute("/*/audio/master", "headphonesVolume"), "100")
        XCTAssertEqual(try doc.attribute("/*/audio/master", "meterF1"), "0", "没有 stats 时表读数 0")
        XCTAssertEqual(try doc.attribute("/*/audio/busA", "volume"), "100")
        XCTAssertNotNil(try doc.nodes("/*/audio/busB").first)
    }

    func testC3_xmlReflectsOutputsOverlaysTransitionAndAudio() throws {
        var state = TestStates.base()
        state.outputs[0].enabled = true
        state.outputs[1].enabled = true
        state.outputs.append(OutputState(number: 3, kind: .stream, name: "推流 2", settings: OutputSettings(stream: StreamSettings(url: "rtmp://a/b"))))
        state.overlays[0].input = 3
        state.overlays[0].on = true
        state.overlays[0].animProgress = 1
        state.ftb.on = true
        state.ftb.level = 1
        state.transition = TransitionState(type: .wipe, durationTicks: 90)
        state.audio.buses[0].gainDb = -6.0206
        state.audio.buses[0].muted = true
        state.inputs[1].settings.audio.muted = true
        state.inputs[1].settings.audio.gainDb = -24
        state.inputs[1].settings.audio.routing = BusRouting(master: true, busA: true, busB: false, headphones: true)
        state.inputs[1].settings.audio.solo = true
        state.inputs[3].name = "A & \"B\" <C> 'D'"
        let doc = try xml(state)
        XCTAssertEqual(try doc.text("/*/recording"), "True")
        XCTAssertEqual(try doc.text("/*/streaming"), "True")
        XCTAssertEqual(try doc.attribute("/*/streaming", "channel1"), "True", "第 1 路推流")
        XCTAssertEqual(try doc.attribute("/*/streaming", "channel2"), "False", "第 2 路推流没开")
        XCTAssertEqual(try doc.text("/*/overlays/overlay[@number='1']"), "3")
        XCTAssertEqual(try doc.text("/*/fadeToBlack"), "True")
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[1]", "effect"), "Wipe")
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[1]", "duration"), "1500")
        XCTAssertEqual(try doc.attribute("/*/audio/master", "volume"), "50")
        XCTAssertEqual(try doc.attribute("/*/audio/master", "muted"), "True")
        XCTAssertEqual(try doc.input(2, "muted"), "True")
        XCTAssertEqual(try doc.input(2, "solo"), "True")
        XCTAssertEqual(try doc.input(2, "volume"), "6.31", "-24 dB → 6.31%")
        XCTAssertEqual(try doc.input(2, "audiobusses"), "M,A")
        XCTAssertEqual(try doc.input(4, "title"), "A & \"B\" <C> 'D'", "转义后再解析回来一致")
        XCTAssertEqual(try doc.text("/*/inputs/input[@number='4']"), "A & \"B\" <C> 'D'")
        // 表读数来自 Stats（铁律 4：不另算）
        let stats = Stats(ts: 1, tick: .zero, renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                          audio: .init(dropouts: 0, underruns: 0, discontinuities: 0,
                                       meters: .init(buses: [.init(bus: "master", peakDb: [-6.0206, -12.0412], truePeakDb: [-6, -12], lufsM: -20, lufsS: -20, lufsI: -20, lra: 1)],
                                                     inputs: [2: .init(peakDb: [-20, 0])])),
                          rssMb: 1, cpuPct: 1, gpuPct: 1)
        let withMeters = try xml(state, stats: stats)
        XCTAssertEqual(try withMeters.attribute("/*/audio/master", "meterF1"), "0.5")
        XCTAssertEqual(try withMeters.attribute("/*/audio/master", "meterF2"), "0.25")
        XCTAssertEqual(try withMeters.input(2, "meterF1"), "0.1")
        XCTAssertEqual(try withMeters.input(2, "meterF2"), "1")
        XCTAssertEqual(try withMeters.input(1, "meterF1"), "0", "没有读数的输入写 0")
    }

    func testC3_gapsInInputNumbersGetBlankPlaceholders() throws {
        var state = TestStates.base()
        state.inputs = [1, 2, 5].map { InputConfig(number: $0, name: "in\($0)", source: .synthetic(settings: SyntheticSourceSettings())) }
        state.program = 5
        state.preview = 1
        let doc = try xml(state)
        XCTAssertEqual(try doc.nodes("/*/inputs/input").count, 5, "位置 = 编号，缺的位置补占位")
        XCTAssertEqual(try doc.input(3, "type"), "Blank")
        XCTAssertEqual(try doc.input(4, "type"), "Blank")
        XCTAssertEqual(try doc.input(5, "title"), "in5")
        XCTAssertEqual(try doc.nodes("/*/inputs/input").map { ($0 as? XMLElement)?.attribute(forName: "number")?.stringValue }, ["1", "2", "3", "4", "5"])
        XCTAssertEqual(TallyDigits.string(for: state), "20001")
    }

    // MARK: C3：tally 与快照一致

    func testC3_tallyDigitsAndXMLAgreeWithSnapshotTallies() throws {
        var idle = TestStates.base()
        var transition = TestStates.base()
        transition.transition.startTick = Tick(10)
        transition.transition.progress = 0.3
        var overlay = TestStates.base()
        overlay.overlays[1].input = 4
        overlay.overlays[1].on = true
        overlay.overlays[1].animProgress = 1
        var samePVW = TestStates.base()
        samePVW.preview = 1
        var black = TestStates.base()
        black.ftb.on = true
        black.ftb.level = 1
        idle.preview = 3
        for (label, state) in [("idle", idle), ("transition", transition), ("overlay", overlay), ("pgm==pvw", samePVW), ("ftb", black)] {
            let tallies = state.tallies
            let digits = TallyDigits.string(for: state)
            XCTAssertEqual(digits.count, state.inputs.map(\.number).max() ?? 0, label)
            for input in state.inputs {
                let t = tallies[input.number]!
                let digit = digits[digits.index(digits.startIndex, offsetBy: input.number - 1)]
                let expected: Character = t.program ? "1" : (t.preview ? "2" : "0")
                XCTAssertEqual(digit, expected, "\(label) 输入 \(input.number)：TALLY 数字与 MixerState.tally 不一致")
            }
            let doc = try xml(state)
            let active = Int(try doc.text("/*/active") ?? "")!
            let preview = Int(try doc.text("/*/preview") ?? "")!
            XCTAssertEqual(active, state.program, label)
            XCTAssertEqual(preview, state.preview, label)
            let overlayInputs = Set(try doc.nodes("/*/overlays/overlay").compactMap { Int($0.stringValue ?? "") })
            for input in state.inputs {
                let t = tallies[input.number]!
                let fromXML = input.number == active || overlayInputs.contains(input.number)
                if fromXML {
                    XCTAssertTrue(t.program, "\(label) 输入 \(input.number)：XML 说在 PGM，快照说不在")
                } else if t.program {
                    // 唯一允许的差别：转场进行中的 PVW（XML 里没有"转场中"字段，TALLY 数字有）
                    XCTAssertTrue(state.transition.isActive && input.number == state.preview, "\(label) 输入 \(input.number)：快照说在 PGM，XML 说不在")
                }
                XCTAssertEqual(input.number == preview, t.preview, "\(label) 输入 \(input.number)：PVW")
            }
        }
    }

    // MARK: ACTS

    func testC5_activatorValuesAndEvents() throws {
        let state = TestStates.base()
        XCTAssertEqual(try Activators.value(name: "Input", input: nil, state: state), "Input 1 1")
        XCTAssertEqual(try Activators.value(name: "Input", input: 1, state: state), "Input 1 1")
        XCTAssertEqual(try Activators.value(name: "Input", input: 3, state: state), "Input 3 0")
        XCTAssertEqual(try Activators.value(name: "InputPreview", input: nil, state: state), "InputPreview 2 1")
        XCTAssertEqual(try Activators.value(name: "Recording", input: nil, state: state), "Recording 0")
        XCTAssertEqual(try Activators.value(name: "Streaming", input: nil, state: state), "Streaming 0")
        XCTAssertEqual(try Activators.value(name: "FadeToBlack", input: nil, state: state), "FadeToBlack 0")
        XCTAssertEqual(try Activators.value(name: "MasterVolume", input: nil, state: state), "MasterVolume 1")
        XCTAssertEqual(try Activators.value(name: "MasterAudio", input: nil, state: state), "MasterAudio 1", "1 = 有声（没静音）")
        XCTAssertEqual(try Activators.value(name: "BusAAudio", input: nil, state: state), "BusAAudio 1")
        XCTAssertEqual(try Activators.value(name: "BusASolo", input: nil, state: state), "BusASolo 0", "没有总线独听，恒 0")
        XCTAssertEqual(try Activators.value(name: "InputAudio", input: 2, state: state), "InputAudio 2 1")
        XCTAssertEqual(try Activators.value(name: "InputVolume", input: 2, state: state), "InputVolume 2 1")
        XCTAssertEqual(try Activators.value(name: "InputMasterAudio", input: 2, state: state), "InputMasterAudio 2 1")
        XCTAssertEqual(try Activators.value(name: "InputBusAAudio", input: 2, state: state), "InputBusAAudio 2 0")
        XCTAssertEqual(try Activators.value(name: "Overlay1", input: nil, state: state), "Overlay1 0 0", "通道没输入")
        var overlay = state
        overlay.overlays[0].input = 3
        overlay.overlays[0].on = true
        overlay.overlays[0].animProgress = 1
        XCTAssertEqual(try Activators.value(name: "Overlay1", input: nil, state: overlay), "Overlay1 3 1")
        XCTAssertEqual(try Activators.value(name: "Overlay1", input: 4, state: overlay), "Overlay1 4 0")
        XCTAssertThrowsError(try Activators.value(name: "Nope", input: nil, state: state))
        XCTAssertThrowsError(try Activators.value(name: "InputAudio", input: nil, state: state), "要输入号")
        XCTAssertThrowsError(try Activators.value(name: "InputAudio", input: 9, state: state))

        // 事件：前后状态的差
        var after = state
        after.program = 2
        after.preview = 1
        XCTAssertEqual(Activators.events(from: state, to: after), ["Input 1 0", "Input 2 1", "InputPreview 2 0", "InputPreview 1 1"])
        var rec = state
        rec.outputs[0].enabled = true
        XCTAssertEqual(Activators.events(from: state, to: rec), ["Recording 1"])
        var stream = state
        stream.outputs[1].enabled = true
        XCTAssertEqual(Activators.events(from: state, to: stream), ["Streaming 1"])
        var ftb = state
        ftb.ftb.on = true
        XCTAssertEqual(Activators.events(from: state, to: ftb), ["FadeToBlack 1"])
        var mute = state
        mute.inputs[1].settings.audio.muted = true
        XCTAssertEqual(Activators.events(from: state, to: mute), ["InputAudio 2 0"])
        var vol = state
        vol.audio.buses[0].gainDb = -6.0206
        XCTAssertEqual(Activators.events(from: state, to: vol), ["MasterVolume 0.5"])
        var inVol = state
        inVol.inputs[2].settings.audio.gainDb = -20
        XCTAssertEqual(Activators.events(from: state, to: inVol), ["InputVolume 3 0.1"])
        XCTAssertEqual(Activators.events(from: state, to: overlay), ["Overlay1 3 1"])
        var overlayOff = overlay
        overlayOff.overlays[0].on = false
        overlayOff.overlays[0].animProgress = 0
        XCTAssertEqual(Activators.events(from: overlay, to: overlayOff), ["Overlay1 3 0"])
        var busMute = state
        busMute.audio.buses[1].muted = true
        XCTAssertEqual(Activators.events(from: state, to: busMute), ["BusAAudio 0"])
        XCTAssertEqual(Activators.events(from: state, to: state), [])
        var renamed = state
        renamed.inputs[0].name = "x"
        XCTAssertEqual(Activators.events(from: state, to: renamed), [], "改名不是激活器事件")
    }
}
