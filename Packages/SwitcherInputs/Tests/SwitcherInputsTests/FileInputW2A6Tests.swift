import CoreVideo
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherInputs

/// W2-A6（prompt 133）：Codex 2026-10-22 审查 N09（reports/codex-bug-audit-20261022.md；分项 bug-audit-20261022-core-inputs.md CI-04）——
/// 文件输入"暂停还没落实就恢复"。`pause()` 只置请求，推帧线程下一次醒来才把位置冻结在它最近推出的那一帧；这之前来了 `resume()`，
/// 旧代码照样把锚点拍换成将来的一拍、沿用旧的锚点位置 → 位置回到旧锚点（1.5 s → 0），解码器队首在旧播放点之后要重新追，0.5 s 里最多多推 1 帧。
/// App 每 1/60 s 轮询快照、把 paused 的变化转成 pause / resume（InputRuntime.syncPlayback），30 fps 节目两次里一次撞上（看相位）。
/// 旧 D13（W2-A5）修的是暂停紧跟定位，不是这条。
///
/// 照 Codex 的探针：真文件 Tests/Fixtures/w1a-sample-20s.mov（1080p60 20 s；前 400 帧是 60 fps 的源 A，图案帧号 = 帧序号 = 位置 × 60）、
/// 只记帧的槽（不按 pts 挑、不淘汰，记推了几帧和最新一帧）。
final class FileInputW2A6Tests: XCTestCase {
    private static let sample20s = RepoPaths.fixtures.appendingPathComponent("w1a-sample-20s.mov")

