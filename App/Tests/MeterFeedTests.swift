// W3-E3 交付第 4 条：电平表。
// - 多画面电平表 50 ms 喂一次：主线程每 50 ms 读一次 AudioEngineStatus（音频控制循环 50 ms 刷新的那一份，调音台 / 纯音频缩略图读的就是它），
//   拼成 Stats.AudioCounters.Meters（含提案 017 的 rmsDb）调 renderer.setMeters，替掉 G4 检查点的 1 Hz。
//   渲染线程零分配由渲染器自己的用例保证（W3-B2 / 017），这里只验调用频率与线程，再读回多画面纹理确认表真的画出来了。
// - 调音台 MeterBar：RMS 实心条 + 峰值细线；颜色分段 −18 黄 / −6 红（设计方案 §7，2026-09-24）；没有 RMS 的读数退回峰值实心条。
import AppKit
import SwiftUI
import XCTest
import SwitcherContracts
import SwitcherRender
import SwitcherAudioIntegration
@testable import Switcher

@MainActor
final class MeterFeedTests: XCTestCase {
    func testMeters_rendererFedEvery50msOnMainThreadFromMixerStatus() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))   // 1 kHz −20 dBFS + 每秒一个 click
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        let feed = session.meterFeed
        XCTAssertEqual(AudioMeterFeed.interval, 0.05, "与 AudioEngine.statusInterval（50 ms）一样")
        XCTAssertTrue(AppTest.waitUntil(8) { (feed.lastFedMeters?.inputs[1]?.peakDb.max() ?? -200) > -40 },
                      "1 号有电平后喂出去的表里应有它：\(String(describing: feed.lastFedMeters?.inputs[1]))")

        // 频率：3 s 里约 60 次（同一份快照不重复喂，音频控制循环与主线程的 50 ms 相位漂移时偶尔少一次）
        let n0 = feed.feeds
        let t0 = Date()
        AppTest.pump(seconds: 3)
        let elapsed = Date().timeIntervalSince(t0)
        let rate = Double(feed.feeds - n0) / elapsed
        print(String(format: "多画面电平表喂数：%.2f s 喂 %d 次（%.1f Hz），不在主线程的 %d 次；Stats 1 Hz 的那条已撤", elapsed, Int(feed.feeds - n0), rate, Int(feed.offMainThreadFeeds)))
        XCTAssertGreaterThanOrEqual(rate, 15, "≈ 20 Hz（50 ms 一次），不是 1 Hz")
        XCTAssertLessThanOrEqual(rate, 21)
        XCTAssertEqual(feed.offMainThreadFeeds, 0, "setMeters 只在主线程调（非实时线程；它分配、拿锁，不许进音频回调 / 渲染线程）")

        // 同一份：喂出去的 = 这一拍调音台拿到的 AudioEngineStatus 拼的，带 017 的 rmsDb
        let status = try XCTUnwrap(feed.lastStatus)
        let fed = try XCTUnwrap(feed.lastFedMeters)
        XCTAssertEqual(fed, AudioMeterFeed.meters(from: status))
        let input1 = try XCTUnwrap(status.inputs.first { $0.number == 1 })
        XCTAssertEqual(fed.inputs[1]?.peakDb, input1.peakDb)
        XCTAssertEqual(fed.inputs[1]?.rmsDb, input1.rmsDb, "带 017 的 rmsDb")
        let rms = try XCTUnwrap(fed.inputs[1]?.rmsDb.max()), peak = try XCTUnwrap(fed.inputs[1]?.peakDb.max())
        XCTAssertLessThan(rms, peak, "正弦的 RMS 比峰值低约 3 dB：RMS \(rms) / 峰值 \(peak)")
        let master = try XCTUnwrap(fed.buses.first { $0.bus == Bus.master.name }, "PGM 格读 master 总线")
        XCTAssertFalse(master.rmsDb.isEmpty)
        let wc = AppTest.controller.windowController
        XCTAssertEqual(wc.mixerPanel.meters.inputPeakDb[1], input1.peakDb, "调音台条子读的是同一份")
        XCTAssertEqual(wc.mixerPanel.meters.inputRmsDb[1], input1.rmsDb)

        // 渲染器真的收到了：多画面布局开电平表，1 号格子右侧的表条在 RMS 实心段里是绿的（没有读数时是 70% 黑的占位）
        let page = AppTest.controller.panels.showOutputSettings(tab: .multiview).model
        page.setMultiviewMeters(true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.first { $0.kind == .multiview }?.settings.multiview?.meters == true })
        AppTest.pump(seconds: 0.3)
        func meterPixel() throws -> (b: Int, g: Int, r: Int) {
            let rb = try XCTUnwrap(AppTest.readback(session, target: .multiview))
            let placements = MultiviewLayout.placements(settings: MultiviewLayout.layoutSettings(in: session.state), inputs: [1], width: rb.width, height: rb.height)
            let inner = try XCTUnwrap(placements.first { $0.source == .input(number: 1) }?.inner)
            // 表条的位置（与 CompositorPasses.meterStrip 同一个算式）：内框右侧 3% 宽（≥ 4 px），四周留 2 px；左右两个声道各一半
            let iw = inner.width * Double(rb.width), ih = inner.height * Double(rb.height)
            let sw = max(4, (iw * 0.03).rounded())
            let stripX = inner.x * Double(rb.width) + iw - sw - 2, stripBottom = inner.y * Double(rb.height) + ih - 2
            // 左声道、表高 30% 处（RMS −23 dBFS ≈ 62%，峰值 −20 ≈ 67%；刻度线在 1/5…4/5，别采在线上）
            return rb.pixel(x: Int(stripX + sw * 0.25), y: Int(stripBottom - (ih - 4) * 0.3))
        }
        let live = try meterPixel()
        print("多画面 1 号格子表条（喂着）：B\(live.b) G\(live.g) R\(live.r)")
        XCTAssertGreaterThan(live.g, 150, "RMS 实心段应是绿的（渲染器拿到了 50 ms 的表读数）")
        XCTAssertLessThan(live.r, 120)

        // 只有这一个喂数方（检查点 1 Hz 的 Stats 消费者已撤）：停掉它 3 s 以上，渲染器按过期退回占位（1 Hz 那条还在的话表会一直活着）
        feed.stop(clearRenderer: false)
        AppTest.pump(seconds: 3.6)
        let stale = try meterPixel()
        print("多画面 1 号格子表条（停喂 3.6 s）：B\(stale.b) G\(stale.g) R\(stale.r)")
        XCTAssertLessThan(stale.g, 90, "没人喂了应退回 70% 黑的占位")
        feed.start()
        XCTAssertTrue(AppTest.waitUntil(2) { ((try? meterPixel())?.g ?? 0) > 150 }, "接着喂又活过来")
        page.setMultiviewMeters(false)
        AppTest.controller.panels.closeAll()

        // session 停了：显式 setMeters(nil)，定时器停
        let feeds = feed.feeds
        let done = AppTest.expectationBox()
        Task { await AppTest.controller.restartSession(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { done.value && AppTest.controller.session?.isRunning == true })
        XCTAssertTrue(feed.cleared, "停 session 时清掉渲染器里的表（setMeters(nil)）")
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(feed.feeds, feeds, "旧 session 的定时器停了")
    }

    /// MeterBar 的几何与像素：RMS 实心条 + 2 px 峰值细线（颜色按它所在的分段）；没有 RMS 退回峰值实心条、不画细线；静音什么都不画。
    func testMeters_meterBarDrawsRMSBarAndPeakLine() throws {
        let g = MeterBar.levels(peakDb: [-20, -26], rmsDb: [-23, -29])
        XCTAssertEqual(g.bar, 37.0 / 60, accuracy: 1e-9, "实心条 = RMS（L / R 取大）")
        XCTAssertEqual(try XCTUnwrap(g.peakLine), 40.0 / 60, accuracy: 1e-9, "细线 = 峰值")
        let noRMS = MeterBar.levels(peakDb: [-20, -26], rmsDb: [])
        XCTAssertEqual(noRMS.bar, 40.0 / 60, accuracy: 1e-9, "没有 RMS（017 之前的读数）：实心条 = 峰值")
        XCTAssertNil(noRMS.peakLine)
        let silent = MeterBar.levels(peakDb: [-120, -120], rmsDb: [-120, -120])
        XCTAssertEqual(silent.bar, 0)
        XCTAssertNil(silent.peakLine, "静音不画细线")
        XCTAssertEqual(MeterBar.levels(peakDb: nil, rmsDb: nil).bar, 0)

        // 像素：RMS −12 dBFS（0.8，黄区）+ 峰值 −3 dBFS（0.95，红区）
        let h = 120.0
        let image = try Self.render(MeterBar(peakDb: [-3, -3], rmsDb: [-12, -12]).frame(width: 10, height: h))
        func classify(_ fractionFromBottom: Double) throws -> String {
            let y = Int((h * (1 - fractionFromBottom)).rounded(.down))
            let c = try MultiviewLayoutTests.pixel(image, x: 5, y: y)
            if c.1 > c.0 + 40, c.1 > c.2 + 40 { return "green" }
            if c.0 > 150, c.1 > 130, c.2 < 110 { return "yellow" }
            if c.0 > 150, c.1 < 110 { return "red" }
            if abs(c.0 - c.1) < 12, abs(c.1 - c.2) < 12, c.0 < 110 { return "background" }
            return "other\(c)"
        }
        XCTAssertEqual(try classify(0.3), "green", "< −18 dBFS 绿")
        XCTAssertEqual(try classify(0.75), "yellow", "−18…−6 黄（RMS 实心条到 0.8）")
        XCTAssertEqual(try classify(0.87), "background", "RMS 与峰值之间是底色（实心条只到 RMS）")
        XCTAssertEqual(try classify(0.95), "red", "峰值细线在 0.95，红区")
        XCTAssertEqual(try classify(0.98), "background", "细线上面是底色")

        // 没有 RMS：峰值实心条（0.95），中间没有空档
        let peakOnly = try Self.render(MeterBar(peakDb: [-3, -3], rmsDb: []).frame(width: 10, height: h))
        let mid = try MultiviewLayoutTests.pixel(peakOnly, x: 5, y: Int(h * (1 - 0.87)))
        XCTAssertTrue(mid.0 > 150 && mid.1 > 130, "没有 RMS 时实心条到峰值，0.87 处是黄的：\(mid)")
    }

    static func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer 画不出来")
    }
}
