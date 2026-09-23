import XCTest
@testable import SwitcherContracts

/// 提案 017：表读数加 rms_db（用户 2026-09-24 批，G4 续做合入会话落地）。
final class Contracts017Tests: XCTestCase {
    func test017_rmsDbRoundTripsAndMissingKeyDecodesToEmpty() throws {
        typealias M = Stats.AudioCounters.Meters
        let bus = Stats.AudioCounters.BusMeter(bus: Bus.master.name, peakDb: [-6, -6.5], rmsDb: [-12, -12.4], truePeakDb: [-5.8, -6.3], lufsM: -18, lufsS: -19, lufsI: -20, lra: 4)
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(bus), as: UTF8.self),
                       #"{"bus":"master","lra":4,"lufs_i":-20,"lufs_m":-18,"lufs_s":-19,"peak_db":[-6,-6.5],"rms_db":[-12,-12.4],"true_peak_db":[-5.8,-6.3]}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.AudioCounters.BusMeter.self, from: try Stats.lineEncoder.encode(bus)), bus)
        // 017 之前的文件：没有 rms_db → 空数组（= 没有 RMS，读表的只画峰值），其余照解
        let legacy = try JSONDecoder().decode(Stats.AudioCounters.BusMeter.self,
                                              from: Data(#"{"bus":"master","lra":4,"lufs_i":-20,"lufs_m":-18,"lufs_s":-19,"peak_db":[-6,-6.5],"true_peak_db":[-5.8,-6.3]}"#.utf8))
        XCTAssertEqual(legacy.rmsDb, [])
        XCTAssertEqual(legacy.peakDb, [-6, -6.5])
        let input = Stats.AudioCounters.InputMeter(peakDb: [-12, -12.5], rmsDb: [-18, -18.5])
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(input), as: UTF8.self), #"{"peak_db":[-12,-12.5],"rms_db":[-18,-18.5]}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.AudioCounters.InputMeter.self, from: Data(#"{"peak_db":[-1,-2]}"#.utf8)), .init(peakDb: [-1, -2]))
        // 写出总是写全：默认（没有 RMS）也写 "rms_db":[]
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(Stats.AudioCounters.InputMeter(peakDb: [-1])), as: UTF8.self), #"{"peak_db":[-1],"rms_db":[]}"#)
        XCTAssertEqual(M.decibels(fromLinear: 0.1), -20, accuracy: 1e-9)
        XCTAssertEqual(Stats.AudioCounters.BusMeter.jsonKeys.count, 8)
    }
}
