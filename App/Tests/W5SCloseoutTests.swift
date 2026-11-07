// W5-S（prompt 139）App 收口三：133 / 132 / 129 攒下、G12 定级分派的几条 + G12 §7.1 用户 2026-11-07 定的两条。
// W2A6 NDI 发送（源 = 输入 n）：那一路换来源时新来源的音频注册撞上旧槽淡出、走了 30 ms 延后重试，重试成功之后这路 NDI 再没挂上音频
//      （问题单 W2A6-app-ndi-send-input-audio-lost-after-register-retry；Codex testNDI_SourceReplacementMustRestoreAudioAfterRegistrationRetry 搬来改名，
//      被换的输入改成 stop() 快的纯音频合成源——两路都是合成 PCM，旧的 stop() 比淡出快，才进得了重试窗口）；
// W2D5 底栏推流 ▴ 菜单项的悬停提示：密钥栏空着、密钥写在地址末段时也要遮（看同层 streamKey 传 publishNameInPath，与 ShowRedaction 同口径）；
// P57 选动作面板：叠加命令的输入下拉加"（清空）"= 0（命令目录不动）；秒数框填 1e30 不在 Double → Int 上 trap，钳到 DurationLimits.maxTicks 对应的秒数；
// G12 §7.1 第 6 条：NDI 发送在跑中翻 failed 时状态行提示一句，同一路 60 s 内只提示一次；第 5 条：统计窗"音频"一节列效果链延迟（只读 Stats audio.effects）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherAudio
import SwitcherControl
import SwitcherEngine
import SwitcherInputs
import SwitcherNDISend
import SwitcherTestKit
@testable import Switcher

/// 纯音频输入的替身：合成 PCM 写进 CAudioRing，没有画面（同 AudioDeviceInput），不要麦克风权限。
/// 不用 TestKit 的 SyntheticAudioInput：它的 stop() 要等实时线程睡到下一块的到点时刻，本会话实测 140 ms，比混音器摘除淡出
/// （removalFadeBlocks × 256 帧 ≈ 16 ms）慢得多，旧槽早摘掉了、新来源当场注册上，进不了问题单那个重试窗口（Codex 探针 registerRetries = 0 也是这个原因）。
/// 这个替身 stop() 只 cancel 定时器、立即返回（像设备 / 文件输入那样快），换源时新来源的注册必撞 inputAlreadyRegistered、走延后重试。
private struct W5SAudioOnlyFactory: InputFactory {
    func makeInput(config: InputConfig, slot: any FrameSlot, timing: ProgramTiming) throws -> MadeInput {
        guard case .audio = config.source else {
            return try DefaultInputFactory().makeInput(config: config, slot: slot, timing: timing)
        }
        let source = W5SFastStopAudioInput(number: config.number, name: config.name)
        return MadeInput(input: source, audioRing: source.ring, audioBlockFrames: W5SFastStopAudioInput.blockFrames)
    }
}

/// stop() 立即返回的纯音频合成源：DispatchSourceTimer 每块（256 帧 ≈ 5.3 ms）醒一次，按 start 那一刻起的样本数把落后的块补写进环，
/// host time = 起点 + 样本数 / 48 kHz（入口打戳，铁律 5）。stop() 只 cancel 定时器、不等在途的那一次回调——它写的是旧环（换源后混音器不再读），无害。
private final class W5SFastStopAudioInput: Input, @unchecked Sendable {
    static let blockFrames = 256
    let number: Int
    let name: String
    let kind: InputKind = .audio
    let ring = CAudioRing(channelCount: 2)
    private let queue = DispatchQueue(label: "w5s-fast-stop-audio", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// 已写的样本数（只在 queue 上动）。
    private var written: Int64 = 0

    init(number: Int, name: String) {
        self.number = number
        self.name = name
    }

    var state: InputState { lock.withLock { timer == nil ? .noSignal : .live } }
    var videoSlot: (any FrameSlot)? { nil }
    var audioRing: (any AudioRing)? { ring }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let frames = Self.blockFrames
        let start = HostClock.now()
        queue.sync { written = 0 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(Double(frames) * 1e9 / Double(AudioFormat.sampleRate))), leeway: .microseconds(500))
        t.setEventHandler { [self] in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buffer.initialize(repeating: 0.25, count: frames)
            let planes = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
            planes[0] = UnsafePointer(buffer)
            planes[1] = UnsafePointer(buffer)
            defer { planes.deallocate(); buffer.deallocate() }
            let now = HostClock.now()
            while start + HostDuration(seconds: Double(written + Int64(frames)) / Double(AudioFormat.sampleRate)) <= now {
                let stamp = start + HostDuration(seconds: Double(written) / Double(AudioFormat.sampleRate))
                _ = ring.write(planes: UnsafePointer(planes), frameCount: frames, hostTime: stamp)
                written += Int64(frames)
            }
        }
        timer = t
        t.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}

