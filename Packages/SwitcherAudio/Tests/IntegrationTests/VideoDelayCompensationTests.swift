import XCTest
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// W1-B4（prompt 105 交付 2–3，提案 028）：补偿方式一处开关。
/// - `audioPTS`（W5-C 现状）：总线来源的 PTS 前移该总线的效果链延迟，视频不延后（交给引擎的设定值恒 0）。
/// - `videoDelay`（默认）：节目输出时间线 = 采集 + L_m（Master 当前效果链延迟）。Master 的 PTS 不再前移；Bus A / B / 耳机平移 L_m − L_bus；
///   输入来源（ISO / 节目信号）平移 +L_m；L_m 交给视频引擎（`AudioEngine.videoDelay`），画面按 tickTime = 拍点 + L 派发。
///   没接视频引擎（`videoDelay` 为 nil）时退回 audioPTS 的行为——没接线的组装方（App 接线之前）不会出现文件错位。
final class VideoDelayCompensationTests: XCTestCase {
    typealias FX = BusEffectsTests

    /// 576 帧（限幅起音 12 ms）对应的 host 时长：引擎拿到的设定值必须与泵用的同一个换算（帧 × 每帧 host tick，四舍五入）。
    static func duration(frames: Int, _ engine: AudioEngine) -> HostDuration {
        HostDuration(ticks: Int64((Double(frames) * engine.mixer.hostTicksPerFrame).rounded()))
    }

    func setEffects(_ rig: EngineRig, _ effects: [EffectSlot], bus: Bus = .master) async {
        _ = await rig.sm.apply(.setBusEffects(bus: bus, effects: effects))
    }

    // MARK: - 开关与退回

