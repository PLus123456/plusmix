// W5-Q（prompt 126）App 收口：
// W5Q1 打开含越界播放速率的老节目时按界面口径提示"速率 x 超出 0.1–8"、不静默（裁定 #2 (c) 剩下的一半；数字框钳位 G10 胶水已做）——打开 / 打开上次退出时的节目 / 启动恢复三条路；
// W5Q2 "添加输入"的文件信息对竖拍写转正后的尺寸（与 FileInfo.displayWidth / displayHeight 同口径），编码尺寸放括号里（117 §3）；
// D06 两个边角（119 §3）：录着 ISO 删掉这一路再加同编号（录制器停在删除那一拍、提示一句、新的一路不接旧录制器）；换源瞬间别的路注册抢走了这一路原来的
// 混音器槽位（ISO 音轨跟着这一路的编号走，不录到抢槽位的那一路）；
// 030 的界面展示：音频设置窗（常规页的效果链延迟、压缩页"延迟自测"）与推流 / 录制状态窗读 Stats 的 audio.effects（铁律 4：不再读 AudioEngineStatus）。
import AppKit
import AVFoundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherISO
import SwitcherInputs
import SwitcherAudio
@testable import Switcher

@MainActor
final class W5QCloseoutTests: XCTestCase {
    private func temporaryDirectory(_ tag: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-w5q-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: W5Q1 老节目的越界速率

    /// 两路越界速率的老节目：031 之前 App 的速率框不设范围，10 / 0.05 都写得进节目文件（Show.save 不校验）；契约现在拒收这份。
    private func writeOldShow(to url: URL) throws {
        var show = ShowDocuments.emptyShow(name: "旧节目", recordDirectory: url.deletingLastPathComponent().path)
        show.inputs = [InputConfig(number: 3, name: "片头", source: .file(path: "intro.mov", endAction: .loop, rate: 10)),
                       InputConfig(number: 5, name: "慢放", source: .file(path: "slow.mov", endAction: .holdLastFrame, rate: 0.05))]
        try ShowStore().save(show, to: url)
        XCTAssertThrowsError(try ShowStore().load(from: url), "契约拒收（提案 031）：这份节目原样打不开")
    }

    /// 提示按界面口径写清哪一路、速率多少、范围多少（两路都列出来，一次改完），不是 Swift 枚举原样。
    private func assertRateMessage(_ message: String?, file: StaticString = #filePath, line: UInt = #line) {
        let m = message ?? "（没有提示）"
        XCTAssertTrue(m.contains("输入 3"), "说是哪一路：\(m)", file: file, line: line)
        XCTAssertTrue(m.contains("速率 10 超出 0.1–8"), "界面口径的速率与范围：\(m)", file: file, line: line)
        XCTAssertTrue(m.contains("输入 5") && m.contains("速率 0.05 超出 0.1–8"), "越界的几路都列出来：\(m)", file: file, line: line)
        XCTAssertFalse(m.contains("fileRate("), "不是 Swift 枚举原样：\(m)", file: file, line: line)
    }

    /// 节目 › 打开（D04 的打开事务）：读不出来照旧什么都不变（跑着的节目、保存目标），提示写成"输入 3（片头）的播放速率 10 超出 0.1–8"。
    func testW5Q1_openShowWithOutOfRangeRatePromptsInUIWording() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let directory = try temporaryDirectory("open")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("旧节目.\(ShowDocuments.fileExtension)")
        try writeOldShow(to: url)
        let targetBefore = controller.documents.currentURL
        let done = AppTest.expectationBox()
        Task { await controller.openShow(url: url); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(10) { done.value })
        print("W5Q1 打开：\(controller.lastPresentedError.map { "\($0.context) / \($0.message)" } ?? "nil")")
        XCTAssertTrue(controller.session === session, "打不开：跑着的还是原来那份（D04）")
        XCTAssertEqual(controller.documents.currentURL, targetBefore, "保存目标不变")
        let shown = try XCTUnwrap(controller.lastPresentedError, "不静默：要提示")
        XCTAssertEqual(shown.context, L("error.open", url.lastPathComponent))
        assertRateMessage(shown.message)
    }

