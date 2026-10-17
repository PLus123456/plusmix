import Foundation
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 状态机纯函数部分：每条命令的前后状态表驱动；Cut 原子性（V6）；Fade / T-bar / FTB / 叠加动画进度（V7）。
final class ReducerTests: XCTestCase {
    let reducer = MixerReducer()

    /// 输入 1–4（合成源），输出 1 = 录制、2 = 推流；PGM 1、PVW 2。
    static func baseState() -> MixerState {
        var s = MixerState(format: .hd1080p60)
        s.inputs = (1...4).map { InputConfig(number: $0, name: "机位 \($0)", source: .synthetic(settings: SyntheticSourceSettings())) }
        s.outputs = [
            OutputState(number: 1, kind: .record, name: "录制", settings: OutputSettings(record: RecordSettings(directory: "/tmp"))),
            OutputState(number: 2, kind: .stream, name: "推流", settings: OutputSettings(stream: StreamSettings(url: "rtmp://x/y"))),
        ]
        s.program = 1
        s.preview = 2
        return s
    }

    /// 029 起没选输入的 Stinger 不开始（autoTransition 原样返回）：Wipe / Zoom / Stinger 共用的 auto 转场用例先给当前那组的 Stinger 选一路（3 号）。
    /// Wipe / Zoom 不看 stinger 参数；当前那组从此不对应任何槽（currentSlot = nil），完成时不重拷。
    static func stingerReadyState() -> MixerState {
        MixerReducer().reduce(baseState(), .setTransitionParams(wipe: WipeParams(), stinger: StingerParams(input: 3, cutAtTick: 0)), at: Tick(0))
    }

    // MARK: V6 切换

    func testV6_cut_isAtomicSwap_noIntermediateState() {
        let s0 = Self.baseState()
        let s1 = reducer.reduce(s0, .cut, at: Tick(100))
        XCTAssertEqual(s1.program, 2)
        XCTAssertEqual(s1.preview, 1)
        XCTAssertFalse(s1.transition.isActive, "Cut 没有中间态")
        XCTAssertEqual(s1.transition.progress, 0)
        XCTAssertNil(s1.transition.startTick)
        // 除 program / preview / transition 外一律不变
        var expected = s0
        expected.program = 2; expected.preview = 1
        XCTAssertEqual(s1, expected)
        // 转场进行中 Cut：立即完成（对调）并取消转场
        var mid = reducer.reduce(s0, .fade(durationTicks: 30), at: Tick(100))
        mid = reducer.advance(mid, to: Tick(110))
        XCTAssertEqual(mid.transition.progress, 10.0 / 30.0)
        let cutMid = reducer.reduce(mid, .cut, at: Tick(110))
        XCTAssertEqual(cutMid.program, 2)
        XCTAssertEqual(cutMid.preview, 1)
        XCTAssertFalse(cutMid.transition.isActive)
        XCTAssertEqual(cutMid.transition.source, .auto)
    }

    func testV6_cut_effectiveOnTheTickItIsApplied() {
        // 第 999 拍推进：还是 1；第 1000 拍 advance 后 reduce(cut)：2。没有任何一拍处于混合态。
        var s = Self.baseState()
        s = reducer.advance(s, to: Tick(999))
        XCTAssertEqual(s.program, 1)
        s = reducer.advance(s, to: Tick(1000))
        s = reducer.reduce(s, .cut, at: Tick(1000))
        XCTAssertEqual(s.program, 2)
        XCTAssertEqual(s.tally(ofInput: 2), Tally(program: true, preview: false))
        XCTAssertEqual(s.tally(ofInput: 1), Tally(program: false, preview: true))
    }

    // MARK: V6 转场进行中拒收 setPreview / setProgram（W5-E，Q66 (a)，用户 2026-09-29 定）
    //
    // 渲染器转场中按当前的 program 画底、按当前的 preview 画切进来的画面，所以中途改这两路就是 PGM 上的跳变。
    // 与 fade / setTransition / setTransitionParams / autoTransition 同一口径：`transition.isActive` 时原样返回（回执 applied = false）。
    // isActive = progress > 0 || startTick != nil：auto 转场从应用命令那一拍（progress 0、startTick 已记）到对调前一拍；T-bar 推杆在 (0, 1)。

    /// Fade 30 拍进行到第 10 拍发 setPreview(3)：状态一个字段不动、回执 applied = false、快照 PVW 仍是 2；转场按开始时的两路走完，PGM = 2。
    func testV6_setPreviewRejectedDuringTransition() async {
        let start = Tick(100)
        let s1 = reducer.reduce(Self.baseState(), .fade(durationTicks: 30), at: start)
        // 起始拍到对调前一拍，每一拍都拒（黑场 0 也拒）
        for k in 0..<30 {
            let sk = reducer.advance(s1, to: start + k)
            XCTAssertTrue(sk.transition.isActive, "第 s + \(k) 拍")
            XCTAssertEqual(reducer.reduce(sk, .setPreview(input: 3), at: start + k), sk, "第 s + \(k) 拍 setPreview 原样返回")
            XCTAssertEqual(reducer.reduce(sk, .setPreview(input: 0), at: start + k), sk, "第 s + \(k) 拍 setPreview 黑场原样返回")
        }
        let mid = reducer.advance(s1, to: start + 10)
        let rejected = reducer.reduce(mid, .setPreview(input: 3), at: start + 10)
        XCTAssertEqual(rejected.preview, 2)
        let done = reducer.advance(rejected, to: start + 30)
        XCTAssertEqual(done.program, 2, "切进来的仍是开始时的 2 号")
        XCTAssertEqual(done.preview, 1)
        XCTAssertFalse(done.transition.isActive)
        // Wipe / Zoom / Stinger 同一规则
        for type in [TransitionType.wipe, .zoom, .stinger] {
            let auto = reducer.reduce(reducer.reduce(Self.stingerReadyState(), .setTransition(type: type, durationTicks: 20), at: Tick(0)), .autoTransition, at: Tick(10))
            let m = reducer.advance(auto, to: Tick(15))
            XCTAssertEqual(reducer.reduce(m, .setPreview(input: 4), at: Tick(15)), m, "\(type) 进行中 setPreview 原样返回")
            XCTAssertEqual(reducer.advance(m, to: Tick(30)).program, 2, "\(type) 走完 PGM = 2")
        }

        // 状态机：回执 applied = false（API 客户端收到"被拒"），快照 PVW 仍是 2，转场结束 PGM = 2
        let sm = StateMachine(initialState: Self.baseState())
        sm.start()
        defer { sm.stop() }
        await sm.schedule(.fade(durationTicks: 30), at: start)
        await sm.prepare(upTo: start + 10)
        guard case .applied(let receipt) = await sm.submit(IssuedCommand(sequence: 1, issuedAt: .now(), command: .setPreview(input: 3))) else {
            return XCTFail("setPreview 应走到 reducer（结构合法）")
        }
        XCTAssertFalse(receipt.applied, "转场进行中 setPreview 被拒")
        XCTAssertEqual(receipt.appliedTick, start + 10)
        let snap = sm.publisher.latest!
        XCTAssertEqual(snap.sequence, 1, "被拒也发布快照：sequence 确认已处理")
        XCTAssertEqual(snap.state.preview, 2, "快照 PVW 仍是 2")
        XCTAssertEqual(snap.state.transition.progress, 10.0 / 30.0)
        await sm.prepare(upTo: start + 30)
        let end = await sm.state
        XCTAssertEqual(end.program, 2)
        XCTAssertEqual(end.preview, 1)
        XCTAssertFalse(end.transition.isActive)
    }

    /// Shift + 点 / Shift + 数字（setProgram）同样被拒：切出去的底图不换，转场结束后 PVW 拿到的是开始时的 1 号。
    func testV6_setProgramRejectedDuringTransition() async {
        let start = Tick(100)
        let s1 = reducer.reduce(Self.baseState(), .fade(durationTicks: 30), at: start)
        for k in 0..<30 {
            let sk = reducer.advance(s1, to: start + k)
            XCTAssertEqual(reducer.reduce(sk, .setProgram(input: 3), at: start + k), sk, "第 s + \(k) 拍 setProgram 原样返回")
            XCTAssertEqual(reducer.reduce(sk, .setProgram(input: 0), at: start + k), sk, "第 s + \(k) 拍 setProgram 黑场原样返回")
        }
        let mid = reducer.reduce(reducer.advance(s1, to: start + 10), .setProgram(input: 3), at: start + 10)
        XCTAssertEqual(mid.program, 1)
        let done = reducer.advance(mid, to: start + 30)
        XCTAssertEqual(done.program, 2)
        XCTAssertEqual(done.preview, 1, "切出去的仍是开始时的 1 号，不是 3 号")
        for type in [TransitionType.wipe, .zoom, .stinger] {
            let auto = reducer.reduce(reducer.reduce(Self.stingerReadyState(), .setTransition(type: type, durationTicks: 20), at: Tick(0)), .autoTransition, at: Tick(10))
            let m = reducer.advance(auto, to: Tick(15))
            XCTAssertEqual(reducer.reduce(m, .setProgram(input: 4), at: Tick(15)), m, "\(type) 进行中 setProgram 原样返回")
        }

        let sm = StateMachine(initialState: Self.baseState())
        sm.start()
        defer { sm.stop() }
        await sm.schedule(.fade(durationTicks: 30), at: start)
        await sm.prepare(upTo: start + 10)
        guard case .applied(let receipt) = await sm.submit(IssuedCommand(sequence: 1, issuedAt: .now(), command: .setProgram(input: 3))) else {
            return XCTFail("setProgram 应走到 reducer（结构合法）")
        }
        XCTAssertFalse(receipt.applied, "转场进行中 setProgram 被拒")
        XCTAssertEqual(sm.publisher.latest!.state.program, 1, "快照 PGM 底图仍是 1")
        await sm.prepare(upTo: start + 30)
        let end = await sm.state
        XCTAssertEqual(end.program, 2)
        XCTAssertEqual(end.preview, 1)
    }

    /// 转场一结束就照常收：对调那一拍（状态机每拍先 advance 再应用该拍的命令）、Cut 打断之后、T-bar 推到底提交之后。
    func testV6_setPreviewAcceptedAfterTransitionCompletes() async {
        let start = Tick(100)
        let s1 = reducer.reduce(Self.baseState(), .fade(durationTicks: 30), at: start)
        let done = reducer.advance(s1, to: start + 30)
        XCTAssertFalse(done.transition.isActive)
        var expected = done
        expected.preview = 3
        XCTAssertEqual(reducer.reduce(done, .setPreview(input: 3), at: start + 30), expected, "对调那一拍就收，只动 preview")
        expected = done
        expected.program = 4
        XCTAssertEqual(reducer.reduce(done, .setProgram(input: 4), at: start + 30), expected, "对调那一拍就收，只动 program")
        // Cut 打断进行中的转场（立即对调）之后
        let cut = reducer.reduce(reducer.advance(s1, to: start + 10), .cut, at: start + 10)
        XCTAssertEqual(reducer.reduce(cut, .setPreview(input: 3), at: start + 10).preview, 3)
        // T-bar 推到底提交之后
        let committed = reducer.reduce(reducer.reduce(Self.baseState(), .tbar(progress: 0.6), at: Tick(1)), .tbar(progress: 1), at: Tick(2))
        XCTAssertFalse(committed.transition.isActive)
        XCTAssertEqual(reducer.reduce(committed, .setPreview(input: 3), at: Tick(3)).preview, 3)
        XCTAssertEqual(reducer.reduce(committed, .setProgram(input: 4), at: Tick(3)).program, 4)

        // 状态机：同一个 Fade，对调前一拍排的 setPreview(4) 被拒，对调那一拍排的 setPreview(3) 生效
        let sm = StateMachine(initialState: Self.baseState())
        sm.start()
        defer { sm.stop() }
        await sm.schedule(.fade(durationTicks: 30), at: start)
        await sm.schedule(.setPreview(input: 4), at: start + 29)
        await sm.schedule(.setPreview(input: 3), at: start + 30)
        await sm.prepare(upTo: start + 29)
        XCTAssertEqual(sm.publisher.latest!.state.preview, 2, "对调前一拍还在转场：被拒")
        await sm.prepare(upTo: start + 30)
        let end = await sm.state
        XCTAssertEqual(end.program, 2)
        XCTAssertEqual(end.preview, 3, "对调那一拍已空闲：生效")
        guard case .applied(let receipt) = await sm.submit(IssuedCommand(sequence: 1, issuedAt: .now(), command: .setProgram(input: 4))) else {
            return XCTFail("setProgram 应走到 reducer")
        }
        XCTAssertTrue(receipt.applied, "空闲时 setProgram 照常生效")
    }

