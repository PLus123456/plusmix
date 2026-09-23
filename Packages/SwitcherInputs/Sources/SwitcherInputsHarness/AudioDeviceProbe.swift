import Foundation
import SwitcherContracts
import SwitcherInputs

/// `audio-device` 子命令（W2-A2 交付 4）：列输入设备；指定 uid 跑 N 秒，报块数、断裂、hostTime 单调性、块间隔分布。
///
/// 组装方在这里：环由 `HarnessAudioRing` 建（契约 §2.3 的注入规则），`AudioDeviceInput` 只管往里写。
///
/// 命令行入口在 `switcher-input-probe`（`Sources/switcher-input-probe/main.swift`，**不在本会话的可改目录里**，
/// 接法见 reports/issues/W2A2-w2-inputs-probe-audio-device-subcommand.md）；测试直接调这里的函数。
public enum AudioDeviceProbe {
    /// 一次运行的结果。
    public struct Run: Sendable {
        public var uid: String
        public var deviceName: String
        public var seconds: Double
        public var state: InputState
        public var lastError: String?
        public var deviceSampleRate: Double
        public var converting: Bool
        public var blocks: [HarnessAudioRing.BlockRecord]
        public var ringStats: AudioRingStats
        public var blockStats: AudioDeviceInput.BlockStats
        public var fifo: AudioCaptureCounters
        public var counters: InputCounters
        /// 相邻块的 host time 间隔（ms）。
        public var intervalsMs: [Double] { Self.intervals(of: blocks) }
        /// 块与块之间累计帧序号不连续的次数（有断裂就 > 0）。
        public var breaks: Int {
            var n = 0
            for i in 1..<max(blocks.count, 1) where blocks[i].frameIndex != blocks[i - 1].frameIndex + UInt64(blocks[i - 1].frameCount) { n += 1 }
            return n
        }
        /// host time 没有严格递增的次数。
        public var nonMonotonic: Int {
            var n = 0
            for i in 1..<max(blocks.count, 1) where blocks[i].hostTime.ticks <= blocks[i - 1].hostTime.ticks { n += 1 }
            return n
        }
        static func intervals(of blocks: [HarnessAudioRing.BlockRecord]) -> [Double] {
            guard blocks.count > 1 else { return [] }
            return (1..<blocks.count).map { (blocks[$0].hostTime - blocks[$0 - 1].hostTime).milliseconds }
        }
    }

    /// 设备清单（一行一台）。
    public static func deviceLines() -> [String] {
        let devices = AudioInputDevices.list()
        var lines = ["音频输入设备 \(devices.count) 台（麦克风权限 \(CapturePermission.status(for: .audio).rawValue)）："]
        for (index, d) in devices.enumerated() {
            lines.append("  [\(index)] \(d.name)\(d.isDefaultInput ? "（系统默认输入）" : "")")
            lines.append("      uid=\(d.uid)  声道 \(d.inputChannels)  采样率 \(Int(d.sampleRate.rounded())) Hz"
                         + "  可选 \(d.availableSampleRates.map { String(Int($0.rounded())) }.joined(separator: "/"))"
                         + "  48k=\(d.supports48k ? "支持" : "不支持")  IO 块 \(d.bufferFrameSize) 帧"
                         + "  传输 \(d.transportType)  \(d.isAlive ? "在线" : "离线")  \(d.manufacturer)")
        }
        return lines
    }

