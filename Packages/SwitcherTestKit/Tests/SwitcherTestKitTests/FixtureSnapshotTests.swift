import XCTest
import Foundation
import SwitcherContracts
@testable import SwitcherTestKit

/// frameprobe 对 Tests/Fixtures/w1a-sample-20s.mov 的输出做快照（prompt "测试"第 5 条）。
/// 样例：1080p60 20 s，A（ID 0，灰 64，60 fps）→ 第 400 拍 Cut 到 B（ID 1，灰 192，30 fps）→ 第 700 拍 Fade 30 拍回 A；
/// AAC 音轨，click 与闪光同刻。快照 `w1a-sample-20s.expected.json`：整数字段精确比，灰度 ±1.5、时间 ±0.1 ms（不同 OS 的解码器可能差 1 个电平）。
/// 重录快照：W1A_RECORD_SNAPSHOT=1 swift test --filter FixtureSnapshotTests
final class FixtureSnapshotTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixture = repoRoot.appendingPathComponent("Tests/Fixtures/w1a-sample-20s.mov")
    static let expected = repoRoot.appendingPathComponent("Tests/Fixtures/w1a-sample-20s.expected.json")

    struct Snapshot: Codable {
        var info: ProbeVideoInfo
        var audio: ProbeAudioInfo?
        var frameCount: Int
        var framesHead: [ProbeFrame]
        var framesAroundCut: [ProbeFrame]
        var framesAroundFade: [ProbeFrame]
        var stats: FrameAnalysis.StatsReport
        var switches: FrameAnalysis.SwitchesReport
        var fade: FrameAnalysis.FadeReport
        var fadeAuto: FrameAnalysis.FadeReport
        var av: FrameAnalysis.AVReport
        var avMulti: FrameAnalysis.MultiFileAVReport
    }

    /// 两个测试共用一次读取（debug 下解 1200 帧 1080p 要 12 s）。
    static let cached = Task { try await capture() }

    static func capture() async throws -> Snapshot {
        var o = FrameProbe.Options()
        o.inputFps = [0: 60, 1: 30]
        let l = try await FrameProbe.load(fixture, options: o, withAudio: true)
        var fadeOptions = o
        fadeOptions.fadeAt = 700
        fadeOptions.fadeDuration = 30
        let multi = FrameAnalysis.avMulti(files: [("a", l.frames, l.clicks), ("b", l.frames, l.clicks)], frameDurationSeconds: 1 / 60)
        return Snapshot(
            info: l.info, audio: l.audio, frameCount: l.frames.count,
            framesHead: Array(l.frames.prefix(130)),
            framesAroundCut: Array(l.frames[395...405]),
            framesAroundFade: Array(l.frames[698...732]),
            stats: FrameAnalysis.stats(frames: l.frames, programFps: l.fps, inputFps: o.inputFps),
            switches: FrameAnalysis.switches(frames: l.frames, startTick: 0, grayTolerance: o.grayTolerance),
            fade: FrameAnalysis.fade(frames: l.frames, durationTicks: 30, at: 700),
            fadeAuto: FrameAnalysis.fade(frames: l.frames),
            av: FrameAnalysis.av(frames: l.frames, clicks: l.clicks, frameDurationSeconds: 1 / 60),
            avMulti: multi)
    }

    func testW1A_frameprobe_fixtureSnapshot() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path), "样例不存在：\(Self.fixture.path)")
        let actual = try await Self.cached.value
        if ProcessInfo.processInfo.environment["W1A_RECORD_SNAPSHOT"] == "1" || !FileManager.default.fileExists(atPath: Self.expected.path) {
            try ProbeJSON.encoder.encode(actual).write(to: Self.expected)
            XCTFail("已重录快照到 \(Self.expected.path)，再跑一次")
            return
        }
        let expected = try ProbeJSON.decoder.decode(Snapshot.self, from: Data(contentsOf: Self.expected))
        compare(expected, actual)
    }

    /// 样例本身的硬性事实（不靠快照文件也要成立）。
    func testW1A_fixture_factsMatchSpec() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixture.path), "样例不存在")
        let s = try await Self.cached.value
        XCTAssertEqual(s.frameCount, 1200); XCTAssertEqual(s.info.width, 1920); XCTAssertEqual(s.info.height, 1080)
        XCTAssertEqual(s.info.nominalFps, 60, accuracy: 0.01)
        XCTAssertLessThan((try FileManager.default.attributesOfItem(atPath: Self.fixture.path)[.size] as! Int), 5 * 1024 * 1024)
        // V5
        XCTAssertEqual(s.stats.frameCountDelta, 0)
        // V4：A 无重复无丢弃；B 50% 重复全是设计内
        let a = s.stats.inputs.first { $0.inputID == 0 }!, b = s.stats.inputs.first { $0.inputID == 1 }!
        XCTAssertEqual(a.droppedFrames, 0); XCTAssertEqual(a.duplicateFrames, 0); XCTAssertEqual(a.passV4, true)
        XCTAssertEqual(b.designDuplicateRatio!, 0.5); XCTAssertLessThan(b.excessDuplicateRatio!, 0.0005); XCTAssertEqual(b.passV4, true)
        XCTAssertEqual(b.droppedFrames, 0)
        // V6：第 400 拍干净 Cut；Fade 的新 ID 在 728 左右出现
        let cut = s.switches.switches.first { $0.kind == "cut" }!
        XCTAssertEqual(cut.index, 400); XCTAssertEqual(cut.from, 0); XCTAssertEqual(cut.to, 1); XCTAssertTrue(cut.cleanCut)
        XCTAssertTrue(s.switches.allCutsClean)
        // V7：指定模式 29 个混合帧、最大偏差 ≤ 1 帧；自动模式也找到同一段
        XCTAssertEqual(s.fade.fades.count, 1)
        XCTAssertEqual(s.fade.fades[0].startIndex, 701); XCTAssertEqual(s.fade.fades[0].endIndex, 729); XCTAssertEqual(s.fade.fades[0].direction, "B→A")
        XCTAssertLessThanOrEqual(s.fade.fades[0].maxDeviationFrames, 1); XCTAssertTrue(s.fade.fades[0].monotonic); XCTAssertTrue(s.fade.allPassV7)
        XCTAssertEqual(s.fadeAuto.fades.count, 1); XCTAssertEqual(s.fadeAuto.fades[0].startIndex, 701); XCTAssertEqual(s.fadeAuto.fades[0].durationTicks, 30)
        // A2 / A3：20 个闪光 20 个 click 全配上，经 AAC 仍 |偏移| < 0.5 ms，无漂移
        XCTAssertEqual(s.av.flashCount, 20); XCTAssertEqual(s.av.clickCount, 20); XCTAssertEqual(s.av.matchedCount, 20)
        XCTAssertLessThan(s.av.maxAbsMs, 0.5); XCTAssertLessThan(abs(s.av.driftOverSpanMs), 0.5); XCTAssertEqual(s.av.passA2, true)
        // A4：同一文件两份 → 极差 0
        XCTAssertEqual(s.avMulti.events.count, 20); XCTAssertEqual(s.avMulti.maxFlashSpreadMs, 0); XCTAssertEqual(s.avMulti.passA4, true)
        // 闪光帧：0, 60, …；B 段（400–699）里闪光帧因 30 fps 源连着两帧
        XCTAssertEqual(s.framesHead.filter(\.flash).map(\.index), [0, 60, 120])
        XCTAssertEqual(s.framesAroundCut.map(\.inputID), [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(s.framesAroundCut.map { $0.frameNumber! }, [395, 396, 397, 398, 399, 200, 200, 201, 201, 202, 202])
    }

    private func compare(_ e: Snapshot, _ a: Snapshot) {
        XCTAssertEqual(e.info, a.info); XCTAssertEqual(e.audio, a.audio); XCTAssertEqual(e.frameCount, a.frameCount)
        compare(e.framesHead, a.framesHead, "head"); compare(e.framesAroundCut, a.framesAroundCut, "cut"); compare(e.framesAroundFade, a.framesAroundFade, "fade")
        XCTAssertEqual(e.stats, a.stats, "stats 全是整数派生量，精确比")
        XCTAssertEqual(e.switches.switches, a.switches.switches); XCTAssertEqual(e.switches.allCutsClean, a.switches.allCutsClean)
        for (x, y) in zip(e.switches.nominalGrays, a.switches.nominalGrays) { XCTAssertEqual(x.inputID, y.inputID); XCTAssertEqual(x.gray, y.gray, accuracy: 1.5) }
        compare(e.fade, a.fade, "fade"); compare(e.fade, a.fadeAuto, "fadeAuto", other: e.fadeAuto)
        XCTAssertEqual(e.av.flashCount, a.av.flashCount); XCTAssertEqual(e.av.clickCount, a.av.clickCount); XCTAssertEqual(e.av.matchedCount, a.av.matchedCount)
        XCTAssertEqual(e.av.meanMs, a.av.meanMs, accuracy: 0.1); XCTAssertEqual(e.av.maxAbsMs, a.av.maxAbsMs, accuracy: 0.1); XCTAssertEqual(e.av.passA2, a.av.passA2)
        for (x, y) in zip(e.av.pairs, a.av.pairs) {
            XCTAssertEqual(x.flashIndex, y.flashIndex); XCTAssertEqual(x.genTimeMs, y.genTimeMs)
            XCTAssertEqual(x.clickTimeSeconds ?? -1, y.clickTimeSeconds ?? -1, accuracy: 1e-4); XCTAssertEqual(x.offsetMs ?? 0, y.offsetMs ?? 0, accuracy: 0.1)
        }
        XCTAssertEqual(e.avMulti.events.map(\.key), a.avMulti.events.map(\.key)); XCTAssertEqual(e.avMulti.passA4, a.avMulti.passA4)
    }

    private func compare(_ e: [ProbeFrame], _ a: [ProbeFrame], _ label: String) {
        XCTAssertEqual(e.count, a.count, label)
        for (x, y) in zip(e, a) {
            XCTAssertEqual(x.index, y.index, label); XCTAssertEqual(x.frameNumber, y.frameNumber, "\(label) #\(x.index)"); XCTAssertEqual(x.inputID, y.inputID, "\(label) #\(x.index)")
            XCTAssertEqual(x.genTimeMs, y.genTimeMs, "\(label) #\(x.index)"); XCTAssertEqual(x.flash, y.flash, "\(label) #\(x.index)")
            XCTAssertEqual(x.ptsSeconds, y.ptsSeconds, accuracy: 1e-6, label); XCTAssertEqual(x.gray, y.gray, accuracy: 1.5, "\(label) #\(x.index)")
        }
    }

    private func compare(_ e: FrameAnalysis.FadeReport, _ a: FrameAnalysis.FadeReport, _ label: String, other: FrameAnalysis.FadeReport? = nil) {
        let e = other ?? e
        XCTAssertEqual(e.fades.count, a.fades.count, label); XCTAssertEqual(e.allPassV7, a.allPassV7, label)
        for (x, y) in zip(e.fades, a.fades) {
            XCTAssertEqual(x.startIndex, y.startIndex, label); XCTAssertEqual(x.endIndex, y.endIndex, label); XCTAssertEqual(x.direction, y.direction, label)
            XCTAssertEqual(x.durationTicks, y.durationTicks, label); XCTAssertEqual(x.maxDeviationFrames, y.maxDeviationFrames, accuracy: 0.05, label)
            XCTAssertEqual(x.passV7, y.passV7, label); XCTAssertEqual(x.samples.count, y.samples.count, label)
            for (p, q) in zip(x.samples, y.samples) { XCTAssertEqual(p.gray, q.gray, accuracy: 1.5, label); XCTAssertEqual(p.deviationFrames, q.deviationFrames, accuracy: 0.05, label) }
        }
    }
}