    /// T-bar 推到一半算转场进行中：现有 isActive 的 `progress > 0` 已经包含推杆在 (0, 1) 的情况（契约 isActive 不用改）；
    /// 拉回 0 = 取消（progress 0、无 startTick）不再算，照常收。T-bar 接管进行中的 auto 转场后也一样拒。
    func testV6_tbarPartialCountsAsActive() {
        let s0 = Self.baseState()
        for p in [1.0 / 127.0, 0.25, 0.5, 0.99] {
            let bar = reducer.reduce(s0, .tbar(progress: p), at: Tick(5))
            XCTAssertTrue(bar.transition.isActive, "T-bar \(p)")
            XCTAssertNil(bar.transition.startTick, "T-bar 没有起始拍，只靠 progress > 0 算进行中")
            XCTAssertEqual(reducer.reduce(bar, .setPreview(input: 3), at: Tick(6)), bar, "T-bar \(p) 时 setPreview 原样返回")
            XCTAssertEqual(reducer.reduce(bar, .setProgram(input: 3), at: Tick(6)), bar, "T-bar \(p) 时 setProgram 原样返回")
        }
        let taken = reducer.reduce(reducer.advance(reducer.reduce(s0, .fade(durationTicks: 30), at: Tick(10)), to: Tick(20)), .tbar(progress: 0.7), at: Tick(20))
        XCTAssertEqual(reducer.reduce(taken, .setPreview(input: 3), at: Tick(21)), taken, "T-bar 接管 auto 转场后 setPreview 原样返回")
        XCTAssertEqual(reducer.reduce(taken, .setProgram(input: 3), at: Tick(21)), taken, "T-bar 接管 auto 转场后 setProgram 原样返回")
        // 拉回 0：取消，照常收
        let back = reducer.reduce(reducer.reduce(s0, .tbar(progress: 0.5), at: Tick(5)), .tbar(progress: 0), at: Tick(6))
        XCTAssertFalse(back.transition.isActive)
        XCTAssertEqual(back.program, 1)
        XCTAssertEqual(back.preview, 2)
        XCTAssertEqual(reducer.reduce(back, .setPreview(input: 3), at: Tick(7)).preview, 3)
        XCTAssertEqual(reducer.reduce(back, .setProgram(input: 4), at: Tick(7)).program, 4)
    }

    // MARK: V7 转场进度

    func testV7_fade30_progressIsKOver30_thenSwapAtTick30() {
        let s0 = Self.baseState()
        let start = Tick(200)
        let s1 = reducer.reduce(s0, .fade(durationTicks: 30), at: start)
        XCTAssertEqual(s1.transition.type, .fade)
        XCTAssertEqual(s1.transition.durationTicks, 30)
        XCTAssertEqual(s1.transition.startTick, start)
        XCTAssertEqual(s1.transition.source, .auto)
        XCTAssertEqual(s1.transition.progress, 0)
        XCTAssertTrue(s1.transition.isActive, "第 s 拍起 PVW 就在 PGM 上（tally）")
        XCTAssertEqual(s1.tally(ofInput: 2), Tally(program: true, preview: true))
        for k in 0..<30 {
            let sk = reducer.advance(s1, to: start + k)
            XCTAssertEqual(sk.transition.progress, Double(k) / 30.0, "第 s + \(k) 拍 progress = k / 30")
            XCTAssertEqual(sk.program, 1)
            XCTAssertEqual(sk.preview, 2)
        }
        let done = reducer.advance(s1, to: start + 30)
        XCTAssertEqual(done.program, 2)
        XCTAssertEqual(done.preview, 1)
        XCTAssertEqual(done.transition.progress, 0)
        XCTAssertNil(done.transition.startTick)
        XCTAssertFalse(done.transition.isActive)
        XCTAssertEqual(done.transition.type, .fade, "空闲时 type / duration 保留为下一次的选择")
        // 逐拍推进（状态机的用法）与一步到位结果相同
        var step = s1
        for k in 1...30 { step = reducer.advance(step, to: start + k) }
        XCTAssertEqual(step, done)
        // 完成后再 advance 不变
        XCTAssertEqual(reducer.advance(done, to: start + 31), done)
    }

    func testV7_autoTransition_wipeZoomStinger_sameProgressRule() {
        for type in [TransitionType.wipe, .zoom, .stinger] {
            var s = reducer.reduce(Self.stingerReadyState(), .setTransition(type: type, durationTicks: 10), at: Tick(0))   // 029：Stinger 要选了输入
            XCTAssertEqual(s.transition.type, type)
            XCTAssertFalse(s.transition.isActive, "setTransition 不开始")
            s = reducer.reduce(s, .autoTransition, at: Tick(50))
            XCTAssertEqual(s.transition.startTick, Tick(50))
            XCTAssertEqual(reducer.advance(s, to: Tick(55)).transition.progress, 0.5)
            let done = reducer.advance(s, to: Tick(60))
            XCTAssertEqual(done.program, 2)
            XCTAssertFalse(done.transition.isActive)
        }
        // 选了 cut 类型的 autoTransition = 立即对调；时长 0 同理
        let cutType = reducer.reduce(reducer.reduce(Self.baseState(), .setTransition(type: .cut, durationTicks: 30), at: Tick(0)), .autoTransition, at: Tick(1))
        XCTAssertEqual(cutType.program, 2)
        XCTAssertFalse(cutType.transition.isActive)
        let zero = reducer.reduce(Self.baseState(), .fade(durationTicks: 0), at: Tick(1))
        XCTAssertEqual(zero.program, 2)
        XCTAssertFalse(zero.transition.isActive)
        // 进行中再发 autoTransition / fade / setTransition 忽略
        let active = reducer.reduce(Self.baseState(), .fade(durationTicks: 30), at: Tick(10))
        XCTAssertEqual(reducer.reduce(active, .autoTransition, at: Tick(11)), active)
        XCTAssertEqual(reducer.reduce(active, .fade(durationTicks: 5), at: Tick(11)), active)
        XCTAssertEqual(reducer.reduce(active, .setTransition(type: .wipe, durationTicks: 5), at: Tick(11)), active)
        XCTAssertEqual(reducer.reduce(Self.baseState(), .fade(durationTicks: -1), at: Tick(1)), Self.baseState(), "负时长忽略")
    }

    func testV7_tbar_25_50_75_mapping_andCommitAt1() {
        let s0 = Self.baseState()
        for p in [0.25, 0.5, 0.75] {
            let s = reducer.reduce(s0, .tbar(progress: p), at: Tick(7))
            XCTAssertEqual(s.transition.progress, p, "T-bar \(p) 直接映射为混合比例")
            XCTAssertEqual(s.transition.source, .tbar)
            XCTAssertNil(s.transition.startTick)
            XCTAssertTrue(s.transition.isActive)
            XCTAssertEqual(s.program, 1); XCTAssertEqual(s.preview, 2)
            XCTAssertEqual(reducer.advance(s, to: Tick(100)).transition.progress, p, "手动模式 advance 不推进")
        }
        // 推杆位置钳到 0…1
        XCTAssertEqual(reducer.reduce(s0, .tbar(progress: -0.5), at: Tick(1)).transition.progress, 0)
        // 推到 1.0 提交：对调并回到 0 / auto
        let half = reducer.reduce(s0, .tbar(progress: 0.5), at: Tick(1))
        let committed = reducer.reduce(half, .tbar(progress: 1.0), at: Tick(2))
        XCTAssertEqual(committed.program, 2)
        XCTAssertEqual(committed.preview, 1)
        XCTAssertEqual(committed.transition.progress, 0)
        XCTAssertEqual(committed.transition.source, .auto)
        XCTAssertFalse(committed.transition.isActive)
        XCTAssertEqual(reducer.reduce(s0, .tbar(progress: 1.7), at: Tick(2)).program, 2, "> 1 也算提交")
        // T-bar 接管进行中的 auto 转场
        let auto = reducer.reduce(s0, .fade(durationTicks: 30), at: Tick(10))
        let taken = reducer.reduce(reducer.advance(auto, to: Tick(20)), .tbar(progress: 0.9), at: Tick(20))
        XCTAssertEqual(taken.transition.source, .tbar)
        XCTAssertEqual(taken.transition.progress, 0.9)
        XCTAssertNil(taken.transition.startTick)
    }

    func testV7_ftb_levelRamps_andToggleContinuesFromCurrentLevel() {
        var s0 = Self.baseState()
        s0.ftb.durationTicks = 20
        let on = reducer.reduce(s0, .ftb(on: true), at: Tick(100))
        XCTAssertTrue(on.ftb.on)
        XCTAssertEqual(on.ftb.startTick, Tick(100))
        XCTAssertEqual(on.ftb.level, 0)
        for k in 0...20 {
            XCTAssertEqual(reducer.advance(on, to: Tick(100 + Int64(k))).ftb.level, Double(k) / 20.0, accuracy: 1e-12)
        }
        let black = reducer.advance(on, to: Tick(130))
        XCTAssertEqual(black.ftb.level, 1)
        XCTAssertNil(black.ftb.startTick, "到位后空闲")
        XCTAssertEqual(black.tally(ofInput: 1).program, true, "FTB 不改 tally")
        // 中途（level 0.4）关掉：从 0.4 往 0 走，8 拍到 0，不跳变
        let mid = reducer.advance(on, to: Tick(108))
        XCTAssertEqual(mid.ftb.level, 0.4, accuracy: 1e-12)
        let off = reducer.reduce(mid, .ftb(on: false), at: Tick(108))
        XCTAssertFalse(off.ftb.on)
        XCTAssertEqual(off.ftb.level, 0.4, accuracy: 1e-12, "关的那一拍电平不变")
        XCTAssertEqual(reducer.advance(off, to: Tick(112)).ftb.level, 0.2, accuracy: 1e-12)
        let clear = reducer.advance(off, to: Tick(116))
        XCTAssertEqual(clear.ftb.level, 0)
        XCTAssertNil(clear.ftb.startTick)
        // 重复同样的目标：不重启动画
        XCTAssertEqual(reducer.reduce(on, .ftb(on: true), at: Tick(105)), on)
        // 时长 0：立即到位
        var instant = Self.baseState(); instant.ftb.durationTicks = 0
        let i1 = reducer.reduce(instant, .ftb(on: true), at: Tick(3))
        XCTAssertEqual(i1.ftb.level, 1); XCTAssertNil(i1.ftb.startTick)
    }