    /// 跑一路音频设备输入 `seconds` 秒。`log` 打状态变化。
    public static func run(uid: String, seconds: Double, channelCount: Int = 2,
                           options: AudioDeviceInput.Options = AudioDeviceInput.Options(),
                           log: (String) -> Void = { _ in }) throws -> Run {
        let ring = HarnessAudioRing(channelCount: channelCount, capacityFrames: 1 << 16,
                                    logCapacity: max(1 << 12, Int(seconds * 200)))
        let name = AudioInputDevices.list().first { $0.uid == uid }?.name ?? uid
        let input = AudioDeviceInput(number: 1, name: name, deviceUID: uid, audioRing: ring, options: options)
        try input.start()
        var lastState = input.state
        let deadline = HostClock.now() + HostDuration(seconds: seconds)
        // 环没有消费者会满：按 48 kHz 的节奏读走，读的量不超过已有的（所以 underruns 只会来自真的断流）
        let blockFrames = 256
        let scratch = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
            p.initialize(repeating: 0, count: blockFrames)
            return p
        }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for c in 0..<channelCount { table[c] = scratch[c] }
        defer {
            table.deallocate()
            for p in scratch { p.deallocate() }
        }
        while HostClock.now() < deadline {
            let state = input.state
            if state != lastState {
                log("state \(lastState) → \(state)\(input.lastError.map { "  \($0)" } ?? "")")
                lastState = state
            }
            while ring.availableFrames >= blockFrames {
                _ = ring.read(into: UnsafePointer(table), frameCount: blockFrames)
            }
            usleep(2000)
        }
        let result = Run(uid: uid, deviceName: input.deviceName ?? name, seconds: seconds, state: input.state,
                         lastError: input.lastError, deviceSampleRate: input.deviceSampleRate,
                         converting: input.isConverting, blocks: ring.blocks, ringStats: ring.stats,
                         blockStats: input.blockStats, fifo: input.fifoCounters, counters: input.counters)
        input.stop()
        return result
    }

    /// 把一次运行打成报告文本。
    public static func report(_ run: Run) -> [String] {
        func f(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }
        var lines: [String] = []
        lines.append("设备「\(run.deviceName)」uid=\(run.uid)，跑了 \(f(run.seconds, 1)) s，state=\(run.state)"
                     + (run.lastError.map { "（\($0)）" } ?? ""))
        lines.append("  采样率：设备 \(Int(run.deviceSampleRate.rounded())) Hz，\(run.converting ? "泵线程转成 48 kHz" : "直接写环（48 kHz）")")
        lines.append("  块：写环 \(run.blockStats.blocks) 块 / \(run.blockStats.frames) 帧，环拒 \(run.blockStats.framesRejected) 帧，"
                     + "末块 \(run.blockStats.blockFrames) 帧 = \(f(run.blockStats.blockMs)) ms")
        lines.append("  断裂：累计帧序号不连续 \(run.breaks) 处；hostTime 非严格递增 \(run.nonMonotonic) 处；"
                     + "环 overruns \(run.ringStats.overruns) / underruns \(run.ringStats.underruns)")
        let intervals = run.intervalsMs
        if let lo = intervals.min(), let hi = intervals.max() {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let sorted = intervals.sorted()
            lines.append("  块间隔（相邻块 hostTime 之差）：min \(f(lo)) / p50 \(f(sorted[sorted.count / 2])) / 平均 \(f(mean)) / max \(f(hi)) ms，"
                         + "与块长的最大偏差 \(f(run.blockStats.maxIntervalErrorMs)) ms")
        }
        lines.append("  d = 回调到达 − 块首 hostTime：平均 \(f(run.blockStats.meanDelayMs)) ms，标准差 \(f(run.blockStats.sdDelayMs))，"
                     + "min \(f(run.blockStats.minDelayMs)) / max \(f(run.blockStats.maxDelayMs))")
        lines.append("  w = 写环时刻 − 块首 hostTime：平均 \(f(run.blockStats.meanWriteDelayMs)) ms / max \(f(run.blockStats.maxWriteDelayMs))"
                     + "（泵这一跳 = w − d，平均 \(f(run.blockStats.meanWriteDelayMs - run.blockStats.meanDelayMs)) ms）")
        lines.append("  IOProc：回调 \(run.fifo.callbacks) 次，产出 \(run.fifo.blocksProduced) 块，泵取走 \(run.fifo.blocksConsumed) 块，"
                     + "交接区丢 \(run.fifo.blocksDropped) 块 / \(run.fifo.framesDropped) 帧，超大块 \(run.fifo.oversizeBlocks)，"
                     + "空回调 \(run.fifo.emptyCallbacks)，hostTime 退回 \(run.fifo.hostTimeFallbacks)")
        lines.append("  设备 IO 过载 \(run.blockStats.overloads) 次，转换报错 \(run.blockStats.conversionErrors) 次，"
                     + "状态转换 \(run.counters.stateTransitions)（live \(run.counters.liveTransitions) / noSignal \(run.counters.noSignalTransitions) / error \(run.counters.errorTransitions)），"
                     + "重建 \(run.counters.rebuilds)")
        return lines
    }
}