    private func makeTiming(_ format: ProgramFormat = .hd1080p60, leadMs: Double = 80) -> ProgramTiming {
        ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: leadMs))
    }

    private func makeInput(timing: ProgramTiming, slot: any FrameSlot, audioRing: (any AudioRing)? = nil) throws -> FileInput {
        try FileInput(number: 1, name: "文件", path: Self.sample20s.path, endAction: .holdLastFrame, timing: timing,
                      videoSlot: slot, audioRing: audioRing)
    }

    /// 起输入、等它播到 `seconds`（Codex 的探针：位置 ≥ 1.5 s 时动手）。
    private func startAndPlay(_ input: FileInput, to seconds: Double) throws {
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 5000, pollMs: 1) { input.state == .live && input.positionSeconds >= seconds },
                      "5 s 内没播到 \(seconds) s：\(input.positionSeconds) \(input.state) \(input.lastError ?? "")")
    }

    private func sleepMs(_ ms: Double) { usleep(UInt32(ms * 1000)) }

    /// 忙等 ms 毫秒：普通线程的 usleep 会被合并定时器推迟几 ms，卡相位的用例用它。
    private func spinMs(_ ms: Double) {
        let deadline = HostClock.now() + HostDuration(milliseconds: ms)
        while HostClock.now() < deadline {}
    }

    /// 只记帧的槽（Codex 探针里的 Slot）：push 记数、留最新一帧，latest 不看 pts 直接给最新一帧。
    final class RecordingSlot: FrameSlot, @unchecked Sendable {
        let capacity = 3
        private let state = Mutex<(frame: Frame?, pushed: UInt64)>((nil, 0))
        func push(_ frame: Frame) { state.withLock { $0 = (frame, $0.pushed + 1) } }
        func latest(atOrBefore time: HostTime) -> Frame? { state.withLock { $0.frame } }
        var stats: FrameSlotStats { FrameSlotStats(pushed: pushed) }
        var pushed: UInt64 { state.withLock { $0.pushed } }
        /// 最新一帧的图案帧号（解不出为 nil）。
        var newestNumber: Int? { frameNumber(of: state.withLock { $0.frame }) }
    }

    // MARK: 立即 pause / resume（Codex 的 immediate）

    /// Codex N09 immediate：60 fps 节目播到 1.5 s，连着 `pause(); resume()`（暂停还没被推帧线程落实）。修前：位置回到 0、随后 0.5 s 至多多推 1 帧（两次一致）。
    /// 修好：没落实的暂停只是取消请求——锚点不动、位置接着走、0.5 s 里接着推 ≈ 30 帧、画面帧号接着涨；两次。
    /// 暂停请求挂着的那一下读位置也不退回旧锚点（时间线这时还在走，推帧线程落实之前读到的该是"还在播"的位置）。
    func testN09_pauseThenImmediateResume_cancelsRequest_timelineAndFramesContinue() throws {
        for run in 1...2 {
            let timing = makeTiming()
            let slot = RecordingSlot()
            let input = try makeInput(timing: timing, slot: slot)
            defer { input.stop() }
            try startAndPlay(input, to: 1.5)
            let anchor = input.playbackStartTick
            let shown = slot.newestNumber
            let position = input.positionSeconds
            let pushed = slot.pushed
            input.pause()
            let pending = input.positionSeconds
            XCTAssertFalse(input.pauseIsApplied, "第 \(run) 次：触发条件是暂停还没被推帧线程落实就恢复")
            input.resume()
            let resumedClock = HostClock.now()
            let resumedAt = input.positionSeconds
            XCTAssertFalse(input.isPaused)
            XCTAssertGreaterThanOrEqual(pending, position, "第 \(run) 次：暂停请求还没落实时位置不退回旧锚点")
            XCTAssertEqual(input.playbackStartTick, anchor, "第 \(run) 次：没落实的暂停只是取消请求，锚点不动")
            XCTAssertGreaterThanOrEqual(resumedAt, position, "第 \(run) 次：恢复后位置不退回旧锚点（Codex 修前 1.5 → 0）")
            sleepMs(500)
            let later = input.positionSeconds
            let elapsed = (HostClock.now() - resumedClock).milliseconds() / 1000
            let pushedLater = slot.pushed
            let shownLater = slot.newestNumber
            print("N09 immediate 第 \(run) 次：位置 \(position) → 请求挂着 \(pending) → 恢复 \(resumedAt) → \(String(format: "%.3f", elapsed)) s 后 \(later)；"
                  + "pushed \(pushed) → \(pushedLater)；帧号 \(shown.map(String.init) ?? "nil") → \(shownLater.map(String.init) ?? "nil")")
            XCTAssertEqual(later - resumedAt, elapsed, accuracy: 0.03, "第 \(run) 次：时间线接着走（跟墙钟走）")
            XCTAssertGreaterThanOrEqual(pushedLater - pushed, 25, "第 \(run) 次：随后 0.5 s 接着推帧（60 fps 节目 ≈ 30 帧；修前至多 +1）")
            if let shown, let shownLater {
                XCTAssertGreaterThanOrEqual(shownLater - shown, 25, "第 \(run) 次：画面帧号接着涨（60 fps 文件 0.5 s ≈ 30）")
            } else {
                XCTFail("第 \(run) 次：图案帧号解不出：\(String(describing: shown)) \(String(describing: shownLater))")
            }
            input.stop()
        }
    }

    // MARK: 对照：暂停落实之后再恢复（原来就对）

    /// Codex 的对照：暂停落实（等 100 ms）之后再恢复——修前修后都对：暂停中位置 / 画面不动，恢复照旧重锚到 seekLead 之后的一拍，
    /// 从停住的位置接着走（Codex 实测 1.466 → 1.983、+30 帧）。
    func testN09_control_resumeAfterPauseApplied_continuesFromFrozenFrame() throws {
        let timing = makeTiming()
        let slot = RecordingSlot()
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndPlay(input, to: 1.5)
        let anchor = input.playbackStartTick
        input.pause()
        XCTAssertTrue(waitUntil(timeoutMs: 100, pollMs: 1) { input.pauseIsApplied }, "暂停 100 ms 内该落实")
        sleepMs(100)
        let frozen = input.positionSeconds
        let frozenNumber = slot.newestNumber
        sleepMs(50)
        XCTAssertEqual(input.positionSeconds, frozen, "暂停中位置不走")
        XCTAssertEqual(slot.newestNumber, frozenNumber, "暂停中画面停在同一帧")
        XCTAssertGreaterThanOrEqual(frozen, 1.5 - 1.0 / 60, "冻结在动手时的位置附近")
        let resumeClock = HostClock.now()
        input.resume()
        XCTAssertNotEqual(input.playbackStartTick, anchor, "落实过的暂停：恢复时照旧重锚到 seekLead 之后的一拍")
        sleepMs(500)
        let later = input.positionSeconds
        let elapsed = (HostClock.now() - resumeClock).milliseconds() / 1000
        let laterNumber = slot.newestNumber
        print("N09 对照：冻结 \(frozen)（帧 \(frozenNumber.map(String.init) ?? "nil")）→ 恢复 \(String(format: "%.3f", elapsed)) s 后 \(later)（帧 \(laterNumber.map(String.init) ?? "nil")）")
        // 恢复锚在 seekLead（30 ms）之后的第一拍：位置比墙钟晚 30–47 ms
        XCTAssertGreaterThanOrEqual(later - frozen, elapsed - 0.1, "从停住的位置接着走")
        XCTAssertLessThanOrEqual(later - frozen, elapsed + 1.0 / 60, "恢复之前的位置不往前跳")
        if let frozenNumber, let laterNumber {
            XCTAssertGreaterThanOrEqual(laterNumber - frozenNumber, 24, "画面从停住的帧接着播")
        } else {
            XCTFail("图案帧号解不出：\(String(describing: frozenNumber)) \(String(describing: laterNumber))")
        }
    }

    // MARK: App 的轮询间隔：30 fps 节目、pause 与 resume 隔 1/60 s

    /// Codex poll16：pause 与 resume 之间隔 App 的轮询间隔（1/60 s）。暂停在这 16.7 ms 里落没落实看相位（Codex：30 fps 两次里一次
    /// 2.933 → 0、随后 0.5 s 一帧不推；60 fps 八次都没撞上）。30 fps 节目一拍 33 ms：推帧线程推完一帧马上读一次快照、再睡 20 ms 读下一次，
    /// 读到暂停请求才落实——推完之后 3 ms 以内 pause 的，下一次读快照在轮询间隔之外，恢复时暂停还没落实（随便哪个相位动手约一成撞上；
    /// 本机修前两轮各 1 / 10）。所以按推帧的边沿对相位、间隔用忙等（usleep 会晚几 ms，晚到下一次读快照之后就落实了）：
    /// 同一个输入连做 10 次，前五次在推完之后 0.5–2.5 ms 动手、后五次扫过整拍；落实了的走原来的重锚、没落实的只取消请求，两种都不许往回跳、
    /// 之后都接着播；10 次里至少要有一次卡进"没落实"的窗口。观察窗 0.4 s：10 次做完还在源 A 的 400 帧以内（帧号 = 帧序号）。
    func testN09_30fpsProgram_appPollInterval_tenCycles_neverJumpsBack() throws {
        let timing = makeTiming(.hd1080p30)
        let slot = RecordingSlot()
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndPlay(input, to: 0.3)
        let poll = 1000.0 / 60
        let offsets: [Double] = [0.5, 1, 1.5, 2, 2.5, 6, 12, 18, 24, 30]   // 推完一帧之后多久动手（ms）
        var unapplied = 0
        var failures: [String] = []
        var log: [String] = []
        for (i, offset) in offsets.enumerated() {
            let shown = slot.newestNumber
            let edge = slot.pushed
            let deadline = HostClock.now() + HostDuration(milliseconds: 200)
            while slot.pushed == edge, HostClock.now() < deadline {}
            XCTAssertNotEqual(slot.pushed, edge, "第 \(i) 次：200 ms 里没推帧")
            spinMs(offset)
            let anchor = input.playbackStartTick
            let position = input.positionSeconds
            let pausedAt = HostClock.now()
            input.pause()
            spinMs(poll)
            let applied = input.pauseIsApplied
            input.resume()
            let gap = (HostClock.now() - pausedAt).milliseconds()
            let resumedAt = input.positionSeconds
            if !applied {
                unapplied += 1
                if input.playbackStartTick != anchor { failures.append("第 \(i) 次（没落实）锚点动了") }
                if resumedAt < position { failures.append("第 \(i) 次（没落实）恢复后位置往回跳：\(position) → \(resumedAt)") }
            }
            sleepMs(400)
            let later = input.positionSeconds
            let shownLater = slot.newestNumber
            log.append("\(i)\(applied ? "落实" : "没落实")（+\(offset) ms、隔 \(String(format: "%.1f", gap)) ms）：\(String(format: "%.3f→%.3f→%.3f", position, resumedAt, later)) "
                       + "帧 \(shown.map(String.init) ?? "nil")→\(shownLater.map(String.init) ?? "nil")")
            // 落实了的：暂停 ≤ 16.7 ms + 重锚到 seekLead 之后的一拍（≤ 63 ms），0.4 s 里至少走 0.3 s
            if later - position < 0.3 { failures.append("第 \(i) 次（\(applied ? "落实" : "没落实")）0.4 s 只走了 \(later - position) s") }
            if let shown, let shownLater {
                if shownLater - shown < 18 { failures.append("第 \(i) 次（\(applied ? "落实" : "没落实")）0.4 s 帧号只涨了 \(shownLater - shown)") }
            } else {
                failures.append("第 \(i) 次：图案帧号解不出")
            }
        }
        print("N09 poll16 @30fps：没落实 \(unapplied) / 10；" + log.joined(separator: "；"))
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertGreaterThanOrEqual(unapplied, 1, "10 次里一次都没卡进'暂停没落实'的窗口，这条用例没测到 N09：\(log)")
    }

    // MARK: pause → seek → resume（D13 的顺序）照旧

    /// D13 的顺序（App 同一快照先 pause 再 seek，InputRuntime.syncPlayback）照旧：暂停中定位 = 暂停落在目标上（pauseApplied），
    /// 之后的恢复走"落实过"的重锚，从定位目标接着播。三种：立即连着做、定位后等 300 ms（停在目标那一帧）、暂停落实后再定位。
    func testN09_pauseSeekResume_D13Order_playsFromSeekTarget() throws {
        for variant in ["立即", "定位后等 300 ms", "暂停落实后再定位"] {
            let timing = makeTiming()
            let slot = RecordingSlot()
            let input = try makeInput(timing: timing, slot: slot)
            defer { input.stop() }
            try startAndPlay(input, to: 1.5)
            input.pause()
            if variant == "暂停落实后再定位" {
                XCTAssertTrue(waitUntil(timeoutMs: 100, pollMs: 1) { input.pauseIsApplied }, "\(variant)：暂停没落实")
            }
            input.seek(toSeconds: 5)
            if variant != "立即" {
                sleepMs(300)
                XCTAssertTrue(input.isPaused, "\(variant)：仍暂停")
                XCTAssertEqual(input.positionSeconds, 5, accuracy: 1.0 / 120, "\(variant)：停在定位目标")
                XCTAssertEqual(slot.newestNumber, 300, "\(variant)：画面停在第 300 帧")
            }
            input.resume()
            XCTAssertFalse(input.isPaused, "\(variant)")
            XCTAssertTrue(waitUntil(timeoutMs: 3000, pollMs: 1) { input.playbackStartTick != nil }, "\(variant)：锚点没定下来")
            let anchoredClock = HostClock.now()
            sleepMs(500)
            let later = input.positionSeconds
            let elapsed = (HostClock.now() - anchoredClock).milliseconds() / 1000
            let laterNumber = slot.newestNumber
            print("N09 pause→seek→resume（\(variant)）：锚点定下 \(String(format: "%.3f", elapsed)) s 后位置 \(later)、帧 \(laterNumber.map(String.init) ?? "nil")")
            // 锚点拍在定锚之后 seekLead（30 ms）的第一拍：位置 = 5 + 墙钟 − 30…47 ms
            XCTAssertGreaterThanOrEqual(later - 5, elapsed - 0.1, "\(variant)：从 5 s 接着播")
            XCTAssertLessThanOrEqual(later - 5, elapsed + 1.0 / 60, "\(variant)")
            if let laterNumber {
                XCTAssertGreaterThanOrEqual(laterNumber, 324, "\(variant)：画面从第 300 帧接着播")
                XCTAssertEqual(Double(laterNumber), later * 60, accuracy: 2, "\(variant)：画面帧号与位置一致")
            } else {
                XCTFail("\(variant)：图案帧号解不出")
            }
            input.stop()
        }
    }

    // MARK: 同根：暂停没落实时改速率

    /// 同一个窗口的另一个入口：暂停请求挂着时改速率，旧的 setter 按"暂停中 = 位置已冻结"不重算锚点位置（留着旧锚点的 0）、只换锚点拍和速率，
    /// 随后的恢复（没落实 = 取消请求）就接着这条错的时间线：位置回到旧锚点。App 的 reconcile 先改速率再对 pause / resume
    /// （InputRuntime.reconcile → applyPlayback），"上一轮刚 pause、这一轮改速率 + resume"就是这个顺序。修好：没落实的暂停 = 时间线照走，
    /// 改速率按还在播重算锚点位置；恢复后从原位置按 2 倍速接着走。
    func testN09_rateChangeWhilePauseUnapplied_thenResume_positionContinues() throws {
        let timing = makeTiming()
        let slot = RecordingSlot()
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndPlay(input, to: 1.5)
        let shown = slot.newestNumber
        let clock = HostClock.now()
        let position = input.positionSeconds
        input.pause()
        XCTAssertFalse(input.pauseIsApplied, "触发条件：暂停还没落实")
        input.rate = 2
        input.resume()
        let resumedAt = input.positionSeconds
        XCTAssertEqual(input.rate, 2)
        // 新锚点在 seekLead 之后的一拍（≤ 47 ms），锚点之前按新速率倒推，比原位置早一点点
        XCTAssertGreaterThanOrEqual(resumedAt, position - 0.06, "恢复后位置不退回旧锚点")
        sleepMs(500)
        let later = input.positionSeconds
        let elapsed = (HostClock.now() - clock).milliseconds() / 1000
        let laterNumber = slot.newestNumber
        print("N09 暂停没落实时改速率：\(position) → 恢复 \(resumedAt) → \(String(format: "%.3f", elapsed)) s 后 \(later)；帧 \(shown.map(String.init) ?? "nil") → \(laterNumber.map(String.init) ?? "nil")")
        // 位置 = 原位置 + 2 × 墙钟 − (新锚点 − 改速率那一刻 ≤ 47 ms)；2 倍速下位置按 2 / 60 s 一格走
        XCTAssertGreaterThanOrEqual(later - position, 2 * elapsed - 0.1, "2 倍速接着走")
        XCTAssertLessThanOrEqual(later - position, 2 * elapsed + 2.0 / 60)
        if let shown, let laterNumber {
            XCTAssertGreaterThanOrEqual(laterNumber - shown, 50, "画面按 2 倍速接着播")
        } else {
            XCTFail("图案帧号解不出")
        }
    }

    // MARK: 音频：块序号接着数

    /// 没落实的暂停被取消时音频也不许断：块的 host time 从头到尾首尾相接（每块 256 帧），不重写、不跳块。修前恢复把锚点挪到将来的一拍、
    /// 位置回到旧锚点，块从新锚点重数（host time 断开一截、源样本从头再来）；只取消请求但仍让推帧线程把块序号从 0 重数的话，
    /// 新块从旧锚点那一刻数起——旧的块全是 `.gone`（跳过）、最后写过的那块还在 FIFO 里又写一遍。
    func testN09_pauseThenImmediateResume_withAudio_chunksStayContiguous() throws {
        let timing = makeTiming()
        let slot = RecordingSlot()
        let ring = RecordingAudioRing(channelCount: 2)
        let input = try makeInput(timing: timing, slot: slot, audioRing: ring)
        defer { input.stop() }
        try startAndPlay(input, to: 1.5)
        let before = input.fileCountersSnapshot
        let blocksBefore = ring.recorded.count
        input.pause()
        XCTAssertFalse(input.pauseIsApplied, "触发条件：暂停还没落实")
        input.resume()
        sleepMs(500)
        let after = input.fileCountersSnapshot
        input.stop()
        let blocks = ring.recorded
        XCTAssertGreaterThan(blocksBefore, 200, "1.5 s 该写了 ≈ 280 块：\(blocksBefore)")
        let chunk = HostDuration(nanoseconds: 256 * 1_000_000_000 / 48_000)
        var breaks: [String] = []
        for i in max(1, blocksBefore - 20)..<blocks.count {
            let step = Int64(blocks[i].hostTime.ticks) - Int64(blocks[i - 1].hostTime.ticks)
            if abs(step - chunk.ticks) > 2 { breaks.append("第 \(i) 块 host time 步进 \(step) ticks（应 \(chunk.ticks)）") }
        }
        let written = after.audioChunksWritten - before.audioChunksWritten
        print("N09 音频：动手前 \(blocksBefore) 块，0.5 s 后 \(blocks.count) 块；写 \(written)、跳 \(after.audioChunksSkipped - before.audioChunksSkipped)；断点 \(breaks.prefix(5))")
        XCTAssertTrue(breaks.isEmpty, "音频块不首尾相接：\(breaks.prefix(10))")
        XCTAssertEqual(after.audioChunksSkipped, before.audioChunksSkipped, "取消暂停不该跳块：\(after)")
        XCTAssertGreaterThanOrEqual(written, 80, "0.5 s 该写 ≈ 94 块：\(after)")
    }
}
