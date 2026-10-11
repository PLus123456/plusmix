import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// 函数名 → 内部 Command 的映射表（纯函数）。测试 ID：C5（Companion 的模块用到的子集）。
final class FunctionTranslatorTests: XCTestCase {
    let fps = FrameRate.fps60
    let config: VMixCompatConfiguration = {
        var c = VMixCompatConfiguration()
        c.enabled = true
        return c
    }()

    func plan(_ line: String, state: MixerState = TestStates.base()) throws -> [Command] {
        let request = try XCTUnwrap(FunctionRequest(commandLine: line), "解析失败：\(line)")
        return try FunctionTranslator.plan(request, state: state, frameRate: fps, configuration: config).commands
    }

    func error(_ line: String, state: MixerState = TestStates.base()) -> CompatError? {
        guard let request = FunctionRequest(commandLine: line) else { return CompatError(code: .badParameter, message: "parse") }
        do {
            _ = try FunctionTranslator.plan(request, state: state, frameRate: fps, configuration: config)
            return nil
        } catch let e as CompatError {
            return e
        } catch {
            XCTFail("不是 CompatError：\(error)")
            return nil
        }
    }

    // MARK: 请求解析

    func testC5_requestParsing_queryStringDecodingAndCaseInsensitiveKeys() throws {
        let r = try XCTUnwrap(FunctionRequest(commandLine: "SetVolume input=2&VALUE=50&name=%E6%9C%BA%E4%BD%8D%201&plus=a+b"))
        XCTAssertEqual(r.name, "SetVolume")
        XCTAssertEqual(r.parameter("Input"), "2")
        XCTAssertEqual(r.parameter("value"), "50")
        XCTAssertEqual(r.parameter("Name"), "机位 1", "百分号解码")
        XCTAssertEqual(r.parameter("plus"), "a b", "+ 当空格（表单编码）")
        XCTAssertNil(r.parameter("missing"))
        let bare = try XCTUnwrap(FunctionRequest(commandLine: "Cut"))
        XCTAssertEqual(bare.name, "Cut")
        XCTAssertTrue(bare.parameters.isEmpty)
        XCTAssertNil(FunctionRequest(commandLine: "   "), "空函数名不合法")
        let query = FunctionRequest(name: "Fade", queryItems: [("Duration", "1000"), ("Input", "3")])
        XCTAssertEqual(query.parameter("duration"), "1000")
    }

    // MARK: 切换

    func testC5_cutAndFade() throws {
        XCTAssertEqual(try plan("Cut"), [.cut])
        XCTAssertEqual(try plan("Cut Input=3"), [.setPreview(input: 3), .cut], "带 Input 的 Cut：先把它放到 PVW 再切，旧 PGM 进 PVW")
        XCTAssertEqual(try plan("Fade"), [.fade(durationTicks: 30)], "默认 500 ms @60 = 30 拍")
        XCTAssertEqual(try plan("Fade Duration=1000&Input=4"), [.setPreview(input: 4), .fade(durationTicks: 60)])
        XCTAssertEqual(try plan("fade duration=250"), [.fade(durationTicks: 15)], "函数名与参数名都不分大小写")
        XCTAssertEqual(error("Fade Duration=abc")?.code, .badParameter)
        XCTAssertEqual(error("Fade Duration=-5")?.code, .badParameter)
        XCTAssertEqual(try plan("Wipe Duration=500"), [.setTransition(type: .wipe, durationTicks: 30), .autoTransition])
        XCTAssertEqual(try plan("Zoom"), [.setTransition(type: .zoom, durationTicks: 30), .autoTransition])
        XCTAssertEqual(error("Merge")?.code, .notImplemented)
        XCTAssertEqual(error("Stinger1")?.code, .notConfigured, "没配 stinger 输入")
        var withStinger = TestStates.base()
        withStinger.transition.stinger.input = 4
        XCTAssertEqual(try plan("Stinger1", state: withStinger), [.setTransition(type: .stinger, durationTicks: 30), .autoTransition],
                       "没有配好的 Stinger 槽时，照旧用当前那组的 stinger 输入（API 的 setTransitionParams 设的）")
        // 转场槽（W5-M）：Stinger 输入设在槽里（转场列 ▾ 菜单）——Stinger1 = 执行第一个选了输入的 Stinger 槽
        var slotted = TestStates.base()
        slotted.transition.slots[3].stinger.input = 3
        XCTAssertEqual(try plan("Stinger1", state: slotted), [.useTransitionSlot(slot: 4, start: true)], "出厂槽 4 是 Stinger，选了输入就用它")
        slotted.transition.slots[1] = TransitionSlot(type: .stinger, durationTicks: 40, stinger: StingerParams(input: 4, cutAtTick: 10))
        XCTAssertEqual(try plan("Stinger1", state: slotted), [.useTransitionSlot(slot: 2, start: true)], "按槽号找第一个")
        var unset = TestStates.base()
        unset.transition.slots[0] = TransitionSlot(type: .stinger, durationTicks: 30)
        XCTAssertEqual(error("Stinger1", state: unset)?.code, .notConfigured, "Stinger 槽都没选输入")
    }

