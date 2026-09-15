import Foundation
import SwitcherContracts
import CLibSamplerate

// 设备时钟 → host 时钟的重采样（录制 / 编码路径；设计方案 §3.6 的另一半）。
//
// 混音器跑在输出设备的 IOProc 上：每块 256 帧，块首样本 host time 是 HAL 对设备采样钟的投影（精确），但设备晶振相对 host 有
// ±几 ppm 到几十 ppm 的偏差，所以 Master 每 host 秒不是恰好 48000 个样本。录制器 / 封装器按样本计数排时间轴（AVAssetWriter
// 忽略 PTS 间隙，W1-E 报告 1.3 第 2 条），不重采样就会以设备 ppm 漂（A3 要求 8 小时 ≤ 16 ms，即 0.55 ppm）。
// 这里把消费者看到的流重采样到 host 时钟：输出样本 m 的时刻恰好 = 起点 + m / 48000（host time），与视频拍点同一时基。
//
// 做法（非实时线程，允许分配 / 锁 / 日志——它跑在泵线程上，不是 IOProc）：
//   - 每来一块（帧数 n、块首 host time T）：应产出的总样本数 = (块尾 host time − 起点) × 48000 − 交付余量，向它补齐
//     （want = 目标 − 已产出），所以输出计数永远钉在 host 时基上，误差 < 1 帧，不累积。
//   - 比率 = 输出 / 输入 = 48000 / 设备实际采样率，纯前馈：设备速率从块 stamp 测（stamp 是 HAL 按采样钟投影的，精度 µs 级：
//     8 块 43 ms 的窗就有 ~1 ppm；之后每 2 s 测一次，前 10 分钟累计平均、之后指数窗 τ = 10 分钟——窗口 2 s 本身就有 0.02 ppm）。
//     libsamplerate 按 1/ratio 精确推进输入位置，所以长期平均比率 = 测得的速率比 → 输入位置相对 stamp 不漂
//     （残差 ≈ 早期估计误差 × 几秒，< 1 帧）。第一次测到之前不产出（比率 1.0 那段会把位置误差冻结进去，−50 ppm × 2 s = 5 帧，实测过）。
//     不用 FIFO 占用做反馈：占用是幅度 = chunk 的锯齿，PI 会追锯齿的相位（实测积分绕到 100 ppm）。
//   - libsamplerate 回调 API（与 W1-D 的热路径同一用法）：库在手里 ≤ 半长时才向 FIFO 要一段 chunk；交付余量 = 半长 + 2 chunk，
//     保证回调要数据时 FIFO 里有（回调不能返回 0）。空设备 / 离线驱动的时钟就是 host 时钟（比率恒 1.0），
//     AudioEngine 默认对它们旁路本类（bit 精确）。
final class HostClockResampler {
    /// 声道数（交错处理）。
    let channels: Int
    /// libsamplerate 每次向 FIFO 要的帧数。
    let chunkFrames: Int
    /// 名义采样率。
    let sampleRate: Double
    /// 起点：输出样本 0 的 host time（第一块的首样本 host time，调用方已减掉对齐延迟）。
    private(set) var originHostTime: HostTime?
    /// 已产出的输出样本数。
    private(set) var framesProduced: Int64 = 0
    /// 已收到的输入帧数。
    private(set) var framesReceived: Int64 = 0
    /// 当前比率（输出 / 输入）。
    private(set) var ratio: Double = 1
    /// 前馈估计的设备速率比（设备帧 / host 名义帧）；nil = 还没测到。
    private(set) var deviceRateRatio: Double?
    /// 回调向 FIFO 要数据但 FIFO 空的次数（输入不够：比率偏低或输入断了）。
    private(set) var starvedPulls: UInt64 = 0
    /// 最近一次调用后的 FIFO 占用（帧）。
    var fifoFrames: Int { (fifo.count - fifoRead) / channels }

    private var state: OpaquePointer?
    private var fifo: [Float] = []           // 交错
    private var fifoRead = 0                  // 已交给库的元素数（帧 × 声道）
    private var chunk: [Float]
    private var output: [Float]
    private var planeStorage: [Float] = []
    // 前馈速率测量
    private var windowStartHost: HostTime?
    private var windowStartFrames: Int64 = 0
    private let rateWindow: HostDuration
    private let rateTauSeconds: Double
    /// 第一次测量的窗口（块数）：8 块 ≈ 43 ms。
    private let firstWindowBlocks = 8
    private var blocksSeen = 0
    private var measuredSeconds: Double = 0
    private let timebase: MachTimebase

