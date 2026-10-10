import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
@testable import SwitcherISO

/// W1-B4（prompt 105，提案 028；用户 2026-10-10 批本会话改这一个文件）：videoDelay 补偿下引擎交来的 RenderedFrame.tickTime = 拍点 + L，
/// program.pts 仍是拍点（画面内容的时刻）。ISO 抽帧（ISO 录制、源是输入 n 的 NDI 发送）要按内容时刻挑这一路的帧、按 tickTime 打戳：
/// 这样 ISO 画面与 ISO 音轨（输入来源同样平移 +L）在同一条节目输出时间线上。L = 0 时两者相等，行为与以前相同（TeeTapPlannerTests 那条照旧）。
final class VideoDelayISOTapTests: XCTestCase {
    func testAV_isoTapPicksByContentTimeUnderVideoDelay() throws {
        let tee = InputFrameTee(primary: LockFreeFrameSlot(capacity: 3))
        let branch = try XCTUnwrap(tee.addBranch())
        let sink = RecordingSink()
        let tap = ISOFrameTap(inputNumber: 2, branch: branch, sink: sink)
        let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
        let delay = HostDuration(milliseconds: 12)
        /// 引擎延后 12 ms 派发的那一帧：tickTime = 拍点 + 12 ms，program.pts = 拍点。
        func delayed(_ tick: Int) -> RenderedFrame {
            let t = spec.time(of: Tick(Int64(tick)))
            return RenderedFrame(tick: Tick(Int64(tick)), tickTime: t + delay, program: makeFrame(input: 0, sequence: UInt64(tick), pts: t),
                                 submitTime: t, gpuStart: t, gpuEnd: t)
        }
        // 第 1 拍：分支上有拍点前 4 ms 的帧（序号 1）与拍点后 8 ms 的帧（序号 2：晚于拍点、早于拍点 + 12 ms，派发那一刻已经到了）
        tee.push(makeFrame(input: 2, sequence: 1, pts: spec.time(of: Tick(1)) - HostDuration(milliseconds: 4)))
        tee.push(makeFrame(input: 2, sequence: 2, pts: spec.time(of: Tick(1)) + HostDuration(milliseconds: 8)))
        tap.consume(delayed(1))
        // 第 2 拍：序号 2 ≤ 拍点 → 取 2
        tap.consume(delayed(2))
        let got = sink.frames
        XCTAssertEqual(got.map(\.sequence), [1, 2], "按画面内容的时刻（拍点）挑：第 1 拍是序号 1，不是拍点 + 12 ms 时已到的序号 2")
        XCTAssertEqual(got.map(\.tickTime), [spec.time(of: Tick(1)) + delay, spec.time(of: Tick(2)) + delay], "打戳用节目输出时间线（tickTime）")
        XCTAssertEqual(got.map { $0.tick.rawValue }, [1, 2])
        XCTAssertEqual(tap.counters.repeated, 0)
    }
}
