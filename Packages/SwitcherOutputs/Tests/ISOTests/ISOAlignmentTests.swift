import Darwin
import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
@testable import SwitcherISO

/// A4 多文件对齐：4 路输入各自的视频 ISO（经 InputFrameTee → ISOFrameTap → Recorder）+ PGM，同一拍启动、共用起点，
/// 每路自己的画面（闪光）和自己的 click；frameprobe av 多文件比同一事件在各文件里的时刻。阈值 ≤ 1 帧（16.67 ms），目标 ≤ 1 ms。
/// 第 4 路是 30 fps 输入（只在偶数拍出帧），文件里同一帧录两次，帧数仍与其他路相同。
final class ISOAlignmentTests: XCTestCase {
    func testA4_fourVideoISORoutesPlusPGM_sameEventWithin1Frame() throws {
        try Tools.requireFFprobe()
        let frameprobe = try Tools.frameprobe()
        let format = ProgramFormat.hd720p60   // 5 路 H.264 = 300 fps；720p 让硬件编码器留有余量（W1-E2 报告 §5：1080p 吞吐约 240–300 fps）
        let fps = 60
        let seconds = 10
        let ticks = seconds * fps
        let halfFrame = HostDuration(seconds: format.frameDuration.doubleValue / 2)

        // 每路自己的图案（输入 ID = 编号）；先建喂料器再定 t0（预生成要时间）
        let inputFeeders = try (1...4).map { n in try PatternFeeder(configuration: .init(format: format, inputID: n, texture: .flat)) }
        let pgmFeeder = try PatternFeeder(configuration: .init(format: format, inputID: 0, texture: .flat))
        let t0 = HostClock.now() + HostDuration(milliseconds: 400)
        let clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        let signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: format.frameRate))

        // 5 个录制器：PGM + 4 路 ISO；每个自己的音频喂料（同一个 TestSignal：click 在 t0 + k s）
        func recorder(_ name: String) -> Recorder {
            Recorder(configuration: .init(url: TestPaths.file("a4-\(name).mov"), format: format,
                                          video: VideoEncodeSettings(codec: .h264, bitrateBps: 4_000_000), audio: AudioEncodeSettings(codec: .pcm),
                                          name: name))
        }
        let pgm = recorder("pgm")
        let iso = (1...4).map { recorder("iso\($0)") }
        let recorders = [pgm] + iso
        let signalFeeders = recorders.map { _ in SignalFeeder(signal: signal) }
        let tees = (1...4).map { _ in InputFrameTee(primary: LockFreeFrameSlot(capacity: 3)) }
        let taps = try (0..<4).map { i in ISOFrameTap(inputNumber: i + 1, branch: try XCTUnwrap(tees[i].addBranch()), sink: iso[i]) }
        let consumers: [any FrameConsumer] = [pgm] + taps

        let start = RecordingStart(clock: clock, tick: .zero)
        for r in recorders { try r.start(at: start) }

        // 实时喂：每拍先把各路输入的帧 push 进各自的 tee（pts = 拍点 − 半帧，App 里合成源就是这么提前的；第 4 路只在偶数拍出帧），
        // 再派发 PGM 帧给 [PGM 录制器 + 4 个 tap]，最后喂各路音频到拍点
        var late = 0
        var inputSequence = [UInt64](repeating: 0, count: 4)
        for tick in 0..<ticks {
            let t = Tick(Int64(tick))
            let tickTime = clock.time(of: t)
            mach_wait_until(tickTime.ticks)
            if HostClock.now() - tickTime > format.frameDuration.hostDuration { late += 1 }
            for i in 0..<4 {
                if i == 3 && tick % 2 == 1 { continue }
                let rendered = try inputFeeders[i].makeFrame(tick: t, tickTime: tickTime)
                inputSequence[i] += 1
                let f = Frame(pixelBuffer: rendered.program.pixelBuffer, pts: tickTime - halfFrame, duration: rendered.program.duration,
                              color: .bt709Limited, inputNumber: i + 1, sequence: inputSequence[i], ingressTime: HostClock.now())
                tees[i].push(f)
            }
            let frame = try pgmFeeder.makeFrame(tick: t, tickTime: tickTime)
            for c in consumers { c.consume(frame) }
            for (i, r) in recorders.enumerated() { signalFeeders[i].feed(upTo: tickTime, to: [r]) }
        }
        let end = Tick(Int64(ticks))
        let endSample = signal.sampleIndex(at: clock.time(of: end))
        for (i, r) in recorders.enumerated() { signalFeeders[i].flush(upToSample: endSample, to: [r]) }
        var results: [RecordingResult] = []
        for r in recorders { results.append(try stopAndWait(r, atTick: end)) }

        // 各文件：帧数相同 = 拍数、第一帧 PTS 相同、无跳帧、ffprobe 无错
        var firstPTS: [Double] = []
        for (i, res) in results.enumerated() {
            let probe = try Tools.probe(res.url)
            XCTAssertEqual(probe.errors, "", "文件 \(i) 有错")
            XCTAssertEqual(Int(res.videoFrames), ticks, "第 \(i) 个文件帧数")
            XCTAssertEqual(res.encoder.skipped, 0, "第 \(i) 个文件跳帧")
            firstPTS.append(try Tools.firstVideoPTS(res.url) ?? -1)
            print("A4 文件 \(res.url.lastPathComponent)：\(res.videoFrames) 帧 / \(res.audioFrames) 样本，首帧 PTS \(firstPTS[i])，跳帧 \(res.encoder.skipped)，编码延迟 max \(String(format: "%.1f", res.encoder.maxLatency.milliseconds)) ms")
        }
        XCTAssertEqual(Set(firstPTS).count, 1, "各文件第一帧 PTS 必须相同：\(firstPTS)")
        XCTAssertEqual(firstPTS.first, 0)
        let c4 = taps[3].counters
        XCTAssertEqual(c4.forwarded, UInt64(ticks), "30 fps 那一路每拍都有输出（重复上一帧）")
        XCTAssertEqual(c4.repeated, UInt64(ticks / 2), "30 fps 那一路一半的拍是重复帧")
        XCTAssertEqual(taps[0].counters.repeated, 0, "60 fps 的路没有重复")
        for tap in taps { XCTAssertEqual(tap.counters.noFrame, 0, "第 0 拍前各路就有帧") }

        // frameprobe av 多文件：同一事件（闪光 / click）在 5 个文件里的时刻极差
        let jsonURL = TestPaths.file("a4-multi.json")
        let o = try Tools.run(frameprobe.path, ["av"] + results.map(\.url.path) + ["--fps", "\(fps)", "--out", jsonURL.path, "--markdown"])
        guard o.code == 0, let data = try? Data(contentsOf: jsonURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("frameprobe av 失败：\(o.stderr.prefix(800))\n\(String(decoding: o.stdout, as: UTF8.self).prefix(800))")
            return
        }
        let multi = (obj["multi"] as? [String: Any]) ?? obj
        let maxFlash = multi["maxFlashSpreadMs"] as? Double ?? -1
        let maxClick = multi["maxClickSpreadMs"] as? Double ?? -1
        let events = (multi["events"] as? [[String: Any]])?.count ?? 0
        let thresholdMs = 1000.0 / Double(fps)
        print(String(decoding: o.stdout, as: UTF8.self))
        print("A4：\(events) 个事件，闪光极差最大 \(maxFlash) ms，click 极差最大 \(maxClick) ms；阈值 ≤ \(String(format: "%.2f", thresholdMs)) ms（必须），≤ 1 ms（目标）；喂帧晚点 \(late) 次")
        XCTAssertGreaterThanOrEqual(events, seconds - 2, "10 s 应有约 10 个整秒事件")
        XCTAssertGreaterThanOrEqual(maxFlash, 0)
        XCTAssertGreaterThanOrEqual(maxClick, 0)
        XCTAssertLessThanOrEqual(maxFlash, thresholdMs, "A4 必须：闪光时刻极差 ≤ 1 帧")
        XCTAssertLessThanOrEqual(maxClick, thresholdMs, "A4 必须：click 时刻极差 ≤ 1 帧")
        XCTAssertEqual(multi["passA4"] as? Bool, true, "A4：判定事件里没有文件缺 click / 闪光（frameprobe passA4；G10 胶水 ④）")
        if maxFlash <= 1 && maxClick <= 1 { print("A4 目标（≤ 1 ms）也达到") } else { print("A4 目标（≤ 1 ms）未达到") }
    }
}

private extension Rational {
    /// 有理数秒 → HostDuration。
    var hostDuration: HostDuration { HostDuration(seconds: doubleValue) }
}
