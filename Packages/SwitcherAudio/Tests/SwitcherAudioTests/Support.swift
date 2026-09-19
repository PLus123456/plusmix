import XCTest
import Foundation
import SwitcherContracts
@testable import SwitcherAudio

/// 测试公用：时基、dB 换算、离线搭台。
enum T {
    /// 1 tick = 1 ns 的时基，帧 = 20833.33 ns
    static let tb = MachTimebase(numer: 1, denom: 1)
    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-30)) }
    static func rms(_ a: [Float]) -> Double { (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(a.count, 1))).squareRoot() }
    static func peak(_ a: [Float]) -> Double { Double(a.reduce(0) { max($0, abs($1)) }) }
    /// 环境变量控制的时长（秒）；没设就用默认
    static func seconds(_ env: String, default d: Double) -> Double {
        if let v = ProcessInfo.processInfo.environment[env], let x = Double(v) { return x }
        return d
    }
    static var fullRuns: Bool { ProcessInfo.processInfo.environment["SW_AUDIO_FULL"] == "1" }
}

/// 一个离线搭台：混音器 + 驱动 + 若干合成输入，块之间自动喂输入。
final class OfflineRig {
    let mixer: AudioMixer
    let driver: OfflineAudioDriver
    var sources: [Int: OfflineAudioSource] = [:]
    let t0 = HostTime(ticks: 1_000_000_000)

    init(blockFrames: Int = 256, configure: ((inout AudioMixerConfiguration) -> Void)? = nil) {
        var cfg = AudioMixerConfiguration()
        cfg.timebase = T.tb
        cfg.blockFrames = blockFrames
        configure?(&cfg)
        mixer = AudioMixer(configuration: cfg)
        driver = OfflineAudioDriver(mixer: mixer, blockFrames: blockFrames, startHostTime: t0, timebase: T.tb)
    }

    /// 加一路合成输入到槽位；默认信号 TestSignal（1 kHz −20 dBFS + click）。
    @discardableResult
    func addSource(slot: Int, channels: Int = 1, driftPpm: Double = 0, producerBlock: Int = 256, capacity: Int = 16_384,
                   resampling: ResampleMode = .estimated, targetFrames: Int = 0, targetAgeFrames: Int = 0, sourceT0: HostTime? = nil,
                   generator: ((Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void)? = nil) -> OfflineAudioSource {
        let src = OfflineAudioSource(channels: channels, t0: sourceT0 ?? t0, driftPpm: driftPpm, producerBlockFrames: producerBlock,
                                     capacityFrames: capacity, timebase: T.tb, generator: generator)
        sources[slot] = src
        mixer.attach(ring: src.ring, toSlot: slot, resampling: resampling, targetFrames: targetFrames, targetAgeFrames: targetAgeFrames)
        return src
    }

    /// 跑 n 块：每块前把所有源喂到"块结束时刻"，块后回调。
    func run(blocks: Int, afterEach: ((OfflineBlock) -> Void)? = nil) {
        driver.run(blocks: blocks, beforeEach: { _, end in
            for (_, s) in self.sources { s.deliver(upTo: end) }
        }, afterEach: afterEach)
    }

    /// 跑 n 块并收集某条总线的左右声道。
    func collect(blocks: Int, bus: Bus) -> (left: [Float], right: [Float]) {
        var l = [Float](), r = [Float]()
        l.reserveCapacity(blocks * driver.blockFrames); r.reserveCapacity(blocks * driver.blockFrames)
        run(blocks: blocks) { b in
            let (bl, br) = b.bus(bus)
            l.append(contentsOf: bl); r.append(contentsOf: br)
        }
        return (l, r)
    }
}
