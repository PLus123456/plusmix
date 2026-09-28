import XCTest
import Darwin
import Foundation
import SwitcherContracts
import Synchronization
@testable import SwitcherTestKit

/// W1-A4：`frameprobe av <录像> --fps 60 --discontinuities` 的峰值内存不随录像长度涨
/// （reports/issues/W4A-w1-testkit-frameprobe-memory-grows-with-length.md：修前 1080p60 + 立体声 AAC 的录像
/// 1 分钟 0.73 GB、10 分钟 7.6 GB、1 小时 41 GB，8 小时的 A3 分析不下来）。
///
/// 录像现场用合成源写（`SampleMovieWriter`）：立体声 AAC——录制器与推流出来的音轨都是立体声，frameprobe 读多声道音轨
/// 走的是单独一条分支（先按声道取平均），单声道的样例测不到它；画幅 640×360——只读画面（`frameprobe stats`）的峰值
/// 10 分钟 1080p 也只有 27 MB，涨的那部分与画幅无关，小画幅让整条用例在 debug 下 90 s 内跑完。
/// 合理的增长只有两样：单声道 float 样本（4 B × 48 kHz，1 分钟 11 MB）和逐帧读数（每帧一两百字节），3 分钟比 1 分钟多约 24 MB。
final class FrameProbeMemoryTests: XCTestCase {
    /// 1 分钟与 3 分钟两段的峰值 phys_footprint 之差上限（prompt 82 交付 1）。
    static let maxPeakDifferenceBytes: Int64 = 100 * 1_048_576

    static func spec(seconds: Double) -> SampleMovieWriter.Spec {
        var s = SampleMovieWriter.Spec()
        s.width = 640; s.height = 360; s.seconds = seconds; s.bitrate = 1_000_000
        s.sourceA = SyntheticSourceSettings(frameRate: .fps60, width: 640, height: 360, background: .gray(level: 64), patternID: 0, audio: false)
        s.sourceB = SyntheticSourceSettings(frameRate: .fps30, width: 640, height: 360, background: .gray(level: 192), patternID: 1, audio: false)
        s.events = []
        s.audio = .aac(bitrate: 128_000)
        s.audioChannels = 2
        return s
    }

    struct Probed {
        var output: FrameProbe.AVOutput
        /// 调用前的 phys_footprint。
        var before: Int64
        /// 调用期间采到的最大 phys_footprint。
        var peak: Int64
        var seconds: Double
    }

    /// `FrameProbe.av` 跑一遍（与命令行 `frameprobe av` 同一个入口），期间每 1 ms 采一次 phys_footprint。
    static func probe(_ url: URL, options: FrameProbe.Options) async throws -> Probed {
        let before = physFootprintBytes()
        let sampler = FootprintSampler()
        let started = Date()
        let output: FrameProbe.AVOutput
        do {
            output = try await FrameProbe.av(url, options: options)
        } catch {
            _ = sampler.stop()
            throw error
        }
        let peak = sampler.stop()
        return Probed(output: output, before: before, peak: peak, seconds: Date().timeIntervalSince(started))
    }

    func testW1A4_frameprobeAV_peakFootprintIndependentOfLength() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1a4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let short = dir.appendingPathComponent("60s.mov"), long = dir.appendingPathComponent("180s.mov")
        let started = Date()
        async let writeShort = SampleMovieWriter.write(spec: Self.spec(seconds: 60), to: short)
        async let writeLong = SampleMovieWriter.write(spec: Self.spec(seconds: 180), to: long)
        let written = try await [writeShort, writeLong]
        let writeSeconds = Date().timeIntervalSince(started)

        var options = FrameProbe.Options()
        options.fps = 60
        options.discontinuities = true
        let a = try await Self.probe(short, options: options)
        let b = try await Self.probe(long, options: options)
        let difference = b.peak - a.peak

        func mb(_ v: Int64) -> String { String(format: "%.1f", Double(v) / 1_048_576) }
        func line(_ p: Probed, _ label: String) -> String {
            "\(label)：峰值 \(mb(p.peak)) MB（调用前 \(mb(p.before)) MB，涨 \(mb(p.peak - p.before)) MB），\(String(format: "%.1f", p.seconds)) s"
        }
        print("[W1-A4] 写两段录像 \(String(format: "%.1f", writeSeconds)) s（\(written.map { "\($0.frames) 帧 / \($0.audioSamples) 样本" }.joined(separator: "、"))）；"
              + line(a, "60 s") + "；" + line(b, "180 s") + "；峰值差 \(mb(difference)) MB（阈值 \(mb(Self.maxPeakDifferenceBytes)) MB）")

        // 两段都整条分析完，走的是多声道那条分支
        for (p, seconds) in [(a, 60), (b, 180)] {
            XCTAssertEqual(p.output.audio?.channels, 2, "\(seconds) s")
            XCTAssertEqual(p.output.discontinuities?.sampleCount, seconds * 48000, "\(seconds) s 的音轨整条读完")
            XCTAssertEqual(p.output.av.flashCount, seconds, "\(seconds) s 每秒一次闪光")
        }
        XCTAssertLessThan(difference, Self.maxPeakDifferenceBytes,
                          "frameprobe av 的峰值随录像长度涨：60 s \(mb(a.peak)) MB → 180 s \(mb(b.peak)) MB，差 \(mb(difference)) MB")
    }
}

/// 进程的 phys_footprint（task_vm_info；与 `/usr/bin/time -l` 的 peak memory footprint、Stats 的 rss_mb 同一口径），字节。
func physFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

/// 另起一条线程每 1 ms 读一次 phys_footprint、记最大值。内核 ledger 里的峰值（`ledger_phys_footprint_peak`）是整个进程一生的，
/// 没法按一次调用清零；同一个 xctest 进程里前面的用例用过多少都会算进去。
final class FootprintSampler: Sendable {
    private let running = Atomic<Bool>(true)
    private let peakBytes: Atomic<Int64>
    private let finished = DispatchSemaphore(value: 0)

    init() {
        peakBytes = Atomic(physFootprintBytes())
        let thread = Thread { [self] in
            while running.load(ordering: .relaxed) {
                let now = physFootprintBytes()
                if now > peakBytes.load(ordering: .relaxed) { peakBytes.store(now, ordering: .relaxed) }
                usleep(1000)
            }
            finished.signal()
        }
        thread.name = "w1a4-footprint-sampler"
        thread.start()
    }

    /// 停下，返回采到的最大值（含停的这一刻）。
    func stop() -> Int64 {
        running.store(false, ordering: .relaxed)
        finished.wait()
        return max(peakBytes.load(ordering: .relaxed), physFootprintBytes())
    }
}
