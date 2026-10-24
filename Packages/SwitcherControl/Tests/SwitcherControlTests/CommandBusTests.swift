import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// 命令总线：统一入口、sequence 连续、issuedAt、回执带生效拍、结构性校验、C4 的进程内形态。
final class CommandBusTests: XCTestCase {
    // MARK: 基本行为

    func testBus_assignsContiguousSequencesAndIssuedAt() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let before = HostClock.now()
        let r1 = try await f.bus.submit(.setPreview(input: 3), source: .api)
        let r2 = try await f.bus.submit(.cut, source: .hotkey)
        let r3 = try await f.bus.submit(.setPreview(input: 4), source: .midi)
        let after = HostClock.now()
        XCTAssertEqual([r1.sequence, r2.sequence, r3.sequence], [1, 2, 3])
        XCTAssertEqual(f.bus.lastSequence, 3)
        let log = f.bus.recentEntries()
        XCTAssertEqual(log.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(log.map(\.source), [.api, .hotkey, .midi])
        for e in log {
            XCTAssertGreaterThanOrEqual(e.issuedAt, before)
            XCTAssertLessThanOrEqual(e.issuedAt, after)
            XCTAssertGreaterThanOrEqual(e.appliedAt, e.issuedAt)
            XCTAssertTrue(e.applied)
        }
        // 被 reducer 忽略的（提案 003 §A）：回执和日志都标 applied == false，计 ignored
        let r4 = try await f.bus.submit(.setPreview(input: 4), source: .api)
        XCTAssertFalse(r4.applied, "PVW 已经是 4")
        XCTAssertEqual(f.bus.recentEntries().last?.applied, false)
        XCTAssertEqual(f.bus.counters.ignored, 1)
        let state = await f.stateMachine.state
        XCTAssertEqual(state.program, 3)
        XCTAssertEqual(state.preview, 4)
        // 快照的 sequence 跟到最后一条（被忽略的命令也发布快照：sequence 就是"已处理到哪条"）
        XCTAssertEqual(f.stateMachine.publisher.latest?.sequence, 4)
        XCTAssertEqual(state.preview, 4)
    }

    func testBus_receiptTickIsTheTickThePictureChangesOn() async throws {
        // 渲染线程已经消费到第 100 拍 → 命令只能落在 101
        let f = BusFixture()
        defer { f.stop() }
        await f.stateMachine.prepare(upTo: Tick(100))
        f.stateMachine.noteRendered(Tick(100))
        let r = try await f.bus.submit(.cut, source: .ui)
        XCTAssertEqual(r.appliedTick, Tick(101))
        let snap = f.stateMachine.publisher.latest!
        XCTAssertEqual(snap.tick, Tick(101))
        XCTAssertEqual(snap.state.program, 2)
    }

    // MARK: 结构性校验（非法命令 400 的依据）