    func testC5_previewAndProgramSelection() throws {
        XCTAssertEqual(try plan("PreviewInput Input=3"), [.setPreview(input: 3)])
        XCTAssertEqual(try plan("SetPreviewInput Input=3"), [.setPreview(input: 3)], "prompt 里写的别名")
        XCTAssertEqual(try plan("ActiveInput Input=3"), [.setProgram(input: 3)])
        XCTAssertEqual(try plan("CutDirect Input=3"), [.setProgram(input: 3)], "Companion 的 Send Input to Program 发的是 CutDirect")
        XCTAssertEqual(try plan("PreviewInput Input=机位 3"), [.setPreview(input: 3)], "按名字")
        XCTAssertEqual(try plan("PreviewInput Input=\(InputReference.key(forInput: 3))"), [.setPreview(input: 3)], "按 GUID")
        XCTAssertEqual(try plan("PreviewInput Input=0"), [.setPreview(input: 2)], "0 = 当前 PVW")
        XCTAssertEqual(try plan("PreviewInput Input=-1"), [.setPreview(input: 1)], "-1 = 当前 PGM")
        XCTAssertEqual(error("PreviewInput Input=9")?.code, .inputNotFound)
        XCTAssertEqual(error("PreviewInput Input=没有这路")?.code, .inputNotFound)
        XCTAssertEqual(error("PreviewInput")?.code, .badParameter, "缺 Input")
        XCTAssertEqual(try plan("PreviewInputNext"), [.setPreview(input: 3)])
        XCTAssertEqual(try plan("PreviewInputPrevious"), [.setPreview(input: 1)])
        var atEnd = TestStates.base()
        atEnd.preview = 4
        XCTAssertEqual(try plan("PreviewInputNext", state: atEnd), [.setPreview(input: 1)], "到头回绕")
        atEnd.preview = 1
        XCTAssertEqual(try plan("PreviewInputPrevious", state: atEnd), [.setPreview(input: 4)])
    }