    func testV7_overlay_onOffWithAnimation_andInputSwitch() {
        let s0 = Self.baseState()
        // 通道 2 设动画 fade 10 拍，然后开
        let cfg = reducer.reduce(s0, .setOverlay(channel: 2, rect: .bottomRightQuarter, animation: OverlayAnimation(kind: .fade, durationTicks: 10)), at: Tick(0))
        XCTAssertEqual(cfg.overlays[1].rect, .bottomRightQuarter)
        XCTAssertEqual(cfg.overlays[1].animation.durationTicks, 10)
        let on = reducer.reduce(cfg, .overlay(channel: 2, on: true, input: 3), at: Tick(50))
        XCTAssertEqual(on.overlays[1].input, 3)
        XCTAssertTrue(on.overlays[1].on)
        XCTAssertEqual(on.overlays[1].startTick, Tick(50))
        XCTAssertEqual(on.overlays[1].animProgress, 0)
        XCTAssertTrue(on.overlays[1].isVisible)
        XCTAssertEqual(on.tally(ofInput: 3).program, true)
        XCTAssertEqual(reducer.advance(on, to: Tick(55)).overlays[1].animProgress, 0.5)
        let shown = reducer.advance(on, to: Tick(60))
        XCTAssertEqual(shown.overlays[1].animProgress, 1)
        XCTAssertNil(shown.overlays[1].startTick)
        // 关：从 1 退到 0；退出动画期间仍可见（tally 仍在 PGM）
        let off = reducer.reduce(shown, .overlay(channel: 2, on: false, input: nil), at: Tick(70))
        XCTAssertFalse(off.overlays[1].on)
        XCTAssertEqual(off.overlays[1].input, 3, "input nil = 不换输入")
        let half = reducer.advance(off, to: Tick(75))
        XCTAssertEqual(half.overlays[1].animProgress, 0.5)
        XCTAssertTrue(half.overlays[1].isVisible)
        let hidden = reducer.advance(off, to: Tick(80))
        XCTAssertEqual(hidden.overlays[1].animProgress, 0)
        XCTAssertFalse(hidden.overlays[1].isVisible)
        // 只换输入不改开关
        let swapped = reducer.reduce(shown, .overlay(channel: 2, on: true, input: 4), at: Tick(90))
        XCTAssertEqual(swapped.overlays[1].input, 4)
        XCTAssertEqual(swapped.overlays[1].animProgress, 1)
        XCTAssertNil(swapped.overlays[1].startTick, "开关没变不重启动画")
        // 默认 cut 动画（时长 0）：立即到位
        let instant = reducer.reduce(s0, .overlay(channel: 1, on: true, input: 2), at: Tick(1))
        XCTAssertEqual(instant.overlays[0].animProgress, 1)
        XCTAssertNil(instant.overlays[0].startTick)
        // 非法：通道 0 / 5、不存在的输入
        XCTAssertEqual(reducer.reduce(s0, .overlay(channel: 0, on: true, input: 1), at: Tick(1)), s0)
        XCTAssertEqual(reducer.reduce(s0, .overlay(channel: 5, on: true, input: 1), at: Tick(1)), s0)
        XCTAssertEqual(reducer.reduce(s0, .overlay(channel: 1, on: true, input: 99), at: Tick(1)), s0)
        XCTAssertEqual(reducer.reduce(s0, .setOverlay(channel: 9, rect: .full, animation: OverlayAnimation()), at: Tick(1)), s0)
    }

    // MARK: 每条命令的前后状态（表驱动）

    struct Row {
        let name: String
        let before: (inout MixerState) -> Void
        let command: Command
        let after: (inout MixerState) -> Void
        init(_ name: String, before: @escaping (inout MixerState) -> Void = { _ in }, _ command: Command, after: @escaping (inout MixerState) -> Void) {
            self.name = name; self.before = before; self.command = command; self.after = after
        }
    }

    func testW1B_reduce_everyCommand_beforeAfterTable() {
        let tick = Tick(42)
        let show = Show(name: "载入", state: { var s = Self.baseState(); s.program = 3; s.preview = 4; s.transition.progress = 0.5; s.transition.startTick = Tick(1); return s }())
        let rows: [Row] = [
            Row("cut", .cut) { $0.program = 2; $0.preview = 1 },
            Row("fade", .fade(durationTicks: 12)) { $0.transition.type = .fade; $0.transition.durationTicks = 12; $0.transition.startTick = tick; $0.transition.source = .auto
                                                     $0.transition.currentSlot = nil },   // 020：fade 12 不对应任何槽
            Row("fade 30 = 槽 1 仍对得上", .fade(durationTicks: 30)) { $0.transition.startTick = tick; $0.transition.source = .auto },   // 020：currentSlot 仍是 1
            Row("setTransition", .setTransition(type: .wipe, durationTicks: 15)) { $0.transition.type = .wipe; $0.transition.durationTicks = 15; $0.transition.currentSlot = nil },
            Row("setTransition 与槽 2 相同 → currentSlot 2", .setTransition(type: .wipe, durationTicks: 60)) { $0.transition.type = .wipe; $0.transition.durationTicks = 60; $0.transition.currentSlot = 2 },
            Row("autoTransition", .autoTransition) { $0.transition.startTick = tick },
            Row("setPreview", .setPreview(input: 3)) { $0.preview = 3 },
            Row("setPreview 黑场", .setPreview(input: 0)) { $0.preview = 0 },
            Row("setPreview 不存在", .setPreview(input: 9)) { _ in },
            Row("setProgram", .setProgram(input: 4)) { $0.program = 4 },
            Row("setProgram 不存在", .setProgram(input: -1)) { _ in },
            Row("setPreview auto 转场进行中拒绝（W5-E）", before: { $0.transition.startTick = Tick(40); $0.transition.progress = 2.0 / 30.0 }, .setPreview(input: 3)) { _ in },
            Row("setProgram T-bar 推到一半拒绝（W5-E）", before: { $0.transition.progress = 0.4; $0.transition.source = .tbar }, .setProgram(input: 4)) { _ in },
            Row("tbar", .tbar(progress: 0.3)) { $0.transition.progress = 0.3; $0.transition.source = .tbar },
            // 020 追加（用户 2026-10-17，P5-4）：推到一半改了当前槽，拉回 0 取消那一拍按 currentSlot 重拷当前那组；还在推不重拷；currentSlot nil 不重拷
            Row("tbar 推到一半改过当前槽、推杆还在中间：不重拷",
                before: { $0.transition.progress = 0.4; $0.transition.source = .tbar; $0.transition.slots[0] = TransitionSlot(type: .zoom, durationTicks: 12) },
                .tbar(progress: 0.6)) { $0.transition.progress = 0.6 },
            Row("tbar 拉回 0 取消：按当前槽重拷（020 追加）",
                before: { $0.transition.progress = 0.4; $0.transition.source = .tbar; $0.transition.slots[0] = TransitionSlot(type: .zoom, durationTicks: 12) },
                .tbar(progress: 0)) { $0.transition.progress = 0; $0.transition.type = .zoom; $0.transition.durationTicks = 12 },
            Row("tbar 拉回 0、当前那组不对应槽（currentSlot nil）：不重拷",
                before: { $0.transition.progress = 0.4; $0.transition.source = .tbar; $0.transition.durationTicks = 45; $0.transition.currentSlot = nil },
                .tbar(progress: 0)) { $0.transition.progress = 0 },
            Row("ftb on", .ftb(on: true)) { $0.ftb.on = true; $0.ftb.startTick = tick },
            Row("ftb off 已经是 off", .ftb(on: false)) { _ in },
            Row("overlay", .overlay(channel: 3, on: true, input: 2)) { $0.overlays[2].on = true; $0.overlays[2].input = 2; $0.overlays[2].animProgress = 1 },
            Row("setOverlay", .setOverlay(channel: 1, rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), animation: OverlayAnimation(kind: .slide, durationTicks: 6))) {
                $0.overlays[0].rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4); $0.overlays[0].animation = OverlayAnimation(kind: .slide, durationTicks: 6) },
            Row("audioGain", .audioGain(input: 2, dB: -6)) { $0.inputs[1].settings.audio.gainDb = -6 },
            Row("audioGain 钳到范围", .audioGain(input: 2, dB: 99)) { $0.inputs[1].settings.audio.gainDb = 24 },
            Row("audioGain 不存在", .audioGain(input: 7, dB: -6)) { _ in },
            Row("mute", .mute(input: 1, on: true)) { $0.inputs[0].settings.audio.muted = true },
            Row("busGain", .busGain(bus: .busA, dB: 3)) { $0.audio.buses[1].gainDb = 3 },
            Row("busMute", .busMute(bus: .headphones, on: true)) { $0.audio.buses[3].muted = true },
            Row("setAFV", .setAFV(on: true)) { $0.audio.afv = true },
            Row("startRecord", .startRecord(output: 1)) { $0.outputs[0].enabled = true },
            Row("stopRecord", before: { $0.outputs[0].enabled = true }, .stopRecord(output: 1)) { $0.outputs[0].enabled = false },
            Row("startRecord 对推流输出无效", .startRecord(output: 2)) { _ in },
            Row("startStream", .startStream(output: 2)) { $0.outputs[1].enabled = true },
            Row("stopStream", before: { $0.outputs[1].enabled = true }, .stopStream(output: 2)) { $0.outputs[1].enabled = false },
            Row("startStream 对录制输出无效", .startStream(output: 1)) { _ in },
            Row("startStream 不存在", .startStream(output: 5)) { _ in },
            Row("setInputSettings 先 clamped", .setInputSettings(input: 3, settings: { var s = InputSettings(); s.audio.delayMs = 900; s.audio.pan = 0.5; return s }())) {
                var s = InputSettings(); s.audio.delayMs = 500; s.audio.pan = 0.5; $0.inputs[2].settings = s },
            Row("renameInput", .renameInput(input: 4, name: "讲台")) { $0.inputs[3].name = "讲台" },
            Row("renameInput 不存在", .renameInput(input: 8, name: "x")) { _ in },
            Row("addInput 编号已存在拒绝", .addInput(config: InputConfig(number: 3, name: "重复", source: .image(path: "/a.png")))) { _ in },
            Row("addInput 插在中间保持升序", before: { $0.inputs.remove(at: 1); $0.preview = 0 }, .addInput(config: InputConfig(number: 2, name: "回填", source: .image(path: "/b.png")))) {
                $0.inputs.insert(InputConfig(number: 2, name: "回填", source: .image(path: "/b.png")), at: 1) },
            Row("addInput", .addInput(config: InputConfig(number: 6, name: "图片", source: .image(path: "/a.png")))) {
                $0.inputs.append(InputConfig(number: 6, name: "图片", source: .image(path: "/a.png"))) },
            Row("addInput 编号 0 拒绝", .addInput(config: InputConfig(number: 0, name: "黑", source: .image(path: "/a.png")))) { _ in },
            Row("removeInput 清引用", before: { $0.overlays[0].input = 2; $0.overlays[0].on = true }, .removeInput(input: 2)) {
                $0.inputs.remove(at: 1); $0.preview = 0; $0.overlays[0].input = nil },
            Row("addOutput", .addOutput(config: OutputState(number: 3, kind: .ndi, name: "NDI"))) { $0.outputs.append(OutputState(number: 3, kind: .ndi, name: "NDI")) },
            Row("addOutput 重复编号", .addOutput(config: OutputState(number: 2, kind: .ndi, name: "NDI"))) { _ in },
            Row("removeOutput", .removeOutput(output: 1)) { $0.outputs.remove(at: 0) },
            Row("setOutputSettings", .setOutputSettings(output: 2, settings: OutputSettings(source: .preview))) { $0.outputs[1].settings = OutputSettings(source: .preview) },
            Row("setOutputSettings 不存在", .setOutputSettings(output: 4, settings: OutputSettings())) { _ in },
            Row("loadShow 整体替换并清瞬态", .loadShow(show: show)) { $0 = show.makeState() },

