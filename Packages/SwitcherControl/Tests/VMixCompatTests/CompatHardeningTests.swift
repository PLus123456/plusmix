import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// W2-C4（prompt 116）：Codex 2026-10-13 审查的 D02 / D03——兼容层拿外面送进来的参数把整个进程弄崩（Swift trap，`CompatCore.execute` 的 do/catch 捕不了）。
/// 每条先按审查的触发条件复现（修前独立进程 SIGTRAP），再钉住修后的应答：错误码 + 文案、一条命令都不发、服务照常应答。
final class CompatHardeningTests: XCTestCase {
    let fps = FrameRate.fps60
    let config: VMixCompatConfiguration = {
        var c = VMixCompatConfiguration()
        c.enabled = true
        return c
    }()

    func plan(_ line: String, state: MixerState) throws -> [Command] {
        let request = try XCTUnwrap(FunctionRequest(commandLine: line), "解析失败：\(line)")
        return try FunctionTranslator.plan(request, state: state, frameRate: fps, configuration: config).commands
    }

    /// 翻译出错给错误；翻译成功（不该成功）给 nil 并记下计划。
    func error(_ line: String, state: MixerState, file: StaticString = #filePath, line number: UInt = #line) -> CompatError? {
        guard let request = FunctionRequest(commandLine: line) else {
            XCTFail("解析失败：\(line)", file: file, line: number)
            return nil
        }
        do {
            let p = try FunctionTranslator.plan(request, state: state, frameRate: fps, configuration: config)
            XCTFail("\(line) 应回错误，实际翻译成 \(p.commands)", file: file, line: number)
            return nil
        } catch {
            return error   // typed throws：就是 CompatError
        }
    }

    /// 三种"Input=0 / -1 落空"的状态：空节目（审查原样的 `MixerState()`）、有输入但 PVW / PGM 是黑场、PVW / PGM 指着已经不在的输入
    /// （`MixerState.validate` 不查引用，节目文件 / 删输入的时序都可能留下悬空编号）。
    var emptyStates: [(String, MixerState)] {
        var black = TestStates.base()
        black.program = MixerState.noInput
        black.preview = MixerState.noInput
        var dangling = TestStates.base()
        dangling.program = 8
        dangling.preview = 7
        return [("空节目", MixerState()), ("PVW / PGM 黑场", black), ("PVW / PGM 悬空", dangling)]
    }

    /// 兼容层里所有按 Input 取输入的函数（FunctionTranslator 过了一遍：切换 / PVW / PGM / 改名 / 音量 / 静音 / 路由 / 独听 / 声像 / 叠加）。
    /// 后面是这个函数要的别的参数。
    static let inputFunctions: [(String, String)] = [
        ("Cut", ""), ("Fade", ""), ("Wipe", "&Duration=250"), ("Zoom", ""),
        ("PreviewInput", ""), ("SetPreviewInput", ""), ("ActiveInput", ""), ("CutDirect", ""), ("SetInputName", "&Value=x"),
        ("SetVolume", "&Value=50"),
        ("OverlayInput1", ""), ("OverlayInput2In", ""), ("OverlayInput3Out", ""), ("OverlayInput4Off", ""), ("OverlayInput1Last", ""),
        // 审查复现崩的四组：Audio* / AudioBus* / Solo* / SetBalance（修前 state.input(input)! 解出 nil）
        ("Audio", ""), ("AudioOn", ""), ("AudioOff", ""),
        ("AudioBus", "&Value=A"), ("AudioBusOn", "&Value=M"), ("AudioBusOff", "&Value=B"),
        ("Solo", ""), ("SoloOn", ""), ("SoloOff", ""),
        ("SetBalance", "&Value=0"),
    ]

    // MARK: D02

