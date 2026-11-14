// W5-N（prompt 101）：文件播放控制（D5 / V04）、推流 / 录制状态面板（L11 / V11）、录制 / 推流时长（E10）、状态行分开写码率（X28）、
// 推流鉴权的查询串写法（2026-10-10 裁定 ①）、025 的三个字段（裁定 ③）。
// 播放控制的两条起真 session：从输入的分支槽里逐帧解帧号（FileInput 推进主槽的同一帧也进分支，测试线程是分支唯一的消费者）；
// 面板 / 按钮 / 状态行的几条喂手搭的状态与 Stats 行（铁律 4：界面只读 Stats，喂什么显示什么）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
import SwitcherEngine
import SwitcherInputs
import SwitcherStreaming
@testable import Switcher

@MainActor
final class PlaybackStatusTests: XCTestCase {
    private var wc: MainWindowController { AppTest.controller.windowController }
    private var strip: InputStripView { wc.inputStrip }

    override func tearDown() {
        MainActor.assumeIsolated {
            AppTest.dismissConfirmations()
            AppTest.controller.panels.closeAll()
        }
        super.tearDown()
    }

    // MARK: - 共用

    private func patternMov() throws -> URL {
        let url = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("没有 Tests/Fixtures/pattern.mov") }
        return url
    }

    /// 第 0 帧比定位请求那一拍晚几拍：第 0 帧的拍点 = pts + 半帧相位提前量（FileInput 的口径），换算成**引擎时钟**的拍号再减请求那一拍
    /// （reducer 的 seekTick 是引擎的拍号；`programTiming()` 给新输入的时钟以"现在 + 3 拍"为 0 拍，拍号不是一套，不能直接比）。没看到第 0 帧为 nil。
    private func ticksUntilFrameZero(_ samples: [PlaybackSample], request tick: Tick?, session: SwitcherSession) -> Int64? {
        guard let tick, let spec = session.engine.clock?.spec, let zero = samples.first(where: { $0.number == 0 }) else { return nil }
        let tickTime = zero.pts + session.programTiming().frameDuration / 2
        return spec.tick(at: tickTime).rawValue - tick.rawValue
    }

    /// 一串样本里第一次往回跳（帧号比前一个小）之后的那一帧号；没有往回跳为 nil。
    private func firstAfterJumpBack(_ samples: [PlaybackSample]) -> Int? {
        let numbers = samples.compactMap(\.number)
        guard numbers.count > 1 else { return nil }
        for i in 1..<numbers.count where numbers[i] < numbers[i - 1] { return numbers[i] }
        return nil
    }

    private func stats(ts: Double = 1000, _ encoder: [Stats.EncoderEntry], videoDelayMs: Double = 0) -> Stats {
        Stats(ts: ts, tick: Tick(Int64(ts * 60)), renderMs: 1.5, missedRender: 0, jitterMs: 0, perInput: [:], encoder: encoder,
              audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 10, gpuPct: 20, videoDelayMs: videoDelayMs)
    }

    private func streamOutput(_ n: Int, _ name: String, enabled: Bool = true, url: String = "rtmp://127.0.0.1:1/live") -> OutputState {
        OutputState(number: n, kind: .stream, name: name, enabled: enabled,
                    settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(), stream: StreamSettings(url: url, streamKey: "k")))
    }

    private func recordOutput(_ n: Int, _ name: String, enabled: Bool = true, source: OutputSource = .program) -> OutputState {
        var o = RecordDefaults.output(number: n, name: name, format: .hd1080p60, directory: "/tmp/w5n")
        o.enabled = enabled
        o.settings.source = source
        return o
    }

    // MARK: - 1. 文件播放控制（D5 / V04）

    /// 格子第一行 × ｜ 转场 ｜ Cut ｜ ⏮ ｜ ▶/⏸ ｜ 🔁：后三颗只对文件输入亮（合成源灰着写原因）。
    /// ⏸ = setPlayback(paused: true)：画面停在这一帧，**pts 仍每拍刷新**（每拍一帧新的、帧号不变）；▶ 接着播；⏮（prompt 写 ⟲）= seekPlayback(0)：首帧帧号 0。
    /// 右键"切上 PGM 时从头播"= restartOnProgram：切到别处再切回来，首帧又是 0。从头到尾**输入对象是同一个**（运行表不重建）。
    func testUI_fileCellPlayPauseRestart() throws {
        let fixture = try patternMov()
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "pattern", source: .file(path: fixture.path, endAction: .loop, rate: 1))))
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "文件输入应 live")
        XCTAssertTrue(AppTest.waitUntil(3) { self.strip.cells[1] != nil && self.strip.cells[2] != nil })
        let cell1 = try XCTUnwrap(strip.cells[1]), cell2 = try XCTUnwrap(strip.cells[2])
        // 按钮：第一行六颗 × ｜ 转场 ｜ Cut ｜ ⏮ ｜ ▶/⏸ ｜ 🔁，后三颗只对文件输入亮
        XCTAssertEqual(cell1.firstRowButtons.map(ObjectIdentifier.init),
                       [cell1.removeButton, cell1.transitionButton, cell1.cutButton, cell1.restartButton, cell1.playButton, cell1.loopButton].map(ObjectIdentifier.init))
        for b in [cell1.playButton, cell1.restartButton, cell1.loopButton] {
            XCTAssertTrue(b.isEnabled)
            XCTAssertTrue(b.refusesFirstResponder, "空格仍是 Cut")
        }
        for b in [cell2.playButton, cell2.restartButton, cell2.loopButton] { XCTAssertFalse(b.isEnabled) }
        XCTAssertEqual(cell2.playButton.toolTip, "只对视频 / 音频文件输入")
        XCTAssertEqual(cell2.restartButton.toolTip, "只对视频 / 音频文件输入")
        XCTAssertEqual(cell1.playButton.accessibilityLabel(), "输入 1 暂停", "播放中：按钮是 ⏸")
        XCTAssertEqual(cell1.restartButton.accessibilityLabel(), "输入 1 回到开头")
        XCTAssertTrue(cell1.loopButton.toolTip?.contains("停在最后一帧") == true, "关循环 = 停在最后一帧，提示写明（2026-10-10 裁定 ②）：\(cell1.loopButton.toolTip ?? "")")
        let entry = try XCTUnwrap(session.inputs.entries[1])
        let file = try XCTUnwrap(entry.input as? FileInput)
        let identity = ObjectIdentifier(file)
        let branch = try XCTUnwrap(session.inputs.openBranch(input: 1), "给测试开一个分支槽")
        let sampler = SlotSampler(branch)
        defer {
            _ = sampler.stop()
            session.inputs.releaseBranch(branch, input: 1)
        }
        AppTest.pump(seconds: 0.3)
        let running = sampler.samples(since: 0).compactMap(\.number)
        XCTAssertGreaterThan(running.count, 10, "播放中每拍一帧：\(running)")

        // ⏸：快照里 paused、跑着的 FileInput 暂停；按钮换成 ▶、高亮
        let bus = session.control.bus
        let mark = bus.lastSequence
        cell1.playButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.playback.paused == true && file.isPaused },
                      "⏸ = setPlayback(paused: true)，落到跑着的那个 FileInput 上")
        let sent = bus.recentEntries().filter { $0.sequence > mark }
        XCTAssertEqual(sent.map(\.command), [.setPlayback(input: 1, paused: true)])
        XCTAssertEqual(Set(sent.map(\.source)), [.ui])
        XCTAssertTrue(AppTest.waitUntil(1) { cell1.playButton.accessibilityLabel() == "输入 1 播放" }, "暂停中：按钮是 ▶")
        XCTAssertNotNil(cell1.playButton.bezelColor, "暂停中高亮（画面是停住的）")
        AppTest.pump(seconds: 0.15)
        let pauseMark = sampler.count
        AppTest.pump(seconds: 0.5)
        let paused = sampler.samples(since: pauseMark)
        print("暂停：\(paused.count) 帧，帧号 \(Set(paused.compactMap(\.number)))")
        XCTAssertGreaterThanOrEqual(paused.count, 24, "暂停后仍每拍推一帧（0.5 s ≈ 30 拍）：\(paused)")
        XCTAssertEqual(Set(paused.compactMap(\.number)).count, 1, "暂停后帧号不变：\(paused)")
        let step = HostDuration(milliseconds: 1000.0 / 60)
        for i in 1..<paused.count {
            let d = paused[i].pts - paused[i - 1].pts
            XCTAssertGreaterThan(d, HostDuration(milliseconds: 0), "pts 每拍刷新、往前走：\(paused[i - 1]) → \(paused[i])")
            XCTAssertLessThanOrEqual(d, step + step + HostDuration(milliseconds: 1), "相邻两帧的 pts 差 ≤ 2 拍：\(paused[i - 1]) → \(paused[i])")
        }
        let heldNumber = paused.compactMap(\.number).first

        // ▶：接着播（从停住的那帧往后走）
        cell1.playButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.playback.paused == false && !file.isPaused })
        XCTAssertTrue(AppTest.waitUntil(1) { cell1.playButton.accessibilityLabel() == "输入 1 暂停" })
        let resumeMark = sampler.count
        AppTest.pump(seconds: 0.3)
        let resumed = sampler.samples(since: resumeMark).compactMap(\.number)
        XCTAssertGreaterThan(Set(resumed).count, 5, "继续播放：帧号在走：\(resumed)")
        if let held = heldNumber, let first = resumed.first { XCTAssertGreaterThanOrEqual(first, held, "从停住的帧接着走，不是从头：\(held) → \(resumed)") }

        // ⏮：seekPlayback(0)，首帧帧号 0
        AppTest.pump(seconds: 0.3)
        let restartMark = max(0, sampler.count - 1)   // 带上点之前的最后一帧：定位期间不推帧，标记之后的第一帧可能就是 0
        cell1.restartButton.performClick(nil)
        AppTest.pump(seconds: 0.6)
        let afterRestart = sampler.samples(since: restartMark)
        XCTAssertEqual(session.state.input(1)?.settings.playback.seekSeconds, 0, "⏮ = seekPlayback(0)")
        XCTAssertEqual(firstAfterJumpBack(afterRestart), 0, "从头后首帧帧号 0：\(afterRestart)")
        let restartDelay = ticksUntilFrameZero(afterRestart, request: session.state.input(1)?.settings.playback.seekTick, session: session)
        print("⏮：定位请求那一拍之后第 \(restartDelay.map(String.init) ?? "?") 拍出第 0 帧")

        // 右键：播放控制四项（文件输入才有）；"切上 PGM 时从头播"打勾 = restartOnProgram
        let menu = cell1.contextMenu()
        let titles = menu.items.map(\.title)
        for t in ["暂停", "回到开头", "循环", "切上 PGM 时从头播"] { XCTAssertTrue(titles.contains(t), "右键菜单缺「\(t)」：\(titles)") }
        XCTAssertFalse(cell2.contextMenu().items.map(\.title).contains("切上 PGM 时从头播"), "非文件输入没有播放控制")
        let restartItem = try XCTUnwrap(menu.items.first { $0.title == "切上 PGM 时从头播" })
        XCTAssertEqual(restartItem.state, .off)
        _ = restartItem.target?.perform(restartItem.action, with: restartItem)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.playback.restartOnProgram == true }, "右键打勾 = restartOnProgram")
        XCTAssertEqual(cell1.contextMenu().items.first { $0.title == "切上 PGM 时从头播" }?.state, .on)
        // 切走再切回来：reducer 在换 PGM 那一拍写定位 0，运行表照它 seek
        AppTest.pump(seconds: 0.5)
        session.send(.setProgram(input: 2))
        AppTest.pump(seconds: 0.3)
        let programMark = max(0, sampler.count - 1)
        session.send(.setProgram(input: 1))
        AppTest.pump(seconds: 0.6)
        let afterProgram = sampler.samples(since: programMark)
        XCTAssertEqual(firstAfterJumpBack(afterProgram), 0, "切上 PGM 时从头播：首帧帧号 0：\(afterProgram)")
        let programDelay = ticksUntilFrameZero(afterProgram, request: session.state.input(1)?.settings.playback.seekTick, session: session)
        print("切上 PGM 时从头播：切换那一拍之后第 \(programDelay.map(String.init) ?? "?") 拍出第 0 帧")
        XCTAssertEqual(ObjectIdentifier(session.inputs.entries[1]!.input as AnyObject), identity, "输入对象从头到尾是同一个（不重建）")
    }

    /// 输入设置"来源"一节：文件输入只改"播完"/"播放速率"= 当场生效、不重建这一路（不用点"应用来源"）；路径变了照旧要点应用、重建。
    func testUI_fileSourceEndActionAndRateChangeInPlace() throws {
        let fixture = try patternMov()
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "pattern", source: .file(path: fixture.path, endAction: .loop, rate: 1))))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        let file = try XCTUnwrap(session.inputs.entries[1]?.input as? FileInput)
        let identity = ObjectIdentifier(file)
        let window = try XCTUnwrap(AppTest.controller.panels.showInputSettings(input: 1))
        let model = window.model
        model.section = .source
        let form = model.sourceFormModel()
        form.model.fileRate = 2
        XCTAssertTrue(AppTest.waitUntil(2) {
            if case .file(_, .loop, let rate)? = session.state.input(1)?.source { return rate == 2 } else { return false }
        }, "改速率当场发 setInputSource：\(String(describing: session.state.input(1)?.source))")
        XCTAssertTrue(AppTest.waitUntil(2) { file.rate == 2 }, "速率改在跑着的那个 FileInput 上")
        XCTAssertFalse(model.sourceChanged, "只改速率 / 播完不用点“应用来源”")
        form.model.fileEndAction = .black
        XCTAssertTrue(AppTest.waitUntil(2) { file.endAction == .black }, "播完改成黑场：就地改")
        XCTAssertEqual(ObjectIdentifier(session.inputs.entries[1]!.input as AnyObject), identity, "不重建这一路")
        XCTAssertTrue(model.sourceHint.contains("不重建"), "来源一节的说明写明哪些改动不重建：\(model.sourceHint)")
        // 换文件：要点“应用来源”，重建
        form.model.filePath = fixture.path + "-missing.mov"
        AppTest.pump(seconds: 0.3)
        XCTAssertTrue(model.sourceChanged, "路径变了：等用户点应用")
        XCTAssertEqual(ObjectIdentifier(session.inputs.entries[1]!.input as AnyObject), identity, "没点应用之前不动")
        model.applySource()
        XCTAssertTrue(AppTest.waitUntil(3) { session.inputs.entries[1].map { ObjectIdentifier($0.input as AnyObject) != identity } ?? false }, "路径变了要重建")
    }

    /// 031（用户 2026-10-18 裁定 (c)，G10 胶水 ⑤）：速率框钳进 0.1–8——填 10 当场发出去的是 8、总线不再 400；0.05 → 0.1，≤ 0 / 非数 → 1。
    func testG10_fileRateFieldClampedToContractRange() throws {
        XCTAssertEqual([10, 0.05, 0, -1, .nan, .infinity, 1.5].map(AddInputModel.clampedFileRate), [8, 0.1, 1, 1, 1, 8, 1.5])
        let fixture = try patternMov()
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "pattern", source: .file(path: fixture.path, endAction: .loop, rate: 1))))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        let window = try XCTUnwrap(AppTest.controller.panels.showInputSettings(input: 1))
        window.model.section = .source
        window.model.sourceFormModel().model.fileRate = 10
        XCTAssertTrue(AppTest.waitUntil(2) { if case .file(_, _, let r)? = session.state.input(1)?.source { return r == 8 } else { return false } },
                      "越界的速率钳到 8 再发：\(String(describing: session.state.input(1)?.source))")
        XCTAssertEqual(session.control.bus.counters.rejected, 0, "不再被总线 400")
    }

    /// 三档格子宽（160 / 200 / 256）里第一行六颗都放得下：转场 / Cut 的字不被截（按钮宽 ≥ 字宽 + 6）、⏮ ▶ 🔁 各 20 pt、最后一颗不出格子。
    func testUI_fileCellButtonsFitSmallestCell() throws {
        let cell = InputCellView(config: InputConfig(number: 1, name: "pattern", source: .file(path: "/tmp/w5n.mov", endAction: .loop, rate: 1)))
        // W6-A 改口径：ThumbnailSize 多了第四档"紧凑"（宽 72 的竖小格，按钮不常显、都在右键菜单里），只量带两行按钮的三档
        for size in ThumbnailSize.allCases where size != .compact {
            let thumb = (size.width * 9 / 16).rounded()
            cell.setSize(width: size.width, thumbnailHeight: thumb)
            cell.frame = NSRect(x: 0, y: 0, width: size.width, height: InputCellView.height(thumbnailHeight: thumb))
            cell.layoutSubtreeIfNeeded()
            let frames = cell.firstRowButtons.map { $0.convert($0.bounds, to: cell) }
            print("格子 \(Int(size.width)) pt 第一行：\(frames.map { Int($0.width.rounded()) })")
            for b in [cell.transitionButton, cell.cutButton] {
                let text = (b.title as NSString).size(withAttributes: [.font: b.font ?? NSFont.systemFont(ofSize: 10)]).width
                XCTAssertGreaterThanOrEqual(b.frame.width, text + 6, "\(Int(size.width)) pt：“\(b.title)”放得下")
            }
            for b in cell.playbackButtons { XCTAssertEqual(b.frame.width, InputCellView.iconButtonWidth, accuracy: 0.5) }
            XCTAssertLessThanOrEqual(frames.last!.maxX, size.width - 3.5, "\(Int(size.width)) pt：最后一颗不出格子")
            for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "不重叠") }
        }
    }

    // MARK: - 2. 推流 / 录制状态面板（L11 / V11）

    /// 面板每个目的地一行，数全读 Stats.encoder（uptime_s = 65 → 00:01:05，disconnects / last_error / attempt 原样）；
    /// 下面的事件记录由相邻两行 Stats 的状态变化推出（连接中 → 在推 → 断开 → 重连上），时间 = Stats.ts；录制同理一页。
    /// 底栏推流 ▴ 的"推流状态…"、录制 ▴ 的"录制状态…"、推流页 / 录制页都能开它。
    func testUI_streamStatusPanelReadsStatsUptime() throws {
        var state = MixerState()
        state.outputs = [recordOutput(1, "录制"), streamOutput(2, "主平台"), streamOutput(3, "备用"), streamOutput(4, "没开的", enabled: false)]
        let model = OutputStatusModel()
        let main = Stats.EncoderEntry(output: 2, skipped: 1, bitrate: 5_900_000, frames: 3_900, dropped: 3, reconnects: 1, state: "publishing",
                                      uptimeS: 65, disconnects: 2, lastError: "鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected reason=authfailed")
        let rec = Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, frames: 7_200, dropped: 0, diskFreeMb: 204_800, state: "recording", uptimeS: 3_725)
        func backup(_ s: String, attempt: Int = 0, frames: UInt64 = 0, uptime: Double = 0, error: String = "") -> Stats.EncoderEntry {
            Stats.EncoderEntry(output: 3, skipped: 0, bitrate: s == "publishing" ? 4_000_000 : 0, frames: frames, state: s, uptimeS: uptime,
                               disconnects: error.isEmpty ? 0 : 1, lastError: error, attempt: attempt)
        }
        model.apply(stats: stats(ts: 1_000, [rec, main, backup("connecting", attempt: 1, uptime: 0.4)], videoDelayMs: 40), state: state)
        // 一行一个推流目的地（没开的也列，写"未开"）
        XCTAssertEqual(model.streamRows.map(\.name), ["主平台", "备用", "没开的"])
        let row = try XCTUnwrap(model.streamRows.first { $0.number == 2 })
        XCTAssertEqual(row.uptime, "00:01:05", "uptime_s = 65 → 00:01:05（读 Stats，不在 App 里计时）")
        XCTAssertEqual(row.state, "推流中")
        XCTAssertEqual(row.bitrate, "5.90 Mb/s")
        XCTAssertEqual(row.dropped, "3")
        XCTAssertEqual(row.reconnects, "1")
        XCTAssertEqual(row.disconnects, "2")
        XCTAssertEqual(row.lastError, "鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected reason=authfailed", "最后错误原样显示 StreamOutput 打的那行（G6 追加 ①）")
        XCTAssertEqual(model.streamRows.first { $0.number == 3 }?.state, "连接中", "第 1 次连接 = 连接中（attempt 读 Stats）")
        XCTAssertEqual(model.streamRows.first { $0.number == 4 }?.state, "未开")
        XCTAssertEqual(model.streamRows.first { $0.number == 4 }?.uptime, "—")
        XCTAssertEqual(model.videoDelayText, "视频延后 40 ms", "W1-B4：读 Stats.video_delay_ms")
        // 录制页：时长 / 帧数 / 丢帧 / 剩余空间
        let recRow = try XCTUnwrap(model.recordRows.first)
        XCTAssertEqual(recRow.uptime, "01:02:05")
        XCTAssertEqual(recRow.state, "录制中")
        XCTAssertEqual(recRow.frames, "7200")
        XCTAssertEqual(recRow.disk, "200.0 GB")

        // 事件：相邻两行的状态变化（只做显示，不另算数）
        model.apply(stats: stats(ts: 1_001, [rec, main, backup("publishing", frames: 60, uptime: 1.4)]), state: state)
        model.apply(stats: stats(ts: 1_005, [rec, main, backup("backoff", attempt: 2, frames: 240, uptime: 5.4, error: "连接断了：connection reset by peer")]), state: state)
        model.apply(stats: stats(ts: 1_006, [rec, main, backup("connecting", attempt: 2, frames: 240, uptime: 6.4, error: "连接断了：connection reset by peer")]), state: state)
        model.apply(stats: stats(ts: 1_008, [rec, main, backup("publishing", frames: 300, uptime: 8.4, error: "连接断了：connection reset by peer")]), state: state)
        model.apply(stats: stats(ts: 1_009, [rec, main, backup("publishing", frames: 360, uptime: 9.4, error: "连接断了：connection reset by peer")]), state: state)
        let texts = model.events(for: .stream).map(\.text)
        XCTAssertEqual(texts, ["主平台 · 推流中", "备用 · 连接中", "备用 · 推流中", "备用 · 断开：连接断了：connection reset by peer", "备用 · 重连中（第 1 次）", "备用 · 重连上"],
                       "事件由状态变化推出（第一次看到在跑的路记一条当前状态；状态不变不记）：\(texts)")
        let times = model.events(for: .stream).map(\.time)
        XCTAssertEqual(times.map { $0.timeIntervalSince1970 }, [1_000, 1_000, 1_001, 1_005, 1_006, 1_008], "事件时间 = 那一行 Stats 的 ts")
        XCTAssertEqual(model.events(for: .record).map(\.text), ["录制 · 录制中"], "录制页同理（第一次看到就记一条）")
        XCTAssertEqual(model.streamRows.first { $0.number == 3 }?.uptime, "00:00:09")

        // 入口：底栏推流 ▴"推流状态…"、录制 ▴"录制状态…"、推流页按钮——都开同一个面板
        let panels = AppTest.controller.panels
        let bar = wc.bottomBar
        let streamMenu = bar.streamMenu()
        let statusItem = try XCTUnwrap(streamMenu.items.first { $0.title == "推流状态…" })
        _ = statusItem.target?.perform(statusItem.action, with: statusItem)
        XCTAssertTrue(AppTest.waitUntil(2) { panels.outputStatusWindow?.window?.isVisible == true }, "推流 ▴ 的“推流状态…”开状态面板（原来指向推流页）")
        XCTAssertEqual(panels.outputStatus.page, .stream)
        XCTAssertEqual(panels.outputStatusWindow?.window?.title, "推流 / 录制状态")
        let recordItem = try XCTUnwrap(bar.recordMenu().items.first { $0.title == "录制状态…" }, "录制 ▴ 加“录制状态…”")
        _ = recordItem.target?.perform(recordItem.action, with: recordItem)
        XCTAssertTrue(AppTest.waitUntil(1) { panels.outputStatus.page == .record }, "录制同理一页")
        panels.closeAll()
        let pageModel = OutputSettingsModel(state: state, tab: .stream, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        pageModel.showOutputStatus = { panels.showOutputStatus($0) }
        pageModel.showOutputStatus?(.stream)
        XCTAssertTrue(AppTest.waitUntil(2) { panels.outputStatusWindow?.window?.isVisible == true && panels.outputStatus.page == .stream }, "推流页也能开")
        // "显示日志…" = 帮助 › 打开诊断文件夹（不在测试里真开 Finder：看动作接的是哪一个）
        XCTAssertEqual(OutputStatusModel.showLogsTitle, "显示日志…")
        XCTAssertNotNil(panels.outputStatus.showLogs, "“显示日志…”接到导出最近的系统日志（W5-P，W4C3 第 1 条）")
    }

    // MARK: - 3. 录制 / 推流时长（E10）

    /// 底栏录制 / 推流主体与工具条右组写"● 录制 hh:mm:ss"，时长读 Stats.encoder[].uptime_s；录制 ▴ 每一行、ISO 表的"时长"列同一份。
    func testUI_recordButtonShowsDurationFromStats() throws {
        let bar = BottomBarView()
        var state = MixerState()
        state.inputs = [AppTest.syntheticConfig(number: 1)]
        state.outputs = [recordOutput(1, "录制"), streamOutput(5, "主平台")]
        bar.apply(state: state)
        let rec = Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, frames: 223_500, state: "recording", uptimeS: 3_725.6)
        let pub = Stats.EncoderEntry(output: 5, skipped: 0, bitrate: 6_000_000, frames: 36_000, state: "publishing", uptimeS: 600.2)
        bar.apply(stats: stats([rec, pub]))
        XCTAssertEqual(bar.record.bodyButton.title, "● 录制 01:02:05", "时长 = Stats 的 uptime_s（3725.6 s 向下取整）")
        XCTAssertEqual(bar.stream.bodyButton.title, "● 推流 00:10:00")
        // 下一行 Stats 来了：跟着走（不在 App 里自己计时：Stats 不变，字就不变）
        bar.apply(stats: stats(ts: 1_001, [Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, frames: 223_560, state: "recording", uptimeS: 3_726.6), pub]))
        XCTAssertEqual(bar.record.bodyButton.title, "● 录制 01:02:06")
        AppTest.pump(seconds: 1.2)
        XCTAssertEqual(bar.record.bodyButton.title, "● 录制 01:02:06", "没有新 Stats 就不变（不另算数）")
        // 工具条右组：底栏同一份汇总
        let toolbar = ToolbarOutputStatusView()
        toolbar.show(record: bar.recordSummary, stream: bar.streamSummary)
        XCTAssertEqual(toolbar.recordText, "● 录制 01:02:06")
        XCTAssertEqual(toolbar.streamText, "● 推流 00:10:00")
        // 多路：PGM + 两路 ISO 都在录 → 时长取最长那一路 +"（3 路）"；推流两个在推一个没开 →"（2/3）"
        state.outputs = [recordOutput(1, "录制"), recordOutput(2, "ISO 1", source: .input(number: 1)), recordOutput(3, "ISO 2", source: .input(number: 1)),
                         streamOutput(5, "主平台"), streamOutput(6, "备用"), streamOutput(7, "没开的", enabled: false)]
        bar.apply(state: state)
        bar.apply(stats: stats(ts: 1_002, [
            Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 65),
            Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 64.9),
            Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 64.8),
            Stats.EncoderEntry(output: 5, skipped: 0, bitrate: 6_000_000, frames: 60, state: "publishing", uptimeS: 30),
            Stats.EncoderEntry(output: 6, skipped: 0, bitrate: 6_000_000, frames: 60, state: "publishing", uptimeS: 3_600 * 25 + 1),
        ]))
        XCTAssertEqual(bar.record.bodyButton.title, "● 录制 00:01:05（3 路）")
        XCTAssertEqual(bar.stream.bodyButton.title, "● 推流 25:00:01（2/3）", "超过一天小时数照写，不绕回")
        // 最长的两颗标题在最小窗口宽（1100 pt）下：左组最后一颗（多画面）和右组第一颗（叠加）之间还留着 ≥ 16 pt（底栏的约束），不挤不叠
        let wide = BottomBarView(frame: NSRect(x: 0, y: 0, width: AppTest.minimumMainWindowSize.width, height: Theme.bottomBarHeight))
        wide.apply(state: state)
        wide.apply(stats: stats(ts: 1_002, [
            Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 36_000),
            Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 36_000),
            Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 36_000),
            Stats.EncoderEntry(output: 5, skipped: 0, bitrate: 6_000_000, frames: 60, state: "publishing", uptimeS: 36_000),
            Stats.EncoderEntry(output: 6, skipped: 0, bitrate: 6_000_000, frames: 60, state: "publishing", uptimeS: 36_000),
        ]))
        wide.layoutSubtreeIfNeeded()
        let leftEnd = wide.multiview.convert(wide.multiview.bounds, to: wide).maxX
        let rightStart = wide.overlayButton.convert(wide.overlayButton.bounds, to: wide).minX
        print("底栏 1100 pt、最长标题：左组到 \(Int(leftEnd)) pt，右组从 \(Int(rightStart)) pt 起（录制 \(Int(wide.record.frame.width)) pt、推流 \(Int(wide.stream.frame.width)) pt）")
        XCTAssertEqual(wide.record.bodyButton.title, "● 录制 10:00:00（3 路）")
        XCTAssertGreaterThanOrEqual(rightStart - leftEnd, 16, "最小窗口里左右两组不挤")
        XCTAssertGreaterThanOrEqual(wide.record.bodyButton.frame.width, wide.record.bodyButton.intrinsicContentSize.width - 0.5, "录制主体的字没被压缩")
        // 录制 ▴：每一行"名字 · 状态 · 时长"
        let rows = bar.recordMenu().items.filter { $0.action != nil && !$0.title.hasPrefix("全部") && !$0.title.hasSuffix("…") }.map(\.title)
        XCTAssertEqual(rows, ["录制 · 录制中 · 00:01:05", "ISO 1 · 录制中 · 00:01:04", "ISO 2 · 录制中 · 00:01:04"])
        // ISO 表的"时长"列：同一份 uptime
        let pages = OutputSettingsModel(state: state, tab: .iso, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        pages.apply(stats: stats(ts: 1_002, [
            Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 65),
            Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 18_000_000, frames: 1, state: "recording", uptimeS: 64.9),
        ]))
        XCTAssertEqual(pages.isoRows.map(\.duration), ["00:01:05", "00:01:04"], "PGM 行 = 录制 1 的 uptime；输入 1 这行 = 它的 ISO 路（输出 2）的 uptime")
        pages.apply(stats: stats(ts: 1_003, [Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 0, frames: 1, state: "stopped")]))
        XCTAssertEqual(pages.isoRows.map(\.duration), ["—", "—"], "没在录写 —（不写 00:00:00）")
        XCTAssertEqual(OutputButtonSummary.durationText(0), "00:00:00")
        XCTAssertEqual(OutputButtonSummary.durationText(59.99), "00:00:59")
        XCTAssertEqual(OutputButtonSummary.durationText(-3), "00:00:00")
    }

    // MARK: - 4. 状态行（X28）

    /// 状态行分开写"录制 x · 推流 y"，多路时给最差（码率最低）的那一路；NDI 的原始码率不进这两项；"编码跳帧"标签改成实际含义"编码滞后跳帧"。
    func testUI_statusLineSeparatesRecordAndStreamBitrate() {
        let kinds: [Int: OutputKind] = [1: .record, 2: .stream, 3: .stream, 4: .ndi, 5: .record]
        let s = stats([
            Stats.EncoderEntry(output: 4, skipped: 0, bitrate: 1_990_000_000, frames: 60, state: "publishing"),
            Stats.EncoderEntry(output: 1, skipped: 2, bitrate: 18_000_000, frames: 60, diskFreeMb: 2_048, state: "recording"),
            Stats.EncoderEntry(output: 2, skipped: 5, bitrate: 5_900_000, frames: 60, state: "publishing"),
            Stats.EncoderEntry(output: 3, skipped: 1, bitrate: 2_100_000, frames: 60, state: "publishing"),
            Stats.EncoderEntry(output: 5, skipped: 0, bitrate: 0, frames: 0, state: "idle"),
        ])
        let fields = StatusLineFormatter.fields(current: s, previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(fields.map(\.label), ["节目", "帧率", "渲染", "GPU", "CPU", "丢帧", "编码滞后跳帧", "录制", "推流", "磁盘"])
        let value = Dictionary(uniqueKeysWithValues: fields.map { ($0.label, $0.value) })
        XCTAssertEqual(value["录制"], "18.00 Mb/s")
        XCTAssertEqual(value["推流"], "2.10 Mb/s", "两个目的地在推：给最差（最低）的那一路")
        XCTAssertEqual(value["编码滞后跳帧"], "5", "跳帧给最差的那一路（录制 / 推流里最多的）")
        let line = StatusLineFormatter.line(current: s, previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertTrue(line.contains("录制 18.00 Mb/s  ·  推流 2.10 Mb/s"), line)
        // 只录不推：推流一项写 —；只推不录同理
        let recordOnly = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 6_000_000, frames: 1, state: "recording")]),
                                                    previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(recordOnly.first { $0.label == "录制" }?.value, "6.00 Mb/s")
        XCTAssertEqual(recordOnly.first { $0.label == "推流" }?.value, "—")
        // 推流在退避（码率 0）也算在跑：最差的那一路就是它
        let backoff = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 4_000_000, frames: 1, state: "publishing"),
                                                                 Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 0, frames: 1, state: "backoff", attempt: 2)]),
                                                 previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(backoff.first { $0.label == "推流" }?.value, "0 b/s")
        // 底栏：同一行 Stats 同样的字
        let bar = BottomBarView()
        var state = MixerState()
        state.outputs = [recordOutput(1, "录制"), streamOutput(2, "主平台"), streamOutput(3, "备用"), OutputState(number: 4, kind: .ndi, name: "NDI"), recordOutput(5, "ISO", enabled: false)]
        bar.apply(state: state)
        bar.apply(stats: s)
        XCTAssertTrue(bar.statusLabel.stringValue.contains("编码滞后跳帧 5  ·  录制 18.00 Mb/s  ·  推流 2.10 Mb/s  ·  磁盘 2.0 GB"), bar.statusLabel.stringValue)
    }

    // MARK: - 5. 推流鉴权的两种写法（2026-10-10 裁定 ①）

    /// 鉴权表里"写法"二选一：Adobe（user:pass@，原来的）/ 查询串（?user=&pass=，参数名可改，默认 MediaMTX 的 user / pass）。
    /// 查询串写法由 StreamAddress 写进地址的 query、不碰 userinfo（两种写法互斥：换写法时去掉另一种）；地址框里 query 的 user / pass / token / key 等值
    /// 也打码（名单 = StreamURLRedaction.secretQueryParams），编辑时打码段原样留着就换回原值；节目里只存整条地址。
    func testPanels_streamAuthQueryStringWritesQueryAndMasks() throws {
        var state = MixerState()
        state.outputs = [streamOutput(2, "自建", enabled: false, url: "rtmp://media.local:1935/live?app=1")]
        let model = OutputSettingsModel(state: state, tab: .stream, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        var sent: [Command] = []
        model.send = { sent.append($0) }
        // 默认写法：地址里没有账号 = Adobe；查询串的默认参数名 = MediaMTX 的 user / pass
        XCTAssertEqual(model.streamAuthStyle(2), .adobe)
        XCTAssertEqual(StreamAddress.defaultQueryUserParam, "user")
        XCTAssertEqual(StreamAddress.defaultQueryPassParam, "pass")
        // 查询串：写进 query，别的查询项原样；userinfo 不碰
        XCTAssertNil(model.setStreamAuth(2, user: "op", password: "p@ss w", style: .query(userParam: "user", passParam: "pass")))
        let url = try XCTUnwrap(model.state.output(2)?.settings.stream?.url)
        XCTAssertEqual(url, "rtmp://media.local:1935/live?app=1&user=op&pass=p%40ss%20w")
        XCTAssertNil(StreamAddress.userinfoRange(in: url), "查询串写法不碰 userinfo")
        XCTAssertNoThrow(try StreamDestination(settings: StreamSettings(url: url, streamKey: "k")), "推流包认得这条地址")
        XCTAssertEqual(model.streamAuthStyle(2), .query(userParam: "user", passParam: "pass"), "按地址认回查询串写法")
        XCTAssertEqual(StreamAddress.queryCredentials(of: url, userParam: "user", passParam: "pass")?.user, "op")
        XCTAssertEqual(StreamAddress.queryCredentials(of: url, userParam: "user", passParam: "pass")?.password, "p@ss w", "读出来是解码后的原文")
        // 地址框打码：query 的 user / pass 值换成记号；名单与 StreamURLRedaction 同源
        let masked = model.maskedStreamURL(2)
        XCTAssertEqual(masked, "rtmp://media.local:1935/live?app=1&user=•••&pass=•••")
        for name in ["token", "key", "passphrase", "secret"] {
            XCTAssertEqual(StreamAddress.masked("srt://h:1?\(name)=abc&x=1"), "srt://h:1?\(name)=•••&x=1", "名单里的 \(name) 也打码")
        }
        XCTAssertTrue(StreamURLRedaction.secretQueryParams.isSuperset(of: ["user", "pass", "token", "key"]))
        // 编辑：打码段原样留着 = 换回原值；改了主机照样保住账号；自己写了新值 = 用新值
        XCTAssertEqual(StreamAddress.unmasked(masked, original: url), url)
        XCTAssertEqual(StreamAddress.unmasked("rtmp://other:1935/live?app=1&user=•••&pass=•••", original: url), "rtmp://other:1935/live?app=1&user=op&pass=p%40ss%20w")
        XCTAssertEqual(StreamAddress.unmasked("rtmp://media.local:1935/live?app=1&user=me&pass=•••", original: url), "rtmp://media.local:1935/live?app=1&user=me&pass=p%40ss%20w")
        // 参数名可改（SRS / nginx-rtmp 按自己的规矩）
        XCTAssertNil(model.setStreamAuth(2, user: "op", password: "x1", style: .query(userParam: "username", passParam: "password")))
        XCTAssertEqual(model.state.output(2)?.settings.stream?.url, "rtmp://media.local:1935/live?app=1&username=op&password=x1", "换参数名：旧的 user / pass 去掉")
        // 换回 Adobe：写 userinfo、去掉查询串里的账号；用户名空 = 清掉
        XCTAssertNil(model.setStreamAuth(2, user: "op", password: "x1", style: .adobe))
        XCTAssertEqual(model.state.output(2)?.settings.stream?.url, "rtmp://op:x1@media.local:1935/live?app=1")
        XCTAssertEqual(model.streamAuthStyle(2), .adobe)
        XCTAssertNil(model.setStreamAuth(2, user: "", password: "", style: .query(userParam: "user", passParam: "pass")))
        XCTAssertEqual(model.state.output(2)?.settings.stream?.url, "rtmp://media.local:1935/live?app=1", "用户名空 = 两种写法的账号都去掉")
        // 文案写清哪类服务器用哪种
        XCTAssertTrue(L("outputSettings.stream.auth.style.adobeHint").contains("Wowza"))
        XCTAssertTrue(L("outputSettings.stream.auth.style.queryHint").contains("MediaMTX"))
        XCTAssertTrue(L("outputSettings.stream.auth.style.queryHint").contains("nginx-rtmp"))
        // 节目里只存整条地址：没有多出来的字段 / extra 键
        let o = try XCTUnwrap(model.state.output(2))
        XCTAssertTrue(o.settings.extra.isEmpty, "写法不存进 extra：\(o.settings.extra)")
        XCTAssertFalse(sent.isEmpty)
    }

    // MARK: - 6. 025：三个 App 层标记换成正式字段

    /// 读写都走 RecordSettings.armed / ownFormat、StreamSettings.followFirst；Show.load 后搬一次旧 extra 键（搬完删键）。
    func testPanels_025_showLoadMigratesLegacyAppFlags() throws {
        var show = ShowDocuments.emptyShow(recordDirectory: "/tmp/w5n")
        show.outputs[0].settings.extra[RecordSettings.legacyArmedExtraKey] = .bool(false)
        var iso = RecordDefaults.output(number: 2, name: "ISO", format: .hd1080p60, directory: "/tmp/w5n")
        iso.settings.source = .input(number: 1)
        iso.settings.extra[RecordSettings.legacyOwnFormatExtraKey] = .bool(true)
        var follower = streamOutput(4, "备用", enabled: false)
        follower.settings.extra[StreamSettings.legacyFollowFirstExtraKey] = .bool(true)
        show.outputs += [iso, streamOutput(3, "主平台", enabled: false), follower]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w5n-025-\(UUID().uuidString).\(ShowDocuments.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try ShowStore().save(show, to: url)
        let suite = UserDefaults(suiteName: "w5n-025-\(UUID().uuidString)")!
        let documents = ShowDocuments(defaults: suite, recordDirectory: "/tmp/w5n")
        let loaded = try documents.load(from: url)
        XCTAssertEqual(loaded.outputs[0].settings.record?.armed, false, "旧键 app.record.armed = false 搬进字段")
        XCTAssertEqual(loaded.outputs[1].settings.record?.ownFormat, true)
        XCTAssertEqual(loaded.outputs[3].settings.stream?.followFirst, true)
        for o in loaded.outputs { XCTAssertTrue(o.settings.extra.isEmpty, "搬完删键：\(o.name) \(o.settings.extra)") }
        // OutputLinkage 读字段
        let state = loaded.makeState()
        XCTAssertEqual(OutputLinkage.armedRecords(in: state).map(\.number), [2], "录制 1 取消参与 → 只起 ISO")
        XCTAssertFalse(OutputLinkage.followsRecordMaster(try XCTUnwrap(state.output(2)), in: state), "ownFormat 的 ISO 不跟录制 1")
        XCTAssertTrue(OutputLinkage.followsFirstStream(try XCTUnwrap(state.output(4)), in: state))
        // 写也走字段：录制页取消参与 / 推流页勾跟随，extra 里不出现旧键
        let model = OutputSettingsModel(state: state, tab: .record, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        model.setRecordArmed(1, on: true)
        XCTAssertEqual(model.state.output(1)?.settings.record?.armed, true)
        model.setStreamFollowsFirst(4, on: false)
        XCTAssertEqual(model.state.output(4)?.settings.stream?.followFirst, false)
        let fresh = model.newStreamSettings(url: "rtmp://h/app", key: "k")
        XCTAssertEqual(fresh.stream?.followFirst, true, "第 2 个起新建的目的地默认跟推流 1")
        for o in model.state.outputs { XCTAssertTrue(o.settings.extra.isEmpty, "写也不再用 extra：\(o.name) \(o.settings.extra)") }
        XCTAssertTrue(fresh.extra.isEmpty)
    }
}

/// 分支槽里新到的一帧（按 sequence 去重）：帧号（解不出为 nil）+ pts。不持有 Frame（解码器的像素池要复用），当场解。
struct PlaybackSample: CustomStringConvertible, Sendable {
    let number: Int?
    let pts: HostTime
    var description: String { "#\(number.map(String.init) ?? "?")@\(pts.ticks)" }
}

/// 分支槽的采样线程：主线程要 pump 事件循环让快照落到运行表上（定位 / 暂停都在那儿生效），采样放在另一条线程——它是这个分支槽唯一的消费者，
/// 每 0.5 ms 看一次最新一帧，新的（sequence 变了）就当场解帧号记下。点按钮之前就在采，"定位后的第一帧"不会因为主线程忙别的而漏掉。
final class SlotSampler: @unchecked Sendable {
    private let slot: LockFreeFrameSlot
    private let lock = NSLock()
    private var list: [PlaybackSample] = []
    private var running = true
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    init(_ slot: LockFreeFrameSlot) {
        self.slot = slot
        let thread = Thread { [self] in self.loop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func loop() {
        var last: UInt64?
        while lock.withLock({ running }) {
            if let f = slot.latest(atOrBefore: HostClock.now() + HostDuration(milliseconds: 1000)), f.sequence != last {
                last = f.sequence
                let sample = PlaybackSample(number: TestPattern.decode(pixelBuffer: f.pixelBuffer)?.frameNumber.map(Int.init), pts: f.pts)
                lock.withLock { list.append(sample) }
            }
            usleep(500)
        }
        done.signal()
    }

    /// 到现在为止采了多少帧（当作"从这里往后"的标记）。
    var count: Int { lock.withLock { list.count } }

    /// 标记之后采到的帧。
    func samples(since mark: Int) -> [PlaybackSample] { lock.withLock { Array(list[min(mark, list.count)...]) } }

    /// 停下采样线程（可重复调）。
    func stop() -> [PlaybackSample] {
        let wait = lock.withLock { () -> Bool in
            defer { running = false; stopped = true }
            return !stopped
        }
        if wait { done.wait() }
        return lock.withLock { list }
    }
}