            // P3：提案 010 A4 / 012 的六条新命令
            Row("setOverlayDecoration", .setOverlayDecoration(channel: 2, border: OverlayBorder(width: 0.01, color: RGB8(red: 255, green: 0, blue: 0)),
                                                              anchor: .bottomRight, previewOn: true)) {
                $0.overlays[1].border = OverlayBorder(width: 0.01, color: RGB8(red: 255, green: 0, blue: 0))
                $0.overlays[1].anchor = .bottomRight
                $0.overlays[1].previewOn = true },
            Row("setOverlayDecoration 通道越界拒绝", .setOverlayDecoration(channel: 5, border: nil, anchor: .center, previewOn: true)) { _ in },
            Row("setMonitorMode", .setMonitorMode(mode: .pfl)) { $0.audio.monitorMode = .pfl },
            // 提案 026（P5）：耳机听哪条总线
            Row("setMonitorSource", .setMonitorSource(bus: .busB)) { $0.audio.monitorSource = .busB },
            Row("setMonitorSource headphones = 听耳机总线自己（P5-3 起合法）", .setMonitorSource(bus: .headphones)) { $0.audio.monitorSource = .headphones },
            Row("setMonitorSource 相同值原样返回", .setMonitorSource(bus: .master)) { _ in },
            Row("setBusEffects", .setBusEffects(bus: .busA, effects: [EffectSlot(id: "peakLimiter")])) {
                $0.audio.buses[Bus.busA.rawValue].effects = [EffectSlot(id: "peakLimiter")] },
            Row("setOutputEnabled 非录制 / 推流", before: { $0.outputs.append(OutputState(number: 3, kind: .ndi, name: "NDI")) },
                .setOutputEnabled(output: 3, on: true)) { $0.outputs[2].enabled = true },
            Row("setOutputEnabled 录制输出被拒（走 startRecord）", .setOutputEnabled(output: 1, on: true)) { _ in },
            Row("setOutputEnabled 推流输出被拒（走 startStream）", .setOutputEnabled(output: 2, on: true)) { _ in },
            Row("setOutputEnabled 不存在", .setOutputEnabled(output: 9, on: true)) { _ in },
            Row("renameOutput", .renameOutput(output: 2, name: "主推流")) { $0.outputs[1].name = "主推流" },
            Row("renameOutput 不存在", .renameOutput(output: 9, name: "x")) { _ in },
            Row("setInputSource 保留编号 / 名字 / 设置 / 引用",
                before: { $0.overlays[0].input = 3; $0.overlays[0].on = true; $0.inputs[2].settings.audio.gainDb = -6 },
                .setInputSource(input: 3, source: .ndi(sourceName: "MAC (Cam)", bandwidth: .lowest, jitterBufferFrames: 2))) {
                $0.inputs[2].source = .ndi(sourceName: "MAC (Cam)", bandwidth: .lowest, jitterBufferFrames: 2) },
            Row("setInputSource 不存在", .setInputSource(input: 9, source: .image(path: "/a.png"))) { _ in },