@MainActor
final class W5SCloseoutTests: XCTestCase {
    /// 自己起的 session 用的设置：不出声、不起 API / 兼容层 / tally、不防睡眠（不碰宿主那一个）。
    private static func isolatedSettings() -> AppSettings {
        var s = AppSettings()
        s.audioDevice = .null
        s.apiEnabled = false
        s.compatLayerEnabled = false
        s.tallyEnabled = false
        s.preventSleepWhileRunning = false
        s.preventDisplaySleepWhileRunning = false
        return s
    }

    private func startSession(_ show: Show, factory: any InputFactory) throws -> SwitcherSession {
        let session = try SwitcherSession(show: show, settings: Self.isolatedSettings(), inputFactory: factory,
                                          hotkeyTable: .init(bindings: []), midiTable: .init(mappings: []))
        final class StartOutcome { var done = false; var error: (any Error)? }
        let started = StartOutcome()
        Task {
            do { try await session.start() } catch { started.error = error }
            started.done = true
        }
        XCTAssertTrue(AppTest.waitUntil(20) { started.done }, "session 起得来")
        if let error = started.error { throw error }
        return session
    }

    private func stopSession(_ session: SwitcherSession) {
        let stopped = AppTest.expectationBox()
        Task { await session.stop(); stopped.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { stopped.value }, "session 收得掉")
    }

    // MARK: W2A6 NDI 发送换源撞注册重试