    /// - Parameters:
    ///   - channels: 声道数（Master 2）。
    ///   - converter: libsamplerate 转换器，默认 SRC_SINC_MEDIUM_QUALITY（与混音器一致）。
    ///   - rateWindowSeconds: 前馈测量窗口。
    ///   - rateTauSeconds: 稳态后的指数平均窗（跟晶振温漂）。
    init(channels: Int, converter: Int32 = Int32(SRC_SINC_MEDIUM_QUALITY), chunkFrames: Int = 64, sampleRate: Double = Double(AudioFormat.sampleRate),
         rateWindowSeconds: Double = 2, rateTauSeconds: Double = 600, timebase: MachTimebase = HostClock.timebase) {
        precondition(channels >= 1 && chunkFrames >= 8)
        self.channels = channels
        self.chunkFrames = chunkFrames
        self.sampleRate = sampleRate
        self.rateWindow = HostDuration(seconds: rateWindowSeconds, timebase: timebase)
        self.rateTauSeconds = rateTauSeconds
        self.timebase = timebase
        chunk = [Float](repeating: 0, count: chunkFrames * channels)
        output = [Float](repeating: 0, count: 8192 * channels)
        var err: Int32 = 0
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        state = src_callback_new({ ctx, data in
            let me = Unmanaged<HostClockResampler>.fromOpaque(ctx!).takeUnretainedValue()
            return me.pull(into: data!)
        }, converter, Int32(channels), &err, unmanaged)
        precondition(state != nil, "src_callback_new 失败：\(err)")
    }

    deinit { if let s = state { src_delete(s) } }

    /// 重采样器需要预先看到的输入帧数（sinc 半长；MEDIUM 47）。
    var lookaheadFrames: Int { 47 }
    /// 输出计数相对块尾留的余量（帧）：半长 + 两个 chunk。
    var deliveryMarginFrames: Int { lookaheadFrames + 2 * chunkFrames }

    /// libsamplerate 的取样回调：交一段 chunk（不够就把有的都交；FIFO 空时交零块并计数——不能返回 0，否则库进入终止态）。
    private func pull(into data: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>) -> Int {
        let availableFrames = (fifo.count - fifoRead) / channels
        if availableFrames <= 0 {
            starvedPulls += 1
            for i in chunk.indices { chunk[i] = 0 }
            return chunk.withUnsafeMutableBufferPointer { p in data.pointee = p.baseAddress; return chunkFrames }
        }
        let n = min(chunkFrames, availableFrames)
        let start = fifoRead
        for i in 0..<(n * channels) { chunk[i] = fifo[start + i] }
        fifoRead += n * channels
        return chunk.withUnsafeMutableBufferPointer { p in data.pointee = p.baseAddress; return n }
    }

    /// 喂一块（非交错平面，每个 frameCount 个 float；`hostTime` = 块首样本的 host time，已按对齐延迟修正），
    /// 通过 `deliver` 交出若干输出样本（非交错平面 + 帧数 + 首样本 host time = 起点 + 计数 / 48000）。
    /// 一次调用可能产出 0 帧（起步要先测速率、填满 sinc 半长）。
    func push(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime,
              deliver: (_ planes: UnsafePointer<UnsafePointer<Float>>, _ frames: Int, _ hostTime: HostTime) -> Void) {
        guard frameCount > 0, let state else { return }
        if originHostTime == nil {
            originHostTime = hostTime
            windowStartHost = hostTime
            windowStartFrames = 0
        }
        // 1. 进 FIFO（交错）
        compactFIFO()
        fifo.reserveCapacity(fifo.count + frameCount * channels)
        for i in 0..<frameCount {
            for c in 0..<channels { fifo.append(planes[c][i]) }
        }
        framesReceived += Int64(frameCount)
        blocksSeen += 1
        // 2. 前馈：设备速率比 = 窗口内的帧数 / (host 时长 × 名义采样率)；测到之前不产出
        updateFeedforward(blockHostTime: hostTime, frameCount: frameCount)
        guard let deviceRate = deviceRateRatio else { return }
        // 3. 目标样本数：块尾 host time 对应的输出计数，减去交付余量
        let blockEnd = hostTime + HostDuration(nanoseconds: Int64((Double(frameCount) / (sampleRate * deviceRate) * 1e9).rounded()), timebase: timebase)
        let target = Int64((Double((blockEnd - originHostTime!).nanoseconds(timebase: timebase)) * sampleRate / 1e9).rounded()) - Int64(deliveryMarginFrames)
        let want = Int(target - framesProduced)
        guard want > 0 else { return }
        if output.count < want * channels { output = [Float](repeating: 0, count: want * channels) }
        src_set_ratio(state, ratio)
        let got = output.withUnsafeMutableBufferPointer { p in Int(src_callback_read(state, ratio, want, p.baseAddress)) }
        guard got > 0 else { return }
        // 4. 交付：非交错，PTS 按计数
        let ptsFrames = framesProduced
        framesProduced += Int64(got)
        let pts = originHostTime! + HostDuration(nanoseconds: Int64((Double(ptsFrames) * 1e9 / sampleRate).rounded()), timebase: timebase)
        deliverDeinterleaved(frames: got, hostTime: pts, deliver: deliver)
    }

