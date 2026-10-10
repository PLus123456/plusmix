import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 027（用户 2026-10-10 批，P5 落地）：新节目四路叠加的默认动画 = 淡入淡出 0.5 s（按节目帧率换成拍），进契约默认值——
/// `OverlayAnimation.defaultFade(for:)` 工厂 + `MixerState.newShow(format:outputs:)`；`OverlayAnimation()` 无参默认仍是 cut 0 拍，老文件照读。
final class Contracts027Tests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testContracts_newShowOverlayDefaultsToHalfSecondFade() throws {
        XCTAssertEqual(OverlayAnimation.defaultFadeSeconds, 0.5)
        // 按帧率换拍：60 → 30、59.94 → 30、30 → 15、29.97 → 15、25 → 13（12.5 四舍五入）、50 → 25、24 → 12
        let expected: [(FrameRate, Int)] = [(.fps60, 30), (.fps5994, 30), (.fps30, 15), (.fps2997, 15), (.fps25, 13), (.fps50, 25), (.fps24, 12)]
        for (rate, ticks) in expected {
            let a = OverlayAnimation.defaultFade(for: ProgramFormat(width: 1920, height: 1080, frameRate: rate))
            XCTAssertEqual(a, OverlayAnimation(kind: .fade, durationTicks: ticks, slideFrom: nil), "\(rate)")
        }
        // 新节目：四路叠加都是 fade 0.5 s，其余与 MixerState(format:) 相同
        let s = MixerState.newShow(format: .hd1080p5994)
        XCTAssertEqual(s.overlays.count, MixerState.overlayCount)
        for o in s.overlays {
            XCTAssertEqual(o.animation, OverlayAnimation(kind: .fade, durationTicks: 30))
            XCTAssertNil(o.input)
            XCTAssertFalse(o.on)
            XCTAssertEqual(o.animProgress, 0)
        }
        var plain = MixerState(format: .hd1080p5994)
        for i in plain.overlays.indices { plain.overlays[i].animation = OverlayAnimation.defaultFade(for: .hd1080p5994) }
        XCTAssertEqual(s, plain, "只有四路叠加的动画不同")
        XCTAssertNoThrow(try s.validate())
        // 带输出的形态（App 的 emptyShow 用它）
        let record = OutputState(number: 1, kind: .record, name: "录制", settings: OutputSettings(record: RecordSettings(directory: "/tmp")))
        let withOutputs = MixerState.newShow(format: .hd1080p30, outputs: [record])
        XCTAssertEqual(withOutputs.outputs, [record])
        XCTAssertEqual(withOutputs.overlays.map(\.animation.durationTicks), [15, 15, 15, 15])
        // 无参默认不变（API / 脚本直接构造的 OverlayAnimation 仍是 cut 0 拍），老文件的 animation 照读不改
        XCTAssertEqual(OverlayAnimation(), OverlayAnimation(kind: .cut, durationTicks: 0))
        XCTAssertEqual(MixerState().overlays.map(\.animation), Array(repeating: OverlayAnimation(), count: 4), "MixerState() 的默认不变")
        let g4 = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent("scenarios/g4-show.json")))
        XCTAssertEqual(g4.mixer.overlays.map(\.animation.kind), [.fade, .slide, .zoom, .cut], "G4 的节目文件里存的动画原样")
        XCTAssertEqual(g4.mixer.overlays.map(\.animation.durationTicks), [15, 20, 20, 0])
    }
}