    /// 节目 › 打开上次退出时的节目：LastSession 是老版本存的（越界速率）——原来 loadAutosave 的 try? 吞掉错误，点了什么都不发生。
    func testW5Q1_openLastSessionWithOutOfRangeRateIsNotSilent() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let autosave = controller.documents.autosaveURL
        defer { try? FileManager.default.removeItem(at: autosave) }
        try writeOldShow(to: autosave)
        XCTAssertTrue(controller.documents.hasAutosave, "菜单项亮着（有这份文件）")
        let done = AppTest.expectationBox()
        Task { await controller.openLastSession(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(10) { done.value })
        print("W5Q1 打开上次退出时的节目：\(controller.lastPresentedError.map { "\($0.context) / \($0.message)" } ?? "nil")")
        XCTAssertTrue(controller.session === session, "打不开：跑着的还是原来那份")
        let shown = try XCTUnwrap(controller.lastPresentedError, "不静默：要提示")
        XCTAssertEqual(shown.context, L("error.open", L("menu.show.lastSessionName")))
        assertRateMessage(shown.message)
    }

    /// 启动恢复（上次的文件 → LastSession → 空节目）：两份都是越界速率的老节目——原来两处 try? 静默退到空节目，用户不知道节目为什么没了；
    /// 现在每份打不开的都提示一句，照旧接着退。上次的文件打不开、LastSession 能打开时恢复 LastSession。
    func testW5Q1_restoreAtLaunchWithOutOfRangeRatePromptsEachAndFallsBack() throws {
        let directory = try temporaryDirectory("launch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "com.plusmix.switcher.tests.w5q-launch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let autosave = directory.appendingPathComponent("LastSession.\(ShowDocuments.fileExtension)")
        let docs = ShowDocuments(defaults: defaults, recordDirectory: directory.path, autosaveURL: autosave)
        let last = directory.appendingPathComponent("旧节目.\(ShowDocuments.fileExtension)")
        try writeOldShow(to: last)
        try writeOldShow(to: autosave)
        docs.adopt(last)   // 上次打开的就是它
        XCTAssertEqual(docs.lastURL, last)
        var shown: [(context: String, message: String)] = []
        let restored = AppController.restoreAtLaunch(documents: docs) { error, context in
            shown.append((context, (error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
        print("W5Q1 启动恢复：\(shown.map { "\($0.context) / \($0.message)" })")
        XCTAssertNil(restored, "两份都打不开：空节目")
        XCTAssertEqual(shown.map(\.context), [L("error.open", last.lastPathComponent), L("error.open", L("menu.show.lastSessionName"))], "两份各提示一句")
        for s in shown { assertRateMessage(s.message) }

        // LastSession 能打开：上次的文件提示一句、恢复 LastSession（没存成文件，有内容就算未保存）
        var good = ShowDocuments.emptyShow(name: "上次", recordDirectory: directory.path)
        good.inputs = [AppTest.syntheticConfig(number: 1)]
        try ShowStore().save(good, to: autosave)
        shown = []
        let fallback = try XCTUnwrap(AppController.restoreAtLaunch(documents: docs) { error, context in
            shown.append((context, (error as? LocalizedError)?.errorDescription ?? "\(error)"))
        })
        XCTAssertEqual(fallback.show.inputs.map(\.number), [1])
        XCTAssertEqual(fallback.identity, .untitled)
        XCTAssertEqual(shown.map(\.context), [L("error.open", last.lastPathComponent)])
    }

    // MARK: W5Q2 竖拍的文件信息

    private static func loadMovieInfo(_ path: String) -> MediaFileInfo? {
        var result: MediaFileInfo?
        Task { @MainActor in result = await MediaFileInfo.loadMovie(path: path) }
        AppTest.waitUntil(5) { result != nil }
        return result
    }

    /// 竖拍片子（编码 320×240、90° 方向矩阵）：信息摘要先写转正后的 240×320（FileInput 出帧的尺寸），编码尺寸放括号；与 FileInput 打开后的
    /// FileInfo.displayWidth / displayHeight（编码 width / height）逐项对上。没有方向矩阵的片子照旧只写一个尺寸（AddInputRevampTests 的 pattern.mov）。
    func testW5Q2_portraitFileInfoShowsDisplaySizeWithCodedSizeInParentheses() throws {
        let path = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/w2a5-rot90-320x240.mov").path
        let info = try XCTUnwrap(Self.loadMovieInfo(path))
        print("W5Q2 竖拍摘要：\(info.summary)")
        XCTAssertEqual(info.summary, "H.264 · 240×320（编码 320×240） · 30 fps · 0:01 · 没有声音")

        // 与包里 FileInfo 同口径：把这个文件加成一路，等 FileInput 打开
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "竖拍", source: .file(path: path, endAction: .loop, rate: 1))))
        XCTAssertTrue(AppTest.waitUntil(5) { (session.inputs.entries[1]?.input as? FileInput)?.info != nil }, "FileInput 打开了文件")
        let fileInfo = try XCTUnwrap((session.inputs.entries[1]?.input as? FileInput)?.info)
        XCTAssertTrue(info.summary.contains("\(fileInfo.displayWidth)×\(fileInfo.displayHeight)（编码 \(fileInfo.width)×\(fileInfo.height)）"),
                      "\(info.summary) vs FileInfo \(fileInfo.displayWidth)×\(fileInfo.displayHeight) / \(fileInfo.width)×\(fileInfo.height)")
    }

    // MARK: D06 边角一：录着 ISO 删掉这一路再加同编号

    /// ISO 录着输入 1 时删掉输入 1：录制器停在删除那一拍（主线程看到快照前已经录进去的一两拍撤不回，按已收的帧往后取整）、提示一句、
    /// 录制目标关掉（快照一致）；之后再加一路同编号的输入，它是新的 tee，旧录制器不接上去、也不自动再起一个录新的一路。原来旧录制器挂在没人推的分支上一直定格到手动停。
    func testD06_isoInputRemovedThenReAddedStopsRecorderAtDeletionTick() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, gray: 80, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.registeredInputs.contains(1) })
        let input = try XCTUnwrap(session.state.input(1))
        let iso = ISORoutes.makeISOOutput(for: input, in: session.state, defaultDirectory: AppTest.controller.documents.recordDirectory)
        session.send(.addOutput(config: iso))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(iso.number) != nil })
        session.send(.startRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[iso.number] != nil })
        let entry = try XCTUnwrap(session.outputs.recorders[iso.number])
        AppTest.pump(seconds: 1)
        var notices: [String] = []
        let token = session.observeNotices { notices.append($0) }
        defer { token.invalidate() }
        session.send(.removeInput(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1) == nil && session.inputs.entries[1] == nil })
        let deletion = try XCTUnwrap(session.control.bus.recentEntries().last { $0.command == .removeInput(input: 1) }?.appliedTick)
        // 再加同编号（换个底色），等它起来
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, gray: 200, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        let stopped = AppTest.waitUntil(8) { session.outputs.recorders[iso.number] == nil && session.outputs.lastResults[iso.number] != nil }
        print("W5Q D06 删再加：删除拍 \(deletion.rawValue)，结果 \(session.outputs.lastResults[iso.number].map { "\($0.start.tick.rawValue)…\($0.stopTick.rawValue)，\($0.videoFrames) 帧" } ?? "nil")，提示 \(notices)")
        XCTAssertTrue(stopped, "旧录制器在删除那一拍停下、封口（不定格到手动停）")
        let result = try XCTUnwrap(session.outputs.lastResults[iso.number])
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.url, entry.url)
        XCTAssertGreaterThanOrEqual(result.stopTick.rawValue, deletion.rawValue)
        XCTAssertLessThanOrEqual(result.stopTick.rawValue - deletion.rawValue, 6, "停在删除那一拍（已录进去的拍按已收的帧往后取整，不到 0.1 s）")
        XCTAssertEqual(Int(result.videoFrames), Int(result.stopTick.rawValue - result.start.tick.rawValue), "文件里没有洞")
        XCTAssertTrue(notices.contains { $0.contains("ISO") && $0.contains("输入 1") && $0.contains("删") }, "提示一句：\(notices)")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(iso.number)?.enabled == false }, "录制目标关掉：快照与运行表一致")
        AppTest.pump(seconds: 0.5)
        XCTAssertNil(session.outputs.recorders[iso.number], "新的一路不接旧录制器，也不自动再起一个")
        XCTAssertEqual(session.inputs.entries[1]?.tee.branchCount, 0, "新的一路的 tee 上没有 ISO 分支")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: D06 边角二：换源瞬间别的路注册

    /// 读录像的音轨（解成 48 kHz 立体声 Float32），两声道取平均。
    private static func audioSamples(_ url: URL) -> [Float]? {
        var result: [Float]?
        var done = false
        Task { @MainActor in
            result = try? await Self.decodeAudio(url)
            done = true
        }
        AppTest.waitUntil(10) { done }
        return result
    }

    private static func decodeAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < data.count {
                samples.append((data[i] + data[i + 1]) / 2)
                i += 2
            }
        }
        return samples
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// 换源瞬间别的路注册（119 §3 第 3 条）：InputRuntime.replaceSource 先摘旧环（AudioRuntime.unregister，淡出 3 块后 detach、实时线程确认后槽位才回空闲表）、
    /// 再注册新环（AudioRuntime.register；撞上淡出就排 30 ms 重试）——两步之间别的路注册进来，按后进先出拿走这一路原来的槽位，这一路落到另一个槽位上。
    /// ISO 音轨（推子后、AFV 前的 tap，泵按 .input(n) 共享、加第一个消费者时把编号换成槽位）要跟着输入 1 的编号走：尾段录到输入 1 的正弦（合成源 1 kHz −20 dBFS），
    /// 不是抢了槽位的输入 2（静音）。实测合成源新输入对象建出来就要十几毫秒、多半直接注册回原槽位，窗口靠时序撞，所以这里用 replaceSource 同一对调用把窗口拉开。
    func testD06_isoAudioFollowsInputNumberWhenAnotherInputTakesItsSlot() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, gray: 80, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.registeredInputs.contains(1) })
        let oldSlot = try XCTUnwrap(session.audio.engine.slot(forInput: 1))
        let input = try XCTUnwrap(session.state.input(1))
        let iso = ISORoutes.makeISOOutput(for: input, in: session.state, defaultDirectory: AppTest.controller.documents.recordDirectory)
        session.send(.addOutput(config: iso))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(iso.number) != nil })
        session.send(.startRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[iso.number] != nil })
        let entry = try XCTUnwrap(session.outputs.recorders[iso.number])
        XCTAssertNotNil(entry.recorder.configuration.audio, "这一路带音频：ISO 有音轨")
        AppTest.pump(seconds: 0.5)

        // 摘旧环（换源的第一步）：等 detach、槽位回空闲表
        let made = try XCTUnwrap(session.inputs.entries[1]?.made)
        let ring = try XCTUnwrap(made.audioRing)
        session.audio.unregister(number: 1)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.engine.slot(forInput: 1) == nil }, "旧环摘完")
        AppTest.pump(seconds: 0.3)   // 槽位等实时线程确认 detach 后才还回空闲表

        // 这个窗口里别的路注册：静音的输入 2 按后进先出拿到输入 1 原来的槽位
        var muted = AppTest.syntheticConfig(number: 2, gray: 120, audio: true)
        muted.settings.audio.muted = true
        session.send(.addInput(config: muted))
        XCTAssertTrue(AppTest.waitUntil(5) { session.audio.registeredInputs.contains(2) })
        XCTAssertEqual(session.audio.engine.slot(forInput: 2), oldSlot, "前提：输入 2 拿走了输入 1 原来的槽位（后进先出）")

        // 注册新环（换源的第二步）：输入 1 落到另一个槽位
        session.audio.register(number: 1, ring: ring, blockFrames: made.audioBlockFrames)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.registeredInputs.contains(1) })
        let newSlot = try XCTUnwrap(session.audio.engine.slot(forInput: 1))
        XCTAssertNotEqual(newSlot, oldSlot)
        AppTest.pump(seconds: 2)
        XCTAssertTrue(session.outputs.recorders[iso.number] === entry, "同一个录制器录到底")
        session.send(.stopRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(15) { session.outputs.recorders[iso.number] == nil && session.outputs.lastResults[iso.number] != nil })
        let result = try XCTUnwrap(session.outputs.lastResults[iso.number])
        defer { try? FileManager.default.removeItem(at: result.url) }
        let samples = try XCTUnwrap(Self.audioSamples(result.url))
        let rate = 48_000
        XCTAssertGreaterThan(samples.count, rate * 2, "音轨有内容")
        // 尾段（停之前 0.9 s … 0.15 s）：输入 1 的正弦（两声道平均后 RMS 约 0.04），不是静音的输入 2（0）
        let tail = samples[(samples.count - rate * 9 / 10)..<(samples.count - rate * 15 / 100)]
        let head = samples[(rate / 10)..<(rate * 4 / 10)]
        print("W5Q D06 槽位：输入 1 \(oldSlot) → \(newSlot)，输入 2 \(String(describing: session.audio.engine.slot(forInput: 2)))；ISO 音轨 \(samples.count) 样本，开头 RMS \(Self.rms(head))，尾段 RMS \(Self.rms(tail))")
        XCTAssertGreaterThan(Self.rms(head), 0.01, "开头是输入 1 的正弦（对照；静音是 0）")
        XCTAssertGreaterThan(Self.rms(tail), 0.01, "尾段跟着输入 1 的编号走：录到的是输入 1 的正弦，不是抢了槽位的输入 2（静音）")
        XCTAssertEqual(Int(result.audioFrames), Int(result.stopTick.rawValue - result.start.tick.rawValue) * 800, accuracy: 800, "两轨等长")
    }

    // MARK: 030 的界面展示（读 Stats 的 audio.effects）

    private func stats(_ effects: Stats.AudioCounters.EffectsLatency, videoDelayMs: Double = 0) -> Stats {
        Stats(ts: 1000, tick: Tick(60_000), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
              audio: Stats.AudioCounters(dropouts: 0, underruns: 0, effects: effects), rssMb: 1, cpuPct: 1, gpuPct: 1, videoDelayMs: videoDelayMs)
    }

    /// Master 一格限幅 12 ms、Bus A 自写压缩器（实测 0.5 ms，故意不是 0：看得出读的是这一份）、Bus B 动态处理器 5.33 ms、耳机 0；
    /// 输入 3 压缩器 1.33 ms（实测 0）、输入 4 只有 EQ（0）；输入 1 没装效果（Stats 不列）。
    private var sampleEffects: Stats.AudioCounters.EffectsLatency {
        Stats.AudioCounters.EffectsLatency(
            buses: [.init(bus: "master", latencyMs: 12), .init(bus: "busA", latencyMs: 0.5, measuredLatencyMs: 0.5),
                    .init(bus: "busB", latencyMs: 16.0 / 3), .init(bus: "headphones", latencyMs: 0)],
            inputs: [3: .init(latencyMs: 4.0 / 3, measuredLatencyMs: 0), 4: .init(latencyMs: 0)])
    }

    private var compressorSlot: EffectSlot {
        AudioEffectParams.compressor(thresholdDb: -20, ratio: 4, kneeDb: 6, attackSeconds: 0.005, releaseSeconds: 0.1, makeupGainDb: 0)
    }

    /// 音频设置窗：常规页"效果链延迟"、压缩页"延迟自测"都读 Stats 的 audio.effects（同一份进 stats.jsonl / API）；没收到 Stats 时写"还没量到" / —。
    func test030_audioSettingsRowsReadStatsEffects() {
        var state = MixerState.newShow()
        state.inputs = [AppTest.syntheticConfig(number: 1, audio: true), AppTest.syntheticConfig(number: 3, audio: true)]
        state.inputs[1].settings.effects = [compressorSlot]
        state.audio.buses[1].effects = [compressorSlot]   // Bus A
        let busA = AudioSettingsModel(strip: .bus(.busA), state: state, page: .compressor)
        XCTAssertEqual(busA.compressorSelfTestText, L("audioSettings.compressor.latencyPending"), "还没收到 Stats")
        XCTAssertEqual(busA.effectLatencyText, "—")
        let master = AudioSettingsModel(strip: .bus(.master), state: state)
        let input3 = AudioSettingsModel(strip: .input(3), state: state, page: .compressor)
        let input1 = AudioSettingsModel(strip: .input(1), state: state)
        for m in [busA, master, input3, input1] { m.apply(stats: stats(sampleEffects)) }
        XCTAssertEqual(busA.compressorSelfTestText, L("audioSettings.compressor.latency", 24, 0.5), "延迟自测读 Stats 的 measured_latency_ms（0.5 ms = 24 帧）")
        XCTAssertEqual(busA.effectLatencyText, "0.5 ms")
        XCTAssertEqual(master.effectLatencyText, "12.0 ms")
        XCTAssertNil(master.compressorSelfTestText, "Master 没装压缩器：不显示这一行")
        XCTAssertEqual(input3.effectLatencyText, "1.3 ms")
        XCTAssertEqual(input3.compressorSelfTestText, L("audioSettings.compressor.latency", 0, 0.0))
        XCTAssertEqual(input1.effectLatencyText, L("audioSettings.general.effectLatencyNone"), "没装效果的路 Stats 不列")
    }

    /// 推流 / 录制状态窗底部：每条总线、装了效果的每路一项（名字从快照对号），压缩器的实测值跟在后面；数原样来自 Stats 的 audio.effects。
    func test030_outputStatusListsEffectLatencies() {
        let model = OutputStatusModel()
        var state = MixerState.newShow()
        state.inputs = [InputConfig(number: 3, name: "话筒", source: .synthetic(settings: SyntheticSourceSettings())),
                        InputConfig(number: 4, name: "背景", source: .synthetic(settings: SyntheticSourceSettings()))]
        model.apply(stats: stats(sampleEffects, videoDelayMs: 12), state: state)
        let text = model.effectLatencyText ?? ""
        print("W5Q 030 状态窗：\(text)")
        XCTAssertEqual(text, L("outputStatus.effectLatency", [
            L("outputStatus.effectLatency.item", "Master", "12.0 ms"),
            L("outputStatus.effectLatency.itemMeasured", "Bus A", "0.5 ms", "0.50 ms"),
            L("outputStatus.effectLatency.item", "Bus B", "5.3 ms"),
            L("outputStatus.effectLatency.item", "耳机", "0.0 ms"),
            L("outputStatus.effectLatency.itemMeasured", "输入 3 话筒", "1.3 ms", "0.00 ms"),
            L("outputStatus.effectLatency.item", "输入 4 背景", "0.0 ms"),
        ].joined(separator: L("outputStatus.effectLatency.separator"))))
        XCTAssertEqual(model.videoDelayText, L("outputStatus.videoDelay", 12))
        model.apply(stats: stats(Stats.AudioCounters.EffectsLatency()), state: state)
        XCTAssertNil(model.effectLatencyText, "没有音频引擎 / 老 stats（effects 缺键 = 空）：不显示")
    }

    /// 真引擎：Bus A 装自写压缩器、Master 装一格限幅，等 Stats 出这一节；音频设置窗压缩页"延迟自测"、状态窗那一行的数与 session.stats 里的同一份逐项相同
    /// （铁律 4：UI、API、stats.jsonl 三方读同一个结构）。
    func test030_effectLatencyShownFromSessionStats() throws {
        let session = try AppTest.freshSession()
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        session.send(.setBusEffects(bus: .busA, effects: [compressorSlot]))
        session.send(.setBusEffects(bus: .master, effects: [AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0)]))
        XCTAssertTrue(AppTest.waitUntil(5) {
            let buses = session.stats?.audio.effects.buses ?? []
            return buses.first { $0.bus == "busA" }?.measuredLatencyMs != nil && (buses.first { $0.bus == "master" }?.latencyMs ?? 0) > 0
        }, "Stats 出了效果链延迟：\(String(describing: session.stats?.audio.effects))")
        let w = try XCTUnwrap(panels.showAudioSettings(.bus(.busA), page: .compressor))
        XCTAssertTrue(AppTest.waitUntil(3) {
            guard let ms = session.stats?.audio.effects.buses.first(where: { $0.bus == "busA" })?.measuredLatencyMs else { return false }
            return w.model.compressorSelfTestText == L("audioSettings.compressor.latency", Int((ms * 48).rounded()), ms)
        }, "延迟自测 = Stats 里 Bus A 的 measured_latency_ms：\(String(describing: w.model.compressorSelfTestText))")
        XCTAssertTrue(AppTest.waitUntil(3) {
            guard let master = session.stats?.audio.effects.buses.first(where: { $0.bus == "master" }) else { return false }
            return panels.outputStatus.effectLatencyText?.contains(L("outputStatus.effectLatency.item", "Master", String(format: "%.1f ms", master.latencyMs))) == true
        }, "状态窗那一行：\(String(describing: panels.outputStatus.effectLatencyText))")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }
}