    private func deliverDeinterleaved(frames: Int, hostTime: HostTime, deliver: (UnsafePointer<UnsafePointer<Float>>, Int, HostTime) -> Void) {
        if planeStorage.count < frames * channels { planeStorage = [Float](repeating: 0, count: frames * channels) }
        for i in 0..<frames {
            for c in 0..<channels { planeStorage[c * frames + i] = output[i * channels + c] }
        }
        planeStorage.withUnsafeBufferPointer { buf in
            var ptrs = [UnsafePointer<Float>]()
            ptrs.reserveCapacity(channels)
            for c in 0..<channels { ptrs.append(buf.baseAddress! + c * frames) }
            ptrs.withUnsafeBufferPointer { deliver($0.baseAddress!, frames, hostTime) }
        }
    }

    private func compactFIFO() {
        guard fifoRead > 0 else { return }
        if fifoRead >= fifo.count { fifo.removeAll(keepingCapacity: true) }
        else { fifo.removeFirst(fifoRead) }
        fifoRead = 0
    }

    /// 用本对象的时基换算秒（测试用 1 ns 时基，不能用 HostDuration.seconds 的默认时基）。
    private func seconds(_ d: HostDuration) -> Double { Double(d.nanoseconds(timebase: timebase)) / 1e9 }

    private func updateFeedforward(blockHostTime: HostTime, frameCount: Int) {
        guard let start = windowStartHost else { return }
        let elapsed = blockHostTime - start
        if deviceRateRatio == nil {
            guard blocksSeen > firstWindowBlocks else { return }
        } else {
            guard elapsed >= rateWindow else { return }
        }
        // 本块之前收到的帧数（framesReceived 已含本块）跨过的 host 时长 = 本块 stamp − 窗口起点 stamp
        let frames = Double(framesReceived - Int64(frameCount) - windowStartFrames)
        let elapsedSeconds = seconds(elapsed)
        guard elapsedSeconds > 0 else { return }
        let measured = frames / (elapsedSeconds * sampleRate)
        guard measured > 0.9, measured < 1.1 else { return }
        if let current = deviceRateRatio {
            // 前 rateTau 秒等价于累计平均（α = 窗 / 已测总时长），之后指数窗
            let total = measuredSeconds + elapsedSeconds
            let alpha = min(1, elapsedSeconds / min(total, rateTauSeconds))
            deviceRateRatio = current + (measured - current) * alpha
        } else {
            deviceRateRatio = measured
        }
        measuredSeconds += elapsedSeconds
        windowStartHost = blockHostTime
        windowStartFrames = framesReceived - Int64(frameCount)
        ratio = 1 / deviceRateRatio!
    }

    /// 给状态快照。
    struct Snapshot: Hashable, Sendable {
        var ratio: Double
        var deviceRateRatio: Double?
        var devicePpm: Double? { deviceRateRatio.map { ($0 - 1) * 1e6 } }
        var fifoFrames: Int
        var framesReceived: Int64
        var framesProduced: Int64
        var starvedPulls: UInt64
    }
    var snapshot: Snapshot {
        Snapshot(ratio: ratio, deviceRateRatio: deviceRateRatio, fifoFrames: fifoFrames,
                 framesReceived: framesReceived, framesProduced: framesProduced, starvedPulls: starvedPulls)
    }
}
