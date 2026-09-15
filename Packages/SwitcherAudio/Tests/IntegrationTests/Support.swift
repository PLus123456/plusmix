import XCTest
import Foundation
import SwitcherContracts
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 集成测试公用：时基、dB、click 定位、环境变量时长。
enum IT {
    /// 1 tick = 1 ns 的时基（离线用例）。
    static let tb = MachTimebase(numer: 1, denom: 1)
    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-30)) }
    static func rms(_ a: ArraySlice<Float>) -> Double { (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(a.count, 1))).squareRoot() }
    static func peak(_ a: ArraySlice<Float>) -> Double { Double(a.reduce(0) { max($0, abs($1)) }) }
    static func seconds(_ env: String, default d: Double) -> Double {
        if let v = ProcessInfo.processInfo.environment[env], let x = Double(v) { return x }
        return d
    }
    static var fullRuns: Bool { ProcessInfo.processInfo.environment["SW_AUDIO_FULL"] == "1" }
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// 在单声道样本里找 click 起点：|x| ≥ onset 的第一个样本，之后跳过 holdOff 个样本。
    static func clickOnsets(_ samples: [Float], onset: Float = 0.5, holdOff: Int = 2400) -> [Int] {
        var out: [Int] = []
        var i = 0
        while i < samples.count {
            if abs(samples[i]) >= onset { out.append(i); i += holdOff } else { i += 1 }
        }
        return out
    }
}

/// 收集带 PTS 的输出块，拼成连续时间线（假设块之间连续；真连续与否由 `gaps` 报告）。
final class TimedCapture {
    var channels: Int
    var left: [Float] = []
    var right: [Float] = []
    var firstHostTime: HostTime?
    var expectedNext: HostTime?
    var gaps: [(at: HostTime, deltaFrames: Double)] = []
    var blocks = 0
    let sampleRate = Double(AudioFormat.sampleRate)
    let timebase: MachTimebase

    init(channels: Int = 2, timebase: MachTimebase = HostClock.timebase) {
        self.channels = channels
        self.timebase = timebase
    }

    func append(planes: UnsafePointer<UnsafePointer<Float>>, frames: Int, hostTime: HostTime) {
        if firstHostTime == nil { firstHostTime = hostTime }
        if let e = expectedNext {
            let d = Double((hostTime - e).nanoseconds(timebase: timebase)) * sampleRate / 1e9
            if abs(d) > 0.5 { gaps.append((hostTime, d)) }
        }
        left.append(contentsOf: UnsafeBufferPointer(start: planes[0], count: frames))
        if channels > 1 { right.append(contentsOf: UnsafeBufferPointer(start: planes[1], count: frames)) }
        expectedNext = hostTime + HostDuration(nanoseconds: Int64((Double(frames) * 1e9 / sampleRate).rounded()), timebase: timebase)
        blocks += 1
    }

    /// 样本 i 的 host time（按首块 PTS + 计数）。
    func hostTime(ofSample i: Int) -> HostTime {
        firstHostTime! + HostDuration(nanoseconds: Int64((Double(i) * 1e9 / sampleRate).rounded()), timebase: timebase)
    }
}
