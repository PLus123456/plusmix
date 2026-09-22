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
            var s = reducer.reduce(Self.baseState(), .setTransition(type: type, durationTicks: 10), at: Tick(0))
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
            Row("fade", .fade(durationTicks: 12)) { $0.transition.type = .fade; $0.transition.durationTicks = 12; $0.transition.startTick = tick; $0.transition.source = .auto },
            Row("setTransition", .setTransition(type: .wipe, durationTicks: 15)) { $0.transition.type = .wipe; $0.transition.durationTicks = 15 },
            Row("autoTransition", .autoTransition) { $0.transition.startTick = tick },
            Row("setPreview", .setPreview(input: 3)) { $0.preview = 3 },
            Row("setPreview 黑场", .setPreview(input: 0)) { $0.preview = 0 },
            Row("setPreview 不存在", .setPreview(input: 9)) { _ in },
            Row("setProgram", .setProgram(input: 4)) { $0.program = 4 },
            Row("setProgram 不存在", .setProgram(input: -1)) { _ in },
            Row("tbar", .tbar(progress: 0.3)) { $0.transition.progress = 0.3; $0.transition.source = .tbar },
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
        XCTAssertEqual(covered.count, Self.allCaseNames.count, "33 个 case 每个至少一行：缺 \(Set(Self.allCaseNames).subtracting(covered))")
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

    func testW1B_loadShow_invalidStateIsRejected() {
        var bad = Self.baseState()
        bad.inputs.append(bad.inputs[0]) // 重复编号
        let show = Show(name: "坏", state: bad)
        XCTAssertEqual(reducer.reduce(Self.baseState(), .loadShow(show: show), at: Tick(1)), Self.baseState())
    }

    static let allCaseNames = ["cut", "fade", "setTransition", "autoTransition", "setPreview", "setProgram", "tbar", "ftb", "overlay", "setOverlay",
                               "setOverlayDecoration",
                               "audioGain", "mute", "busGain", "busMute", "setAFV", "setMonitorMode", "setBusEffects",
                               "startRecord", "stopRecord", "startStream", "stopStream", "setOutputEnabled", "renameOutput",
                               "setInputSettings", "renameInput", "addInput", "removeInput", "setInputSource",
                               "addOutput", "removeOutput", "setOutputSettings", "loadShow"]

    static func caseName(_ c: Command) -> String {
        switch c {
        case .cut: "cut"
        case .fade: "fade"
        case .setTransition: "setTransition"
        case .autoTransition: "autoTransition"
        case .setPreview: "setPreview"
        case .setProgram: "setProgram"
        case .tbar: "tbar"
        case .ftb: "ftb"
        case .overlay: "overlay"
        case .setOverlay: "setOverlay"
        case .setOverlayDecoration: "setOverlayDecoration"
        case .audioGain: "audioGain"
        case .mute: "mute"
        case .busGain: "busGain"
        case .busMute: "busMute"
        case .setAFV: "setAFV"
        case .setMonitorMode: "setMonitorMode"
        case .setBusEffects: "setBusEffects"
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
        case .addOutput: "addOutput"
        case .removeOutput: "removeOutput"
        case .setOutputSettings: "setOutputSettings"
        case .loadShow: "loadShow"
        }
    }
}