    func testBus_rejectsStructurallyInvalidCommandsWithReason() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let cases: [(Command, String)] = [
            (.setPreview(input: 9), "输入"),
            (.setProgram(input: -1), "输入"),
            (.overlay(channel: 5, on: true, input: nil), "通道"),
            (.overlay(channel: 1, on: true, input: 42), "输入"),
            (.setOverlay(channel: 0, rect: .full, animation: OverlayAnimation()), "通道"),
            (.audioGain(input: 7, dB: 0), "输入"),
            (.mute(input: 7, on: true), "输入"),
            (.startRecord(output: 2), "录制"),      // 2 号是推流
            (.stopStream(output: 1), "推流"),       // 1 号是录制
            (.startRecord(output: 9), "输出"),
            (.setInputSettings(input: 8, settings: InputSettings()), "输入"),
            (.renameInput(input: 8, name: "x"), "输入"),
            (.addInput(config: InputConfig(number: 1, name: "重复", source: .synthetic(settings: SyntheticSourceSettings()))), "已存在"),
            (.addInput(config: InputConfig(number: 0, name: "零", source: .synthetic(settings: SyntheticSourceSettings()))), "编号"),
            (.removeInput(input: 99), "输入"),
            (.addOutput(config: OutputState(number: 1, kind: .ndi, name: "重复")), "已存在"),
            (.removeOutput(output: 99), "输出"),
            (.setOutputSettings(output: 99, settings: OutputSettings()), "输出"),
            (.fade(durationTicks: -1), "时长"),
            (.setTransition(type: .wipe, durationTicks: -5), "时长"),
            (.useTransitionSlot(slot: 4, start: true), "转场 4 是 Stinger、还没选输入"),   // 提案 029：出厂槽 4 没选输入
        ]
        for (command, keyword) in cases {
            do {
                _ = try await f.bus.submit(command, source: .api)
                XCTFail("应被拒绝：\(command)")
            } catch let e as CommandRejection {
                XCTAssertTrue(e.reason.contains(keyword), "\(command) 的理由「\(e.reason)」应含「\(keyword)」")
                XCTAssertEqual(e.command, command)
            }
        }
        XCTAssertEqual(f.bus.lastSequence, 0, "被拒的命令不占 sequence")
        XCTAssertEqual(f.bus.counters.rejected, UInt64(cases.count))
        let state = await f.stateMachine.state
        XCTAssertEqual(state, TestStates.base(), "状态未变")
    }

    /// 校验器和 reducer 一致：校验器放行的命令，reducer 不会因为"引用不存在"而原样返回；校验器拒绝的，reducer 一定原样返回。
    func testValidator_agreesWithReducer() {
        var state = TestStates.base()
        state.inputs.append(InputConfig(number: 6, name: "片", source: .file(path: "/clip.mov", endAction: .loop, rate: 1)))   // 021：文件输入
        var legacyShowState = state
        legacyShowState.transition = TransitionState(type: .wipe, durationTicks: 45, slots: [], currentSlot: nil)   // 020 之前的节目：没有 slots
        let reducer = MixerReducer()
        let legal: [Command] = [
            .cut, .fade(durationTicks: 30), .setTransition(type: .wipe, durationTicks: 10), .autoTransition,
            .setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 3, cutAtTick: 12)),
            .setTransitionParams(wipe: WipeParams(), stinger: StingerParams()),
            .setPreview(input: 3), .setProgram(input: 0), .tbar(progress: 0.5), .ftb(on: true),
            .overlay(channel: 4, on: true, input: 2), .setOverlay(channel: 1, rect: .bottomRightQuarter, animation: OverlayAnimation(kind: .fade, durationTicks: 10)),
            .audioGain(input: 1, dB: -6), .mute(input: 2, on: true), .busGain(bus: .master, dB: -3), .busMute(bus: .busA, on: true), .setAFV(on: true),
            .setMonitorSource(bus: .busB),   // 提案 026
            .setMonitorSource(bus: .headphones),   // 026：听耳机总线自己，用户 2026-10-12 允许（P5-3）；P5 时拒
            // P5-2：提案 020 / 021 / 023
            .setTransitionSlot(slot: 2, config: TransitionSlot(type: .zoom, durationTicks: 20)),
            .setTransitionSlot(slot: 4, config: TransitionSlot(type: .stinger, durationTicks: 60, stinger: StingerParams(input: 3, cutAtTick: 5))),
            .useTransitionSlot(slot: 1, start: false), .useTransitionSlot(slot: 3, start: true), .setFTBDuration(ticks: 0), .setFTBDuration(ticks: 10),
            .useTransitionSlot(slot: 4, start: false),   // 029：没选输入的 Stinger 槽只选中照常
            .setPlayback(input: 6, paused: true), .seekPlayback(input: 6, seconds: 0), .seekPlayback(input: 6, seconds: 12.5),
            .setInputAudio(input: 1, solo: true), .setInputAudio(input: 2), .setInputColor(input: 1, color: .red), .setInputColor(input: 1, color: nil),
            .loadShow(show: Show(name: "020 之前", state: legacyShowState)),   // 校验器先搬迁再 validate，否则老节目会被 400 拒
            .startRecord(output: 1), .stopRecord(output: 1), .startStream(output: 2), .stopStream(output: 2),
            .setInputSettings(input: 1, settings: InputSettings()), .renameInput(input: 1, name: "新名"),
            .addInput(config: InputConfig(number: 5, name: "五", source: .synthetic(settings: SyntheticSourceSettings()))), .removeInput(input: 4),
            .addOutput(config: OutputState(number: 3, kind: .ndi, name: "NDI")), .removeOutput(output: 2), .setOutputSettings(output: 1, settings: OutputSettings()),
            .loadShow(show: Show(name: "s", state: state)),
            // 提案 031（P5-4）：文件速率 0.1–8 的两端、定位一周整都放行
            .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 0.1)), .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 8)),
            .addInput(config: InputConfig(number: 7, name: "片 2", source: .file(path: "/b.mov", endAction: .loop, rate: 2))),
            .seekPlayback(input: 6, seconds: PlaybackLimits.maxSeekSeconds),
            // 提案 032（P5-5）：输入编号 16 = 上限放行
            .addInput(config: InputConfig(number: 16, name: "满", source: .synthetic(settings: SyntheticSourceSettings()))),
            .loadShow(show: Show(name: "16 路", state: { var s = state; s.inputs.append(InputConfig(number: 16, name: "满", source: .image(path: "/a.png"))); return s }())),
            // 提案 034（P5-7）：时长 = 上限照收、setTransitionSlot / setOverlay 的负数照旧钳 0（不拒）、overlay input 0 = 清空、来源帧率 / 尺寸的边界值
            .fade(durationTicks: DurationLimits.maxTicks), .setTransition(type: .fade, durationTicks: DurationLimits.maxTicks), .setFTBDuration(ticks: DurationLimits.maxTicks),
            .setTransitionSlot(slot: 2, config: TransitionSlot(type: .wipe, durationTicks: DurationLimits.maxTicks)),
            .setTransitionSlot(slot: 2, config: TransitionSlot(type: .wipe, durationTicks: -3)),
            .setOverlay(channel: 1, rect: .full, animation: OverlayAnimation(kind: .fade, durationTicks: DurationLimits.maxTicks)),
            .setOverlay(channel: 1, rect: .full, animation: OverlayAnimation(kind: .fade, durationTicks: -3)),
            .overlay(channel: 2, on: false, input: 0), .overlay(channel: 2, on: true, input: 0),
            .addInput(config: InputConfig(number: 8, name: "屏幕", source: .screen(target: .display(id: 1), frameRate: FrameRate(240), captureAudio: false))),
            .setInputSource(input: 2, source: .synthetic(settings: SyntheticSourceSettings(frameRate: FrameRate(1), width: 16, height: 8192))),
        ]
        for c in legal {
            XCTAssertNil(CommandValidator.reason(rejecting: c, in: state), "\(c) 应放行")
        }
        let illegal: [Command] = [
            .setPreview(input: 9), .overlay(channel: 5, on: true, input: nil), .audioGain(input: 7, dB: 0), .startRecord(output: 2),
            .removeInput(input: 99), .removeOutput(output: 99), .fade(durationTicks: -1),
            .setTransitionParams(wipe: WipeParams(), stinger: StingerParams(input: 9, cutAtTick: 0)),
            .setTransitionParams(wipe: WipeParams(), stinger: StingerParams(input: 0, cutAtTick: 0)),
            // P5-2：提案 020 / 021 / 023
            .setTransitionSlot(slot: 5, config: TransitionSlot(type: .fade, durationTicks: 1)), .setTransitionSlot(slot: 0, config: TransitionSlot(type: .fade, durationTicks: 1)),
            .setTransitionSlot(slot: 1, config: TransitionSlot(type: .stinger, durationTicks: 1, stinger: StingerParams(input: 9, cutAtTick: 0))),
            .useTransitionSlot(slot: 0, start: true), .useTransitionSlot(slot: 5, start: false), .setFTBDuration(ticks: -1),
            .useTransitionSlot(slot: 4, start: true),   // 提案 029：出厂槽 4 = Stinger、没选输入，执行拒（只选中照常，见上）
            .setPlayback(input: 1, paused: true), .setPlayback(input: 9, paused: true),   // 不是文件输入 / 不存在
            .seekPlayback(input: 2, seconds: 1), .seekPlayback(input: 6, seconds: -1), .seekPlayback(input: 6, seconds: .nan), .seekPlayback(input: 9, seconds: 0),
            .setInputAudio(input: 9, solo: true), .setInputColor(input: 9, color: .red),
            // 提案 031（P5-4，Codex D01）：rate 0 / −1 / 极小 / 1e300 / NaN、addInput 带越界速率的文件来源、定位 1e300 / 超一周 / +∞，入口拒，reducer 同判
            .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 0)), .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: -1)),
            .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 0.0001)), .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 1e300)),
            .setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: .nan)), .setInputSource(input: 1, source: .file(path: "/a.mov", endAction: .loop, rate: 9)),
            .addInput(config: InputConfig(number: 7, name: "片 2", source: .file(path: "/b.mov", endAction: .loop, rate: 0))),
            .seekPlayback(input: 6, seconds: 1e300), .seekPlayback(input: 6, seconds: PlaybackLimits.maxSeekSeconds + 1), .seekPlayback(input: 6, seconds: .infinity),
            // 提案 032（P5-5，S1）：addInput 编号超过 16（17 / 2^62 / Int.max）、loadShow 的节目里有 17 号，入口拒，reducer 同判；
            // 按编号取输入的命令遇到越界编号照旧"不存在"（越界的编号进不了状态，所以永远取不到）
            .addInput(config: InputConfig(number: 17, name: "超", source: .synthetic(settings: SyntheticSourceSettings()))),
            .addInput(config: InputConfig(number: 1 << 62, name: "极大", source: .synthetic(settings: SyntheticSourceSettings()))),
            .addInput(config: InputConfig(number: Int.max, name: "极大", source: .synthetic(settings: SyntheticSourceSettings()))),
            .loadShow(show: Show(name: "17 路", state: { var s = state; s.inputs.append(InputConfig(number: 17, name: "超", source: .image(path: "/a.png"))); return s }())),
            .setInputSource(input: 17, source: .image(path: "/a.png")), .setPreview(input: 1 << 62), .removeInput(input: Int.max), .audioGain(input: 17, dB: 0),
            // 提案 034（P5-7，Codex N03 / N08 / N02）：时长超上限（五条）、overlay 负数输入、来源帧率 / 尺寸越界、loadShow 换格式 / 叠加不是 4 个 / 时长与对齐帧数越界
            .fade(durationTicks: DurationLimits.maxTicks + 1), .fade(durationTicks: Int.max), .setTransition(type: .wipe, durationTicks: Int.max), .setFTBDuration(ticks: Int.max),
            .setTransitionSlot(slot: 3, config: TransitionSlot(type: .zoom, durationTicks: DurationLimits.maxTicks + 1)),
            .setOverlay(channel: 3, rect: .full, animation: OverlayAnimation(kind: .zoom, durationTicks: Int.max)),
            .overlay(channel: 1, on: true, input: -1),
            .addInput(config: InputConfig(number: 8, name: "屏幕", source: .screen(target: .display(id: 1), frameRate: FrameRate(241), captureAudio: false))),
            .setInputSource(input: 2, source: .synthetic(settings: SyntheticSourceSettings(width: 0, height: 1080))),
            .setInputSource(input: 2, source: .synthetic(settings: SyntheticSourceSettings(frameRate: FrameRate(Int64.max)))),
            .loadShow(show: Show(name: "720p", state: { var s = state; s.format = .hd720p60; return s }())),
            .loadShow(show: { var show = Show(name: "没叠加", state: state); show.mixer.overlays = []; return show }()),
            .loadShow(show: Show(name: "FTB 超长", state: { var s = state; s.ftb.durationTicks = Int.max; return s }())),
            .loadShow(show: Show(name: "对齐帧数", state: { var s = state; s.audio.alignmentFrames = 24_001; return s }())),
        ]
        for c in illegal {
            XCTAssertNotNil(CommandValidator.reason(rejecting: c, in: state), "\(c) 应拒绝")
            XCTAssertEqual(reducer.reduce(state, c, at: .zero), state, "reducer 对 \(c) 也应原样返回")
        }

        // 提案 029：autoTransition 看要执行的当前那组——空闲且是没选输入的 Stinger（当前槽是这种槽，或 setTransition 直接给的）两边都拒；
        // 选了输入的放行；转场进行中校验器不判（进行中本来就由 reducer 忽略，完成那一拍当前那组还可能按槽重拷）。文案带槽号或"当前转场"。
        var slot4 = state
        slot4.transition.select(slot: 4)
        var legacyStinger = state
        legacyStinger.transition.type = .stinger
        legacyStinger.transition.durationTicks = 45
        legacyStinger.transition.currentSlot = nil
        for (s, words) in [(slot4, "转场 4 是 Stinger、还没选输入"), (legacyStinger, "当前转场是 Stinger、还没选输入")] {
            let r = CommandValidator.reason(rejecting: .autoTransition, in: s)
            XCTAssertEqual(r, words)
            XCTAssertEqual(reducer.reduce(s, .autoTransition, at: .zero), s, "reducer 对 \(words) 也应原样返回")
            XCTAssertNil(CommandValidator.reason(rejecting: .useTransitionSlot(slot: 1, start: true), in: s), "执行别的槽照常")
            XCTAssertNil(CommandValidator.reason(rejecting: .tbar(progress: 0.5), in: s), "T-bar 不管（029 不动 T-bar）")
            XCTAssertNil(CommandValidator.reason(rejecting: .fade(durationTicks: 30), in: s), "fade 总是 Fade")
        }
        var armed = legacyStinger
        armed.transition.stinger.input = 3
        XCTAssertNil(CommandValidator.reason(rejecting: .autoTransition, in: armed), "选了输入的 Stinger 放行")
        XCTAssertNotEqual(reducer.reduce(armed, .autoTransition, at: .zero), armed)
        var pushing = slot4
        pushing.transition.progress = 0.4
        pushing.transition.source = .tbar
        XCTAssertNil(CommandValidator.reason(rejecting: .autoTransition, in: pushing), "进行中交给 reducer")
        XCTAssertEqual(reducer.reduce(pushing, .autoTransition, at: .zero), pushing, "进行中 reducer 本来就忽略")
    }

    /// 提案 031（用户 2026-10-17 批，P5-4；Codex 审查 D01）：越界的文件速率 / 定位秒数在总线入口就拒（API 回 400，见 APIServerTests.test031_*），不占 sequence、状态不变——
    /// 原来 rate = 0 / −1 / 1e300 与 seconds = 1e300 都放行，运行时在 FileInput 的 precondition / Int64 换算上整个进程崩（底层钳位归 117）。
    func test031_fileRateAndSeekSecondsOutOfRange_rejectedWithReason() async throws {
        var state = TestStates.base()
        state.inputs.append(InputConfig(number: 6, name: "片", source: .file(path: "/clip.mov", endAction: .loop, rate: 1)))
        let f = BusFixture(state: state)
        defer { f.stop() }
        let cases: [(Command, String)] = [
            (.setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 0)), "播放速率必须在 0.1–8 之间"),
            (.setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: -1)), "播放速率必须在 0.1–8 之间"),
            (.setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 1e300)), "播放速率必须在 0.1–8 之间"),
            (.seekPlayback(input: 6, seconds: 1e300), "定位秒数必须在 0–604800"),
            (.addInput(config: InputConfig(number: 7, name: "片 2", source: .file(path: "/b.mov", endAction: .loop, rate: 0.0001))), "播放速率必须在 0.1–8 之间"),
        ]
        for (command, keyword) in cases {
            do {
                _ = try await f.bus.submit(command, source: .api)
                XCTFail("应被拒绝：\(command)")
            } catch let e as CommandRejection {
                XCTAssertTrue(e.reason.contains(keyword), "\(command) 的理由「\(e.reason)」应含「\(keyword)」")
            }
        }
        XCTAssertEqual(f.bus.lastSequence, 0, "被拒的命令不占 sequence")
        XCTAssertEqual(f.bus.counters.rejected, UInt64(cases.count))
        let after = await f.stateMachine.state
        XCTAssertEqual(after, state, "状态未变")
        // 边界值照收
        let ok = try await f.bus.submit(.setInputSource(input: 6, source: .file(path: "/clip.mov", endAction: .loop, rate: 8)), source: .api)
        XCTAssertTrue(ok.applied)
        let seek = try await f.bus.submit(.seekPlayback(input: 6, seconds: PlaybackLimits.maxSeekSeconds), source: .api)
        XCTAssertTrue(seek.applied)
    }

    /// 提案 032（用户 2026-10-18 批，P5-5；W2-C4 报告 §3 第 4 条的 S1）：addInput 的编号超过 16 在总线入口就拒（API 回 400，见 APIServerTests.test032_*），
    /// 不占 sequence、状态不变——原来只查 ≥ 1，2^62 号进了状态，开着兼容层时 TALLY 串 `reserveCapacity(最大编号)`、XML 按 1…最大编号写占位 → 分配失败崩或卡死。
    /// loadShow 的节目里有越界编号同样拒（validate 不过）；按编号取输入的命令遇到越界编号照旧"输入 n 不存在"；16 照收，16 路满了再加 17 号仍拒。
    func test032_inputNumberAboveRange_rejectedWithReason() async throws {
        let f = BusFixture()
        defer { f.stop() }
        var wide = TestStates.base()
        wide.inputs.append(InputConfig(number: 17, name: "超", source: .image(path: "/a.png")))
        let cases: [(Command, String)] = [
            (.addInput(config: InputConfig(number: 17, name: "超", source: .synthetic(settings: SyntheticSourceSettings()))), "输入编号必须在 1–16 之间：17"),
            (.addInput(config: InputConfig(number: 1 << 62, name: "极大", source: .synthetic(settings: SyntheticSourceSettings()))), "输入编号必须在 1–16 之间：4611686018427387904"),
            (.addInput(config: InputConfig(number: Int.max, name: "极大", source: .synthetic(settings: SyntheticSourceSettings()))), "输入编号必须在 1–16 之间"),
            (.addInput(config: InputConfig(number: -5, name: "负", source: .synthetic(settings: SyntheticSourceSettings()))), "输入编号必须在 1–16 之间：-5"),
            (.loadShow(show: Show(name: "17 路", state: wide)), "节目文件不合法"),
            (.setInputSource(input: 17, source: .image(path: "/a.png")), "输入 17 不存在"),
            (.setPreview(input: 1 << 62), "输入 4611686018427387904 不存在"),
            (.removeInput(input: Int.max), "不存在"),
        ]
        for (command, keyword) in cases {
            do {
                _ = try await f.bus.submit(command, source: .api)
                XCTFail("应被拒绝：\(command)")
            } catch let e as CommandRejection {
                XCTAssertTrue(e.reason.contains(keyword), "\(command) 的理由「\(e.reason)」应含「\(keyword)」")
            }
        }
        XCTAssertEqual(f.bus.lastSequence, 0, "被拒的命令不占 sequence")
        XCTAssertEqual(f.bus.counters.rejected, UInt64(cases.count))
        let before = await f.stateMachine.state
        XCTAssertEqual(before, TestStates.base(), "状态未变")
        // 上限照收：5…16 加满 16 路，再加 17 仍拒
        for n in 5...16 {
            let r = try await f.bus.submit(.addInput(config: InputConfig(number: n, name: "机位 \(n)", source: .synthetic(settings: SyntheticSourceSettings()))), source: .api)
            XCTAssertTrue(r.applied, "\(n)")
        }
        do {
            _ = try await f.bus.submit(.addInput(config: InputConfig(number: 17, name: "超", source: .synthetic(settings: SyntheticSourceSettings()))), source: .api)
            XCTFail("16 路之后的 17 号应被拒")
        } catch let e as CommandRejection {
            XCTAssertTrue(e.reason.contains("1–16"), e.reason)
        }
        let after = await f.stateMachine.state
        XCTAssertEqual(after.inputs.map(\.number), Array(1...16))
        XCTAssertNoThrow(try after.validate())
    }

    // MARK: 提案 034（Codex 2026-10-22 审查 N03 = 10-24 审计 NS01）

    /// N03：主 API 的时长只拒负数——`{"fade":{"durationTicks":Int.max}}` / `{"setFTBDuration":{"ticks":Int.max}}` 解码得出来、校验器放行，
    /// 之后 FTB 反转在 reducer 的 Double → Int 上崩（Codex 审查树上的 `testAudit20261022_primaryAPIDurationBoundaryDecoder`，原样搬来改名）。入口要拒。
    func testN03_primaryAPIDurationAboveLimit_rejectedAtBoundary() throws {
        for text in [#"{"fade":{"durationTicks":9223372036854775807}}"#, #"{"setFTBDuration":{"ticks":9223372036854775807}}"#] {
            let command = try CommandEnvelope.decode(Data(text.utf8))
            XCTAssertNotNil(CommandValidator.reason(rejecting: command, in: TestStates.base()), "\(text)：超出可安全计算的时长要在 API 入口拒")
        }
        // 034 ④：五条带时长的命令同一个上限、同一句理由（fade / setTransition / setFTBDuration 的负数也走这一句）
        let over = DurationLimits.maxTicks + 1
        let commands: [Command] = [
            .fade(durationTicks: over), .setTransition(type: .zoom, durationTicks: over), .setFTBDuration(ticks: over),
            .setTransitionSlot(slot: 1, config: TransitionSlot(type: .fade, durationTicks: over)),
            .setOverlay(channel: 2, rect: .full, animation: OverlayAnimation(kind: .fade, durationTicks: over)),
        ]
        for command in commands {
            XCTAssertEqual(CommandValidator.reason(rejecting: command, in: TestStates.base()), "时长必须在 0–864000 拍之间：864001", "\(command)")
        }
        for negative in [Command.fade(durationTicks: -1), .setTransition(type: .wipe, durationTicks: -1), .setFTBDuration(ticks: -1)] {
            XCTAssertEqual(CommandValidator.reason(rejecting: negative, in: TestStates.base()), "时长必须在 0–864000 拍之间：-1", "\(negative)")
        }
    }

    /// N08：运行中 loadShow 换格式（1080p60 → 720p30）原来 200、状态报新格式，引擎时钟 / 渲染器 / App 的 session 还是旧的。034 ⑥：400 带两边的格式、不占 sequence、状态不变；同格式照载。
    func testN08_loadShowFormatChange_rejectedWithReason() async throws {
        let f = BusFixture()
        defer { f.stop() }
        var other = TestStates.base()
        other.format = ProgramFormat(width: 1280, height: 720, frameRate: .fps30)
        do {
            _ = try await f.bus.submit(.loadShow(show: Show(name: "720p30", state: other)), source: .api)
            XCTFail("换格式的 loadShow 应被拒")
        } catch let e as CommandRejection {
            XCTAssertEqual(e.reason, "节目格式不同（1920×1080@60 → 1280×720@30）：运行中不能换格式，用打开节目 / 重启 headless")
        }
        var fractional = TestStates.base()
        fractional.format = .hd1080p5994
        XCTAssertEqual(CommandValidator.reason(rejecting: .loadShow(show: Show(name: "59.94", state: fractional)), in: TestStates.base()),
                       "节目格式不同（1920×1080@60 → 1920×1080@59.94）：运行中不能换格式，用打开节目 / 重启 headless")
        XCTAssertEqual(f.bus.lastSequence, 0, "被拒的命令不占 sequence")
        let unchanged = await f.stateMachine.state
        XCTAssertEqual(unchanged.format, .hd1080p60)
        var same = TestStates.base()
        same.program = 3
        let ok = try await f.bus.submit(.loadShow(show: Show(name: "同格式", state: same)), source: .api)
        XCTAssertTrue(ok.applied)
        let loaded = await f.stateMachine.state
        XCTAssertEqual(loaded.program, 3)
    }

    /// N11：`overlay(input: 0)` 原来被总线以"输入 0 不存在"拒（叠加设置的"（无）"发 nil 又是"不换"，两头都清不掉）。034 ⑤：0 = 清空，放行并生效；nil 仍是不换。
    func testN11_overlayInputZero_passesBusAndClears() async throws {
        let f = BusFixture()
        defer { f.stop() }
        _ = try await f.bus.submit(.overlay(channel: 1, on: true, input: 3), source: .api)
        let routed = await f.stateMachine.state
        XCTAssertEqual(routed.overlays[0].input, 3)
        let clear = try await f.bus.submit(.overlay(channel: 1, on: true, input: 0), source: .api)
        XCTAssertTrue(clear.applied)
        let cleared = await f.stateMachine.state
        XCTAssertNil(cleared.overlays[0].input)
        XCTAssertTrue(cleared.overlays[0].on, "开关不动")
        let keep = try await f.bus.submit(.overlay(channel: 1, on: true, input: nil), source: .api)
        XCTAssertFalse(keep.applied, "nil = 不换（开关也没变）")
        XCTAssertEqual(CommandValidator.reason(rejecting: .overlay(channel: 1, on: true, input: -1), in: TestStates.base()), "输入 -1 不存在")
        XCTAssertEqual(f.bus.counters.rejected, 0)
    }

    /// 034 ② / ②b / ③ / ⑧：来源的帧率 / 尺寸、loadShow 的结构 / 格式 / 时长 / 对齐帧数，总线入口拒并给人话（API 400），不占 sequence、状态不变；边界值照收。
    func test034_numericLimits_rejectedWithReason() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let screen = { (rate: FrameRate) in InputSource.screen(target: .display(id: 1), frameRate: rate, captureAudio: false) }
        var noOverlays = Show(name: "没叠加", state: TestStates.base())
        noOverlays.mixer.overlays = []
        let tooBig = { (edit: (inout MixerState) -> Void) -> Show in var s = TestStates.base(); edit(&s); return Show(name: "越界", state: s) }
        let cases: [(Command, String)] = [
            (.addInput(config: InputConfig(number: 5, name: "屏幕", source: screen(FrameRate(241)))), "帧率必须在 1–240 之间：241"),
            (.setInputSource(input: 2, source: screen(FrameRate(Rational(1, 2)))), "帧率必须在 1–240 之间：0.50"),
            (.addInput(config: InputConfig(number: 5, name: "合成", source: .synthetic(settings: SyntheticSourceSettings(frameRate: FrameRate(1_000))))), "帧率必须在 1–240 之间：1000"),
            (.setInputSource(input: 2, source: .synthetic(settings: SyntheticSourceSettings(width: 0, height: 0))), "画面尺寸必须在 16–8192 之间：0×0"),
            (.loadShow(show: noOverlays), "节目文件不合法：overlayCount(0)"),
            (.loadShow(show: tooBig { $0.format = ProgramFormat(width: -1, height: 0, frameRate: .fps60) }), "节目文件不合法：节目尺寸必须在 16–8192 之间：-1×0"),
            (.loadShow(show: tooBig { $0.format = ProgramFormat(width: 1920, height: 1080, frameRate: FrameRate(Int64.max)) }), "节目文件不合法：帧率必须在 1–240 之间：9223372036854775807"),
            (.loadShow(show: tooBig { $0.ftb.durationTicks = Int.max }), "节目文件不合法：时长必须在 0–864000 拍之间：9223372036854775807"),
            (.loadShow(show: tooBig { $0.audio.alignmentFrames = 1 << 62 }), "节目文件不合法：音频对齐帧数必须在 0–24000 之间：4611686018427387904"),
            (.loadShow(show: tooBig { $0.inputs[0].source = screen(FrameRate(300)) }), "节目文件不合法：输入 1 的帧率必须在 1–240 之间"),
        ]
        for (command, reason) in cases {
            do {
                _ = try await f.bus.submit(command, source: .api)
                XCTFail("应被拒绝：\(command)")
            } catch let e as CommandRejection {
                XCTAssertEqual(e.reason, reason, "\(command)")
            }
        }
        XCTAssertEqual(f.bus.lastSequence, 0, "被拒的命令不占 sequence")
        let before = await f.stateMachine.state
        XCTAssertEqual(before, TestStates.base(), "状态未变")
        // 边界值照收
        for command in [Command.fade(durationTicks: DurationLimits.maxTicks), .setFTBDuration(ticks: DurationLimits.maxTicks),
                        .addInput(config: InputConfig(number: 5, name: "屏幕", source: screen(FrameRate(240))))] {
            let r = try await f.bus.submit(command, source: .api)
            XCTAssertTrue(r.applied, "\(command)")
        }
    }

    // MARK: C4（进程内形态）：每秒 100 条带序号命令，两个并发"客户端"

    func testC4_hundredCommandsPerSecond_twoConcurrentClients_noLossNoReorder() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let perClient = 300   // 每客户端 3 s × 100/s；正式 60 s 的版本在 scripts/apitest 里跑
        let interval: Duration = .milliseconds(10)
        actor Log { var receipts: [CommandReceipt] = []; func add(_ r: CommandReceipt) { receipts.append(r) } }
        let logs = [Log(), Log()]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in 0..<2 {
                group.addTask {
                    var next = ContinuousClock.now
                    for k in 1...perClient {
                        let r = try await f.bus.submit(.renameInput(input: client + 1, name: "c\(client)-\(k)"), source: .api)
                        await logs[client].add(r)
                        next += interval
                        try await Task.sleep(until: next)
                    }
                }
            }
            try await group.waitForAll()
        }
        // 每个客户端自己的回执 sequence 严格递增（无乱序）
        for client in 0..<2 {
            let seqs = await logs[client].receipts.map(\.sequence)
            XCTAssertEqual(seqs.count, perClient)
            XCTAssertEqual(seqs, seqs.sorted(), "客户端 \(client) 乱序")
            XCTAssertEqual(Set(seqs).count, perClient)
        }
        // 两个客户端合起来：1…600 连续无丢失
        let all = await (logs[0].receipts + logs[1].receipts).map(\.sequence).sorted()
        XCTAssertEqual(all, Array(1...UInt64(2 * perClient)))
        XCTAssertEqual(f.bus.lastSequence, UInt64(2 * perClient))
        // 状态机按序应用：最终名字是各自的最后一条；快照 sequence = 最后一条
        let state = await f.stateMachine.state
        XCTAssertEqual(state.input(1)?.name, "c0-\(perClient)")
        XCTAssertEqual(state.input(2)?.name, "c1-\(perClient)")
        XCTAssertEqual(f.stateMachine.publisher.latest?.sequence, UInt64(2 * perClient))
        let applied = await f.stateMachine.appliedSequences
        XCTAssertEqual(applied, Array(1...UInt64(2 * perClient)), "状态机应用顺序 = sequence 顺序")
        let pending = await f.stateMachine.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// 观察者在每条命令应用后被调用（状态推送靠它）。
    func testBus_observerSeesEveryAppliedEntryInOrder() async throws {
        let f = BusFixture()
        defer { f.stop() }
        final class Recorder: CommandBusObserver, @unchecked Sendable {
            let lock = NSLock(); var seen: [UInt64] = []
            func commandBus(_ bus: CommandBus, didApply entry: CommandLogEntry) { lock.lock(); seen.append(entry.sequence); lock.unlock() }
        }
        let rec = Recorder()
        f.bus.addObserver(rec)
        for _ in 0..<5 { _ = try await f.bus.submit(.cut, source: .ui) }
        XCTAssertEqual(rec.seen, [1, 2, 3, 4, 5])
    }
}