    /// D02：Input=0（当前 PVW）/ -1（当前 PGM）落空时一律 InputNotFound（HTTP 404），文案说明是哪一个落空；普通不存在的编号（99）照旧。
    /// 修前：InputReference 把它解成 noInput = 0（或悬空编号）交给翻译器，四组音频动作 `state.input(input)!` 强制解包 → 整个进程 SIGTRAP；
    /// 切换类把 0 当黑场发出去、叠加 / 改名 / 音量交给总线拒（回 400 Rejected，原因是"输入 0 不存在"）。
    func testD02_inputZeroOrMinusOneOnEmptyPreviewOrProgramIsInputNotFound() throws {
        for (label, state) in emptyStates {
            for (function, extra) in Self.inputFunctions {
                for ref in ["0", "-1", "99"] {
                    let line = "\(function) Input=\(ref)\(extra)"
                    let e = error(line, state: state)
                    XCTAssertEqual(e?.code, .inputNotFound, "\(label)：\(line) → \(e?.wireText ?? "nil")")
                    XCTAssertEqual(e?.httpStatus, 404, "\(label)：\(line)")
                    if ref == "0" { XCTAssertTrue(e?.message.contains("preview") ?? false, "\(label)：\(line) 文案点明是当前 PVW：\(e?.message ?? "nil")") }
                    if ref == "-1" { XCTAssertTrue(e?.message.contains("program") ?? false, "\(label)：\(line) 文案点明是当前 PGM：\(e?.message ?? "nil")") }
                }
            }
        }
        // 审查报告原样的四条 + 控制组
        for line in ["Audio Input=0", "Solo Input=-1", "SetBalance Input=0&Value=0", "AudioBus Input=0&Value=A", "Audio Input=99"] {
            XCTAssertEqual(error(line, state: MixerState())?.code, .inputNotFound, line)
        }
        // PVW / PGM 是真输入：0 / -1 照常解成它（老口径不变）
        let s = TestStates.base()
        XCTAssertEqual(try plan("Audio Input=0", state: s), [.mute(input: 2, on: true)], "0 = 当前 PVW（2）")
        XCTAssertEqual(try plan("Solo Input=-1", state: s).count, 1, "-1 = 当前 PGM（1）")
        XCTAssertEqual(try plan("Cut Input=0", state: s), [.setPreview(input: 2), .cut])
        XCTAssertEqual(try plan("ActiveInput Input=-1", state: s), [.setProgram(input: 1)])
        // 不带 Input 的 Cut / Fade 照旧（PVW 黑场也照切，Input= 才要求点名一路真输入）
        XCTAssertEqual(try plan("Cut", state: MixerState()), [.cut])
        XCTAssertEqual(try plan("Fade", state: MixerState()), [.fade(durationTicks: 30)])
    }

    /// D02 经真服务走一遍（审查的触发方式：HTTP `/api/?Function=Audio&Input=0`、TCP `FUNCTION Audio Input=0`）：空节目里四组音频动作都回 404 InputNotFound、
    /// 一条命令都不进总线、服务照常应答（修前第一条请求就把 xctest 进程带走）。
    func testD02_http_tcp_emptyShowAudioFunctionsAnswerInputNotFound() async throws {
        let f = try await CompatFixture.start(state: MixerState())
        defer { Task { await f.stop() } }
        let before = f.bus.lastSequence
        for query in ["Function=Audio&Input=0", "Function=AudioOn&Input=0", "Function=AudioOff&Input=-1", "Function=Solo&Input=-1",
                      "Function=SoloOn&Input=0", "Function=AudioBus&Input=0&Value=A", "Function=SetBalance&Input=0&Value=0",
                      "Function=SetVolume&Input=-1&Value=50", "Function=Audio&Input=99"] {
            let r = try await get(f.httpBase, "/api/?\(query)")
            XCTAssertEqual(r.status, 404, "\(query)：\(r.body)")
            XCTAssertTrue(r.body.hasPrefix("InputNotFound: "), "\(query)：\(r.body)")
        }
        XCTAssertEqual(f.bus.lastSequence, before, "一条命令都没进总线")
        let c = try LineClient(port: f.tcpPort)
        _ = try c.readLine()
        try c.send("FUNCTION Audio Input=0")
        let line = try XCTUnwrap(try c.readLine())
        XCTAssertTrue(line.hasPrefix("FUNCTION ER InputNotFound: "), line)
        try c.send("PING")
        XCTAssertEqual(try c.readLine(), "PING OK PONG", "TCP 会话还在")
        let xml = try await get(f.httpBase, "/api")
        XCTAssertEqual(xml.status, 200, "服务照常应答")
        XCTAssertEqual(f.server.counters.functionErrors, 10)
    }

    // MARK: D03

