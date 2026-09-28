// W3-E6（prompt 84）：App 起会话的顺序——慢活（控制层、引擎预热）在定 t0 之前做完，节目时钟不再起在 t0 之后
// （W1-B3 定位的"启动第一秒停顿"：App 先定 t0 = now + 300 ms 再做 0.7 s 的 control.start，reports/w1-core-3.md §1.1）。
//
// 冷启动的代价在 control.start 的 MIDI 那一步：进程里第一次连 MIDIServer ≈ 0.58–0.59 s（本会话量：真 App 五次 582–592 ms、测试宿主启动时 587 ms；
// 同一进程之后 0.2 ms，别的进程正连着 MIDIServer 时新进程也只要 12 ms）。所以测试宿主里只有启动时那个会话赶得上真冷启动：
//   - testW3E6_launchSession_realColdStart_clockNotLate 读的就是它（AppController.firstStartReport）；
//   - testW3E6_sessionStart_clockNotLateAfterColdStart 在之后的会话上用 ControlRuntime.midiColdStartForTesting 按量到的值模拟这一步
//     （同样在主线程上同步卡住，与 MIDIHost.shared 第一次建锚客户端一样），其余全是真的：replaceSession → 8 路合成源 → 状态行 Stats。
// 都写成同步用例：async 测试体在主队列的 dispatch 块里跑，AppTest.pump 的嵌套 run loop 排不空主队列，引擎启动的 main actor 续体回不来
// （ReleaseTests.R7 的注释）；异步的部分用 Task + 轮询盒子。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class StartupOrderTests: XCTestCase {
    /// 进程里第一次连 MIDIServer 的代价（本会话量的 582–592 ms 取整；热的 0.2–13 ms）。
    static let midiColdStart: TimeInterval = 0.58

    /// 交付 1：真 App 会话"第一次起"（control.start 冷启动）之后，引擎的 clockStartLag ≤ 20 ms、头 2 秒 missed_render ≤ 2、各路 drop 0。
    /// 节目 = W1-B3 在真 App 里量的 m0 那 8 路合成源（30 fps 两路、一路带音频，60 fps 六路），走 AppController.replaceSession（主窗口绑着）。
    /// 修前（定 t0 之后才起控制层）：起晚 ≈ 定 t0 之后的 输入 + 控制层 + 音频 − 300 ms，missed_render = ⌊起晚 / 16.7 ms⌋，
    /// 这段时间 3 格帧槽挤掉的帧算 drop（真 App：起晚 491–507 ms、missed 29–30、drop 11–12 / 28–29）。
    func testW3E6_sessionStart_clockNotLateAfterColdStart() throws {
        _ = try AppTest.runningSession()   // 等启动时的 replaceSession 完成（它进行中时再调会被 replacing 挡掉）
        let controller = AppTest.controller
        var show = controller.documents.emptyShow(name: "w3e6-cold-start")
        show.inputs = (1...8).map { n in
            AppTest.syntheticConfig(number: n, frameRate: n <= 2 ? .fps30 : .fps60, gray: UInt8(40 + 20 * n), audio: n == 1)
        }
        show.mixer.program = 1
        show.mixer.preview = 2
        ControlRuntime.midiColdStartForTesting = Self.midiColdStart
        defer { ControlRuntime.midiColdStartForTesting = nil }
        let done = AppTest.expectationBox()
        Task { await controller.replaceSession(show: show); done.value = true }
        guard AppTest.waitUntil(30, { done.value && controller.session?.isRunning == true }) else {
            XCTFail("节目没起来：\(String(describing: controller.lastError))")
            return
        }
        ControlRuntime.midiColdStartForTesting = nil
        let session = try XCTUnwrap(controller.session)
        final class Rows { var stats: [Stats] = [] }
        let rows = Rows()
        let token = session.observeStats { rows.stats.append($0) }
        defer { token.invalidate() }
        XCTAssertTrue(AppTest.waitUntil(8) { rows.stats.count >= 2 }, "起引擎后 2 秒内应有两行 Stats")

        let lag = session.engine.clockStartLag.milliseconds
        print("W3E6 冷启动会话：起步 \(String(describing: session.startReport))")
        for (i, s) in rows.stats.prefix(2).enumerated() {
            let drops = s.perInput.keys.sorted().map { "\($0):\(s.perInput[$0]!.drop)" }.joined(separator: " ")
            print("W3E6 第 \(i + 1) 行：tick \(s.tick.rawValue) missed_render \(s.missedRender) jitter_ms \(String(format: "%.3f", s.jitterMs)) drop [\(drops)]")
        }
        XCTAssertLessThanOrEqual(lag, 20, "时钟起在 t0 之后 \(String(format: "%.1f", lag)) ms：定 t0 之后做的事吃掉了提前量（\(String(describing: session.startReport))）")
        guard rows.stats.count >= 2 else { return }
        let second = rows.stats[1]
        XCTAssertLessThanOrEqual(second.missedRender, 2, "头 2 秒 missed_render")
        XCTAssertEqual(second.perInput.keys.sorted(), Array(1...8), "8 路都该在 Stats 里")
        for n in second.perInput.keys.sorted() {
            XCTAssertEqual(second.perInput[n]!.drop, 0, "输入 \(n) 头 2 秒的 drop")
        }
    }

    /// 真的冷启动：测试宿主启动时的那个会话（AppController.launch → replaceSession，进程里第一次 control.start）。
    /// 修前：控制层 609 ms（MIDI 587 ms）排在定 t0 之后 → 时钟起晚 405 ms（本会话第一次探针）。
    /// 别的进程正连着 MIDIServer（音频软件、另一个 PlusMix……）时这一步本来就是热的，修前也可能不红；修后冷热都应准时。
    func testW3E6_launchSession_realColdStart_clockNotLate() throws {
        _ = try AppTest.runningSession()
        let controller = AppTest.controller
        XCTAssertTrue(AppTest.waitUntil(5) { controller.firstStartReport != nil }, "启动时的会话应留下起步记录")
        let report = try XCTUnwrap(controller.firstStartReport)
        print("W3E6 启动时的会话：起步 \(report)")
        XCTAssertLessThanOrEqual(report.clockStartLagMs, 20,
                                 "启动时的会话时钟起在 t0 之后 \(String(format: "%.1f", report.clockStartLagMs)) ms（控制层 \(String(format: "%.1f", report.controlMs)) ms）")
    }

    /// 停与起对称：起到一半就停（退出 App 时第一个会话还在起控制层）——stop 要等 start 停下来，再把已经起的部分按停的顺序收掉：
    /// 时钟没起、预热过的渲染器 / 状态机线程放掉了、控制层（API / MIDI / 推送源）停了、音频引擎没在跑、输入一个都不剩。
    /// 修前 stop 看 isRunning == false 就直接返回，start 接着把引擎、音频、输入全起起来，会话在控制器之外空转。
    func testW3E6_stopDuringStart_leavesNothingRunning() throws {
        _ = try AppTest.runningSession()
        let controller = AppTest.controller
        let old = controller.session
        let errorBefore = controller.lastError.map { "\($0)" }
        var show = controller.documents.emptyShow(name: "w3e6-stop-during-start")
        show.inputs = [AppTest.syntheticConfig(number: 1, frameRate: .fps60, gray: 90, audio: true)]
        show.mixer.program = 1
        let replaced = AppTest.expectationBox()
        Task { await controller.replaceSession(show: show); replaced.value = true }
        // 新会话一出现（start 正在起控制层、还没定 t0）就退出
        guard AppTest.waitUntil(15, { controller.session != nil && controller.session !== old }) else {
            XCTFail("新会话没建出来")
            return
        }
        let session = try XCTUnwrap(controller.session)
        XCTAssertFalse(session.isRunning, "这时 start 应还在起控制层")
        let stopped = AppTest.expectationBox()
        Task { await controller.shutdown(); stopped.value = true }
        let finished = AppTest.waitUntil(20) { replaced.value && stopped.value }
        defer {
            // 修前那个会话会在控制器之外跑起来：先停掉它，再给后面的用例换回一个跑着的会话
            let restored = AppTest.expectationBox()
            Task {
                await session.stop()
                await controller.newShow()
                restored.value = true
            }
            AppTest.waitUntil(20) { restored.value && controller.session?.isRunning == true }
        }
        XCTAssertTrue(finished, "replaceSession 与 shutdown 都应返回")
        XCTAssertNil(controller.session)
        XCTAssertEqual(controller.lastError.map { "\($0)" }, errorBefore, "起到一半被停不是错误")
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.engine.isRunning, "引擎不该在跑")
        XCTAssertNil(session.engine.clock, "时钟不该起")
        XCTAssertNil(session.renderer.preparedFormat, "预热过的渲染器要放掉")
        XCTAssertNil(session.renderer.sink)
        XCTAssertFalse(session.audio.engine.isRunning, "音频引擎不该在跑")
        XCTAssertFalse(session.control.isRunning, "控制层（推送源 / 命令循环）要停")
        XCTAssertFalse(session.control.midi.isRunning, "MIDI 要停")
        XCTAssertNotEqual(session.control.apiServer?.isRunning, true, "API 要停")
        XCTAssertTrue(session.inputs.entries.isEmpty, "输入一个都不该剩：\(session.inputs.entries.keys.sorted())")
        XCTAssertEqual(session.engine.registeredInputs, [])
    }
}
