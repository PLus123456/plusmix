// W5-I（prompt 95）输出设置页：推流预设 / 质量 / 状态 / 鉴权，录制输出列表与 ISO 表，外部显示页与输出总览。
// 面板是 SwiftUI 表单，测试驱动它们的模型（OutputSettingsModel）；端到端的几条看 session.state（快照）与运行表，模型级的几条用一份手搭的状态 + 记下发出的命令。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherExternal
import SwitcherStreaming
@testable import Switcher

@MainActor
final class OutputPagesTests: XCTestCase {
    @MainActor final class Sent { var list: [Command] = [] }

    /// 模型级：一份手搭的状态 + 记下发出的命令（不起引擎）。
    private func detachedModel(_ state: MixerState, tab: OutputSettingsModel.Tab = .stream) -> (OutputSettingsModel, Sent) {
        let model = OutputSettingsModel(state: state, tab: tab, defaultRecordDirectory: "/tmp/w5i", showName: "t", queriesSystemExtensions: false)
        let sent = Sent()
        model.send = { sent.list.append($0) }
        return (model, sent)
    }

    private func stats(_ encoder: [Stats.EncoderEntry]) -> Stats {
        Stats(ts: 1, tick: Tick(60), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: encoder,
              audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 1, gpuPct: 1)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            AppTest.dismissConfirmations()
            AppTest.controller.panels.closeAll()
        }
        super.tearDown()
    }

    // MARK: - 推流：服务预设（L6 / Q31）

    /// 选"服务" = 填好入口地址（可改），节目里只存完整地址、不存服务 id；关窗再开按地址认回来；每场发地址的平台不填地址；预设表是 App 资源 JSON。
    func testPanels_streamPresetFillsURLAndKeepsFullURLInShow() throws {
        // 预设表（Q31 (a) 的短表与顺序）：两个自定义在前，国内四个，海外三个；两种语言都有名字和"去哪拿"；固定入口的地址推流包认得
        let services = OutputSettingsModel.streamServices
        XCTAssertEqual(services.map(\.id), ["customRTMP", "customSRT", "wechatChannels", "douyin", "bilibili", "kuaishou", "youtube", "facebook", "twitch"])
        for s in services {
            XCTAssertFalse((s.name["zh-Hans"] ?? "").isEmpty, "\(s.id) 缺中文名")
            XCTAssertFalse((s.name["en"] ?? "").isEmpty, "\(s.id) 缺英文名")
            XCTAssertFalse((s.hint["zh-Hans"] ?? "").isEmpty || (s.hint["en"] ?? "").isEmpty, "\(s.id) 缺一句去哪拿")
            if s.kind == .fixed {
                let url = try XCTUnwrap(s.url, "\(s.id) 是固定入口却没有地址")
                let d = try StreamDestination(settings: StreamSettings(url: url, streamKey: "k"))
                XCTAssertTrue(s.schemes.contains(d.scheme.rawValue), "\(s.id) 的地址协议 \(d.scheme) 不在 \(s.schemes)")
                XCTAssertTrue(s.matches(url: url), "\(s.id) 认不出自己的地址")
            } else {
                XCTAssertNil(s.url, "\(s.id) 不该填地址（每场发 / 自定义）")
            }
        }
        XCTAssertEqual(StreamServiceCatalog.service(id: "facebook")?.schemes, ["rtmps"], "Facebook 只收 RTMPS")

        let session = try AppTest.freshSession()
        let page = AppTest.controller.panels.showOutputSettings(tab: .stream).model
        let n = page.addStream(url: "", key: "abcd-1234")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) != nil })
        XCTAssertEqual(page.streamService(n).id, "customRTMP", "空地址 = 自定义 RTMP")

        page.applyStreamService(n, id: "youtube")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.stream?.url == "rtmp://a.rtmp.youtube.com/live2" },
                      "选 YouTube 应填好入口地址：\(String(describing: session.state.output(n)?.settings.stream))")
        XCTAssertEqual(session.state.output(n)?.settings.stream?.streamKey, "abcd-1234", "推流码不动")
        XCTAssertEqual(page.streamService(n).id, "youtube")
        // 节目里只存完整地址：保存出来的节目只在地址里出现 youtube，extra 里没有服务 id
        let output = try XCTUnwrap(session.state.output(n))
        XCTAssertEqual(output.settings.extra.keys.filter { $0.lowercased().contains("service") }, [], "\(output.settings.extra)")
        let data = try session.makeShow().save()
        let back = try Show.load(from: data)
        XCTAssertEqual(back.outputs.first { $0.number == n }?.settings.stream?.url, "rtmp://a.rtmp.youtube.com/live2")
        XCTAssertEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "youtube").count - 1, 1, "节目文件里 youtube 只出现在地址里")
        // 关窗再开（新模型，没有"刚选过"的记忆）：按地址认回 YouTube；手改成 rtmps 入口也认
        let fresh = OutputSettingsModel(state: session.state, tab: .stream, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        XCTAssertEqual(fresh.streamService(n).id, "youtube")
        XCTAssertEqual(StreamServiceCatalog.service(forURL: "rtmps://a.rtmps.youtube.com:443/live2").id, "youtube")
        XCTAssertEqual(StreamServiceCatalog.service(forURL: "rtmp://ingest.global-contribute.live-video.net/app").id, "twitch")

        // 每场发地址的平台：不填地址；当前是别家的固定入口 → 清空让用户贴
        page.applyStreamService(n, id: "bilibili")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.stream?.url == "" }, "换到每场发地址的平台应清掉 YouTube 的入口")
        XCTAssertEqual(page.streamService(n).id, "bilibili", "刚选过的平台从空地址认不出来，按选的显示")
        XCTAssertFalse(page.streamService(n).hintText.isEmpty)
        page.commitStreamAddress(n, url: "rtmp://live-push.bilivideo.com/live-bvc/", key: "?streamname=x")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.stream?.url == "rtmp://live-push.bilivideo.com/live-bvc/" })
        // 自定义 SRT：地址协议对不上就清空
        page.applyStreamService(n, id: "customSRT")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.stream?.url == "" })
        XCTAssertEqual(page.streamService(n).id, "customSRT")
        page.commitStreamAddress(n, url: "srt://127.0.0.1:9000?streamid=publish:s1", key: "")
        XCTAssertTrue(AppTest.waitUntil(3) { page.streamService(n).id == "customSRT" && session.state.output(n)?.settings.stream?.url.hasPrefix("srt://") == true })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: - 推流：质量档（L7 / L8 / Q30）

    /// 选质量档 = 写编码字段（H.264、尺寸、码率、关键帧 2 s 按节目帧率、AAC）；任何一项对不上显示"自定义"；新目的地默认封顶 1080p 的那一档。
    func testPanels_streamQualityPresetWritesEncoderFields() throws {
        let session = try AppTest.freshSession()
        XCTAssertEqual(session.format, .hd1080p60, "测试宿主的空节目是 1080p60")
        let page = AppTest.controller.panels.showOutputSettings(tab: .stream).model
        let n = page.addStream(url: AppTest.closedRTMP("q"), key: "")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) != nil })
        // 新目的地：1080p 档（60 fps → 6 Mb/s）、关键帧 2 s = 120 帧、AAC 160k
        var o = try XCTUnwrap(session.state.output(n))
        XCTAssertEqual(o.settings.video, VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000, keyframeIntervalFrames: 120, width: 1920, height: 1080))
        XCTAssertEqual(o.settings.audio, AudioEncodeSettings(codec: .aac, bitrateBps: 160_000))
        XCTAssertEqual(page.streamQualityID(n), "1080p")
        XCTAssertEqual(page.keyframeText(n), "2 s（= 120 帧）")

        page.applyStreamQuality(n, id: "720p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.video?.width == 1280 }, "\(String(describing: session.state.output(n)?.settings.video))")
        o = try XCTUnwrap(session.state.output(n))
        XCTAssertEqual(o.settings.video, VideoEncodeSettings(codec: .h264, bitrateBps: 3_000_000, keyframeIntervalFrames: 120, width: 1280, height: 720))
        XCTAssertEqual(o.settings.audio, AudioEncodeSettings(codec: .aac, bitrateBps: 128_000))
        XCTAssertEqual(page.streamQualityID(n), "720p")

        // 手改一项 → "自定义"；选"自定义"不改字段、展开编码详情
        page.updateOutput(n) { $0.video?.bitrateBps = 2_000_000 }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.video?.bitrateBps == 2_000_000 })
        XCTAssertEqual(page.streamQualityID(n), OutputSettingsModel.customQualityID)
        let before = session.state.output(n)?.settings
        page.applyStreamQuality(n, id: OutputSettingsModel.customQualityID)
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(session.state.output(n)?.settings, before, "选自定义不改字段")
        XCTAssertTrue(page.expandedEncodeDetails.contains(n), "选自定义展开编码详情")

        // 关键帧按秒改：1 s = 60 帧
        page.setKeyframeSeconds(n, 1)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.video?.keyframeIntervalFrames == 60 })
        XCTAssertEqual(page.keyframeText(n), "1 s（= 60 帧）")

        page.applyStreamQuality(n, id: "1080p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.video?.bitrateBps == 6_000_000 })
        XCTAssertEqual(session.state.output(n)?.settings.video?.keyframeIntervalFrames, 120, "选档把关键帧写回 2 s")

        // 30 fps 的节目（模型级）：1080p 档 4.5 Mb/s、关键帧 60 帧；下拉文字写实际码率
        var show = ShowDocuments.emptyShow()
        show.mixer.format = .hd1080p30
        let (m30, _) = detachedModel(show.makeState())
        let tier = try XCTUnwrap(StreamQualityTier.tier(id: "1080p"))
        XCTAssertEqual(tier.video(for: .hd1080p30), VideoEncodeSettings(codec: .h264, bitrateBps: 4_500_000, keyframeIntervalFrames: 60, width: 1920, height: 1080))
        XCTAssertEqual(tier.title(for: .hd1080p30), "1080p · 4.5 Mb/s · 音频 160k")
        XCTAssertEqual(tier.title(for: .hd1080p60), "1080p · 6 Mb/s · 音频 160k")
        let s30 = m30.newStreamSettings(url: "rtmp://x/app", key: "")
        XCTAssertEqual(s30.video?.keyframeIntervalFrames, 60, "新建按节目帧率写帧数：30 fps × 2 s")
        XCTAssertEqual(s30.video?.bitrateBps, 4_500_000)
        // 720p 节目：默认档不放大
        XCTAssertEqual(StreamQualityTier.defaultTier(for: .hd720p60).id, "720p")
        XCTAssertEqual(StreamQualityTier.defaultTier(for: .uhd2160p30).id, "1080p", "封顶 1080p")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: - 推流：与推流 1 相同（L9）

    /// 第 2 个起默认"与推流 1 相同"：推流 1 改编码它跟着改；在推的时候不动、停了再跟；取消勾以后各管各的。
    func testPanels_secondDestinationFollowsFirstUntilDetached() throws {
        let session = try AppTest.freshSession()
        let page = AppTest.controller.panels.showOutputSettings(tab: .stream).model
        let a = page.addStream(url: AppTest.closedRTMP("a"), key: "")
        let b = page.addStream(url: AppTest.closedRTMP("b"), key: "")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(a) != nil && session.state.output(b) != nil })
        XCTAssertTrue(page.isStreamLeader(a))
        XCTAssertFalse(page.streamFollowsFirst(a), "推流 1 自己不算跟随")
        XCTAssertTrue(page.streamFollowsFirst(b), "第 2 个起默认与推流 1 相同")
        XCTAssertEqual(page.streamTitle(a), "推流 1")
        XCTAssertEqual(page.streamTitle(b), "推流 2")
        XCTAssertEqual(page.streamSubtitle(b), "输出 \(b)")
        XCTAssertEqual(session.state.output(b)?.settings.video, session.state.output(a)?.settings.video)

        // 推流 1 换档 → 推流 2 跟着换（UI 层跟随，OutputLinkageSync）
        page.applyStreamQuality(a, id: "720p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(b)?.settings.video?.width == 1280 && session.state.output(b)?.settings.audio?.bitrateBps == 128_000 },
                      "推流 2 应跟上推流 1：\(String(describing: session.state.output(b)?.settings.video))")

        // 推流 2 在推（连不上的地址，一直连接中 = 在跑的路）：推流 1 再改，它不动；停了再跟
        session.send(.startStream(output: b))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(b)?.enabled == true })
        page.applyStreamQuality(a, id: "1080p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(a)?.settings.video?.width == 1920 })
        AppTest.pump(seconds: 0.5)
        XCTAssertEqual(session.state.output(b)?.settings.video?.width, 1280, "在推的路不动")
        session.send(.stopStream(output: b))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.output(b)?.enabled == false && session.state.output(b)?.settings.video?.width == 1920 },
                      "停了以后跟上：\(String(describing: session.state.output(b)))")

        // 取消跟随：推流 1 再改，推流 2 留着自己的
        page.setStreamFollowsFirst(b, on: false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(b)?.settings.stream?.followFirst == false }, "读 025 的正式字段 StreamSettings.followFirst")
        XCTAssertFalse(page.streamFollowsFirst(b))
        page.applyStreamQuality(a, id: "720p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(a)?.settings.video?.width == 1280 })
        AppTest.pump(seconds: 0.5)
        XCTAssertEqual(session.state.output(b)?.settings.video?.width, 1920, "取消跟随以后不再跟")
        // 推流 2 自己改不影响推流 1
        page.applyStreamQuality(b, id: "720p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(b)?.settings.video?.width == 1280 })
        XCTAssertEqual(session.state.output(a)?.settings.video?.width, 1280)
        // 再勾上：马上抄一次
        page.applyStreamQuality(a, id: "1080p")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(a)?.settings.video?.width == 1920 })
        page.setStreamFollowsFirst(b, on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(b)?.settings.video == session.state.output(a)?.settings.video })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: - ISO 表跟录制格式（K9 / K10）

    /// 录制页改 ProRes 后没在录的 ISO 路跟着变、在录的不变（停了再跟）；目录同理；ISO 表 = PGM 行 + 每路输入，PGM 行取消 = 只录 ISO。
    func testPanels_isoTableFollowsRecordFormat() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        let page = AppTest.controller.panels.showOutputSettings(tab: .iso).model
        let master = try XCTUnwrap(OutputLinkage.recordMaster(in: session.state))
        XCTAssertEqual(page.isoRows.map(\.id), ["pgm", "input-1", "input-2"])
        XCTAssertEqual(page.isoRows.map(\.checked), [true, false, false], "PGM 行默认勾着（参与录制）")
        page.setISORow("input-1", on: true)
        page.setISORow("input-2", on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { ISORoutes.isoRecord(in: session.state, input: 1) != nil && ISORoutes.isoRecord(in: session.state, input: 2) != nil })
        let iso1 = try XCTUnwrap(ISORoutes.isoRecord(in: session.state, input: 1)).number
        let iso2 = try XCTUnwrap(ISORoutes.isoRecord(in: session.state, input: 2)).number
        XCTAssertTrue(AppTest.waitUntil(2) { page.isoRows.map(\.checked) == [true, true, true] })
        XCTAssertEqual(page.isoRows.first { $0.id == "input-1" }?.output, iso1)
        XCTAssertTrue(page.isoFormatLine.contains("H.264"), page.isoFormatLine)
        XCTAssertTrue(page.isoFormatLine.contains("18 Mb/s"), "1080p60 的录制默认 18 Mb/s（Q30）：\(page.isoFormatLine)")
        XCTAssertEqual(page.detailTab(for: try XCTUnwrap(session.state.output(iso1))), .iso, "跟录制 1 的 ISO 路详情在 ISO 页")
        XCTAssertFalse(page.recordList.contains { $0.number == iso1 }, "ISO 路不在录制页的列表里")

        // ISO 1 在录
        session.send(.startRecord(output: iso1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.output(iso1)?.enabled == true && session.outputs.recorders[iso1] != nil })
        XCTAssertTrue(AppTest.waitUntil(2) { page.isoRows.first { $0.id == "input-1" }?.locked == true }, "录着的行锁住")

        // 录制页改 ProRes 422
        page.tab = .record
        page.updateRecord { $0.video?.codec = .prores422 }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(iso2)?.settings.video?.codec == .prores422 }, "没在录的 ISO 路跟着变")
        AppTest.pump(seconds: 0.5)
        XCTAssertEqual(session.state.output(iso1)?.settings.video?.codec, .h264, "在录的不变")
        XCTAssertEqual(session.state.output(master.number)?.settings.video?.codec, .prores422)
        XCTAssertTrue(page.isoFormatLine.contains("ProRes 422"), page.isoFormatLine)
        let note = try XCTUnwrap(page.recordDeferredNote, "在录的路停了才跟，要提示")
        XCTAssertTrue(note.contains(try XCTUnwrap(session.state.output(iso1)).name), note)
        XCTAssertNotNil(page.recordLiveNote, "录着的时候页顶提示改动从下一次开录起生效（K6）")

        session.send(.stopRecord(output: iso1))
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(iso1)?.enabled == false && session.outputs.recorders.isEmpty })
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(iso1)?.settings.video?.codec == .prores422 }, "停了以后跟上（下一次开录生效）")
        XCTAssertNil(page.recordDeferredNote)

        // 录制页的目录对全部录制路生效
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w5i-iso-\(UUID().uuidString)").path
        page.updateRecordFiles { $0.directory = dir }
        XCTAssertTrue(AppTest.waitUntil(3) { [iso1, iso2].allSatisfy { session.state.output($0)?.settings.record?.directory == dir } }, "目录同步到 ISO 路")
        XCTAssertTrue([iso1, iso2].allSatisfy { session.state.output($0)?.settings.record?.fileNamePattern.contains("{output}") == true }, "ISO 的文件名模板带 {output}")
        XCTAssertEqual(page.isoRows.first { $0.id == "input-2" }?.directory, dir)

        // PGM 行取消 = 只录 ISO：底栏"录制"只起两路 ISO
        page.setISORow("pgm", on: false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(master.number)?.settings.record?.armed == false }, "读 025 的正式字段 RecordSettings.armed")
        XCTAssertNil(session.state.output(master.number)?.settings.extra["app.record.armed"], "不再写 extra 键")
        XCTAssertEqual(page.isoRows.first?.checked, false)
        wc.bottomBar.record.bodyButton.performClick(nil)   // 92 的分体控件：主体是 record.bodyButton（G7 合并时接）
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders.count == 2 }, "只起 ISO 两路：\(session.outputs.recorders.keys.sorted())")
        XCTAssertEqual(Set(session.outputs.recorders.keys), [iso1, iso2])
        XCTAssertEqual(session.state.output(master.number)?.enabled, false, "PGM 没录")
        wc.bottomBar.record.bodyButton.performClick(nil)   // 92 的分体控件：主体是 record.bodyButton（G7 合并时接）
        if AppTest.waitForConfirmation(.stopRecord) != nil { AppTest.answer(.confirm) }
        XCTAssertTrue(AppTest.waitUntil(15) { session.outputs.recorders.isEmpty && !session.state.outputs.contains { $0.kind == .record && $0.enabled } })
        page.setISORow("pgm", on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(master.number)?.settings.record?.armed == true })
        try? FileManager.default.removeItem(atPath: dir)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: - 录制输出列表（K4 / K7 / K8）

    /// 录制页 = 录制输出列表：加第二路 PGM 录制（默认码率按节目格式）、改名、自己的格式、来源只列 PGM / 输入、参与录制开关、删除。
    func testPanels_recordOutputListAddsSecondPGMRecording() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        let page = AppTest.controller.panels.showOutputSettings(tab: .record).model
        let master = try XCTUnwrap(OutputLinkage.recordMaster(in: session.state))
        XCTAssertEqual(page.recordList.map(\.number), [master.number])
        XCTAssertEqual(master.settings.video?.bitrateBps, 18_000_000, "新节目的录制码率按节目格式（1080p60 ≈ 18 Mb/s，Q30）")
        XCTAssertEqual(master.settings.audio, AudioEncodeSettings(codec: .aac, bitrateBps: 256_000))
        XCTAssertEqual(page.recordSourceChoices, [.program, .input(number: 1)], "来源只列 PGM / 输入（PVW / 多画面运行时照录 PGM，不给）")

        let n = page.addRecordOutput()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) != nil })
        var o = try XCTUnwrap(session.state.output(n))
        XCTAssertEqual(o.kind, .record)
        XCTAssertEqual(o.settings.source, .program)
        XCTAssertEqual(o.name, "录制 2")
        XCTAssertFalse(o.enabled)
        XCTAssertEqual(o.settings.record?.armed, true, "新加的录制路参与录制（025 的正式字段）")
        XCTAssertEqual(o.settings.video?.bitrateBps, 18_000_000)
        XCTAssertEqual(o.settings.audio?.bitrateBps, 256_000)
        XCTAssertEqual(o.settings.record?.directory, master.settings.record?.directory)
        XCTAssertTrue(o.settings.record?.fileNamePattern.contains("{output}") ?? false, "第二路 PGM 录制的文件名不能和录制 1 撞")
        XCTAssertEqual(page.recordList.map(\.number), [master.number, n])
        XCTAssertEqual(page.recordTitle(n), "录制 2")
        XCTAssertTrue(page.recordPlanLine.contains("2 路"), page.recordPlanLine)

        // 改名（renameOutput）、自己的格式：录制 1 不跟着变
        page.rename(n, "母版")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.name == "母版" })
        page.updateOutput(n) { $0.video?.codec = .prores422HQ }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.video?.codec == .prores422HQ })
        XCTAssertEqual(session.state.output(master.number)?.settings.video?.codec, .h264, "第二路自己的格式不影响录制 1")
        // 录制 1 改码率：第二路（PGM、自己的格式）编码不跟，文件一节（目录）跟
        page.updateRecord { $0.video?.bitrateBps = 20_000_000 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w5i-rec-\(UUID().uuidString)").path
        page.updateRecordFiles { $0.directory = dir }
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.record?.directory == dir }, "目录对全部录制路生效")
        XCTAssertEqual(session.state.output(n)?.settings.video?.codec, .prores422HQ)
        XCTAssertEqual(session.state.output(n)?.settings.video?.bitrateBps, 18_000_000)

        // 来源改成输入 1：仍在录制页（自己的格式），不变成跟录制 1 的 ISO 路
        page.setRecordSource(n, .input(number: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.source == .input(number: 1) })
        o = try XCTUnwrap(session.state.output(n))
        XCTAssertFalse(OutputLinkage.followsRecordMaster(o, in: session.state))
        XCTAssertEqual(page.recordList.map(\.number), [master.number, n])
        page.updateRecord { $0.video?.bitrateBps = 22_000_000 }
        AppTest.pump(seconds: 0.4)
        XCTAssertEqual(session.state.output(n)?.settings.video?.codec, .prores422HQ)

        // 参与录制：关掉第二路 → 底栏"录制"只起录制 1
        page.setRecordArmed(n, on: false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.record?.armed == false })
        XCTAssertTrue(page.recordPlanLine.contains("1 路"), page.recordPlanLine)
        wc.bottomBar.record.bodyButton.performClick(nil)   // 92 的分体控件：主体是 record.bodyButton（G7 合并时接）
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders.count == 1 }, "\(session.outputs.recorders.keys.sorted())")
        XCTAssertNotNil(session.outputs.recorders[master.number])
        XCTAssertNotNil(page.recordLiveNote)
        wc.bottomBar.record.bodyButton.performClick(nil)   // 92 的分体控件：主体是 record.bodyButton（G7 合并时接）
        if AppTest.waitForConfirmation(.stopRecord) != nil { AppTest.answer(.confirm) }
        XCTAssertTrue(AppTest.waitUntil(15) { session.outputs.recorders.isEmpty && session.state.output(master.number)?.enabled == false })

        page.removeOutput(n)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) == nil })
        XCTAssertEqual(page.recordList.map(\.number), [master.number])
        try? FileManager.default.removeItem(atPath: dir)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: - 输出总览（F8）

    /// 输出组最上面"输出总览"：每个输出一行（种类、名字、来源、开 / 关、状态），点行跳到它的详情页。
    func testPanels_outputOverviewListsEveryOutput() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        XCTAssertEqual(OutputSettingsModel.Tab.allCases.first, .overview, "总览在输出组最上面")
        let page = AppTest.controller.panels.showOutputSettings(tab: .overview).model
        XCTAssertEqual(page.tab, .overview)
        let stream = page.addStream(url: AppTest.closedRTMP("ov"), key: "")
        let ndi = page.addNDI(name: "PlusMix 总览", groups: "", conversion: "auto", source: .program)
        let external = page.addExternalDisplay(screenNumber: 0x0BAD_F00D, source: .preview)   // 不存在的显示器：窗口只等它接上，不盖任何屏
        page.setVirtualCamera(enabled: false)
        page.setMultiviewSafeArea(true)
        page.setISO(input: 1, on: true)
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.outputs.count == 7 }, "\(session.state.outputs.map { "\($0.number) \($0.kind)" })")
        let rows = page.overviewRows
        XCTAssertEqual(rows.map(\.number), session.state.outputs.map(\.number), "每个输出一行")
        for (row, o) in zip(rows, session.state.outputs) {
            XCTAssertEqual(row.kind, o.kind)
            XCTAssertEqual(row.name, o.name)
            XCTAssertEqual(row.on, o.enabled)
            XCTAssertEqual(row.source, o.settings.source.title(in: session.state))
            XCTAssertFalse(row.kindTitle.isEmpty || row.kindTitle.hasPrefix("outputSettings."), "种类要有文案：\(row.kindTitle)")
            XCTAssertFalse(row.status.isEmpty || row.status.hasPrefix("outputSettings."), "\(o.kind) 状态要有文案：\(row.status)")
        }
        let master = try XCTUnwrap(OutputLinkage.recordMaster(in: session.state)).number
        let iso = try XCTUnwrap(ISORoutes.isoRecord(in: session.state, input: 1)).number
        let vcam = try XCTUnwrap(page.virtualCameraOutput).number
        let multiview = try XCTUnwrap(page.multiviewOutput).number
        let tabs = Dictionary(uniqueKeysWithValues: rows.map { ($0.number, $0.tab) })
        XCTAssertEqual(tabs, [master: .record, iso: .iso, stream: .stream, ndi: .ndi, external: .external, vcam: .virtualCamera, multiview: .multiview])
        XCTAssertEqual(rows.first { $0.number == stream }?.kindTitle, "推流")
        XCTAssertEqual(rows.first { $0.number == master }?.status, "未开")

        // 状态读 Stats.encoder（按输出编号对号）
        page.apply(stats: stats([Stats.EncoderEntry(output: ndi, skipped: 0, bitrate: 0, frames: 300, connections: 2, state: "publishing")]))
        XCTAssertEqual(page.overviewRows.first { $0.number == ndi }?.status, OutputStatusText.ndi(enabled: true, entry: OutputRuntime.encoderEntry(page.encoderStats, forOutput: ndi)))

        // 点行跳详情
        page.openDetail(stream)
        XCTAssertEqual(page.tab, .stream)
        XCTAssertEqual(page.focusedOutput, stream)
        page.openDetail(iso)
        XCTAssertEqual(page.tab, .iso)
        page.openDetail(external)
        XCTAssertEqual(page.tab, .external)

        for n in [stream, ndi, external, iso] { page.removeOutput(n) }
        XCTAssertTrue(AppTest.waitUntil(5) { session.aux.external.windows.isEmpty && session.state.outputs.count == 3 })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: - 推流：起停、状态行、合计上行（L3 / Q30）

    func testPanels_L3_streamPageStartStopStatusLineAndTotalUplink() throws {
        var show = ShowDocuments.emptyShow()
        show.outputs.append(AppTest.streamOutput(number: 2, url: "rtmp://127.0.0.1:1/live/a"))
        show.outputs.append(AppTest.streamOutput(number: 3, url: ""))
        let (model, sent) = detachedModel(show.makeState())
        XCTAssertTrue(model.canStartStream(2))
        XCTAssertFalse(model.canStartStream(3), "没有地址不能开")
        model.setStreamRunning(2, on: true)
        model.setStreamRunning(3, on: true)
        XCTAssertEqual(sent.list, [.startStream(output: 2)])
        sent.list.removeAll()
        model.startAllStreams()
        XCTAssertEqual(sent.list, [.startStream(output: 2)], "全部开始：有地址、没开的")
        sent.list.removeAll()

        // 2 号在推：状态行 = 状态 · 码率 · 丢帧 · 重连（读 Stats.encoder 里 output = 2 的那一项）
        var state = model.state
        state.outputs[1].enabled = true
        model.apply(state: state)
        model.apply(stats: stats([Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 18_000_000, state: "idle"),
                                  Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 5_900_000, frames: 600, dropped: 3, reconnects: 1, state: "publishing")]))
        XCTAssertEqual(model.streamStatusLine(output: 2), "推流中 · 5.9 Mb/s · 丢 3 帧 · 重连 1 次")
        XCTAssertEqual(model.streamStatusLine(output: 3), "未开")
        model.startAllStreams()
        XCTAssertEqual(sent.list, [], "开着的不再发")

        // 停：先问（挂到 ConfirmationCenter 的那一问），答"停"才发
        var asked: [(ConfirmationCenter.Kind, [Int])] = []
        var pending: (@MainActor () -> Void)?
        model.confirmStop = { kind, routes, perform in asked.append((kind, routes.map(\.number))); pending = perform }
        model.stopAllStreams()
        XCTAssertEqual(asked.map(\.0), [.stopStream])
        XCTAssertEqual(asked.map(\.1), [[2]])
        XCTAssertEqual(sent.list, [], "答之前不停")
        pending?()
        XCTAssertEqual(sent.list, [.stopStream(output: 2)])
        sent.list.removeAll()
        model.setStreamRunning(2, on: false)
        XCTAssertEqual(asked.count, 2, "段首开关关掉也先问")
        pending?()
        XCTAssertEqual(sent.list, [.stopStream(output: 2)])

        // 合计上行：每个目的地各自编码（6 Mb/s + 160k）× 2
        XCTAssertEqual(model.totalUplinkBps, 2 * (6_000_000 + 160_000))
        XCTAssertEqual(model.totalUplinkText, "合计上行约 12.3 Mb/s（2 个目的地）")
        // 在推的路锁住（W5-B / L12）：编码、服务、鉴权都不改
        sent.list.removeAll()
        model.applyStreamQuality(2, id: "720p")
        model.applyStreamService(2, id: "youtube")
        XCTAssertNotNil(model.setStreamAuth(2, user: "u", password: "p"))
        XCTAssertEqual(sent.list, [], "在推的路锁住")
    }

    // MARK: - 推流：鉴权（L10，G6 追加）

    /// "鉴权…"写回地址的 userinfo：URLComponents 的 setter 只转义一次，读回用推流包的 StreamDestination.credentials；地址框里打码；SRT 写 passphrase。
    func testPanels_L10_streamAuthWritesUserinfoOnceAndMasksAddress() throws {
        var show = ShowDocuments.emptyShow()
        show.outputs.append(AppTest.streamOutput(number: 2, url: "rtmp://live.example.com/app"))
        show.outputs.append(AppTest.streamOutput(number: 3, url: "srt://127.0.0.1:9000?streamid=publish:s1&latency=200"))
        let (model, sent) = detachedModel(show.makeState())
        XCTAssertNil(model.streamCredentials(2))

        XCTAssertNil(model.setStreamAuth(2, user: "op@x", password: "p@ss:w rd%"))
        let url = try XCTUnwrap(model.state.output(2)?.settings.stream?.url)
        XCTAssertTrue(url.hasPrefix("rtmp://op%40x:"), url)
        XCTAssertFalse(url.contains("%25%"), "只转义一次：\(url)")
        let creds = try XCTUnwrap(try StreamDestination(settings: StreamSettings(url: url)).credentials, "连接层读得到账号")
        XCTAssertEqual(creds.user, "op@x")
        XCTAssertEqual(creds.password, "p@ss:w rd%")
        XCTAssertEqual(model.streamCredentials(2), creds)
        XCTAssertEqual(sent.list.count, 1)
        // 再写一遍同样的值：地址不变（不会越转越长）
        XCTAssertNil(model.setStreamAuth(2, user: "op@x", password: "p@ss:w rd%"))
        XCTAssertEqual(model.state.output(2)?.settings.stream?.url, url)
        XCTAssertEqual(sent.list.count, 1, "没变不发")

        // 地址框打码；编辑时打码段原样留着 = 换回原来的账号
        let masked = model.maskedStreamURL(2)
        XCTAssertEqual(masked, "rtmp://•••@live.example.com/app")
        XCTAssertEqual(StreamAddress.unmasked("rtmp://•••@live.example.com/app2", original: url), url.replacingOccurrences(of: "/app", with: "/app2"))
        XCTAssertEqual(StreamAddress.unmasked("rtmp://live.example.com/app", original: url), "rtmp://live.example.com/app", "用户把打码段删了 = 去掉账号")
        XCTAssertEqual(StreamAddress.unmasked("rtmp://•••@h/app", original: "rtmp://h/app"), "rtmp://h/app", "原来没账号：去掉记号")
        XCTAssertEqual(StreamAddress.masked("rtmp://h/app?user=a"), "rtmp://h/app?user=•••", "查询串里的不当 userinfo；值照名单打码（2026-10-10 裁定 ①，W5-N 起）")

        // 清掉
        XCTAssertNil(model.setStreamAuth(2, user: "", password: ""))
        XCTAssertEqual(model.state.output(2)?.settings.stream?.url, "rtmp://live.example.com/app")
        XCTAssertNil(model.streamCredentials(2))

        // SRT：passphrase 只收字母数字和 - . _ ~、10–79 个字符；别的查询项原样
        XCTAssertNotNil(model.setStreamAuth(3, user: "", password: "bad pass&1=2"), "有空格 / & / = 不收")
        XCTAssertNotNil(model.setStreamAuth(3, user: "", password: "short"), "太短不收")
        XCTAssertNil(model.setStreamAuth(3, user: "", password: "Abc-123_x.~yz"))
        let srt = try XCTUnwrap(model.state.output(3)?.settings.stream?.url)
        XCTAssertTrue(srt.contains("passphrase=Abc-123_x.~yz"), srt)
        XCTAssertTrue(srt.contains("streamid=publish:s1") && srt.contains("latency=200"), "别的查询项原样：\(srt)")
        XCTAssertEqual(StreamAddress.srtPassphrase(of: srt), "Abc-123_x.~yz")
        // RTMP 的账号写不到 SRT 地址上、坏地址先报错
        XCTAssertThrowsError(try StreamAddress.withCredentials(srt, user: "u", password: "p"))
        XCTAssertThrowsError(try StreamAddress.withCredentials("not a url", user: "u", password: "p"))
    }

    // MARK: - 外部显示：每块屏单选（M2 / M5，与底栏菜单同一份数据）

    func testPanels_M5_externalPagePerScreenSingleSelect() throws {
        var show = ShowDocuments.emptyShow()
        show.inputs = [AppTest.syntheticConfig(number: 1)]
        // 老节目：同一块屏上叠了两路（W5-F 起不再叠）
        show.outputs.append(OutputState(number: 2, kind: .externalDisplay, name: "旧 1", enabled: true,
                                        settings: OutputSettings(source: .program, display: DisplayOutputSettings(displayID: 7))))
        show.outputs.append(OutputState(number: 3, kind: .externalDisplay, name: "旧 2", enabled: true,
                                        settings: OutputSettings(source: .preview, display: DisplayOutputSettings(displayID: 7))))
        let (model, sent) = detachedModel(show.makeState(), tab: .external)
        let main = DisplayInfo(id: 1, name: "内建", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true, maximumFramesPerSecond: 120, backingScaleFactor: 2)
        let second = DisplayInfo(id: 7, name: "投影", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), isMain: false, maximumFramesPerSecond: 60, backingScaleFactor: 1)
        model.displays = { [main, second] }
        XCTAssertEqual(model.screenRows.map(\.id), [1, 7])
        XCTAssertNil(model.screenRows[0].source, "主屏没配 = 关闭")
        XCTAssertEqual(model.screenRows[1].source, .program, "那一路 = 开着的里编号最小的")
        XCTAssertEqual(model.screenRows[1].output, 2)

        // 第二块屏选 PVW：同一路换源（窗口不重开），同屏别的路关掉——与底栏菜单同一套命令
        model.pickScreen(7, source: .preview)
        XCTAssertEqual(sent.list, ExternalDisplayRouting.pick(display: second, source: .preview, in: show.makeState()))
        XCTAssertEqual(sent.list.first, .setOutputSettings(output: 2, settings: OutputSettings(source: .preview, display: DisplayOutputSettings(displayID: 7))))
        XCTAssertTrue(sent.list.contains(.setOutputEnabled(output: 3, on: false)), "同屏不叠：\(sent.list)")
        XCTAssertEqual(model.screenRows[1].source, .preview, "本地先改")
        // 关闭：开着的都关，配置留着
        sent.list.removeAll()
        model.pickScreen(7, source: nil)
        XCTAssertEqual(sent.list, [.setOutputEnabled(output: 2, on: false)])
        XCTAssertNil(model.screenRows[1].source)
        XCTAssertNotNil(model.state.output(2), "关闭不删")
        // 主屏选输入 1：没有那一路 = 加一路（名字"显示器 · 源"）
        sent.list.removeAll()
        model.pickScreen(1, source: .input(number: 1))
        guard case .addOutput(let config)? = sent.list.first else { return XCTFail("应加一路：\(sent.list)") }
        XCTAssertEqual(config.kind, .externalDisplay)
        XCTAssertEqual(config.settings.display?.displayID, 1)
        XCTAssertEqual(config.settings.source, .input(number: 1))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.name, L("externalMenu.outputName", "内建", OutputSource.input(number: 1).title(in: model.state)))
    }

    // MARK: - 多画面：格子编辑（M7）

    func testPanels_M7_multiviewCellEditor() throws {
        var show = ShowDocuments.emptyShow()
        show.inputs = [AppTest.syntheticConfig(number: 1), AppTest.syntheticConfig(number: 2)]
        let (model, sent) = detachedModel(show.makeState(), tab: .multiview)
        XCTAssertEqual(model.multiviewCellSources, [.program, .preview, .input(number: 1), .input(number: 2)], "格子不能套多画面自己")
        // 从当前预设转成自定义：格子 = 预设的摆法（PVW / PGM + 每路输入）
        model.convertMultiviewPresetToCustom()
        guard case .addOutput(let config)? = sent.list.last else { return XCTFail("没有多画面输出时先加一个承载布局的：\(sent.list)") }
        let cells = try XCTUnwrap(config.settings.multiview?.custom)
        XCTAssertEqual(Set(cells.map(\.source)), [.program, .preview, .input(number: 1), .input(number: 2)])
        XCTAssertTrue(cells.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 && $0.rect.x >= 0 && $0.rect.x + $0.rect.width <= 1.0001 })
        // 改来源、改位置（钳到 0–1）、加、删
        model.setMultiviewCell(at: 0, source: .input(number: 2))
        model.setMultiviewCell(at: 0, x: 0.1, y: -0.5, width: 0.4, height: 2)
        var layout = model.multiviewLayout
        XCTAssertEqual(layout.custom[0].source, .input(number: 2))
        XCTAssertEqual(layout.custom[0].rect, NormalizedRect(x: 0.1, y: 0, width: 0.4, height: 1))
        model.addMultiviewCell()
        XCTAssertEqual(model.multiviewLayout.custom.count, cells.count + 1)
        model.removeMultiviewCell(at: 0)
        layout = model.multiviewLayout
        XCTAssertEqual(layout.custom.count, cells.count)
        guard case .setOutputSettings(_, let last)? = sent.list.last else { return XCTFail("改格子走 setOutputSettings：\(sent.list)") }
        XCTAssertEqual(last.multiview, layout)
        model.clearMultiviewCustomCells()
        XCTAssertEqual(model.multiviewLayout.custom, [])
    }

    // MARK: - 新建录制的默认值（K8 / Q30）

    func testPanels_K8_newRecordDefaultsFollowProgramFormat() {
        XCTAssertEqual(RecordDefaults.videoBitrateBps(for: .hd1080p30), 10_000_000)
        XCTAssertEqual(RecordDefaults.videoBitrateBps(for: .hd1080p60), 18_000_000)
        XCTAssertEqual(RecordDefaults.videoBitrateBps(for: .hd1080p5994), 18_000_000, "59.94 按 60 档")
        XCTAssertEqual(RecordDefaults.videoBitrateBps(for: ProgramFormat(width: 2560, height: 1440, frameRate: .fps60)), 32_000_000)
        XCTAssertEqual(RecordDefaults.videoBitrateBps(for: .uhd2160p30), 36_000_000)
        XCTAssertEqual(RecordDefaults.videoBitrateBps(for: .hd720p60), 8_000_000, "其余按 0.15 bit / 像素 / 帧")
        XCTAssertEqual(RecordDefaults.audio(), AudioEncodeSettings(codec: .aac, bitrateBps: 256_000))
        let show = ShowDocuments.emptyShow()
        XCTAssertEqual(show.outputs[0].settings.video?.bitrateBps, 18_000_000, "空节目（1080p60）的录制输出")
        XCTAssertEqual(show.outputs[0].settings.audio?.bitrateBps, 256_000)
        XCTAssertEqual(VideoEncodeSettings().bitrateBps, 6_000_000, "契约默认值不动")
        // 720p 节目里新加的录制输出
        var s = ShowDocuments.emptyShow()
        s.mixer.format = .hd720p60
        let (model, sent) = detachedModel(s.makeState(), tab: .record)
        let n = model.addRecordOutput()
        guard case .addOutput(let config)? = sent.list.first else { return XCTFail("\(sent.list)") }
        XCTAssertEqual(config.number, n)
        XCTAssertEqual(config.settings.video?.bitrateBps, 8_000_000)
        XCTAssertEqual(model.keyframeText(1), "2 s（= 120 帧）")
    }
}