    /// W2A6（S1，问题单代码链 1–4）：源是输入 1 的 NDI 发送在跑、带着输入 1 的音频；输入 1 换来源（纯音频合成源 → 另一个纯音频合成源）——
    /// 新来源的注册撞上旧槽还在淡出、30 ms 后重试；运行表这时已经摘下重挂了这路 NDI（registeredInputs 里没有 1 → 没建音频挂件）。
    /// 修前：重试成功后 followInputAudioSlots 只遍历已有挂件，这路 NDI 的 audio 一直是 nil、音频块不再涨（要关开这路输出才回来）。
    func testW2A6_ndiSendRestoresAudioAfterSourceReplacementHitsRegisterRetry() throws {
        _ = try AppTest.runningSession()   // 别跟宿主起它自己那个 session 抢
        var show = ShowDocuments.emptyShow(name: "w5s-ndi-audio-retry")
        show.mixer.format = ProgramFormat(width: 320, height: 240, frameRate: .fps30)
        show.inputs = [InputConfig(number: 1, name: "话筒 A", source: .audio(deviceUID: "w5s-synthetic-a"))]
        show.outputs = []
        let session = try startSession(show, factory: W5SAudioOnlyFactory())
        defer { stopSession(session) }
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.runtimeState(of: 1) == .live && session.audio.registeredInputs.contains(1) })

        let number = 2
        session.send(.addOutput(config: OutputState(number: number, kind: .ndi, name: "PlusMix W5S \(UUID().uuidString.prefix(8))", enabled: true,
                                                   settings: OutputSettings(source: .input(number: 1)))))
        XCTAssertTrue(AppTest.waitUntil(8) { session.outputs.ndiSenders[number]?.phase == .running && session.outputs.ndiSenders[number]?.audio?.token != nil },
                      "NDI 发送起来、挂着输入 1 的音频：\(String(describing: session.outputs.failed[number]))")
        let entry = try XCTUnwrap(session.outputs.ndiSenders[number])
        // 没有 SDK 时 sender 是空实现（不发、不计音频块）：挂件这半照测，音频块那半只在真发的时候测
        let sends = !entry.sender.countersSnapshot.unavailable
        if sends {
            XCTAssertTrue(AppTest.waitUntil(3) { entry.sender.countersSnapshot.audioBlocksSent > 20 }, "换源前在发音频块")
        }

        let retriesBefore = session.audio.registerRetries
        let old = try XCTUnwrap(session.inputs.entries[1]?.input)
        session.send(.setInputSource(input: 1, source: .audio(deviceUID: "w5s-synthetic-b")))
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.entries[1]?.input !== old && session.audio.registeredInputs.contains(1) }, "新来源注册上")
        XCTAssertGreaterThan(session.audio.registerRetries, retriesBefore, "真进了注册重试窗口（旧来源 stop() 比淡出快）——没进的话这条测不到问题单那条链")
        XCTAssertTrue(session.outputs.ndiSenders[number] === entry, "换源不重建 sender")
        XCTAssertTrue(AppTest.waitUntil(2) { entry.audio?.token != nil },
                      "重试成功后这路 NDI 要重新挂上输入 1 的音频：audio=\(String(describing: entry.audio)) token=\(String(describing: entry.audio?.token))")
        if case .input(let n)? = entry.audio?.source { XCTAssertEqual(n, 1) } else { XCTFail("挂的是输入 1：\(String(describing: entry.audio?.source))") }
        if sends {
            AppTest.pump(seconds: 0.3)
            let first = entry.sender.countersSnapshot.audioBlocksSent
            AppTest.pump(seconds: 1)
            let second = entry.sender.countersSnapshot.audioBlocksSent
            print("W5S W2A6：registerRetries +\(session.audio.registerRetries - retriesBefore)，音频块 \(first) → \(second)")
            XCTAssertGreaterThan(second, first + 20, "换源后音频块接着涨")
        }

        session.send(.setOutputEnabled(output: number, on: false))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.ndiSenders[number] == nil })
    }

    // MARK: W2D5 底栏推流 ▴ 菜单 / 悬停的路径密钥

    private static func streamOutput(_ number: Int, _ name: String, url: String, key: String) -> OutputState {
        OutputState(number: number, kind: .stream, name: name, enabled: false,
                    settings: OutputSettings(stream: StreamSettings(url: url, streamKey: key)))
    }

    /// W2D5（S2，reports/w2-stream-5.md §3 第 4 条）：推流 ▴ 菜单每一项的悬停提示写着地址——密钥栏空（只有空白也算）、密钥写在 RTMP 地址末段时
    /// 末段换成标记（ShowRedaction 同口径：看同层 streamKey）；密钥栏非空的那一路地址末段是应用名 / 子路径，照原样。
    func testW2D5_streamMenuTooltipHidesPathKeyWhenKeyFieldEmpty() throws {
        let state = MixerState(outputs: [
            Self.streamOutput(2, "整条地址", url: "rtmp://h/live/KEYW5S2", key: ""),
            Self.streamOutput(3, "空白密钥栏", url: "rtmps://h:443/app/KEYW5S3", key: "  "),
            Self.streamOutput(4, "分开填", url: "rtmp://h/live/sub", key: "SECRETW5S4"),
            Self.streamOutput(5, "带账号", url: "rtmp://u:PASSW5S5@h/live/KEYW5S5", key: ""),
        ])
        let rows = StreamMenuRow.rows(state: state, encoder: [], failure: { _ in nil })
        let tips = rows.map { $0.toolTip ?? "" }
        print("W5S W2D5 提示：\(tips)")
        for secret in ["KEYW5S2", "KEYW5S3", "SECRETW5S4", "PASSW5S5", "KEYW5S5"] {
            XCTAssertFalse(tips.joined(separator: "\n").contains(secret), "悬停提示里不该有 \(secret)")
        }
        XCTAssertTrue(tips[0].contains("rtmp://h/live/<redacted>"), tips[0])
        XCTAssertTrue(tips[1].contains("rtmps://h:443/app/<redacted>"), tips[1])
        XCTAssertTrue(tips[2].contains("rtmp://h/live/sub"), "密钥栏非空：末段是子路径，照原样：\(tips[2])")
        XCTAssertTrue(tips[3].contains("/live/<redacted>"), tips[3])

        // 真的 ▴ 菜单（菜单栏"输出 › 推流 ▸"也是它）：项的 toolTip 就是上面那几行
        let session = try AppTest.freshSession()
        for o in state.outputs { session.send(.addOutput(config: o)) }
        let bar = AppTest.controller.windowController.bottomBar
        XCTAssertTrue(AppTest.waitUntil(3) { bar.streamMenu().items.compactMap(\.toolTip).count >= 4 }, "四个目的地都在菜单里")
        let menuTips = bar.streamMenu().items.compactMap(\.toolTip).joined(separator: "\n")
        for secret in ["KEYW5S2", "KEYW5S3", "SECRETW5S4", "PASSW5S5", "KEYW5S5"] {
            XCTAssertFalse(menuTips.contains(secret), "▴ 菜单项悬停不该有 \(secret)")
        }
        XCTAssertTrue(menuTips.contains("rtmp://h/live/sub"))
    }

    // MARK: P57 选动作面板

    private func picker(current: ControlAction? = nil, state: @escaping () -> MixerState?) -> ActionPickerModel {
        ActionPickerModel(context: .hotkey, current: current, state: state, defaults: AppTest.controller.defaults)
    }

    /// P57（reports/p5-contracts-7.md §3 第 2 条，G12 §7.1 第 11 条）：叠加命令（overlay）的输入在命令目录里是 input(allowsBlack: false)、可选——
    /// 面板原来只有"不换输入"和各路输入，选不到 0（034 ⑤：input 0 = 清空这个通道的输入）。面板自己加"（清空）"= 0，目录不动；
    /// 一句话摘要写"清空"、不写"黑场"；别的 allowsBlack: false 的输入下拉（setInputAudio）不加，setPreview 照旧是"黑场"。
    func testP57_overlayCommandPickerOffersClearOption() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let p = picker { session.state }
        p.select("command.overlay")
        let field = try XCTUnwrap(p.selected?.fields.first { $0.name == "input" })
        XCTAssertEqual(field.type, .input(allowsBlack: false), "命令目录不动")
        let choices = p.inputChoices(for: field)
        XCTAssertEqual(Array(choices.prefix(2)).map(\.title), ["不换输入", "（清空）"])
        XCTAssertEqual(Array(choices.prefix(2)).map(\.value), [nil, .number(0)])
        XCTAssertEqual(choices.dropFirst(2).map(\.value), session.state.inputs.map { .number($0.number) })
        p.set("input", .input(.number(0)))
        XCTAssertEqual(p.builtAction, .command(.overlay(channel: 1, on: true, input: 0)), "（清空）= input 0")
        let built = try XCTUnwrap(p.builtAction)
        let summary = ActionText.summary(built, state: session.state)
        XCTAssertTrue(summary.contains("清空") && !summary.contains("黑场"), summary)
        // 存下的动作打开时定位回"（清空）"，原样拼回
        let located = picker(current: .command(.overlay(channel: 2, on: false, input: 0))) { session.state }
        XCTAssertEqual(located.values["input"], .input(.number(0)))
        XCTAssertEqual(located.builtAction, .command(.overlay(channel: 2, on: false, input: 0)))
        // 别的输入下拉不受影响
        p.select("command.setInputAudio")
        let audioField = try XCTUnwrap(p.selected?.fields.first { $0.name == "input" })
        XCTAssertFalse(p.inputChoices(for: audioField).contains { $0.value == .number(0) }, "setInputAudio 没有 0")
        p.select("command.setPreview")
        let previewField = try XCTUnwrap(p.selected?.fields.first { $0.name == "input" })
        XCTAssertEqual(p.inputChoices(for: previewField).first?.title, "黑场")
        XCTAssertFalse(p.inputChoices(for: previewField).contains { $0.title == "（清空）" })
    }

    /// P57（reports/p5-contracts-7.md §3 第 3 条）：秒数显示 `String(Int(rounded))` 与拼动作时的 `Int((秒 × 帧率).rounded())` 对 1e30 秒会 Double → Int 溢出 trap。
    /// 显示：任何 Double 都不 trap（Int 装不下的按 %g 写）；拼动作：时长格钳到 DurationLimits.maxTicks 对应的秒数（同 OverlaySettingsModel.ticks(seconds:)）。
    func testP57_actionTextSecondsAndBuildDoNotTrapOnHugeSeconds() throws {
        XCTAssertEqual(ActionText.seconds(0.5), "0.5 秒")
        XCTAssertEqual(ActionText.seconds(14_400), "14400 秒")
        XCTAssertEqual(ActionText.seconds(1e30), "1e+30 秒", "显示不 trap")
        XCTAssertEqual(ActionText.seconds(.infinity), "inf 秒")
        // 存下来的定位动作（热键表 JSON 里手写的 1e30）：摘要不 trap
        XCTAssertTrue(ActionText.summary(.command(.seekPlayback(input: 1, seconds: 1e30))).contains("1e+30"))

        // 拼动作：durationTicks / durationMs 格里塞着 1e30（表单之外进来的值）照样不 trap，钳到上限
        let rate = FrameRate.fps60
        let entries = ActionCatalog.entries(for: .hotkey)
        let ticksEntry = try XCTUnwrap(entries.first { e in !e.advanced && !e.legacy && e.fields.contains { $0.type == .durationTicks } }, "有按拍的时长格")
        var values = ActionCatalog.defaults(for: ticksEntry, state: nil)
        let ticksField = try XCTUnwrap(ticksEntry.fields.first { $0.type == .durationTicks })
        values[ticksField.name] = .seconds(1e30)
        let builtTicks = try XCTUnwrap(ActionCatalog.build(ticksEntry, values: values, frameRate: rate), ticksEntry.id)
        XCTAssertTrue(CommandText.summary(try XCTUnwrap(Self.command(builtTicks))).contains("\(DurationLimits.maxTicks)"), "\(builtTicks)")
        let msEntry = try XCTUnwrap(entries.first { $0.id == "action.fadeMs" })
        XCTAssertEqual(ActionCatalog.build(msEntry, values: ["durationMs": .seconds(1e30)], frameRate: rate), .fadeMs(durationMs: 3_600_000),
                       "毫秒格钳到 1 小时（maxTicks @ 240 fps，任何合法帧率下换出来都 ≤ maxTicks）")
    }

    /// P57：表单里的秒数框（DurationField 的绑定走 setSeconds）填 1e30——按格的类型钳：按拍的到 maxTicks ÷ 帧率、毫秒的到 1 小时、定位秒数到 PlaybackLimits.maxSeekSeconds；
    /// 负数 / NaN → 0。框里随即显示钳后的值，摘要与预览都不 trap。
    func testP57_actionPickerSecondsFieldClampsHugeValue() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let rate = session.state.format.frameRate.framesPerSecond.doubleValue
        let p = picker { session.state }
        let entries = ActionCatalog.entries(for: .hotkey)
        let ticksEntry = try XCTUnwrap(entries.first { e in !e.advanced && !e.legacy && e.fields.contains { $0.type == .durationTicks } })
        let ticksField = try XCTUnwrap(ticksEntry.fields.first { $0.type == .durationTicks })
        p.select(ticksEntry.id)
        p.setSeconds(ticksField.name, 1e30)
        XCTAssertEqual(p.values[ticksField.name], .seconds(Double(DurationLimits.maxTicks) / rate), "按拍的格钳到 maxTicks ÷ 帧率")
        XCTAssertNotNil(p.builtAction)
        XCTAssertFalse(p.preview.isEmpty)
        p.setSeconds(ticksField.name, -3)
        XCTAssertEqual(p.values[ticksField.name], .seconds(0))
        p.setSeconds(ticksField.name, .nan)
        XCTAssertEqual(p.values[ticksField.name], .seconds(0))
        p.setSeconds(ticksField.name, 2.5)
        XCTAssertEqual(p.values[ticksField.name], .seconds(2.5), "范围里的照常")

        p.select("action.fadeMs")
        p.setSeconds("durationMs", 1e30)
        XCTAssertEqual(p.values["durationMs"], .seconds(3_600))
        XCTAssertEqual(p.builtAction, .fadeMs(durationMs: 3_600_000))

        p.select("command.seekPlayback")
        p.setSeconds("seconds", 1e30)
        XCTAssertEqual(p.values["seconds"], .seconds(PlaybackLimits.maxSeekSeconds))
        XCTAssertNotNil(p.builtAction)
    }

    private static func command(_ action: ControlAction) -> Command? {
        if case .command(let c) = action { return c }
        return nil
    }

    // MARK: G12 §7.1 第 6 条：NDI 在跑中翻 failed 时状态行提示

    /// 纯逻辑：上一行不是 failed、这一行是 failed 才算"翻"；同一路 60 s 内只提示一次；各路分开；停了再起是新的一次。
    func testG12_6_ndiFailingNoticeOncePer60Seconds() {
        var n = NDIFailingNotices()
        XCTAssertFalse(n.note(output: 2, state: "publishing", now: 0))
        XCTAssertTrue(n.note(output: 2, state: "failed", now: 1), "publishing → failed：提示")
        XCTAssertFalse(n.note(output: 2, state: "failed", now: 2), "还是 failed：不再提示")
        XCTAssertFalse(n.note(output: 2, state: "publishing", now: 3))
        XCTAssertFalse(n.note(output: 2, state: "failed", now: 30), "60 s 内又翻：不提示")
        XCTAssertFalse(n.note(output: 2, state: "publishing", now: 40))
        XCTAssertTrue(n.note(output: 3, state: "failed", now: 41), "别的路各算各的（第一行就是 failed 也算翻）")
        XCTAssertTrue(n.note(output: 2, state: "failed", now: 61.5), "离上次提示 ≥ 60 s：再提示")
        n.forget(output: 3)
        XCTAssertTrue(n.note(output: 3, state: "failed", now: 50), "停了再起：新的一次")
        XCTAssertFalse(n.note(output: 4, state: "idle", now: 0))
        XCTAssertFalse(n.note(output: 4, state: nil, now: 1))
    }

    /// 接线：在跑的 NDI 发送，Stats.encoder 里它那一项翻成 failed（D08：连续送不出去）→ 状态行"NDI 发送 n 出错：<last_error>"一次；
    /// 来回翻不刷屏；过了 60 s 再翻再提示。Stats 行是喂进 noteStats 的（真 sender 不会自己翻），时钟用替身。
    func testG12_6_ndiFailingWhileRunningShowsStatusNoticeThrottled() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let page = AppTest.controller.panels.showOutputSettings(tab: .ndi).model
        defer { AppTest.controller.panels.closeAll() }
        let number = page.addNDI(name: "PlusMix W5S 翻 failed \(UUID().uuidString.prefix(6))", groups: "", conversion: "auto", source: .program)
        defer {
            page.removeOutput(number)
            _ = AppTest.waitUntil(5) { session.outputs.ndiSenders[number] == nil }
        }
        XCTAssertTrue(AppTest.waitUntil(8) { session.outputs.ndiSenders[number]?.phase == .running }, "\(String(describing: session.outputs.failed[number]))")
        final class Clock { var now: TimeInterval = 1000 }
        let clock = Clock()
        session.outputs.noticeUptime = { clock.now }
        defer { session.outputs.noticeUptime = { ProcessInfo.processInfo.systemUptime } }
        var notices: [String] = []
        let token = session.observeNotices { notices.append($0) }
        defer { token.invalidate() }
        func row(_ state: String, _ error: String = "") -> Stats {
            Stats(ts: 1, tick: Tick(60), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:],
                  encoder: [Stats.EncoderEntry(output: number, skipped: 0, bitrate: 0, state: state, lastError: error)],
                  audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 1)
        }
        func failing() -> [String] { notices.filter { $0.contains("NDI 发送 \(number) 出错") } }
        session.outputs.noteStats(row("publishing"))
        session.outputs.noteStats(row("failed", "连续 30 帧没送出：像素格式 w5s"))
        XCTAssertEqual(failing(), ["NDI 发送 \(number) 出错：连续 30 帧没送出：像素格式 w5s"])
        clock.now += 10
        session.outputs.noteStats(row("publishing"))
        session.outputs.noteStats(row("failed", "连续 30 帧没送出：像素格式 w5s"))
        XCTAssertEqual(failing().count, 1, "60 s 内来回翻不刷屏：\(notices)")
        clock.now += 51
        session.outputs.noteStats(row("publishing"))
        session.outputs.noteStats(row("failed"))
        XCTAssertEqual(failing().count, 2, "过了 60 s 再翻再提示：\(notices)")
        XCTAssertEqual(failing().last, "NDI 发送 \(number) 出错（原因见输出设置的 NDI 页）", "没有 last_error 时的那一句")
        XCTAssertEqual(L10n.string("notice.ndiSendFailing", language: "en"), "NDI output %d error: %@")
    }

    // MARK: G12 §7.1 第 5 条：统计窗列效果链延迟

    /// 统计窗"音频"一节多一张效果链延迟表：总线按 Stats 列的顺序、输入按编号（名字从快照对号，删了的写"已删"），延迟一位小数、压缩器实测两位；
    /// 数原样来自 Stats.audio.effects（铁律 4），瞬时值、不受"重置"影响。
    func testG12_5_statsWindowListsEffectChainLatency() {
        var state = MixerState()
        state.inputs = [InputConfig(number: 2, name: "机位", source: .synthetic(settings: SyntheticSourceSettings()))]
        let effects = Stats.AudioCounters.EffectsLatency(
            buses: [.init(bus: "master", latencyMs: 0), .init(bus: "busA", latencyMs: 5.333, measuredLatencyMs: 5.3125),
                    .init(bus: "busB", latencyMs: 0), .init(bus: "headphones", latencyMs: 1.5)],
            inputs: [7: .init(latencyMs: 2.04), 2: .init(latencyMs: 1.33, measuredLatencyMs: 0)])
        let stats = Stats(ts: 1, tick: Tick(60), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                          audio: Stats.AudioCounters(dropouts: 0, underruns: 0, effects: effects), rssMb: 1, cpuPct: 1, gpuPct: 1)
        let model = StatsWindowModel()
        model.apply(stats: stats, state: state)
        XCTAssertEqual(model.effectRows.map(\.name), ["Master", "Bus A", "Bus B", "耳机", "输入 2 · 机位", "输入 7（已删）"])
        XCTAssertEqual(model.effectRows.map(\.latencyText), ["0.0 ms", "5.3 ms", "0.0 ms", "1.5 ms", "1.3 ms", "2.0 ms"])
        XCTAssertEqual(model.effectRows.map(\.measuredText), ["—", "5.31 ms", "—", "—", "0.00 ms", "—"])
        model.reset()
        XCTAssertEqual(model.effectRows.count, 6, "瞬时值：重置不动它")
        // 没有效果链数据（老 Stats / 引擎没起）：空表
        model.apply(stats: Stats(ts: 2, tick: Tick(120), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                                 audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 1), state: state)
        XCTAssertTrue(model.effectRows.isEmpty)
        XCTAssertEqual(L10n.string("statsWindow.effects.title", language: "en"), "Effect chain latency")
    }
}