    /// 默认就是 videoDelay；没接视频引擎时按 audioPTS 走（Master 的 click 仍在整秒），接上之后才生效。
    func testAV_compensation_defaultVideoDelay_fallsBackToAudioPTSUntilEngineAttached() async throws {
        XCTAssertEqual(AudioEngineConfiguration().avCompensation, .videoDelay, "默认 videoDelay（prompt 105）")
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        await setEffects(rig, [FX.limiter(attackSeconds: 0.012)])
        let cap = try rig.capture(.master)
        await rig.run(seconds: 4)
        XCTAssertEqual(rig.engine.avCompensationInEffect, .audioPTS, "没接视频引擎：退回 audioPTS")
        XCTAssertEqual(rig.engine.status.avCompensation, .audioPTS)
        for o in cap.clickOffsetsMs(t0: rig.t0) { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒") }
        let stub = StubVideoDelay()
        rig.engine.videoDelay = stub
        XCTAssertEqual(rig.engine.avCompensationInEffect, .videoDelay)
        XCTAssertEqual(stub.last, Self.duration(frames: 576, rig.engine), "接上那一刻就把当前 Master 的延迟交过去")
        rig.engine.videoDelay = nil
        XCTAssertEqual(stub.last, .zero, "摘掉：旧的引擎延后归零")
        XCTAssertEqual(rig.engine.avCompensationInEffect, .audioPTS)
        await rig.shutdown()
    }

    /// audioPTS：接了引擎也不延后视频（设定值恒 0），总线 PTS 照 W5-C 前移。
    func testAV_compensation_audioPTSMode_keepsW5CBehaviourAndNeverDelaysVideo() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false)) { $0.avCompensation = .audioPTS }
        let stub = StubVideoDelay()
        rig.engine.videoDelay = stub
        try rig.addSource(number: 1)
        await setEffects(rig, FX.clickSafeChain)
        let cap = try rig.capture(.master)
        await rig.run(seconds: 5)
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 832)
        XCTAssertEqual(rig.engine.avCompensationInEffect, .audioPTS)
        XCTAssertTrue(stub.targets.allSatisfy { $0 == .zero }, "audioPTS 下视频不延后：\(stub.targets)")
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(offsets.count, 3)
        for o in offsets { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒") }
        await rig.shutdown()
    }

    // MARK: - videoDelay：各来源都在节目输出时间线上

    /// Master 限幅 12 ms（576 帧）、Bus A 限幅 2 ms（96 帧）：引擎拿到 12 ms；Master 不前移（click 在 PTS = k s + 12 ms），
    /// Bus A 平移 12 − 2 ms、输入（ISO）平移 +12 ms——三条流的 click 都在 k s + 12 ms，与画面（tickTime = 拍点 + 12 ms）同一条线。PTS 全程连续。
    func testAV_videoDelayMode_allSourcesOnOutputTimeline() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        let stub = StubVideoDelay()
        rig.engine.videoDelay = stub
        try rig.addSource(number: 1)
        var s = InputSettings(); s.audio.routing = BusRouting(master: true, busA: true)
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
        await setEffects(rig, [FX.limiter(attackSeconds: 0.012)])
        await setEffects(rig, [FX.limiter(attackSeconds: 0.002)], bus: .busA)
        let master = try rig.capture(.master), busA = try rig.capture(.bus(.busA)), iso = try rig.capture(.input(number: 1))
        await rig.run(seconds: 6)
        XCTAssertEqual(rig.engine.avCompensationInEffect, .videoDelay)
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 576)
        XCTAssertEqual(rig.engine.effectsStatus(.busA).latencyFrames, 96)
        XCTAssertEqual(stub.last, Self.duration(frames: 576, rig.engine), "引擎拿到 Master 的 12 ms")
        for (name, cap) in [("Master", master), ("Bus A", busA), ("ISO 输入 1", iso)] {
            let offsets = cap.clickOffsetsMs(t0: rig.t0)
            XCTAssertGreaterThanOrEqual(offsets.count, 4, "\(name)：\(offsets)")
            for o in offsets { XCTAssertEqual(o.offsetMs, -12, accuracy: 0.05, "\(name) 第 \(o.second) 秒：click 在 k s + 12 ms（音频 PTS 不前移）") }
            XCTAssertEqual(cap.gaps.count, 0, "\(name) PTS 连续")
        }
        XCTAssertEqual(rig.engine.programPTS(forBlockHostTime: rig.t0 + HostDuration(seconds: 1)), rig.t0 + HostDuration(seconds: 1) - rig.engine.alignmentDuration,
                       "videoDelay：Master 的 PTS = 块首 − 对齐延迟（不减效果链延迟）")
        await rig.shutdown()
    }

    /// 运行中 Master 的延迟变了（0 → 12 ms → 2 ms → 0）：引擎依次拿到 12 / 2 / 0 ms；Master 不拼接（PTS 连续、丢 / 补都是 0），
    /// 输入来源在变化那一块拼接（+L_m 变大补静音、变小丢样本），PTS 连续；每一段的 click 都在 k s + 那一段的 L。
    func testAV_videoDelayMode_masterLatencyChange_splicesNonMasterSourcesOnly() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        let stub = StubVideoDelay()
        rig.engine.videoDelay = stub
        try rig.addSource(number: 1)
        let master = try rig.capture(.master), iso = try rig.capture(.input(number: 1))
        await rig.run(until: rig.t0 + HostDuration(seconds: 2.5))
        await setEffects(rig, [FX.limiter(attackSeconds: 0.012)])
        await rig.run(until: rig.t0 + HostDuration(seconds: 5.5))
        await setEffects(rig, [FX.limiter(attackSeconds: 0.002)])
        await rig.run(until: rig.t0 + HostDuration(seconds: 8.5))
        await setEffects(rig, [FX.limiter(attackSeconds: 0.002, enabled: false)])
        await rig.run(until: rig.t0 + HostDuration(seconds: 11.5))
        let expected = [0, 576, 96, 0].map { Self.duration(frames: $0, rig.engine) }
        XCTAssertEqual(stub.targets.reduce(into: [HostDuration]()) { if $0.last != $1 { $0.append($1) } }, expected, "设定值依次 0 / 12 / 2 / 0 ms")
        for (name, cap) in [("Master", master), ("ISO 输入 1", iso)] {
            let offsets = cap.clickOffsetsMs(t0: rig.t0)
            XCTAssertGreaterThanOrEqual(offsets.count, 10, "\(name)：\(offsets)")
            for o in offsets {
                let l = o.second <= 2 ? 0.0 : o.second <= 5 ? 12 : o.second <= 8 ? 2 : 0
                XCTAssertEqual(o.offsetMs, -l, accuracy: 0.05, "\(name) 第 \(o.second) 秒：click 应在 k s + \(l) ms")
            }
            XCTAssertEqual(cap.gaps.count, 0, "\(name) PTS 连续")
        }
        let status = rig.engine.status.consumers
        let m = try XCTUnwrap(status.first { $0.source == "\(AudioTapSource.master)" })
        let i = try XCTUnwrap(status.first { $0.source == "\(AudioTapSource.input(number: 1))" })
        XCTAssertEqual(m.latencyFramesDropped + m.latencyFramesInserted, 0, "Master 不拼接")
        XCTAssertEqual(i.latencyFramesInserted, 576, "输入来源：L_m 涨 576 → 平移 +576，补静音")
        XCTAssertEqual(i.latencyFramesDropped, 480 + 96, "L_m 降 480、再降 96 → 丢样本")
        await rig.shutdown()
    }

    // MARK: - 引擎跟着走（prompt 105 的 testAV_videoDelayFollowsBusEffectLatency）

    /// 真视频引擎 + 空设备音频引擎（videoDelay，接上）：Master 加限幅起音 12 ms → 引擎设定值 = 12 ms，派发时刻比渲染完成晚 12 ms ± 1 拍
    /// （tickTime − 拍点 = 12 ms 精确）；关掉效果回 0；全程（含两次过渡）每一拍派发一次、按序、tickTime 严格递增。
    func testAV_videoDelayFollowsBusEffectLatency() async throws {
        let rig = try await AVSyncRig(compensation: .videoDelay)
        await rig.wait(until: 1.0)
        await rig.setMasterEffects([FX.limiter(attackSeconds: 0.012)])
        await rig.wait(until: 3.0)
        let during = rig.video.videoDelayTarget
        await rig.setMasterEffects([FX.limiter(attackSeconds: 0.012, enabled: false)])
        await rig.wait(until: 5.0)
        let after = rig.video.videoDelayTarget
        await rig.shutdown()
        let period = rig.clock.duration(ofTicks: 1)
        let twelve = Self.duration(frames: 576, rig.audio)
        XCTAssertEqual(during, twelve, "Master 限幅 12 ms → 视频延后设定 12 ms")
        XCTAssertEqual(after, .zero, "关掉效果回 0")
        let entries = rig.recorder.entries
        func window(_ from: Double, _ to: Double) -> [FrameTimingRecorder.Entry] {
            entries.filter { $0.pts >= rig.t0 + HostDuration(seconds: from) && $0.pts < rig.t0 + HostDuration(seconds: to) }
        }
        let before = window(0.2, 0.9), on = window(1.6, 2.9), off = window(3.6, 4.9)
        XCTAssertGreaterThan(before.count, 30); XCTAssertGreaterThan(on.count, 60); XCTAssertGreaterThan(off.count, 60)
        for e in before + off {
            XCTAssertEqual(e.tickTime, e.pts, "不延后：tickTime = 拍点")
            XCTAssertLessThan((e.dispatched - e.gpuEnd).milliseconds, 2, "不延后：渲染完成就派发")
        }
        var lag: [Double] = []
        for e in on {
            XCTAssertEqual(e.tickTime - e.pts, twelve, "第 \(e.tick) 拍：tickTime = 拍点 + 12 ms")
            lag.append((e.dispatched - e.gpuEnd).milliseconds)
            XCTAssertEqual((e.dispatched - e.gpuEnd).milliseconds, 12, accuracy: period.milliseconds, "派发比渲染完成晚 12 ms ± 1 拍")
        }
        print("W1-B4 跟随：开限幅后派发 − 渲染完成 平均 \(String(format: "%.3f", lag.reduce(0, +) / Double(max(lag.count, 1)))) ms；设定 \(String(format: "%.3f", during.milliseconds)) → \(String(format: "%.3f", after.milliseconds)) ms")
        let problems = rig.recorder.problems
        XCTAssertEqual(problems.dupOrOrder, 0, "不重复、不乱序")
        XCTAssertEqual(problems.ptsRegressions, 0, "tickTime 严格递增（两次过渡都按 1/4 拍平滑）")
        let ticks = entries.map(\.tick)
        XCTAssertEqual(UInt64(ticks.count) + rig.video.counters.missedRender, UInt64((ticks.last ?? -1) - (ticks.first ?? 0) + 1), "不丢帧：每一拍派发一次（时钟跳过的拍除外）")
        XCTAssertEqual(rig.video.counters.videoDelayOverflow, 0)
    }

    // MARK: - A2：两种方式下画面与声音的时间戳一致

    /// 空设备 + 真视频引擎，Master 限幅起音 30 ms（1440 帧），两种补偿方式各跑 8 s：闪光帧（第 60k 拍）的 tickTime − 第 k 个 click 的 PTS
    /// 整秒配对 ≤ 1 ms，两种方式的均值差 ≤ 1 ms（同一条节目时间线，只是 videoDelay 整体晚 30 ms）。录制文件的 frameprobe 版本在
    /// switcher-headless 的 `testA2_videoDelayMode_recordingStaysAligned`（录制器就是按这两个时间戳写文件的）。
    func testA2_videoDelayMode_videoAndAudioTimestampsAligned_nullDevice() async throws {
        var means: [AVCompensation: Double] = [:]
        for mode in [AVCompensation.audioPTS, .videoDelay] {
            let rig = try await AVSyncRig(compensation: mode)
            let analyzer = StreamAnalyzer(name: "a2-\(mode)", t0: rig.t0)
            try rig.audio.addConsumer(analyzer, source: .master)
            await rig.wait(until: 0.2)
            await rig.setMasterEffects([FX.limiter(attackSeconds: 0.03)])
            await rig.wait(until: 8.6)
            await rig.shutdown()
            XCTAssertEqual(rig.audio.effectsStatus(.master).latencyFrames, 1440)
            var a2: [Double] = []
            for c in analyzer.clickOffsetsMs where c.second >= 1 {
                guard let flash = rig.recorder.entry(tick: Int64(60 * c.second)) else { continue }
                let clickPTS = rig.t0 + HostDuration(seconds: Double(c.second)) - HostDuration(milliseconds: c.offsetMs)
                a2.append((flash.tickTime - clickPTS).milliseconds)
            }
            let mean = a2.reduce(0, +) / Double(max(a2.count, 1))
            means[mode] = mean
            print("W1-B4 A2（\(mode)，Master 限幅 30 ms）：\(a2.count) 对，均值 \(String(format: "%.3f", mean)) ms，最大 |\(String(format: "%.3f", a2.map(abs).max() ?? 0))| ms；视频延后 \(String(format: "%.3f", rig.video.counters.videoDelayMs)) ms")
            XCTAssertGreaterThanOrEqual(a2.count, 6, "\(mode)")
            for v in a2 { XCTAssertLessThanOrEqual(abs(v), 1, "\(mode)：整秒配对 ≤ 1 ms") }
            XCTAssertEqual(rig.video.counters.videoDelayMs, mode == .videoDelay ? 30 : 0, accuracy: 0.001)
        }
        XCTAssertEqual(means[.videoDelay]!, means[.audioPTS]!, accuracy: 1, "两种方式的 A2 相同（不双重补偿）")
    }

    // MARK: - A5：监听同步

    /// prompt 105 交付 3：Master 开着限幅起音 30 ms 时，监视器呈现时刻 − 扬声器出声时刻 ≤ 1 帧（真回环）。
    func testA5_monitorSync_loopback() throws {
        throw XCTSkip("""
            BLOCKED-硬件：要一台音频接口（线路输出 → 线路输入回环）+ 一台对着监视器的光电探头（或 1/1000 s 快门的相机），本机没有。步骤：
            1. App（或 switcher-headless --preview --av-compensation videoDelay，渲染器开 displayDelayHistory）开一路合成源，Master 加限幅起音 30 ms；
            2. 音频接口的线路输出接回线路输入，作为纯音频输入录进来（或直接用接口的回环通道）；光电探头贴在 PGM 监视器上，探头信号进接口的另一路输入；
            3. 录 1 分钟，按整秒的闪光 / click 配对：监视器呈现时刻（探头上升沿）− 扬声器出声时刻（回环里的 click 起点），减去接口自身的往返延迟（A5 的做法：往返 / 2）；
            4. 判：≤ 1 帧（60 fps 16.7 ms）；同时关掉限幅再量一次，两次之差应 ≤ 1 ms 量级（空设备模拟见 testA5_monitorSync_nullDeviceSimulation）。
            """)
    }

    /// prompt 105 交付 3 的空设备模拟：扬声器出声时刻 = 混音块的输出时刻（空设备时钟 = host 时钟，直接挂 Master tap 量 click 起点）；
    /// 监视器呈现时刻 = 闪光帧的派发时刻（显示源按同一个延后挑帧，见 SwitcherRender 的 displayDelay 用例；这里不含显示器自己的扫描延迟）。
    /// 判：videoDelay、Master 限幅 30 ms 时的（呈现 − 出声）与不开效果时相差 ≤ 1 帧；对照：audioPTS 下开 30 ms 限幅会差 ≈ 30 ms（不同步）。
    func testA5_monitorSync_nullDeviceSimulation() async throws {
        func measure(_ mode: AVCompensation, effects: Bool) async throws -> (mean: Double, count: Int) {
            let rig = try await AVSyncRig(compensation: mode)
            guard let speaker = SpeakerTap(mixer: rig.audio.mixer) else { throw XCTSkip("混音器没有空的 tap") }
            if effects {
                await rig.wait(until: 0.2)
                await rig.setMasterEffects([FX.limiter(attackSeconds: 0.03)])
            }
            await rig.wait(until: 6.6)
            speaker.stop()
            await rig.shutdown()
            var diffs: [Double] = []
            for k in 1...6 {
                guard let heard = speaker.onset(second: k, t0: rig.t0), let shown = rig.recorder.entry(tick: Int64(60 * k)) else { continue }
                diffs.append((shown.dispatched - heard).milliseconds)
            }
            return (diffs.reduce(0, +) / Double(max(diffs.count, 1)), diffs.count)
        }
        let baseline = try await measure(.videoDelay, effects: false)
        let synced = try await measure(.videoDelay, effects: true)
        let unsynced = try await measure(.audioPTS, effects: true)
        let frame = 1000.0 / 60
        print("""
            W1-B4 A5 模拟（空设备，呈现 − 出声）：不开效果 \(String(format: "%.3f", baseline.mean)) ms（\(baseline.count) 对）；\
            videoDelay + 限幅 30 ms \(String(format: "%.3f", synced.mean)) ms（差 \(String(format: "%+.3f", synced.mean - baseline.mean))）；\
            audioPTS + 限幅 30 ms \(String(format: "%.3f", unsynced.mean)) ms（差 \(String(format: "%+.3f", unsynced.mean - baseline.mean))）。\
            绝对值 ≈ −对齐延迟 42.7 ms：模拟里画面没有采集 / 显示器的延迟，真机上由 L2 那条视频链补上
            """)
        XCTAssertGreaterThanOrEqual(baseline.count, 5); XCTAssertGreaterThanOrEqual(synced.count, 5); XCTAssertGreaterThanOrEqual(unsynced.count, 5)
        XCTAssertLessThanOrEqual(abs(synced.mean - baseline.mean), frame, "videoDelay：开着限幅 30 ms 监听仍同步（≤ 1 帧）")
        XCTAssertGreaterThan(abs(unsynced.mean - baseline.mean), 25, "对照：audioPTS 下开限幅，画面比声音早约 30 ms")
    }
}