    /// D03：毫秒参数（Fade / Wipe / Zoom 的 Duration、SetTransitionDuration1–4 的 Value）只收有限、0 ≤ v ≤ 3 600 000（1 小时）的数，
    /// 换成拍用可失败的整数转换；越界 / 非数 / 无穷 → BadParameter（HTTP 400），一条命令都不发。500 ms @60 = 30 拍照旧。
    /// 修前：1e300 过了 isFinite 检查，`Int((ms / 1000 * fps).rounded())` 越过 Int.max → SIGTRAP。
    func testD03_durationMillisecondsMustBeRepresentable() throws {
        let s = TestStates.base()
        XCTAssertEqual(try plan("Fade Duration=500", state: s), [.fade(durationTicks: 30)], "控制组：500 ms = 30 拍")
        XCTAssertEqual(try plan("Fade Duration=0", state: s), [.fade(durationTicks: 0)], "0 ms 合法（= 切）")
        XCTAssertEqual(try plan("Fade Duration=3600000", state: s), [.fade(durationTicks: 216_000)], "上限 1 小时 = 216 000 拍")
        XCTAssertEqual(try plan("Fade Duration=1e3", state: s), [.fade(durationTicks: 60)], "科学计数法照收")
        var slot1 = s.transition.slots[0]
        slot1.durationTicks = 216_000
        XCTAssertEqual(try plan("SetTransitionDuration1 Value=3600000", state: s), [.setTransitionSlot(slot: 1, config: slot1)])
        let bad = ["3600000.6", "3600001", "-1", "-0.6", "nan", "NaN", "inf", "-inf", "1e309", "1e300", "9.3e18", "abc"]
        for value in bad {
            for line in ["Fade Duration=\(value)", "Wipe Duration=\(value)", "Zoom Duration=\(value)&Input=3",
                         "SetTransitionDuration1 Value=\(value)", "SetTransitionDuration2 Value=\(value)",
                         "SetTransitionDuration3 Value=\(value)", "SetTransitionDuration4 Value=\(value)"] {
                let e = error(line, state: s)
                XCTAssertEqual(e?.code, .badParameter, "\(line) → \(e?.wireText ?? "nil")")
                XCTAssertEqual(e?.httpStatus, 400, line)
                XCTAssertTrue(e?.message.contains("3600000") ?? false, "文案给出可收范围：\(e?.message ?? "nil")")
            }
        }
        // 帧率高也不溢出：240 fps 的上限
        let request = try XCTUnwrap(FunctionRequest(commandLine: "Fade Duration=3600000"))
        XCTAssertEqual(try FunctionTranslator.plan(request, state: s, frameRate: FrameRate(240), configuration: config).commands,
                       [.fade(durationTicks: 864_000)])
    }

    /// D03 经真服务走一遍（审查的触发方式：HTTP `Function=Fade&Duration=1e300`、`SetTransitionDuration1&Value=1e300`）：回 400 BadParameter、状态不变、服务照常应答。
    func testD03_http_hugeDurationAnswersBadParameter() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let before = f.bus.lastSequence
        for query in ["Function=Fade&Duration=1e300", "Function=SetTransitionDuration1&Value=1e300", "Function=Wipe&Duration=1e300",
                      "Function=Fade&Duration=NaN", "Function=Fade&Duration=-1"] {
            let r = try await get(f.httpBase, "/api/?\(query)")
            XCTAssertEqual(r.status, 400, "\(query)：\(r.body)")
            XCTAssertTrue(r.body.hasPrefix("BadParameter: "), "\(query)：\(r.body)")
        }
        XCTAssertEqual(f.bus.lastSequence, before, "一条命令都没进总线")
        let state = await f.stateMachine.state
        XCTAssertEqual(state.transition.slots[0].durationTicks, TestStates.base().transition.slots[0].durationTicks, "槽 1 时长没被改")
        let ok = try await get(f.httpBase, "/api/?Function=SetTransitionDuration1&Value=500")
        XCTAssertEqual(ok.status, 200, "控制组照常：\(ok.body)")
        let xml = try await get(f.httpBase, "/api")
        XCTAssertEqual(xml.status, 200)
        XCTAssertEqual(try StatusDocument(xml.body).attribute("/*/transitions/transition[1]", "duration"), "500")
    }

    /// D03 的反方向（过 VMixCompat 时顺带查出来的同类转换）：XML 状态把槽的拍数换成毫秒，`Int((ticks × 1000 / fps).rounded())` 对主 API 送进来的
    /// 超大 durationTicks（校验器只拒负数）同样越过 Int.max → 每 250 ms 轮询一次 XML 的 Companion 一连上就崩。现在毫秒封顶在 Int.max、文档照常生成。
    func testD03_statusXMLSaturatesHugeSlotDuration() throws {
        var s = TestStates.base()
        s.transition.slots[0].durationTicks = Int.max
        s.transition.slots[1].durationTicks = Int.max / 16   // 拍数本身合法，× 1000 / 60 才越过 Int.max（> 5.5e17 拍就越）
        s.transition.slots[2].durationTicks = 90
        let xml = StatusXML.document(state: s, frameRate: fps, stats: nil, configuration: config)
        let doc = try StatusDocument(xml)
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[1]", "duration"), String(Int.max), "封顶，不崩")
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[2]", "duration"), String(Int.max), "换成毫秒才越界的也封顶")
        XCTAssertEqual(try doc.attribute("/*/transitions/transition[3]", "duration"), "1500", "正常值照旧：90 拍 @60 = 1500 ms")
        var bare = TestStates.base()
        bare.transition.slots = []
        bare.transition.durationTicks = Int.max
        XCTAssertNoThrow(try StatusDocument(StatusXML.document(state: bare, frameRate: fps, stats: nil, configuration: config)), "没有槽时写当前那组，同样封顶")
    }

    // MARK: 辅助

    func get(_ base: URL, _ pathAndQuery: String) async throws -> (status: Int, body: String) {
        let url = try XCTUnwrap(URL(string: base.absoluteString + pathAndQuery), pathAndQuery)
        let (data, resp) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self))
    }
}