            // 提案 016：改 Wipe / Stinger 参数
            Row("setTransitionParams", .setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 3, cutAtTick: 12))) {
                $0.transition.wipe = WipeParams(direction: .topToBottom, softness: 0.2); $0.transition.stinger = StingerParams(input: 3, cutAtTick: 12); $0.transition.currentSlot = nil },
            Row("setTransitionParams 软边钳到 ≤ 1、换底拍钳到 ≥ 0",
                .setTransitionParams(wipe: WipeParams(direction: .diagonal, softness: 1.5), stinger: StingerParams(input: nil, cutAtTick: -4))) {
                $0.transition.wipe = WipeParams(direction: .diagonal, softness: 1); $0.transition.stinger = StingerParams(input: nil, cutAtTick: 0); $0.transition.currentSlot = nil },
            Row("setTransitionParams 软边钳到 ≥ 0", .setTransitionParams(wipe: WipeParams(direction: .rightToLeft, softness: -0.3), stinger: StingerParams())) {
                $0.transition.wipe = WipeParams(direction: .rightToLeft, softness: 0); $0.transition.currentSlot = nil },
            Row("setTransitionParams 与槽 1 相同 → currentSlot 仍 1", .setTransitionParams(wipe: WipeParams(), stinger: StingerParams())) { _ in },
            Row("setTransitionParams stinger 输入不存在拒绝",
                .setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 9, cutAtTick: 12))) { _ in },
            Row("setTransitionParams stinger 输入 0 拒绝（0 是黑场，不是输入）", .setTransitionParams(wipe: WipeParams(), stinger: StingerParams(input: 0, cutAtTick: 0))) { _ in },
            Row("setTransitionParams T-bar 推到一半拒绝", before: { $0.transition.progress = 0.4; $0.transition.source = .tbar },
                .setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams())) { _ in },

            // 提案 020（P5-2）：转场槽与 FTB 时长
            Row("setTransitionSlot 改非当前槽只动槽", .setTransitionSlot(slot: 3, config: TransitionSlot(type: .zoom, durationTicks: 20))) {
                $0.transition.slots[2] = TransitionSlot(type: .zoom, durationTicks: 20) },
            Row("setTransitionSlot 改当前槽、空闲时当前那组同时重拷", .setTransitionSlot(slot: 1, config: TransitionSlot(type: .fade, durationTicks: 12))) {
                $0.transition.slots[0] = TransitionSlot(type: .fade, durationTicks: 12); $0.transition.type = .fade; $0.transition.durationTicks = 12 },
            Row("setTransitionSlot 钳位（时长 ≥ 0、软边 0–1、换底拍 ≥ 0）",
                .setTransitionSlot(slot: 2, config: TransitionSlot(type: .wipe, durationTicks: -5, wipe: WipeParams(direction: .diagonal, softness: 2), stinger: StingerParams(input: nil, cutAtTick: -1)))) {
                $0.transition.slots[1] = TransitionSlot(type: .wipe, durationTicks: 0, wipe: WipeParams(direction: .diagonal, softness: 1), stinger: StingerParams(input: nil, cutAtTick: 0)) },
            Row("setTransitionSlot 槽越界拒绝", .setTransitionSlot(slot: 5, config: TransitionSlot(type: .fade, durationTicks: 1))) { _ in },
            Row("setTransitionSlot 槽 0 拒绝", .setTransitionSlot(slot: 0, config: TransitionSlot(type: .fade, durationTicks: 1))) { _ in },
            Row("setTransitionSlot stinger 输入不存在拒绝", .setTransitionSlot(slot: 4, config: TransitionSlot(type: .stinger, durationTicks: 60, stinger: StingerParams(input: 9, cutAtTick: 0)))) { _ in },
            Row("setTransitionSlot 相同配置原样返回", .setTransitionSlot(slot: 1, config: TransitionSlot(type: .fade, durationTicks: 30))) { _ in },
            Row("setTransitionSlot 转场进行中也收（只改槽，当前那组不动）", before: { $0.transition.startTick = Tick(40); $0.transition.progress = 2.0 / 30.0 },
                .setTransitionSlot(slot: 1, config: TransitionSlot(type: .fade, durationTicks: 12))) { $0.transition.slots[0] = TransitionSlot(type: .fade, durationTicks: 12) },
            Row("useTransitionSlot 只选中", .useTransitionSlot(slot: 2, start: false)) {
                $0.transition.type = .wipe; $0.transition.durationTicks = 60; $0.transition.wipe = WipeParams(direction: .leftToRight, softness: 0); $0.transition.stinger = StingerParams(); $0.transition.currentSlot = 2 },
            Row("useTransitionSlot 选中并开始", .useTransitionSlot(slot: 3, start: true)) {
                $0.transition.type = .zoom; $0.transition.durationTicks = 60; $0.transition.currentSlot = 3; $0.transition.startTick = tick; $0.transition.source = .auto; $0.transition.progress = 0 },
            // 提案 029（P5-3）：没选输入的 Stinger 槽不执行（不选中、不开始）；只选中照常；选了输入照常开始；autoTransition 要执行的当前那组是这种也拒
            Row("useTransitionSlot Stinger 槽没选输入拒绝（029）", .useTransitionSlot(slot: 4, start: true)) { _ in },
            Row("useTransitionSlot Stinger 槽没选输入只选中照常（029）", .useTransitionSlot(slot: 4, start: false)) {
                $0.transition.type = .stinger; $0.transition.durationTicks = 60; $0.transition.currentSlot = 4 },
            Row("useTransitionSlot Stinger 槽选了输入照常开始", before: { $0.transition.slots[3].stinger.input = 3 }, .useTransitionSlot(slot: 4, start: true)) {
                $0.transition.type = .stinger; $0.transition.durationTicks = 60; $0.transition.stinger.input = 3; $0.transition.currentSlot = 4
                $0.transition.startTick = tick; $0.transition.source = .auto },
            Row("autoTransition 当前槽是没选输入的 Stinger 拒绝（029）", before: { $0.transition.select(slot: 4) }, .autoTransition) { _ in },
            Row("autoTransition 当前那组是没选输入的 Stinger（不对应槽）也拒绝（029）",
                before: { $0.transition.type = .stinger; $0.transition.durationTicks = 45; $0.transition.currentSlot = nil }, .autoTransition) { _ in },
            Row("autoTransition 当前那组是选了输入的 Stinger 照常开始",
                before: { $0.transition.type = .stinger; $0.transition.durationTicks = 45; $0.transition.stinger.input = 3; $0.transition.currentSlot = nil }, .autoTransition) {
                $0.transition.startTick = tick },
            Row("useTransitionSlot 转场进行中拒绝", before: { $0.transition.startTick = Tick(40); $0.transition.progress = 2.0 / 30.0 }, .useTransitionSlot(slot: 2, start: true)) { _ in },
            Row("useTransitionSlot T-bar 推到一半拒绝", before: { $0.transition.progress = 0.4; $0.transition.source = .tbar }, .useTransitionSlot(slot: 2, start: false)) { _ in },
            Row("useTransitionSlot 槽越界拒绝", .useTransitionSlot(slot: 0, start: true)) { _ in },
            Row("useTransitionSlot 已是当前槽且相同 → 原样返回", .useTransitionSlot(slot: 1, start: false)) { _ in },
            Row("setFTBDuration", .setFTBDuration(ticks: 15)) { $0.ftb.durationTicks = 15 },
            Row("setFTBDuration 负拒绝", .setFTBDuration(ticks: -1)) { _ in },
            Row("setFTBDuration 相同值原样返回", .setFTBDuration(ticks: 30)) { _ in },

            // 提案 021（P5-2）：文件输入播放控制（基础状态都是合成源，先加一路文件输入 5）
            Row("setPlayback", before: { $0.inputs.append(Self.fileInput(5)) }, .setPlayback(input: 5, paused: true)) { $0.inputs[4].settings.playback.paused = true },
            Row("setPlayback 相同值原样返回", before: { $0.inputs.append(Self.fileInput(5)) }, .setPlayback(input: 5, paused: false)) { _ in },
            Row("setPlayback 非文件输入拒绝", .setPlayback(input: 1, paused: true)) { _ in },
            Row("setPlayback 不存在", .setPlayback(input: 9, paused: true)) { _ in },
            Row("seekPlayback", before: { $0.inputs.append(Self.fileInput(5)) }, .seekPlayback(input: 5, seconds: 12.5)) {
                $0.inputs[4].settings.playback.seekSeconds = 12.5; $0.inputs[4].settings.playback.seekTick = tick },
            Row("seekPlayback 负数拒绝（校验器同判，与 fade 负时长一样）", before: { $0.inputs.append(Self.fileInput(5)) }, .seekPlayback(input: 5, seconds: -3)) { _ in },
            Row("seekPlayback 0 = 从头", before: { $0.inputs.append(Self.fileInput(5)) }, .seekPlayback(input: 5, seconds: 0)) {
                $0.inputs[4].settings.playback.seekSeconds = 0; $0.inputs[4].settings.playback.seekTick = tick },
            Row("seekPlayback 同一拍同一位置原样返回", before: { $0.inputs.append(Self.fileInput(5)); $0.inputs[4].settings.playback.seekSeconds = 4; $0.inputs[4].settings.playback.seekTick = tick },
                .seekPlayback(input: 5, seconds: 4)) { _ in },
            Row("seekPlayback 非有限拒绝", before: { $0.inputs.append(Self.fileInput(5)) }, .seekPlayback(input: 5, seconds: .nan)) { _ in },
            Row("seekPlayback 非文件输入拒绝", .seekPlayback(input: 2, seconds: 1)) { _ in },

            // 提案 023 四 / 五（P5-2）：分类颜色、细粒度音频
            Row("setInputColor", .setInputColor(input: 1, color: .red)) { $0.inputs[0].color = .red },
            Row("setInputColor 清掉", before: { $0.inputs[1].color = .blue }, .setInputColor(input: 2, color: nil)) { $0.inputs[1].color = nil },
            Row("setInputColor 相同值原样返回", .setInputColor(input: 1, color: nil)) { _ in },
            Row("setInputColor 不存在", .setInputColor(input: 9, color: .green)) { _ in },
            Row("setInputAudio 只动 solo", .setInputAudio(input: 1, solo: true)) { $0.inputs[0].settings.audio.solo = true },
            Row("setInputAudio 三项", .setInputAudio(input: 2, solo: true, afv: false, routing: BusRouting(master: true, busA: true))) {
                $0.inputs[1].settings.audio.solo = true; $0.inputs[1].settings.audio.afv = false; $0.inputs[1].settings.audio.routing = BusRouting(master: true, busA: true) },
            Row("setInputAudio 全 nil 原样返回", .setInputAudio(input: 1)) { _ in },
            Row("setInputAudio 全与现状相同原样返回", .setInputAudio(input: 1, solo: false, afv: true, routing: .masterOnly)) { _ in },
            Row("setInputAudio 不存在", .setInputAudio(input: 9, solo: true)) { _ in },
        ]
        var covered = Set<String>()
        for row in rows {
            var before = Self.baseState()
            row.before(&before)
            var expected = before
            row.after(&expected)
            let actual = reducer.reduce(before, row.command, at: tick)
            XCTAssertEqual(actual, expected, row.name)
            covered.insert(Self.caseName(row.command))
        }
        XCTAssertEqual(covered.count, Self.allCaseNames.count, "42 个 case 每个至少一行：缺 \(Set(Self.allCaseNames).subtracting(covered))")
    }

    func testW1B_reduce_isPureAndDoesNotMutateInput() {
        let s = Self.baseState()
        let copy = s
        let a = reducer.reduce(s, .fade(durationTicks: 30), at: Tick(5))
        let b = reducer.reduce(s, .fade(durationTicks: 30), at: Tick(5))
        XCTAssertEqual(a, b)
        XCTAssertEqual(s, copy)
        XCTAssertEqual(reducer.advance(a, to: Tick(20)), reducer.advance(a, to: Tick(20)))
        // advance 到 startTick 之前的拍：进度钳在 0
        XCTAssertEqual(reducer.advance(a, to: Tick(1)).transition.progress, 0)
    }

    /// 提案 012 B：换来源不碰编号 / 名字 / 设置，也不碰 PGM / PVW / 叠加引用（与 removeInput + addInput 的关键区别）。
    func testP3_setInputSource_keepsNumberNameSettingsAndReferences() {
        var s = Self.baseState()
        s.overlays[0].input = 2
        s.overlays[0].on = true
        s.inputs[1].settings.audio.gainDb = -12
        s.inputs[1].name = "主持人"
        let after = reducer.reduce(s, .setInputSource(input: 2, source: .file(path: "/a.mov", endAction: .loop, rate: 1)), at: Tick(7))
        XCTAssertEqual(after.inputs[1].source, .file(path: "/a.mov", endAction: .loop, rate: 1))
        XCTAssertEqual(after.inputs[1].kind, .file, "kind 由 source 推出")
        XCTAssertEqual(after.inputs[1].number, 2)
        XCTAssertEqual(after.inputs[1].name, "主持人")
        XCTAssertEqual(after.inputs[1].settings.audio.gainDb, -12)
        XCTAssertEqual(after.program, s.program)
        XCTAssertEqual(after.preview, s.preview)
        XCTAssertEqual(after.overlays[0].input, 2, "叠加引用保留")
        // 对照：removeInput 会清掉引用
        let removed = reducer.reduce(s, .removeInput(input: 2), at: Tick(7))
        XCTAssertNil(removed.overlays[0].input)
    }

    /// 提案 012：相同值的命令 reducer 原样返回（状态机据此把回执的 applied 置 false）。
    func testP3_newCommands_sameValueLeavesStateUnchanged() {
        var s = Self.baseState()
        s.outputs.append(OutputState(number: 3, kind: .ndi, name: "NDI", enabled: true))
        XCTAssertEqual(reducer.reduce(s, .setOutputEnabled(output: 3, on: true), at: Tick(1)), s)
        XCTAssertEqual(reducer.reduce(s, .renameOutput(output: 3, name: "NDI"), at: Tick(1)), s)
        XCTAssertEqual(reducer.reduce(s, .setMonitorMode(mode: s.audio.monitorMode), at: Tick(1)), s)
        XCTAssertEqual(reducer.reduce(s, .setBusEffects(bus: .master, effects: []), at: Tick(1)), s)
        XCTAssertEqual(reducer.reduce(s, .setOverlayDecoration(channel: 1, border: nil, anchor: .center, previewOn: false), at: Tick(1)), s)
    }

    /// 提案 016：转场进行中（auto 或 T-bar 推到一半）被拒——进行中的那一次按开始时的参数走；结束后再发就生效，别的字段一个不动；
    /// 相同值原样返回（回执 applied = false）；cutAtTick ≥ durationTicks 不钳（= 完成时换）。
    func test016_setTransitionParams_rejectedWhileActive_appliesAfterwards() {
        let wanted = Command.setTransitionParams(wipe: WipeParams(direction: .rightToLeft, softness: 0.25), stinger: StingerParams(input: 4, cutAtTick: 20))
        let auto = reducer.reduce(Self.baseState(), .setTransition(type: .wipe, durationTicks: 30), at: Tick(9))
        let started = reducer.reduce(auto, .autoTransition, at: Tick(10))
        let midAuto = reducer.advance(started, to: Tick(20))
        XCTAssertTrue(midAuto.transition.isActive)
        XCTAssertEqual(reducer.reduce(midAuto, wanted, at: Tick(20)), midAuto, "auto 转场中被拒")
        let midBar = reducer.reduce(Self.baseState(), .tbar(progress: 0.4), at: Tick(5))
        XCTAssertEqual(reducer.reduce(midBar, wanted, at: Tick(6)), midBar, "T-bar 推到一半被拒")

        let done = reducer.advance(started, to: Tick(40))
        XCTAssertFalse(done.transition.isActive)
        XCTAssertEqual(done.program, 2, "转场按原参数走完")
        let after = reducer.reduce(done, wanted, at: Tick(41))
        XCTAssertEqual(after.transition.wipe, WipeParams(direction: .rightToLeft, softness: 0.25))
        XCTAssertEqual(after.transition.stinger, StingerParams(input: 4, cutAtTick: 20))
        var rest = after
        rest.transition.wipe = done.transition.wipe
        rest.transition.stinger = done.transition.stinger
        XCTAssertEqual(rest, done, "只动 wipe / stinger 两组")
        XCTAssertEqual(reducer.reduce(after, wanted, at: Tick(42)), after, "相同值原样返回")

        let late = reducer.reduce(done, .setTransitionParams(wipe: WipeParams(), stinger: StingerParams(input: nil, cutAtTick: 500)), at: Tick(43))
        XCTAssertEqual(late.transition.stinger.cutAtTick, 500, "≥ durationTicks 不钳")
        XCTAssertNil(late.transition.stinger.input)
    }

    func testW1B_loadShow_invalidStateIsRejected() {
        var bad = Self.baseState()
        bad.inputs.append(bad.inputs[0]) // 重复编号
        let show = Show(name: "坏", state: bad)
        XCTAssertEqual(reducer.reduce(Self.baseState(), .loadShow(show: show), at: Tick(1)), Self.baseState())
    }

    // MARK: P4：reducer 的两条小规则（prompt 67 交付 3）

    /// removeInput 删掉 Stinger 用的那一路：`transition.stinger.input` 置 nil，与叠加引用同口径（W3-E2 报告 §4 第 1 条）；换底拍不动，删别的输入不碰它。
    /// 引用留着悬空的话，App 改 Wipe 参数时带上的 stinger 会让整条 setTransitionParams 被拒。
    func testP4_removeInput_clearsStingerReference() {
        var s = Self.baseState()
        s.transition.stinger = StingerParams(input: 3, cutAtTick: 12)
        XCTAssertEqual(reducer.reduce(s, .removeInput(input: 4), at: Tick(1)).transition.stinger, StingerParams(input: 3, cutAtTick: 12), "删别的输入不碰 stinger")

        let removed = reducer.reduce(s, .removeInput(input: 3), at: Tick(1))
        var expected = s
        expected.inputs.remove(at: 2)
        expected.transition.stinger = StingerParams(input: nil, cutAtTick: 12)
        XCTAssertEqual(removed, expected, "stinger 用的输入删了就置 nil，换底拍与别的字段不动")

        let wipe = WipeParams(direction: .diagonal, softness: 0.1)
        XCTAssertEqual(reducer.reduce(removed, .setTransitionParams(wipe: wipe, stinger: removed.transition.stinger), at: Tick(2)).transition.wipe, wipe,
                       "删完之后照当前 stinger 改 Wipe 参数照常生效")
    }

    /// 提案 019 D（用户 2026-09-27 批）：addInput / setInputSettings 带进来的 `EffectSlot(id: "border")` 剥掉——P4 之后这是效果链里 border 格的最后一个入口；
    /// 别的效果格原样、顺序不变；没有 border 格的设置一个字节不动；校验器不改。
    func test019_addInputAndSetInputSettings_stripLegacyBorderEffectSlots() throws {
        let eq = EffectSlot(id: "parametricEQ", enabled: true, params: ["gain": .number(3)])
        let border = EffectSlot(id: OverlayBorder.legacyEffectID, enabled: true, params: ["width": .number(0.02)])
        let disabledBorder = EffectSlot(id: OverlayBorder.legacyEffectID, enabled: false)
        let comp = EffectSlot(id: "compressor", enabled: false)
        var withBorder = InputSettings()
        withBorder.effects = [eq, border, comp, disabledBorder]
        var clean = withBorder
        clean.effects = [eq, comp]

        // addInput
        let base = Self.baseState()
        let number = (base.inputs.map(\.number).max() ?? 0) + 1
        let added = reducer.reduce(base, .addInput(config: InputConfig(number: number, name: "带边框格", source: try XCTUnwrap(base.inputs.first).source, settings: withBorder)), at: Tick(1))
        let addedInput = try XCTUnwrap(added.inputs.first { $0.number == number })
        XCTAssertEqual(addedInput.settings.effects, [eq, comp], "两个 border 格（启用的、停用的）都清掉，别的格原样、顺序不变")
        XCTAssertEqual(addedInput.settings, clean.clamped(), "除了 border 格，其余与 clamped() 相同")
        XCTAssertNoThrow(try added.validate())
        // setInputSettings
        let target = try XCTUnwrap(base.inputs.first).number
        let set = reducer.reduce(base, .setInputSettings(input: target, settings: withBorder), at: Tick(2))
        XCTAssertEqual(set.inputs.first { $0.number == target }?.settings.effects, [eq, comp])
        XCTAssertEqual(set.inputs.first { $0.number == target }?.settings, clean.clamped())
        // 没有 border 格：与原规则逐字段相等
        let plain = reducer.reduce(base, .setInputSettings(input: target, settings: clean), at: Tick(3))
        var expected = base
        expected.inputs[0].settings = clean.clamped()
        XCTAssertEqual(plain, expected)
        XCTAssertEqual(MixerReducer.strippingLegacyBorder(clean), clean, "没有 border 格的设置一个字节不动")
    }

    /// addOutput / setOutputSettings / loadShow 进来的设置先过一遍 `migratingLegacyKeys()`（W3-B2 报告 §4 第 4 条；loadShow 用户 2026-09-27 定一并做）：
    /// API 客户端直接带过渡键（extra["layout"] / ["displayID"] / ["fallbackToMain"]、效果格 "border"）的，与读节目文件得到同一份正式字段，不再静默变成默认布局 / 没有边框。
    func testP4_outputSettingsFromCommands_migrateLegacyKeys() {
        let layoutKey = MultiviewLayoutSettings.legacyExtraKey
        let legacyLayout = OutputSettings(source: .multiview, extra: [layoutKey: .string("3x3"), "ndi.groups": .string("studio")])

        let added = reducer.reduce(Self.baseState(), .addOutput(config: OutputState(number: 3, kind: .multiview, name: "多画面", settings: legacyLayout)), at: Tick(1))
        XCTAssertEqual(added.output(3)?.settings.multiview, MultiviewLayoutSettings(preset: "3x3"), "addOutput 带的 extra[\"layout\"] 搬进正式字段")
        XCTAssertEqual(added.output(3)?.settings.extra, ["ndi.groups": .string("studio")], "旧键清掉，别的 extra 键原样留着")
        XCTAssertEqual(added.output(3)?.settings, legacyLayout.migratingLegacyKeys(), "与 Show.load 同一套规则")

        var s = Self.baseState()
        s.outputs.append(OutputState(number: 3, kind: .externalDisplay, name: "外屏"))
        let legacyDisplay = OutputSettings(source: .preview, extra: [DisplayOutputSettings.legacyDisplayIDKey: .number(2),
                                                                     DisplayOutputSettings.legacyFallbackKey: .bool(true)])
        let set = reducer.reduce(s, .setOutputSettings(output: 3, settings: legacyDisplay), at: Tick(1))
        XCTAssertEqual(set.output(3)?.settings, OutputSettings(source: .preview, display: DisplayOutputSettings(displayID: 2, fallbackToMain: true)),
                       "setOutputSettings 带的 extra[\"displayID\"] / [\"fallbackToMain\"] 搬进正式字段")
        XCTAssertEqual(reducer.reduce(set, .setOutputSettings(output: 3, settings: legacyDisplay), at: Tick(2)), set, "搬完与现状相同 → 原样返回（回执 applied = false）")
        var official = legacyDisplay
        official.display = DisplayOutputSettings(displayID: 7, fallbackToMain: false)
        XCTAssertEqual(reducer.reduce(s, .setOutputSettings(output: 3, settings: official), at: Tick(1)).output(3)?.settings.display,
                       DisplayOutputSettings(displayID: 7, fallbackToMain: false), "正式字段已有值时旧键不覆盖，只清掉")

        // loadShow：整份节目按 Show.load 同一套规则搬迁（输出过渡键、叠加用到的输入里的 "border" 效果格）
        var old = Self.baseState()
        old.outputs.append(OutputState(number: 3, kind: .multiview, name: "多画面", enabled: true, settings: legacyLayout))
        old.inputs[1].settings.effects = [EffectSlot(id: OverlayBorder.legacyEffectID, params: ["width": 0.02, "color": .array([255, 0, 0])])]
        old.overlays[0].input = 2
        let show = Show(name: "API 发来的老节目", state: old)
        let loaded = reducer.reduce(Self.baseState(), .loadShow(show: show), at: Tick(1))
        XCTAssertEqual(loaded, show.migratingLegacyKeys().makeState())
        XCTAssertEqual(loaded.output(3)?.settings.multiview?.preset, "3x3")
        XCTAssertEqual(loaded.overlays[0].border, OverlayBorder(width: 0.02, color: RGB8(red: 255, green: 0, blue: 0)))
        XCTAssertEqual(loaded.inputs[1].settings.effects, [], "搬走的效果格清掉")
    }

    // MARK: 提案 026（P5；headphones 用户 2026-10-12 允许，P5-3）：耳机听哪条总线

    /// `setMonitorSource`：四条总线都生效、只动 `audio.monitorSource`——headphones = 听耳机总线自己（只听每路 routing.headphones 送出的那些；P5 时拒收）；
    /// 相同值原样返回（回执 applied = false）。独听（monitorMode + solo）与监听点（monitorPoint）不受它影响。
    func test026_setMonitorSource_acceptsAllFourBuses_andSameValueUnchanged() {
        let s = Self.baseState()
        XCTAssertEqual(s.audio.monitorSource, .master, "新状态默认听 Master")
        for bus in [Bus.busA, .busB, .headphones] {
            let after = reducer.reduce(s, .setMonitorSource(bus: bus), at: Tick(1))
            var expected = s
            expected.audio.monitorSource = bus
            XCTAssertEqual(after, expected, "\(bus)")
        }
        XCTAssertEqual(reducer.reduce(s, .setMonitorSource(bus: .master), at: Tick(1)), s, "相同值原样返回")
        var onB = s
        onB.audio.monitorSource = .busB
        var onHeadphones = s
        onHeadphones.audio.monitorSource = .headphones
        XCTAssertEqual(reducer.reduce(onB, .setMonitorSource(bus: .headphones), at: Tick(2)), onHeadphones, "从 busB 换到耳机总线自己")
        XCTAssertEqual(reducer.reduce(onHeadphones, .setMonitorSource(bus: .headphones), at: Tick(3)), onHeadphones, "相同值原样返回")
        XCTAssertEqual(reducer.reduce(onHeadphones, .setMonitorSource(bus: .master), at: Tick(3)), s, "回到 Master")
        // 与监听方式 / 监听点互不影响
        let pfl = reducer.reduce(onHeadphones, .setMonitorMode(mode: .pfl), at: Tick(4))
        XCTAssertEqual(pfl.audio.monitorSource, .headphones)
        XCTAssertEqual(pfl.audio.monitorMode, .pfl)
        XCTAssertEqual(pfl.audio.monitorPoint, onHeadphones.audio.monitorPoint)
    }

    // MARK: 提案 020（P5-2）：转场槽 + FTB 时长

    static func fileInput(_ n: Int, restartOnProgram: Bool = false, paused: Bool = false) -> InputConfig {
        var c = InputConfig(number: n, name: "片 \(n)", source: .file(path: "/clip\(n).mov", endAction: .holdLastFrame, rate: 1))
        c.settings.playback.restartOnProgram = restartOnProgram
        c.settings.playback.paused = paused
        return c
    }

    /// 进行中改当前槽：进行中的那一次按开始时的参数走完，完成那一拍把当前那组按槽重拷（completeTransition 在 currentSlot 非 nil 时总是重拷，幂等）。
    func test020_setTransitionSlot_whileActive_recopiesOnCompletion() {
        let started = reducer.reduce(Self.baseState(), .useTransitionSlot(slot: 2, start: true), at: Tick(10))
        XCTAssertEqual(started.transition.currentSlot, 2); XCTAssertEqual(started.transition.type, .wipe); XCTAssertEqual(started.transition.durationTicks, 60)
        let mid = reducer.advance(started, to: Tick(20))
        XCTAssertTrue(mid.transition.isActive)
        let changed = reducer.reduce(mid, .setTransitionSlot(slot: 2, config: TransitionSlot(type: .zoom, durationTicks: 20)), at: Tick(20))
        XCTAssertEqual(changed.transition.slots[1], TransitionSlot(type: .zoom, durationTicks: 20), "槽改了")
        XCTAssertEqual(changed.transition.type, .wipe); XCTAssertEqual(changed.transition.durationTicks, 60, "进行中的那一次不动")
        XCTAssertEqual(changed.transition.currentSlot, 2)
        XCTAssertEqual(reducer.advance(changed, to: Tick(50)).transition.progress, 40.0 / 60.0, accuracy: 1e-12, "按原时长走")
        XCTAssertEqual(reducer.advance(changed, to: Tick(50)).transition.type, .wipe)
        let done = reducer.advance(changed, to: Tick(70))
        XCTAssertFalse(done.transition.isActive)
        XCTAssertEqual(done.program, 2); XCTAssertEqual(done.preview, 1)
        XCTAssertEqual(done.transition.currentGroup, TransitionSlot(type: .zoom, durationTicks: 20), "完成那一拍重拷")
        XCTAssertEqual(done.transition.currentSlot, 2)
        XCTAssertEqual(reducer.advance(done, to: Tick(71)), done, "重拷幂等")
        // 空闲时改当前槽：马上重拷
        let idle = reducer.reduce(done, .setTransitionSlot(slot: 2, config: TransitionSlot(type: .fade, durationTicks: 5)), at: Tick(72))
        XCTAssertEqual(idle.transition.currentGroup, TransitionSlot(type: .fade, durationTicks: 5))
        XCTAssertEqual(idle.transition.currentSlot, 2)
        // T-bar 推到一半改当前槽：只改槽；推到 1 提交那一拍重拷
        let bar = reducer.reduce(idle, .tbar(progress: 0.4), at: Tick(80))
        let barChanged = reducer.reduce(bar, .setTransitionSlot(slot: 2, config: TransitionSlot(type: .zoom, durationTicks: 9)), at: Tick(81))
        XCTAssertEqual(barChanged.transition.currentGroup, TransitionSlot(type: .fade, durationTicks: 5))
        let committed = reducer.reduce(barChanged, .tbar(progress: 1), at: Tick(82))
        XCTAssertEqual(committed.transition.currentGroup, TransitionSlot(type: .zoom, durationTicks: 9))
        XCTAssertEqual(committed.program, 1)
        // cut 也走 completeTransition：currentSlot 非 nil 就重拷（与槽相同时无感）
        let cut = reducer.reduce(committed, .cut, at: Tick(83))
        XCTAssertEqual(cut.transition.currentGroup, committed.transition.currentGroup)
    }

    /// useTransitionSlot(start: true) 一拍内原子完成：类型 cut 或时长 0 的槽立即对调；start = false 只选中（Stinger 槽没选输入的 029 起拒收，见 test029_*）。
    func test020_useTransitionSlot_startAtomic_cutSlotCompletesImmediately() {
        let withCut = reducer.reduce(Self.baseState(), .setTransitionSlot(slot: 3, config: TransitionSlot(type: .cut, durationTicks: 0)), at: Tick(1))
        let cut = reducer.reduce(withCut, .useTransitionSlot(slot: 3, start: true), at: Tick(2))
        XCTAssertEqual(cut.program, 2); XCTAssertEqual(cut.preview, 1)
        XCTAssertFalse(cut.transition.isActive)
        XCTAssertEqual(cut.transition.currentSlot, 3); XCTAssertEqual(cut.transition.type, .cut)
        let zero = reducer.reduce(Self.baseState(), .setTransitionSlot(slot: 2, config: TransitionSlot(type: .wipe, durationTicks: 0)), at: Tick(1))
        XCTAssertEqual(reducer.reduce(zero, .useTransitionSlot(slot: 2, start: true), at: Tick(2)).program, 2, "时长 0 = 原子对调")
        // 只选中：T-bar 用新类型
        let selected = reducer.reduce(Self.baseState(), .useTransitionSlot(slot: 3, start: false), at: Tick(3))
        XCTAssertFalse(selected.transition.isActive)
        XCTAssertEqual(selected.transition.type, .zoom)
        XCTAssertEqual(reducer.reduce(selected, .tbar(progress: 0.5), at: Tick(4)).transition.type, .zoom)
        // 再选同一个槽、当前那组相同 → 原样（applied = false）；start = true 的同一个槽照常开始
        XCTAssertEqual(reducer.reduce(selected, .useTransitionSlot(slot: 3, start: false), at: Tick(5)), selected)
        XCTAssertTrue(reducer.reduce(selected, .useTransitionSlot(slot: 3, start: true), at: Tick(5)).transition.isActive)
    }

    /// 老命令执行后 currentSlot：当前那组不再对应任何槽 → nil；仍与某个槽相同（fade 30 = 槽 1）就留着 / 对上那个槽。
    func test020_legacyTransitionCommands_updateCurrentSlot() {
        let s = Self.baseState()
        XCTAssertEqual(s.transition.currentSlot, 1)
        XCTAssertEqual(reducer.reduce(s, .fade(durationTicks: 30), at: Tick(1)).transition.currentSlot, 1, "fade 30 = 槽 1")
        XCTAssertNil(reducer.reduce(s, .fade(durationTicks: 12), at: Tick(1)).transition.currentSlot)
        XCTAssertEqual(reducer.reduce(s, .setTransition(type: .zoom, durationTicks: 60), at: Tick(1)).transition.currentSlot, 3)
        XCTAssertNil(reducer.reduce(s, .setTransition(type: .zoom, durationTicks: 61), at: Tick(1)).transition.currentSlot)
        XCTAssertNil(reducer.reduce(s, .setTransitionParams(wipe: WipeParams(direction: .diagonal, softness: 0), stinger: StingerParams()), at: Tick(1)).transition.currentSlot)
        // 从 nil 回到槽：useTransitionSlot
        let off = reducer.reduce(s, .fade(durationTicks: 12), at: Tick(1))
        let doneOff = reducer.advance(off, to: Tick(20))
        XCTAssertNil(doneOff.transition.currentSlot, "完成时 currentSlot nil 不重拷")
        XCTAssertEqual(doneOff.transition.durationTicks, 12)
        XCTAssertEqual(reducer.reduce(doneOff, .useTransitionSlot(slot: 1, start: false), at: Tick(21)).transition.currentSlot, 1)
    }

    /// removeInput 清引用的规则扩到 4 个槽：slots[k].stinger.input == input 的置 nil；当前那组照 P4 的规则。
    func test020_removeInput_clearsStingerReferenceInSlots() {
        var s = Self.baseState()
        s.transition.slots[3].stinger.input = 3
        s.transition.slots[2].stinger.input = 4
        s.transition.stinger.input = 3
        let removed = reducer.reduce(s, .removeInput(input: 3), at: Tick(1))
        XCTAssertNil(removed.transition.slots[3].stinger.input)
        XCTAssertEqual(removed.transition.slots[2].stinger.input, 4, "指向别的输入的不动")
        XCTAssertNil(removed.transition.stinger.input)
        XCTAssertEqual(removed.transition.slots[3].durationTicks, 60, "只动引用")
    }

    /// setFTBDuration 在 FTB 渐变中：按当前电平对应的起点回拨，电平从当前值按新时长继续走、不跳变；时长 0 立即到位。
    func test020_setFTBDuration_midFadeContinuesFromCurrentLevel() {
        let on = reducer.reduce(Self.baseState(), .ftb(on: true), at: Tick(100))   // durationTicks 30
        let mid = reducer.advance(on, to: Tick(110))
        XCTAssertEqual(mid.ftb.level, 1.0 / 3.0, accuracy: 1e-12)
        let slow = reducer.reduce(mid, .setFTBDuration(ticks: 60), at: Tick(110))
        XCTAssertEqual(slow.ftb.durationTicks, 60)
        XCTAssertEqual(slow.ftb.level, 1.0 / 3.0, accuracy: 1e-12, "改的那一拍电平不变")
        XCTAssertEqual(slow.ftb.startTick, Tick(90), "等效起点：110 − round(1/3 × 60)")
        XCTAssertEqual(reducer.advance(slow, to: Tick(120)).ftb.level, 0.5, accuracy: 1e-12, "按新时长继续走")
        let black = reducer.advance(slow, to: Tick(150))
        XCTAssertEqual(black.ftb.level, 1); XCTAssertNil(black.ftb.startTick)
        // 空闲时只改数字
        let idle = reducer.reduce(black, .setFTBDuration(ticks: 15), at: Tick(151))
        XCTAssertEqual(idle.ftb.durationTicks, 15); XCTAssertEqual(idle.ftb.level, 1); XCTAssertNil(idle.ftb.startTick)
        // 渐变中改成 0：立即到位
        let instant = reducer.reduce(mid, .setFTBDuration(ticks: 0), at: Tick(110))
        XCTAssertEqual(instant.ftb.level, 1); XCTAssertNil(instant.ftb.startTick)
        XCTAssertEqual(reducer.reduce(mid, .setFTBDuration(ticks: 30), at: Tick(110)), mid, "相同值原样返回")
    }

    /// loadShow 带 020 之前的节目（没有 slots）：reducer 先搬迁再 validate，读得进来、补了出厂槽。
    func test020_loadShow_migratesSlotsBeforeValidate() {
        var old = Self.baseState()
        old.transition = TransitionState(type: .wipe, durationTicks: 45, slots: [], currentSlot: nil)
        let show = Show(name: "020 之前", state: old)
        let loaded = reducer.reduce(Self.baseState(), .loadShow(show: show), at: Tick(1))
        XCTAssertEqual(loaded.transition.slots.count, 4)
        XCTAssertEqual(loaded.transition.slots[0], TransitionSlot(type: .wipe, durationTicks: 45))
        XCTAssertEqual(loaded.transition.currentSlot, 1)
        XCTAssertEqual(loaded, show.migratingLegacyKeys().makeState())
        var broken = Self.baseState()
        broken.transition.slots.removeLast()
        XCTAssertEqual(reducer.reduce(Self.baseState(), .loadShow(show: Show(name: "3 个槽", state: broken)), at: Tick(1)), Self.baseState(), "slots 不是 4 个（且非空）被拒")
    }

    /// 020 追加（用户 2026-10-17 裁定，P5-4）：T-bar 推到一半时改了当前槽（进行中只改槽），之后拉回 0 **取消**——取消那一拍按 currentSlot 重拷当前那组
    /// （与 completeTransition 同一句、幂等），下一次回车执行的是改过的配置（P5-3 探针：原来回车执行改之前的 Fade 30）。推杆还在中间不重拷；
    /// 推到负数钳到 0 同样算取消；T-bar 接管 auto 转场后拉回 0 一样；currentSlot = nil（当前那组是老命令直接给的）不重拷。
    func test020_tbarCancelRecopiesCurrentSlot() {
        let s0 = Self.baseState()   // 当前槽 1 = Fade 30
        let bar = reducer.reduce(s0, .tbar(progress: 0.4), at: Tick(10))
        let changed = reducer.reduce(bar, .setTransitionSlot(slot: 1, config: TransitionSlot(type: .zoom, durationTicks: 12)), at: Tick(11))
        XCTAssertEqual(changed.transition.slots[0], TransitionSlot(type: .zoom, durationTicks: 12), "槽改了")
        XCTAssertEqual(changed.transition.currentGroup, TransitionSlot(type: .fade, durationTicks: 30), "推到一半只改槽，当前那组不动")
        let pushed = reducer.reduce(changed, .tbar(progress: 0.6), at: Tick(12))
        XCTAssertEqual(pushed.transition.type, .fade, "推杆还在中间：不重拷")
        let cancelled = reducer.reduce(pushed, .tbar(progress: 0), at: Tick(13))
        XCTAssertFalse(cancelled.transition.isActive)
        XCTAssertEqual(cancelled.program, 1); XCTAssertEqual(cancelled.preview, 2, "取消不换人")
        XCTAssertEqual(cancelled.transition.currentGroup, TransitionSlot(type: .zoom, durationTicks: 12), "取消那一拍按当前槽重拷")
        XCTAssertEqual(cancelled.transition.currentSlot, 1)
        XCTAssertEqual(reducer.reduce(cancelled, .tbar(progress: 0), at: Tick(14)), cancelled, "重拷幂等")
        // 回车执行的是改过的配置：Zoom 12 拍
        let enter = reducer.reduce(cancelled, .autoTransition, at: Tick(20))
        XCTAssertEqual(enter.transition.type, .zoom)
        XCTAssertEqual(enter.transition.durationTicks, 12)
        XCTAssertEqual(enter.transition.startTick, Tick(20))
        XCTAssertEqual(reducer.advance(enter, to: Tick(26)).transition.progress, 0.5, accuracy: 1e-12, "按 12 拍走")
        XCTAssertEqual(reducer.advance(enter, to: Tick(32)).program, 2, "第 12 拍对调")
        // 推到负数钳到 0：同样算取消
        XCTAssertEqual(reducer.reduce(pushed, .tbar(progress: -0.3), at: Tick(13)).transition.currentGroup, TransitionSlot(type: .zoom, durationTicks: 12))
        // T-bar 接管进行中的 auto 转场（auto 进行中改了当前槽）后拉回 0：同样重拷
        let auto = reducer.advance(reducer.reduce(s0, .autoTransition, at: Tick(100)), to: Tick(110))
        XCTAssertTrue(auto.transition.isActive)
        let autoChanged = reducer.reduce(auto, .setTransitionSlot(slot: 1, config: TransitionSlot(type: .wipe, durationTicks: 20)), at: Tick(110))
        let takenBack = reducer.reduce(autoChanged, .tbar(progress: 0), at: Tick(111))
        XCTAssertFalse(takenBack.transition.isActive)
        XCTAssertEqual(takenBack.program, 1)
        XCTAssertEqual(takenBack.transition.currentGroup, TransitionSlot(type: .wipe, durationTicks: 20))
        // currentSlot = nil（setTransition 直接给的 Wipe 45 不对应任何槽）：取消不重拷
        let legacy = reducer.reduce(s0, .setTransition(type: .wipe, durationTicks: 45), at: Tick(1))
        XCTAssertNil(legacy.transition.currentSlot)
        let legacyBack = reducer.reduce(reducer.reduce(legacy, .tbar(progress: 0.5), at: Tick(2)), .tbar(progress: 0), at: Tick(3))
        XCTAssertEqual(legacyBack.transition.currentGroup, legacy.transition.currentGroup)
        XCTAssertNil(legacyBack.transition.currentSlot)
    }

    // MARK: 提案 029（用户 2026-10-12 定，P5-3）：没选输入的 Stinger 槽拒收

    /// useTransitionSlot(start: true) 遇到效果 = Stinger 且没选输入的槽（`isStingerWithoutInput`）：状态原样（不选中、不开始；回执 applied = false）——
    /// 看槽的配置不看槽号（出厂槽 4，或改成 Stinger 的槽 2 一样）；start = false 照常选中（之后 T-bar 用）；给槽选了输入照常开始；removeInput 清掉那一路后又拒。
    func test029_useTransitionSlot_stingerWithoutInput_startRefused_selectAllowed() async {
        let s0 = Self.baseState()
        XCTAssertTrue(s0.transition.slots[3].isStingerWithoutInput, "出厂槽 4 = Stinger、没选输入")
        XCTAssertEqual(reducer.reduce(s0, .useTransitionSlot(slot: 4, start: true), at: Tick(10)), s0, "不选中、不开始")
        let selected = reducer.reduce(s0, .useTransitionSlot(slot: 4, start: false), at: Tick(10))
        XCTAssertEqual(selected.transition.currentSlot, 4)
        XCTAssertEqual(selected.transition.type, .stinger)
        XCTAssertFalse(selected.transition.isActive, "只选中照常")
        XCTAssertEqual(reducer.reduce(selected, .useTransitionSlot(slot: 4, start: true), at: Tick(11)), selected, "已是当前槽也一样拒")
        // 别的槽改成没选输入的 Stinger：同样拒（看配置，不看槽号）
        let slot2 = reducer.reduce(s0, .setTransitionSlot(slot: 2, config: TransitionSlot(type: .stinger, durationTicks: 30)), at: Tick(12))
        XCTAssertEqual(reducer.reduce(slot2, .useTransitionSlot(slot: 2, start: true), at: Tick(13)), slot2)
        // 选了输入：照常一拍内选中并开始，走完对调
        let armed = reducer.reduce(s0, .setTransitionSlot(slot: 4, config: TransitionSlot(type: .stinger, durationTicks: 60, stinger: StingerParams(input: 3, cutAtTick: 20))), at: Tick(14))
        let started = reducer.reduce(armed, .useTransitionSlot(slot: 4, start: true), at: Tick(15))
        XCTAssertTrue(started.transition.isActive)
        XCTAssertEqual(started.transition.startTick, Tick(15))
        XCTAssertEqual(started.transition.currentSlot, 4)
        XCTAssertEqual(started.transition.stinger, StingerParams(input: 3, cutAtTick: 20))
        XCTAssertEqual(reducer.advance(started, to: Tick(75)).program, 2, "走完对调")
        // 删掉 Stinger 用的那一路：槽里的引用清掉（020），又成了没选输入的槽
        let removed = reducer.reduce(armed, .removeInput(input: 3), at: Tick(16))
        XCTAssertTrue(removed.transition.slots[3].isStingerWithoutInput)
        XCTAssertEqual(reducer.reduce(removed, .useTransitionSlot(slot: 4, start: true), at: Tick(17)), removed)

        // 状态机：结构合法、走到 reducer，回执 applied = false，当前槽仍是 1
        let sm = StateMachine(initialState: s0)
        sm.start()
        defer { sm.stop() }
        guard case .applied(let receipt) = await sm.submit(IssuedCommand(sequence: 1, issuedAt: .now(), command: .useTransitionSlot(slot: 4, start: true))) else {
            return XCTFail("useTransitionSlot 应走到 reducer")
        }
        XCTAssertFalse(receipt.applied, "没选输入的 Stinger 槽不执行")
        let after = await sm.state
        XCTAssertEqual(after.transition.currentSlot, 1, "没被选中")
        XCTAssertFalse(after.transition.isActive)
    }

    /// autoTransition（回车 / "执行当前转场" / 格子"转场" / 兼容层老路）：要执行的当前那组是没选输入的 Stinger → 原样（applied = false）——当前槽是这种槽，
    /// 或 setTransition / setTransitionParams 直接给的（currentSlot = nil）都算，否则绕过 useTransitionSlot 还是一次延迟硬切。给当前那组选了输入照常开始。
    /// fade（总是 Fade）、cut 不受影响；T-bar 不动——推这样的当前那组照收（progress = 推杆位置），推到 1 提交、拉回 0 取消（画面口径见 CONTRACTS.md 转场槽一段）。
    func test029_autoTransition_currentStingerWithoutInput_refused_tbarUnaffected() async {
        let s0 = Self.baseState()
        let slot4 = reducer.reduce(s0, .useTransitionSlot(slot: 4, start: false), at: Tick(1))
        XCTAssertTrue(slot4.transition.currentGroup.isStingerWithoutInput)
        XCTAssertEqual(reducer.reduce(slot4, .autoTransition, at: Tick(2)), slot4, "当前槽是没选输入的 Stinger")
        // 老命令直接给的（不对应任何槽）同样拒
        let legacy = reducer.reduce(s0, .setTransition(type: .stinger, durationTicks: 45), at: Tick(1))
        XCTAssertNil(legacy.transition.currentSlot)
        XCTAssertEqual(reducer.reduce(legacy, .autoTransition, at: Tick(2)), legacy, "setTransition 选的没选输入的 Stinger")
        // 选了输入：照常开始、走完对调
        let armed = reducer.reduce(legacy, .setTransitionParams(wipe: WipeParams(), stinger: StingerParams(input: 3, cutAtTick: 10)), at: Tick(2))
        let started = reducer.reduce(armed, .autoTransition, at: Tick(3))
        XCTAssertEqual(started.transition.startTick, Tick(3))
        XCTAssertEqual(reducer.advance(started, to: Tick(48)).program, 2)
        // fade / cut 不受影响
        let faded = reducer.reduce(slot4, .fade(durationTicks: 30), at: Tick(4))
        XCTAssertTrue(faded.transition.isActive)
        XCTAssertEqual(faded.transition.type, .fade)
        let cut = reducer.reduce(slot4, .cut, at: Tick(4))
        XCTAssertEqual(cut.program, 2); XCTAssertEqual(cut.preview, 1)
        XCTAssertEqual(cut.transition.currentGroup, slot4.transition.currentGroup, "cut 完成按当前槽重拷，仍是槽 4")
        // T-bar 不动：推到一半照收，推到 1 提交，拉回 0 取消
        let half = reducer.reduce(slot4, .tbar(progress: 0.5), at: Tick(5))
        XCTAssertEqual(half.transition.progress, 0.5)
        XCTAssertEqual(half.transition.source, .tbar)
        XCTAssertEqual(half.transition.type, .stinger)
        XCTAssertEqual(reducer.reduce(half, .tbar(progress: 1), at: Tick(6)).program, 2)
        let back = reducer.reduce(half, .tbar(progress: 0), at: Tick(6))
        XCTAssertFalse(back.transition.isActive)
        XCTAssertEqual(back.program, 1)

        // 状态机：回执 applied = false
        let sm = StateMachine(initialState: slot4)
        sm.start()
        defer { sm.stop() }
        guard case .applied(let receipt) = await sm.submit(IssuedCommand(sequence: 1, issuedAt: .now(), command: .autoTransition)) else {
            return XCTFail("autoTransition 应走到 reducer")
        }
        XCTAssertFalse(receipt.applied)
        let after = await sm.state
        XCTAssertFalse(after.transition.isActive)
        XCTAssertEqual(after.program, 1)
    }

    // MARK: 提案 021（P5-2）：切上 PGM 时从头播

    /// restartOnProgram 的四处 PGM 换人：cut / auto 完成 / T-bar 提交 / setProgram 换成它的那一拍写 seekSeconds = 0、seekTick = 那一拍（auto 完成 = 开始拍 + 时长，逐拍推进与一步到位等价）；
    /// 换走的那一路不写；PGM 没变不写；restartOnProgram = false 不写；暂停中照样定位、仍暂停。
    func test021_restartOnProgram_writesSeekZeroWhenInputLandsOnProgram() {
        var s = Self.baseState()
        s.inputs.append(Self.fileInput(5, restartOnProgram: true, paused: true))
        s.inputs.append(Self.fileInput(6, restartOnProgram: false))
        s.preview = 5
        // cut
        let cut = reducer.reduce(s, .cut, at: Tick(100))
        XCTAssertEqual(cut.program, 5)
        XCTAssertEqual(cut.inputs[4].settings.playback, PlaybackSettings(paused: true, restartOnProgram: true, seekSeconds: 0, seekTick: Tick(100)), "定位到 0 但仍暂停")
        XCTAssertEqual(cut.inputs[0].settings.playback, PlaybackSettings(), "换走的那一路不写")
        // 再 cut 回去：5 号离开 PGM，不写新定位（上一次的留着，直到载入节目或下一次定位）
        let back = reducer.reduce(cut, .cut, at: Tick(101))
        XCTAssertEqual(back.inputs[4].settings.playback.seekTick, Tick(100))
        // auto 完成：开始拍 + 时长
        var auto = s
        auto.inputs[4].settings.playback.paused = false
        let started = reducer.reduce(auto, .fade(durationTicks: 30), at: Tick(200))
        XCTAssertNil(started.inputs[4].settings.playback.seekTick, "开始那一拍还没换人")
        let step = reducer.advance(reducer.advance(started, to: Tick(229)), to: Tick(230))
        let jump = reducer.advance(started, to: Tick(235))
        XCTAssertEqual(step.inputs[4].settings.playback.seekTick, Tick(230))
        XCTAssertEqual(jump.inputs[4].settings.playback.seekTick, Tick(230), "一步到位等价")
        XCTAssertEqual(jump.inputs[4].settings.playback.seekSeconds, 0)
        XCTAssertEqual(jump.program, 5)
        // T-bar 提交
        let bar = reducer.reduce(reducer.reduce(s, .tbar(progress: 0.5), at: Tick(300)), .tbar(progress: 1), at: Tick(301))
        XCTAssertEqual(bar.program, 5)
        XCTAssertEqual(bar.inputs[4].settings.playback.seekTick, Tick(301))
        XCTAssertNil(reducer.reduce(s, .tbar(progress: 0.5), at: Tick(300)).inputs[4].settings.playback.seekTick, "推到一半不算换人")
        // setProgram
        let direct = reducer.reduce(s, .setProgram(input: 5), at: Tick(400))
        XCTAssertEqual(direct.inputs[4].settings.playback.seekTick, Tick(400))
        XCTAssertEqual(reducer.reduce(direct, .setProgram(input: 5), at: Tick(401)), direct, "PGM 没变：不再写")
        // restartOnProgram = false：不写
        var six = s
        six.preview = 6
        XCTAssertEqual(reducer.reduce(six, .cut, at: Tick(500)).inputs[5].settings.playback, PlaybackSettings())
        // 非文件输入上 PGM：playback 不动（别的 kind 照存不读）
        XCTAssertEqual(reducer.reduce(s, .setProgram(input: 3), at: Tick(600)).inputs[2].settings.playback, PlaybackSettings())
        // 手发 seekPlayback 走同一条路：同一拍同一位置再发原样返回，换一拍再发生效
        let seek = reducer.reduce(cut, .seekPlayback(input: 5, seconds: 0), at: Tick(100))
        XCTAssertEqual(seek, cut, "同一拍同一位置")
        XCTAssertEqual(reducer.reduce(cut, .seekPlayback(input: 5, seconds: 0), at: Tick(102)).inputs[4].settings.playback.seekTick, Tick(102))
    }

    static let allCaseNames = ["cut", "fade", "setTransition", "setTransitionParams", "autoTransition", "setPreview", "setProgram", "tbar", "ftb",
                               "setTransitionSlot", "useTransitionSlot", "setFTBDuration",
                               "overlay", "setOverlay", "setOverlayDecoration",
                               "audioGain", "mute", "busGain", "busMute", "setAFV", "setMonitorMode", "setMonitorSource", "setBusEffects", "setInputAudio",
                               "startRecord", "stopRecord", "startStream", "stopStream", "setOutputEnabled", "renameOutput",
                               "setInputSettings", "renameInput", "addInput", "removeInput", "setInputSource", "setPlayback", "seekPlayback", "setInputColor",
                               "addOutput", "removeOutput", "setOutputSettings", "loadShow"]

    static func caseName(_ c: Command) -> String {
        switch c {
        case .cut: "cut"
        case .fade: "fade"
        case .setTransition: "setTransition"
        case .setTransitionParams: "setTransitionParams"
        case .autoTransition: "autoTransition"
        case .setPreview: "setPreview"
        case .setProgram: "setProgram"
        case .tbar: "tbar"
        case .ftb: "ftb"
        case .setTransitionSlot: "setTransitionSlot"
        case .useTransitionSlot: "useTransitionSlot"
        case .setFTBDuration: "setFTBDuration"
        case .overlay: "overlay"
        case .setOverlay: "setOverlay"
        case .setOverlayDecoration: "setOverlayDecoration"
        case .audioGain: "audioGain"
        case .mute: "mute"
        case .busGain: "busGain"
        case .busMute: "busMute"
        case .setAFV: "setAFV"
        case .setMonitorMode: "setMonitorMode"
        case .setMonitorSource: "setMonitorSource"
        case .setBusEffects: "setBusEffects"
        case .setInputAudio: "setInputAudio"
        case .startRecord: "startRecord"
        case .stopRecord: "stopRecord"
        case .startStream: "startStream"
        case .stopStream: "stopStream"
        case .setOutputEnabled: "setOutputEnabled"
        case .renameOutput: "renameOutput"
        case .setInputSettings: "setInputSettings"
        case .renameInput: "renameInput"
        case .addInput: "addInput"
        case .removeInput: "removeInput"
        case .setInputSource: "setInputSource"
        case .setPlayback: "setPlayback"
        case .seekPlayback: "seekPlayback"
        case .setInputColor: "setInputColor"
        case .addOutput: "addOutput"
        case .removeOutput: "removeOutput"
        case .setOutputSettings: "setOutputSettings"
        case .loadShow: "loadShow"
        }
    }
}