    func testC5_transitionSlotAndFader() throws {
        // 转场槽落地（W5-M）：Transition1 = 执行转场 1（原来 = autoTransition，只有一个槽），SetTransitionEffect1 / Duration1 改槽 1
        let s = TestStates.base()
        XCTAssertEqual(try plan("Transition1"), [.useTransitionSlot(slot: 1, start: true)])
        var wipe1 = s.transition.slots[0]
        wipe1.type = .wipe
        XCTAssertEqual(try plan("SetTransitionEffect1 Value=Wipe"), [.setTransitionSlot(slot: 1, config: wipe1)])
        var cut1 = s.transition.slots[0]
        cut1.type = .cut
        XCTAssertEqual(try plan("SetTransitionEffect1 Value=Cut"), [.setTransitionSlot(slot: 1, config: cut1)])
        XCTAssertEqual(error("SetTransitionEffect1 Value=Fly")?.code, .notImplemented)
        var long1 = s.transition.slots[0]
        long1.durationTicks = 60
        XCTAssertEqual(try plan("SetTransitionDuration1 Value=1000"), [.setTransitionSlot(slot: 1, config: long1)])
        XCTAssertEqual(try plan("SetFader Value=255"), [.tbar(progress: 1)])
        XCTAssertEqual(try plan("SetFader Value=0"), [.tbar(progress: 0)])
        let half = try XCTUnwrap(try plan("SetFader Value=128").first)
        guard case .tbar(let p) = half else { return XCTFail("\(half)") }
        XCTAssertEqual(p, 128.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(error("SetFader Value=300")?.code, .badParameter)
        XCTAssertEqual(error("SetFader")?.code, .badParameter)
    }

    /// Transition1–4 = 执行转场 1–4（提案 020 的槽，W5-M）：一条 useTransitionSlot(n, start: true)，一拍内选中并开始；
    /// 转场进行中再发由状态机忽略（"(no change)"，HTTPTests 走一遍）；Stinger 槽没选输入照常执行（与快捷键同口径，只有屏幕上的按钮拦，X18）。
    func testC5_transition2ExecutesSlot() throws {
        for n in 1...4 {
            XCTAssertEqual(try plan("Transition\(n)"), [.useTransitionSlot(slot: n, start: true)], "Transition\(n) = 执行转场 \(n)")
            XCTAssertTrue(FunctionCatalog.implemented.map(\.name).contains("Transition\(n)"), "Transition\(n) 在实现表里")
            XCTAssertFalse(FunctionCatalog.knownUnimplemented.contains("Transition\(n)"), "Transition\(n) 不再列为未实现")
        }
        XCTAssertEqual(try plan("transition2"), [.useTransitionSlot(slot: 2, start: true)], "函数名不分大小写")
        XCTAssertEqual(try FunctionTranslator.plan(XCTUnwrap(FunctionRequest(commandLine: "transition2")), state: TestStates.base(), frameRate: fps,
                                                   configuration: config).name, "Transition2", "应答回显规范写法")
        var busy = TestStates.base()
        busy.transition.startTick = Tick(5)
        busy.transition.progress = 0.3
        XCTAssertEqual(try plan("Transition3", state: busy), [.useTransitionSlot(slot: 3, start: true)], "翻译不看进行中（状态机判，回 no change）")
        XCTAssertEqual(error("Transition5")?.code, .notImplemented, "只有 4 个槽")
        XCTAssertEqual(error("Transition0")?.code, .notImplemented)
    }

    /// SetTransitionEffect1–4 / SetTransitionDuration1–4 = 改转场 n 的效果 / 时长（setTransitionSlot，槽里别的字段原样带上）；
    /// 效果名只收我们有的五种（Cut / Fade / Wipe / Zoom / Stinger），上游别的效果 NotImplemented、谁都没有的名字 BadParameter。
    func testC5_setTransitionEffect3MapsToSlot() throws {
        let s = TestStates.base()
        var zoomToWipe = s.transition.slots[2]
        XCTAssertEqual(zoomToWipe.type, .zoom, "出厂槽 3 = Zoom 1 s")
        zoomToWipe.type = .wipe
        XCTAssertEqual(try plan("SetTransitionEffect3 Value=Wipe"), [.setTransitionSlot(slot: 3, config: zoomToWipe)])
        for (name, type) in [("Cut", TransitionType.cut), ("Fade", .fade), ("zoom", .zoom), ("Stinger", .stinger), ("WIPE", .wipe)] {
            var c = s.transition.slots[2]
            c.type = type
            XCTAssertEqual(try plan("SetTransitionEffect3 Value=\(name)"), [.setTransitionSlot(slot: 3, config: c)], name)
        }
        for upstream in ["Fly", "Merge", "Slide", "CubeZoom", "WipeReverse", "VerticalWipe"] {
            let e = error("SetTransitionEffect3 Value=\(upstream)")
            XCTAssertEqual(e?.code, .notImplemented, upstream)
            XCTAssertTrue(e?.message.contains("SetTransitionEffect3") ?? false, "文案点名函数：\(e?.message ?? "nil")")
        }
        XCTAssertEqual(error("SetTransitionEffect3 Value=Sparkle")?.code, .badParameter, "谁都没有的效果名")
        XCTAssertEqual(error("SetTransitionEffect3")?.code, .badParameter, "缺 Value")
        // 槽里的 Wipe / Stinger 参数、时长原样带上，只换效果
        var custom = TestStates.base()
        custom.transition.slots[2] = TransitionSlot(type: .zoom, durationTicks: 50, wipe: WipeParams(direction: .diagonal, softness: 0.2),
                                                    stinger: StingerParams(input: 3, cutAtTick: 7))
        var expected = custom.transition.slots[2]
        expected.type = .stinger
        XCTAssertEqual(try plan("SetTransitionEffect3 Value=Stinger", state: custom), [.setTransitionSlot(slot: 3, config: expected)])
        // 时长：毫秒按帧率换拍，只改时长
        var slot4 = s.transition.slots[3]
        slot4.durationTicks = 120
        XCTAssertEqual(try plan("SetTransitionDuration4 Value=2000"), [.setTransitionSlot(slot: 4, config: slot4)])
        var slot2 = s.transition.slots[1]
        slot2.durationTicks = 45
        XCTAssertEqual(try plan("SetTransitionDuration2 Value=750"), [.setTransitionSlot(slot: 2, config: slot2)])
        XCTAssertEqual(error("SetTransitionDuration2 Value=-1")?.code, .badParameter)
        XCTAssertEqual(error("SetTransitionDuration2")?.code, .badParameter, "缺 Value")
        // 目录：1–4 都在实现表、不在"已知未实现"；5 起按前缀族算上游有、这里没有
        for n in 1...4 {
            for base in ["SetTransitionEffect", "SetTransitionDuration"] {
                XCTAssertTrue(FunctionCatalog.implemented.map(\.name).contains("\(base)\(n)"), "\(base)\(n)")
                XCTAssertFalse(FunctionCatalog.knownUnimplemented.contains("\(base)\(n)"), "\(base)\(n)")
            }
        }
        XCTAssertEqual(error("SetTransitionEffect5 Value=Fade")?.code, .notImplemented)
        XCTAssertEqual(error("SetTransitionDuration5 Value=500")?.code, .notImplemented)
    }

    /// 转场进行中（T-bar 推到一半也算）带 Input 的 Cut 直接回 NotConfigured，一条都不发：W5-E 之后 setPreview 在转场中被拒，
    /// 而 cut 会把正在进行的那次做完，PGM 落在原来那次的目标、不是点名的那一路（问题单 W5E-w3-control2-compat-cut-input-mid-transition 的 (a)）。
    /// 不带 Input 的 Cut 照旧把当前转场做完；空闲时照旧"先放 PVW 再切"。
    func testC5_cutWithInputDuringTransitionIsRefused() throws {
        var busy = TestStates.base()
        busy.transition.startTick = Tick(10)
        busy.transition.progress = 0.4
        let e = error("Cut Input=3", state: busy)
        XCTAssertEqual(e?.code, .notConfigured)
        XCTAssertEqual(e?.httpStatus, 409)
        XCTAssertTrue(e?.wireText.hasPrefix("NotConfigured: Cut") ?? false, e?.wireText ?? "nil")
        XCTAssertEqual(try plan("Cut", state: busy), [.cut], "不带 Input：照旧把当前转场做完")
        var tbar = TestStates.base()
        tbar.transition.source = .tbar
        tbar.transition.progress = 0.5
        XCTAssertEqual(error("Cut Input=3", state: tbar)?.code, .notConfigured, "T-bar 推到一半也算进行中")
        XCTAssertEqual(try plan("Cut Input=3"), [.setPreview(input: 3), .cut], "空闲时照旧")
        XCTAssertEqual(error("Cut Input=9", state: busy)?.code, .inputNotFound, "输入不存在仍先报输入不存在")
    }

    // MARK: 叠加

    func testC5_overlays() throws {
        XCTAssertEqual(try plan("OverlayInput1 Input=3"), [.overlay(channel: 1, on: true, input: 3)], "关着 → 开并换输入")
        var on = TestStates.base()
        on.overlays[0].input = 3
        on.overlays[0].on = true
        on.overlays[0].animProgress = 1
        XCTAssertEqual(try plan("OverlayInput1 Input=3", state: on), [.overlay(channel: 1, on: false, input: nil)], "同一路已在上面 → 关")
        XCTAssertEqual(try plan("OverlayInput1 Input=4", state: on), [.overlay(channel: 1, on: true, input: 4)], "换另一路 → 保持开并换输入")
        XCTAssertEqual(try plan("OverlayInput1", state: on), [.overlay(channel: 1, on: false, input: nil)], "不带 Input 的开关")
        XCTAssertEqual(error("OverlayInput1")?.code, .notConfigured, "通道没有输入又不给 Input")
        XCTAssertEqual(try plan("OverlayInput2In Input=3"), [.overlay(channel: 2, on: true, input: 3)])
        XCTAssertEqual(try plan("OverlayInput1Out", state: on), [.overlay(channel: 1, on: false, input: nil)])
        XCTAssertEqual(try plan("OverlayInput1Off", state: on), [.overlay(channel: 1, on: false, input: nil)])
        XCTAssertEqual(try plan("OverlayInput1Last", state: on), [.overlay(channel: 1, on: false, input: nil)], "Last = 用通道当前输入开关")
        XCTAssertEqual(try plan("OverlayInput4Off"), [.overlay(channel: 4, on: false, input: nil)], "本来就关也发（reducer 会忽略，回执 applied=false）")
        on.overlays[2].input = 4
        on.overlays[2].on = true
        XCTAssertEqual(try plan("OverlayInputAllOff", state: on), [.overlay(channel: 1, on: false, input: nil), .overlay(channel: 3, on: false, input: nil)], "只关开着的")
        XCTAssertEqual(try plan("OverlayInputAllOff"), [], "全关着：空计划")
        XCTAssertEqual(error("OverlayInput5 Input=1")?.code, .badParameter, "通道 1–4")
        XCTAssertEqual(error("OverlayInput1Zoom")?.code, .notImplemented)
        XCTAssertEqual(error("PreviewOverlayInput1 Input=3")?.code, .notImplemented)
        XCTAssertEqual(error("OverlayInput1 Input=9")?.code, .inputNotFound)
    }

    // MARK: 输出

    func testC5_recordingAndStreaming() throws {
        XCTAssertEqual(try plan("StartRecording"), [.startRecord(output: 1)])
        XCTAssertEqual(try plan("StopRecording"), [.stopRecord(output: 1)])
        XCTAssertEqual(try plan("StartStopRecording"), [.startRecord(output: 1)])
        var recording = TestStates.base()
        recording.outputs[0].enabled = true
        XCTAssertEqual(try plan("StartStopRecording", state: recording), [.stopRecord(output: 1)])
        XCTAssertEqual(try plan("StartStreaming"), [.startStream(output: 2)])
        XCTAssertEqual(try plan("StartStreaming Value=0"), [.startStream(output: 2)], "Value = 第几路推流（0 起）")
        XCTAssertEqual(error("StartStreaming Value=1")?.code, .outputNotFound)
        XCTAssertEqual(try plan("StopStreaming"), [.stopStream(output: 2)])
        XCTAssertEqual(try plan("StartStopStreaming"), [.startStream(output: 2)])
        var streaming = TestStates.base()
        streaming.outputs[1].enabled = true
        XCTAssertEqual(try plan("StartStopStreaming", state: streaming), [.stopStream(output: 2)])
        // 多路推流：Value 选第 k 路；配置里指定的优先于"第一路"
        var two = TestStates.base()
        two.outputs.append(OutputState(number: 5, kind: .stream, name: "推流 2", settings: OutputSettings(stream: StreamSettings(url: "rtmp://a/b"))))
        XCTAssertEqual(try plan("StartStreaming Value=1", state: two), [.startStream(output: 5)])
        var pinned = config
        pinned.streamOutput = 5
        let r = try XCTUnwrap(FunctionRequest(commandLine: "StartStreaming"))
        XCTAssertEqual(try FunctionTranslator.plan(r, state: two, frameRate: fps, configuration: pinned).commands, [.startStream(output: 5)])
        // 没有该类输出
        var none = TestStates.base()
        none.outputs = []
        XCTAssertEqual(error("StartRecording", state: none)?.code, .notConfigured)
        XCTAssertEqual(error("StartStreaming", state: none)?.code, .notConfigured)
        XCTAssertEqual(error("StartExternal")?.code, .notImplemented)
    }

    func testC5_fadeToBlack() throws {
        XCTAssertEqual(try plan("FadeToBlack"), [.ftb(on: true)])
        var black = TestStates.base()
        black.ftb.on = true
        XCTAssertEqual(try plan("FadeToBlack", state: black), [.ftb(on: false)])
    }

    // MARK: 音频

    func testC5_masterVolumeCurve() throws {
        XCTAssertEqual(try plan("SetMasterVolume Value=100"), [.busGain(bus: .master, dB: 0)])
        XCTAssertEqual(try plan("SetMasterVolume Value=0"), [.busGain(bus: .master, dB: -96)], "推子到底 = 增益下限")
        let half = try XCTUnwrap(try plan("SetMasterVolume Value=50").first)
        guard case .busGain(.master, let dB) = half else { return XCTFail("\(half)") }
        XCTAssertEqual(dB, 80 * log10(0.5), accuracy: 1e-9, "推子 f → 幅度 (f/100)^4 → dB")
        XCTAssertEqual(error("SetMasterVolume Value=101")?.code, .badParameter)
        XCTAssertEqual(error("SetMasterVolume")?.code, .badParameter)
        XCTAssertEqual(try plan("SetBusAVolume Value=100"), [.busGain(bus: .busA, dB: 0)])
        XCTAssertEqual(try plan("SetBusBVolume Value=100"), [.busGain(bus: .busB, dB: 0)])
        XCTAssertEqual(try plan("SetHeadphonesVolume Value=100"), [.busGain(bus: .headphones, dB: 0)])
        let input = try XCTUnwrap(try plan("SetVolume Input=2&Value=75").first)
        guard case .audioGain(2, let g) = input else { return XCTFail("\(input)") }
        XCTAssertEqual(g, 80 * log10(0.75), accuracy: 1e-9)
        // 往返：dB → 推子 → dB
        for dB in [-96.0, -60, -24, -6, 0] {
            XCTAssertEqual(VolumeScale.dB(fromFader: VolumeScale.fader(fromDb: dB)), dB, accuracy: 1e-6)
        }
        XCTAssertEqual(VolumeScale.fader(fromDb: 12), 100, "0 dB 以上推子顶格")
        XCTAssertEqual(VolumeScale.amplitudePercent(fromDb: 0), 100)
        XCTAssertEqual(VolumeScale.amplitudePercent(fromDb: -6.0206), 50, accuracy: 0.01)
        XCTAssertEqual(VolumeScale.amplitudePercent(fromDb: 24), 100, "上限 100")
    }

    func testC5_audioToggles() throws {
        XCTAssertEqual(try plan("Audio Input=2"), [.mute(input: 2, on: true)], "Audio = 开关；开着 → 静音")
        var muted = TestStates.base()
        muted.inputs[1].settings.audio.muted = true
        XCTAssertEqual(try plan("Audio Input=2", state: muted), [.mute(input: 2, on: false)])
        XCTAssertEqual(try plan("AudioOn Input=2", state: muted), [.mute(input: 2, on: false)])
        XCTAssertEqual(try plan("AudioOff Input=2"), [.mute(input: 2, on: true)])
        XCTAssertEqual(error("Audio")?.code, .badParameter)
        XCTAssertEqual(try plan("MasterAudio"), [.busMute(bus: .master, on: true)])
        XCTAssertEqual(try plan("MasterAudioON"), [.busMute(bus: .master, on: false)], "Companion 发的是大写 ON")
        XCTAssertEqual(try plan("MasterAudioOff"), [.busMute(bus: .master, on: true)])
        XCTAssertEqual(try plan("BusAAudio"), [.busMute(bus: .busA, on: true)])
        XCTAssertEqual(try plan("BusBAudioOn"), [.busMute(bus: .busB, on: false)])
        XCTAssertEqual(try plan("BusXAudio Value=B"), [.busMute(bus: .busB, on: true)])
        XCTAssertEqual(try plan("BusXAudioOff Value=A"), [.busMute(bus: .busA, on: true)])
        XCTAssertEqual(error("BusXAudio Value=C")?.code, .badParameter, "只有 A / B")
        // 路由：AudioBus Input=n&Value=M|A|B
        let route = try XCTUnwrap(try plan("AudioBus Input=2&Value=A").first)
        guard case .setInputSettings(2, let settings) = route else { return XCTFail("\(route)") }
        XCTAssertTrue(settings.audio.routing.busA)
        XCTAssertTrue(settings.audio.routing.master, "其他路由不动")
        XCTAssertEqual(error("AudioBus Input=2&Value=G")?.code, .badParameter)
        XCTAssertEqual(error("AudioAuto Input=2")?.code, .notImplemented, "AFV 在这里是全局的，不映射")
        // 独听 / 声像 / 改名
        let solo = try XCTUnwrap(try plan("SoloOn Input=3").first)
        guard case .setInputSettings(3, let s2) = solo else { return XCTFail("\(solo)") }
        XCTAssertTrue(s2.audio.solo)
        let pan = try XCTUnwrap(try plan("SetBalance Input=3&Value=-0.5").first)
        guard case .setInputSettings(3, let s3) = pan else { return XCTFail("\(pan)") }
        XCTAssertEqual(s3.audio.pan, -0.5)
        XCTAssertEqual(error("SetBalance Input=3&Value=2")?.code, .badParameter)
        XCTAssertEqual(try plan("SetInputName Input=2&Value=Cam"), [.renameInput(input: 2, name: "Cam")])
    }

    // MARK: 未实现 / 未知

    func testC5_unimplementedFunctionsReturnExplicitErrors() throws {
        for name in ["SetText", "Snapshot", "QuickPlay", "StartExternal", "StartMultiCorder", "SetOutput2", "ReplayPlay", "OverlayInput1Zoom", "AudioAuto"] {
            let e = error("\(name) Input=1")
            XCTAssertEqual(e?.code, .notImplemented, name)
            XCTAssertTrue(e?.message.contains(name) ?? false, "错误文案要点名函数：\(e?.message ?? "nil")")
        }
        let unknown = error("DefinitelyNotAFunction")
        XCTAssertEqual(unknown?.code, .unknownFunction)
        XCTAssertEqual(unknown?.httpStatus, 400)
        XCTAssertEqual(error("SetText")?.httpStatus, 501)
        XCTAssertEqual(error("PreviewInput Input=9")?.httpStatus, 404)
        XCTAssertEqual(error("SetFader Value=999")?.httpStatus, 400)
        XCTAssertTrue(error("SetText")!.wireText.hasPrefix("NotImplemented: "), "TCP 的 ER 文案以错误码开头")
        // 目录：实现表里的每个名字都能翻译（用最小参数），并且不在"已知未实现"表里
        for doc in FunctionCatalog.implemented {
            XCTAssertFalse(FunctionCatalog.knownUnimplemented.contains(doc.name), "\(doc.name) 同时出现在两张表")
        }
        XCTAssertTrue(FunctionCatalog.implemented.map(\.name).contains("Cut"))
        XCTAssertTrue(FunctionCatalog.implemented.map(\.name).contains("OverlayInput1Off"))
        XCTAssertTrue(FunctionCatalog.implemented.map(\.name).contains("SetMasterVolume"))
        // prompt 点名的子集全部在实现表里
        for name in ["Cut", "Fade", "SetPreviewInput", "PreviewInput", "ActiveInput", "OverlayInput1", "OverlayInput2", "OverlayInput3", "OverlayInput4",
                     "OverlayInput1Off", "OverlayInput2Off", "OverlayInput3Off", "OverlayInput4Off", "StartRecording", "StopRecording",
                     "StartStreaming", "StopStreaming", "FadeToBlack", "SetMasterVolume", "Audio", "AudioOn", "AudioOff"] {
            XCTAssertTrue(FunctionCatalog.implemented.map(\.name).contains(name), "prompt 要求的 \(name) 不在实现表里")
        }
    }
}
