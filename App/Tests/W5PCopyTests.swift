// W5-P（prompt 119）App 口径：111 留下的（鉴权停下的推流写"失败"、推流页红字分两句、编码详情、状态行不算 failed）、
// 112 留下的（格子"转场"与 T-bar 遇没选输入的 Stinger 当前组）、W4C3 写手册查出来的 S3 一批（reports/issues/W4C3-w5-app-gaps-found-by-docs.md）。
import AppKit
import SwiftUI
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class W5PCopyTests: XCTestCase {
    // MARK: 111 留下的：鉴权停下的推流

    private func streamRoute(_ n: Int, state: String?, failure: OutputRouteFailure? = nil) -> OutputRouteStatus {
        OutputRouteStatus(output: OutputState(number: n, kind: .stream, name: "推流 \(n)", enabled: true), entry: state.map {
            Stats.EncoderEntry(output: n, skipped: 0, bitrate: 0, state: $0)
        }, failure: failure)
    }

    /// 底栏：推流对象停在 failed（服务器拒绝鉴权）的写"失败"（与状态窗、Stats 同一个字；用户 2026-10-17 定），仍是深红、点主体仍重试它；
    /// 运行表起不来的照旧写"起不来"。▴ 菜单那一项同样写"失败"、点 = 单路重试。
    func testW5P111_authStoppedStreamSaysFailedInBottomBar() {
        let stopped = OutputRouteFailure(reason: "推流 2 不再重连：鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized", stoppedStream: true)
        let route = streamRoute(2, state: "failed", failure: stopped)
        let state = OutputButtonSummary.routeState(route, kind: .stream)
        XCTAssertEqual(state.text, "失败")
        XCTAssertEqual(state.severity, .error)
        let summary = OutputButtonSummary.stream([route])
        XCTAssertEqual(summary.title, "推流 · 失败", "原来写「推流 · 起不来」，状态窗写「失败」，两处不一致")
        XCTAssertTrue(summary.toolTip?.contains("推流 2：失败 — 推流 2 不再重连：鉴权失败") == true, summary.toolTip ?? "")
        XCTAssertTrue(summary.toolTip?.contains("点一下：重试起不来 / 失败的路") == true, "点主体 = 重试它：\(summary.toolTip ?? "")")
        // 运行表起不来（字符串字面量 = 这一种）：照旧"起不来"、提示照旧
        let startFailed = OutputButtonSummary.stream([streamRoute(3, state: "failed", failure: "推流 3 没有地址")])
        XCTAssertEqual(startFailed.title, "推流 · 起不来")
        XCTAssertTrue(startFailed.toolTip?.contains("点一下：重试起不来的路") == true, startFailed.toolTip ?? "")
        // ▴ 菜单：同字、点 = 单路重试
        let mixer = MixerState(outputs: [OutputState(number: 2, kind: .stream, name: "主平台", enabled: true)])
        let rows = StreamMenuRow.rows(state: mixer, encoder: [Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "failed")]) { $0 == 2 ? stopped : nil }
        XCTAssertEqual(rows.map(\.title), ["主平台 · 失败"])
        XCTAssertEqual(rows.map(\.click), [.retry])
    }

    /// 推流页：状态行写"失败：原因"，红字按原因分两句——鉴权停下的改了设置不会自己重试，写"改对后点「重试」"；起不来的照旧"改好会自动重试"。
    /// 编码详情：重试间隔"一直重试，鉴权失败除外"。
    func testW5P111_streamingPageSplitsFailureHintByCause() {
        let state = MixerState(outputs: [
            OutputState(number: 2, kind: .stream, name: "主平台", enabled: true, settings: OutputSettings(source: .program, stream: StreamSettings(url: "rtmp://127.0.0.1/live"))),
            OutputState(number: 3, kind: .stream, name: "备用", enabled: true, settings: OutputSettings(source: .program, stream: StreamSettings(url: ""))),
            OutputState(number: 4, kind: .stream, name: "关着", enabled: false, settings: OutputSettings(source: .program, stream: StreamSettings(url: ""))),
        ])
        let model = OutputSettingsModel(state: state, tab: .stream, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        model.routeFailure = { n in
            switch n {
            case 2: OutputRouteFailure(reason: "推流 2 不再重连：鉴权失败（用户名或密码不对）", stoppedStream: true)
            case 3: "推流 3 没有地址"
            case 4: "推流 4 没有地址"
            default: nil
            }
        }
        model.refreshRouteDetails()
        XCTAssertEqual(model.streamStatus(output: 2), "失败：推流 2 不再重连：鉴权失败（用户名或密码不对）")
        XCTAssertEqual(model.streamStatus(output: 3), "起不来：推流 3 没有地址")
        XCTAssertEqual(model.streamFailureHint(2), "这一路已停止、不再自己重连（服务器拒绝了鉴权）：改对地址 / 账号后点「重试」，光改设置不会自己重试；也可以先停用这一路。")
        XCTAssertEqual(model.streamFailureHint(3), "改好地址 / 密钥（回车或离开输入框）会自动重试；也可以先停用这一路。")
        XCTAssertNil(model.streamFailureHint(4), "关着的路不写红字")
        XCTAssertFalse(model.isStreamLocked(2), "停住的路照旧不锁：要能改对")
        XCTAssertEqual(L("outputSettings.stream.reconnect", 30.0), "重试间隔最长 30 s（一直重试，鉴权失败除外）")
        XCTAssertEqual(L10n.string("outputSettings.stream.statusStopped", language: "en", "x"), "Failed: x")
        XCTAssertTrue(L10n.string("outputSettings.stream.failedHintStopped", language: "en").contains("click “Retry”"))
        XCTAssertEqual(L10n.string("outputSettings.stream.reconnect", language: "en", 30.0), "Max retry interval 30 s (keeps retrying, except after an authentication failure)")
    }

    // MARK: 112 留下的：当前那组是没选输入的 Stinger

    private var panel: TransitionPanelView { AppTest.controller.windowController.transitionPanel }

    private func uiCommands(_ session: SwitcherSession, since: UInt64) -> [Command] {
        session.control.bus.recentEntries().filter { $0.sequence > since && $0.source == .ui }.map(\.command)
    }

    private func lastSequence(_ session: SwitcherSession) -> UInt64 { session.control.bus.recentEntries().last?.sequence ?? 0 }

    /// PGM 1、PVW 2，当前槽 = 出厂的槽 4（没选输入的 Stinger，"用于 T-bar（不执行）"选上的）。
    private func prepareUnsetStingerCurrent() throws -> SwitcherSession {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.useTransitionSlot(slot: 4, start: false))
        guard AppTest.waitUntil(3, { session.state.program == 1 && session.state.preview == 2 && session.state.transition.currentSlot == 4
            && session.state.transition.currentGroup.isStingerWithoutInput }) else {
            throw XCTSkip("前提没就绪：\(session.state.transition)")
        }
        AppTest.pump(seconds: 0.1)
        return session
    }

    /// 格子"转场"（112 留下的，用户 2026-10-17 定）：当前那组是没选输入的 Stinger → 先弹这个槽的输入选择、整条不发（PVW 也不换）。
    /// 原来发 setPreview + autoTransition，前一条生效、后一条被拒，PVW 换了却没转场。选了输入只改槽，再点才执行。
    func testW5P112_cellTransitionWithUnsetStingerAsksForInputAndSendsNothing() throws {
        let session = try prepareUnsetStingerCurrent()
        let cell = try XCTUnwrap(AppTest.controller.windowController.inputStrip.cells[3])
        XCTAssertTrue(cell.transitionButton.isEnabled, "按钮照样能点（点了是先选输入）")
        XCTAssertTrue(cell.transitionButton.toolTip?.contains("还没选输入") == true, cell.transitionButton.toolTip ?? "nil")
        let since = lastSequence(session)
        _ = AppTest.measurePoppedMenu(open: { cell.transitionButton.performClick(nil) }, menu: { self.panel.activeMenu })
        let menu = try XCTUnwrap(panel.activeMenu, "应弹出槽 4 的输入选择")
        XCTAssertEqual(menu.items.first?.title, "转场 4 · Stinger：先选一路输入（选了才执行）", "\(menu.items.map(\.title))")
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(uiCommands(session, since: since), [], "整条不发：既不换 PVW，也不发 autoTransition")
        XCTAssertEqual(session.state.preview, 2, "PVW 不换")
        XCTAssertEqual(session.state.program, 1)
        XCTAssertFalse(session.state.transition.isActive)
        // 选一路输入：只改槽 4
        menu.performActionForItem(at: menu.index(of: try XCTUnwrap(menu.items.first { $0.title == "输入 3 合成 3" })))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[3].stinger.input == 3 && !session.state.transition.currentGroup.isStingerWithoutInput },
                      "\(session.state.transition)")
        XCTAssertFalse(session.state.transition.isActive, "选了输入不执行")
        AppTest.pump(seconds: 0.1)
        // 再点"转场"：照常 setPreview + autoTransition（Stinger 用输入 3 跑完、3 上 PGM）
        cell.transitionButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(5) { !session.state.transition.isActive && session.state.program == 3 }, "\(session.state.program)")
        XCTAssertEqual(session.control.bus.counters.rejected, 0, "一条都没被拒")
    }

    /// T-bar（112 留下的，用户 2026-10-17 定）：当前槽是没选输入的 Stinger 时推了照契约会硬切，界面拦——T-bar 灰掉、下面写"转场 n 是 Stinger、还没选输入"；
    /// 选了输入 / 换了当前槽就恢复。
    func testW5P112_tbarDisabledWhileCurrentSlotIsUnsetStinger() throws {
        let session = try prepareUnsetStingerCurrent()
        let panel = self.panel
        XCTAssertTrue(AppTest.waitUntil(1) { !panel.tbar.isEnabled }, "T-bar 灰掉")
        XCTAssertFalse(panel.tbarHint.isHidden, "下面有一行提示")
        XCTAssertEqual(panel.tbarHint.stringValue, "转场 4 是 Stinger、还没选输入")
        XCTAssertTrue(panel.tbar.toolTip?.contains("硬切") == true, panel.tbar.toolTip ?? "nil")
        let since = lastSequence(session)
        panel.tbar.simulateDrag(to: 1)
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(uiCommands(session, since: since), [], "灰着的 T-bar 推不动、不发 tbar")
        XCTAssertEqual(session.state.program, 1)
        // 换一个当前槽：恢复
        session.send(.useTransitionSlot(slot: 1, start: false))
        XCTAssertTrue(AppTest.waitUntil(2) { panel.tbar.isEnabled && panel.tbarHint.isHidden }, "当前槽换成 Fade：T-bar 恢复")
        XCTAssertNil(panel.tbar.toolTip)
    }

    // MARK: W4C3 的 S3 一批（reports/issues/W4C3-w5-app-gaps-found-by-docs.md）

    /// 第 1 条：推流 / 录制状态窗"显示日志…"原来打开诊断文件夹，里面只有崩溃 / 卡死记录、没有推流 / 录制日志（那些只在系统日志里）。
    /// 现在把最近 10 分钟本程序的系统日志导出成文本、放进诊断文件夹再打开；提示照实写。第 12 条：英文提示里的菜单名对上"Show Diagnostics Folder"。
    func testW4C3_1_showLogsExportsRecentSystemLog() throws {
        XCTAssertEqual(OutputStatusModel.showLogsTitle, "显示日志…")
        XCTAssertFalse(L("outputStatus.showLogsTip").contains("推流 / 录制的日志在里面"), "不再说诊断文件夹里有推流 / 录制日志")
        XCTAssertTrue(L("outputStatus.showLogsTip").contains("系统日志"), L("outputStatus.showLogsTip"))
        let en = L10n.string("outputStatus.showLogsTip", language: "en")
        XCTAssertFalse(en.contains("Open Diagnostics Folder"), en)
        XCTAssertTrue(en.contains(L10n.string("menu.help.showDiagnosticsFolder", language: "en")), "英文菜单名：\(en)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-w5p-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        NSLog("W5P W4C3-1 导出系统日志用例的标记行")
        let url = try DiagnosticsExport.writeRecentLog(minutes: 1, processes: [ProductName.executable], directory: dir)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path, "放进给的目录（正式 App 是诊断文件夹）")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("log-") && url.pathExtension == "txt", url.lastPathComponent)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# log show --last 1m"), String(text.prefix(200)))
        XCTAssertTrue(text.contains("process == \"\(ProductName.executable)\""), String(text.prefix(200)))
    }

    /// 第 2 条：推流 / 录制状态窗、统计窗、多画面窗口在前时按键照样走快捷键表（X12 同一类：原来只有设置类窗口转发）。
    func testW4C3_2_statusStatsAndMultiviewWindowsForwardHotkeys() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let panels = controller.panels
        defer {
            panels.closeAll()
            if controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
        }
        try controller.applyHotkeyTable(.default)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 && session.state.preview == 2 })
        var expected = (program: 2, preview: 1)
        func pressSpace(_ window: NSWindow?, _ what: String) throws {
            let w = try XCTUnwrap(window, what)
            let handled = session.control.hotkeys.counters.handled
            AppTest.press(" ", in: w)
            XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == expected.program && session.state.preview == expected.preview },
                          "\(what)在前按空格 = Cut：PGM \(session.state.program) PVW \(session.state.preview)")
            XCTAssertEqual(session.control.hotkeys.counters.handled, handled + 1, "\(what)：走的是快捷键表")
            expected = (expected.preview, expected.program)
        }
        try pressSpace(panels.showOutputStatus(.stream)?.window, "推流 / 录制状态窗")
        try pressSpace(panels.showStats().window, "统计窗")
        controller.windowController.toggleMultiviewWindow()
        try pressSpace(controller.windowController.multiviewWindow?.window, "多画面窗口")
    }

    /// 第 3 条：每路输入只装 EQ + 一个动态格（W1-D3 的 InputEffectPlan，peakLimiter 每路不装），输入设置窗的效果页原来照样有"限幅器"一节，
    /// 勾上调参数都存进节目、听不出变化。现在输入设置窗不显示那一节；链里已有的限幅格原样留着、列在"其他效果（原样保留）"里。
    func testW4C3_3_inputEffectsPageHidesLimiterSection() {
        let limiter = AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.02, preGainDb: 3)
        let eq = AudioEffectParams.parametricEQ(centerHz: 1000, q: 1, gainDb: 2)
        let editor = EffectChainEditor(slots: [eq, limiter])
        XCTAssertFalse(InputSettingsView.effectsShowLimiter, "输入设置窗不显示限幅那一节")
        XCTAssertEqual(EffectChainView.sectionTitles(showsLimiter: false), [L("effects.eq.title"), L("effects.dynamics.title"), L("effects.others.title")])
        XCTAssertTrue(EffectChainView.sectionTitles(showsLimiter: true).contains(L("effects.limiter.title")), "总线那边（如果用它）照旧有")
        XCTAssertEqual(EffectChainView.otherSlots(editor, showsLimiter: false), [limiter], "已有的限幅格列进\"其他效果（原样保留）\"")
        XCTAssertEqual(EffectChainView.otherSlots(editor, showsLimiter: true), [], "显示限幅节时它不在\"其他\"里")
        XCTAssertEqual(editor.slots, [eq, limiter], "链原样写回，限幅格不丢")
    }

    /// 第 4 条：几处过时的文案——限幅的延迟提示按总线分开（Master 的效果延迟 G8b 起由画面一起延后来对齐，监听不再晚于画面；Bus A / B 原句）；
    /// "切上 PGM 时从头播"首帧晚约 3 拍（W5-N 实测，不是 1–2 拍）。
    func testW4C3_4_limiterLatencyHintPerBusAndFirstFrameThreeTicks() {
        let state = MixerState()
        let master = AudioSettingsModel(strip: .bus(.master), state: state, page: .limiter)
        let busA = AudioSettingsModel(strip: .bus(.busA), state: state, page: .limiter)
        XCTAssertTrue(master.limiterLatencyHint.contains("画面跟着一起延后"), master.limiterLatencyHint)
        XCTAssertFalse(master.limiterLatencyHint.contains("耳机 / 扬声器监听会晚这么多"), "Master 的监听不再晚于画面")
        XCTAssertTrue(busA.limiterLatencyHint.contains("耳机 / 扬声器监听会晚这么多"), "Bus A / B 保留原句：\(busA.limiterLatencyHint)")
        for key in ["cell.menu.restartOnProgram.tip", "inputSettings.playback.hint"] {
            XCTAssertTrue(L(key).contains("约 3 拍"), "\(key)：\(L(key))")
            XCTAssertFalse(L(key).contains("1–2 拍"), key)
            let en = L10n.string(key, language: "en")
            XCTAssertTrue(en.contains("about 3 ticks"), "\(key) en：\(en)")
            XCTAssertFalse(en.contains("1–2 ticks"), key)
        }
    }

    /// 第 12 条：只有英文错的三处——Stinger 选输入菜单的段标题（选了只改槽、要再点一次才执行）、诊断文件夹的菜单名（第 1 条的用例里查）、
    /// 文件来源"就地改"提示里的两个字段名对上表单（"At end" / "Playback rate"）。
    func testW4C3_12_englishCopyMatchesUI() {
        let header = L10n.string("slot.stingerMenu.header", language: "en", 4)
        XCTAssertFalse(header.contains("runs once chosen"), header)
        XCTAssertTrue(header.contains("then click again to run it"), header)
        let hint = L10n.string("inputSettings.source.fileInPlaceHint", language: "en")
        XCTAssertTrue(hint.contains("“\(L10n.string("addInput.file.endAction", language: "en"))”"), hint)
        XCTAssertTrue(hint.contains("“\(L10n.string("addInput.file.rate", language: "en"))”"), hint)
        XCTAssertFalse(hint.contains("“Speed”"), hint)
    }

    /// 第 5 条：输入设置窗"播放"一节的按钮与格子同一口径——播完（不循环、跑着的那个已经无信号）= "▶ 播放"、点了从头播（seekPlayback 0）；
    /// 原来只看 paused，播完时仍写"⏸ 暂停"、点了发 setPlayback(true)，再点"▶ 播放"也只是取消暂停、画面不动。
    func testW4C3_5_settingsPlayButtonKnowsPlaybackEnded() {
        var runtime: InputState? = .live
        func model(endAction: FileEndAction, paused: Bool = false) -> (InputSettingsModel, () -> [Command]) {
            var config = InputConfig(number: 3, name: "片子", source: .file(path: "/tmp/w5p.mov", endAction: endAction, rate: 1))
            config.settings.playback.paused = paused
            let m = InputSettingsModel(config: config)
            var sent: [Command] = []
            m.send = { sent.append($0) }
            m.runtimeState = { runtime }
            m.refreshRuntime()
            return (m, { sent })
        }
        let play = L("inputSettings.playback.play"), pause = L("inputSettings.playback.pause")
        // 播着：⏸ 暂停 → setPlayback(true)
        var (m, sent) = model(endAction: .holdLastFrame)
        XCTAssertEqual(m.playButtonTitle, pause)
        m.togglePaused()
        XCTAssertEqual(sent(), [.setPlayback(input: 3, paused: true)])
        // 播完了（不循环、无信号）：▶ 播放 → 从头播
        runtime = .noSignal
        (m, sent) = model(endAction: .holdLastFrame)
        XCTAssertEqual(m.playButtonTitle, play, "播完 = ▶，同格子")
        m.togglePaused()
        XCTAssertEqual(sent(), [.seekPlayback(input: 3, seconds: 0)], "播完点 ▶ = 从头播")
        // 循环的不会"播完"：无信号也照旧按暂停翻
        (m, sent) = model(endAction: .loop)
        XCTAssertEqual(m.playButtonTitle, pause)
        // 暂停中：▶ 播放 → 取消暂停
        runtime = .live
        (m, sent) = model(endAction: .holdLastFrame, paused: true)
        XCTAssertEqual(m.playButtonTitle, play)
        m.togglePaused()
        XCTAssertEqual(sent(), [.setPlayback(input: 3, paused: false)])
    }

    /// 第 6 条：英文界面转场列 T-bar 那一行出厂就截尾（"Transition 1 · Fade 0.5…"，这一行 134 pt）。英文写短"T1 · Fade 0.5 s ▾"，
    /// 中文照旧"转场 1 · Fade 0.5 秒 ▾"（121–133 pt 放得下）；悬停提示 / 辅助功能标签照旧写全。
    func testW4C3_6_englishTbarRowFitsWithoutTruncation() throws {
        let session = try AppTest.freshSession()
        let panel = self.panel
        defer {
            L10n.languageOverride = "zh-Hans"
            panel.apply(state: session.state)
        }
        let row = Theme.transitionColumnWidth - 16
        for (language, first) in [("zh-Hans", "转场 1 · Fade 0.5 秒 ▾"), ("en", "T1 · Fade 0.5 s ▾")] {
            L10n.languageOverride = language
            for n in TransitionSlot.indexRange {
                var state = session.state
                state.transition.currentSlot = n
                let slot = state.transition.slots[n - 1]
                state.transition.type = slot.type
                state.transition.durationTicks = slot.durationTicks
                state.transition.wipe = slot.wipe
                state.transition.stinger = slot.stinger
                panel.apply(state: state)
                let title = panel.tbarSlotButton.title
                if n == 1 { XCTAssertEqual(title, first, language) }
                let width = panel.tbarSlotButton.intrinsicContentSize.width
                print("W5P W4C3-6 \(language) 槽 \(n)：「\(title)」\(String(format: "%.1f", width)) pt / 行 \(row) pt")
                XCTAssertLessThanOrEqual(width, row, "\(language) 槽 \(n)「\(title)」放得下")
                XCTAssertTrue(panel.tbarSlotButton.accessibilityLabel()?.contains(language == "en" ? "Transition \(n)" : "转场 \(n)") == true,
                              "辅助功能标签写全：\(panel.tbarSlotButton.accessibilityLabel() ?? "nil")")
            }
        }
    }

    /// 状态行（W4C3 第 11 条）：failed 的推流不算在跑——原来取码率最低的那一路，起不来 / 鉴权停下的码率 0，写"推流 0 b/s"；状态窗写 —，两处不一致。
    func testW5P111_statusLineIgnoresFailedStreams() {
        func stats(_ entries: [Stats.EncoderEntry]) -> Stats {
            Stats(ts: 10, tick: Tick(600), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: entries,
                  audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 1)
        }
        let kinds: [Int: OutputKind] = [1: .record, 2: .stream, 3: .stream]
        let onlyFailed = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "failed")]),
                                                    previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(onlyFailed.first { $0.label == L("status.streamBitrate") }?.value, "—", "只有失败的那一路：推流码率写 —")
        let mixed = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "failed"),
                                                               Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 4_500_000, state: "publishing")]),
                                               previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(mixed.first { $0.label == L("status.streamBitrate") }?.value, "4.50 Mb/s", "失败的那一路不拖低在推的")
        let backoff = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "backoff")]),
                                                 previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(backoff.first { $0.label == L("status.streamBitrate") }?.value, "0 b/s", "退避中的照旧算在跑（X28）")
    }
}
