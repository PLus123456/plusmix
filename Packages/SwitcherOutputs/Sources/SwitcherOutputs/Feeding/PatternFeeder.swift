import CoreVideo
import Darwin
import Foundation
import SwitcherContracts

/// 测试喂料（prompt 交付 5）：用契约的 TestPattern 在 CPU 上直接写 NV12 帧，按精确拍点时刻喂给 FrameConsumer。
/// 不需要合成引擎和 TestKit 线程源；命令行录制器和所有录制测试都用它。
///
/// 内容：帧号 = tick、时间戳 = 生成时 host time、输入 ID、闪光按 `TestPattern.isFlashTick`；标记区之外的画面：
/// - `.flat`：纯 TestPattern（灰底），几乎不耗码率（静态图案 H.264 约 0.05 Mbps）；
/// - `.noise(amplitude:)`：标记区下方铺有界白噪声（每帧换一张预生成平面 + 随机行偏移），让码率控制真正工作（E2 用）。
///   预生成 8 张平面，逐帧只做 memcpy；噪声不碰标记区，图案照样能解码。
public final class PatternFeeder: @unchecked Sendable {
    /// 参数。
    public struct Configuration: Sendable {
        /// 节目格式。
        public var format: ProgramFormat
        /// 输入 ID（调色板索引 0–15）。
        public var inputID: Int
        /// 底色。
        public var background: TestPattern.Background
        /// 标记区之外的纹理。
        public var texture: Texture
        /// 像素池最少缓冲数。
        public var poolSize: Int
        public init(format: ProgramFormat, inputID: Int = 0, background: TestPattern.Background = .gray(level: 128),
                    texture: Texture = .flat, poolSize: Int = 8) {
            self.format = format
            self.inputID = inputID
            self.background = background
            self.texture = texture
            self.poolSize = poolSize
        }
    }

    /// 标记区之外的纹理。
    public enum Texture: Hashable, Sendable {
        /// 纯图案。
        case flat
        /// 有界白噪声：底色 ± amplitude（亮度）；色度 ± amplitude / 2。
        case noise(amplitude: Int, seed: UInt64)
    }

    /// 节拍方式。
    public enum Pacing: Sendable {
        /// 每拍 mach_wait_until 到拍点时刻再喂（拍点时刻由 clock 给）。
        case realTime
        /// 不等拍点；`readyToAccept` 返回 false 时自旋等待（喂料端做背压，编码器永远不因喂得太快而丢帧）。
        case fastest(readyToAccept: @Sendable () -> Bool)
    }

    /// 一次喂料的结果。
    public struct FeedReport: Sendable {
        /// 喂出去的帧数。
        public var framesFed: Int = 0
        /// 每次 `consume` 调用的耗时（host tick），按帧。
        public var pushDurations: [HostDuration] = []
        /// 实时节拍下，醒来时已经晚于拍点超过一帧的次数。
        public var lateTicks: Int = 0
        /// 第一拍的拍点时刻。
        public var firstTickTime: HostTime = .zero

        /// push 耗时分位（毫秒）。
        public func pushPercentileMs(_ p: Double) -> Double {
            guard !pushDurations.isEmpty else { return 0 }
            let sorted = pushDurations.map { $0.milliseconds }.sorted()
            let idx = min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.down)))
            return sorted[idx]
        }
    }

    /// 错误。
    public enum Error: Swift.Error { case poolCreateFailed(CVReturn), bufferCreateFailed(CVReturn) }

    public let configuration: Configuration
    private let pool: CVPixelBufferPool
    private let geometry: TestPattern.Geometry
    private let noiseLuma: [UnsafeMutablePointer<UInt8>]
    private let noiseChroma: [UnsafeMutablePointer<UInt8>]
    private let noiseRowStart: Int
    private var rng: SplitMix64
    private var sequence: UInt64 = 0
    private let frameDuration: HostDuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        let w = configuration.format.width, h = configuration.format.height
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: PixelFormat.nv12.cvPixelFormatType(range: .limited),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: configuration.poolSize]
        var p: CVPixelBufferPool?
        let r = CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
        guard r == kCVReturnSuccess, let p else { throw Error.poolCreateFailed(r) }
        pool = p
        geometry = TestPattern.Geometry(width: w, height: h)
        // 噪声从标记区下面一行开始（ID 块底边向下取偶再留一块间隔），保证解码采样区不被碰
        let markBottom = geometry.idRect.y + geometry.idRect.height + geometry.blockSize
        noiseRowStart = (markBottom + 1) & ~1
        frameDuration = HostDuration(nanoseconds: Int64((configuration.format.frameDuration.doubleValue * 1e9).rounded()))
        switch configuration.texture {
        case .flat:
            noiseLuma = []
            noiseChroma = []
            rng = SplitMix64(seed: 0)
        case .noise(let amplitude, let seed):
            var g = SplitMix64(seed: seed)
            let amp = max(0, min(100, amplitude))
            let base: Int
            switch configuration.background {
            case .gray(let level): base = Int(TestPattern.limitedLumaPublic(level))
            case .gradient: base = 128
            }
            let planes = 8
            noiseLuma = (0..<planes).map { _ in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
                for i in 0..<(w * h) {
                    let v = base + Int(g.next() % UInt64(2 * amp + 1)) - amp
                    p[i] = UInt8(clamping: max(16, min(235, v)))
                }
                return p
            }
            noiseChroma = (0..<planes).map { _ in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h / 2)
                let camp = max(0, amp / 2)
                for i in 0..<(w * h / 2) {
                    let v = 128 + Int(g.next() % UInt64(2 * camp + 1)) - camp
                    p[i] = UInt8(clamping: max(16, min(240, v)))
                }
                return p
            }
            rng = g
        }
    }

    deinit {
        for p in noiseLuma { p.deallocate() }
        for p in noiseChroma { p.deallocate() }
    }

    /// 生成第 `tick` 拍的 PGM 帧（拍点时刻 = clock.time(of: tick)）。`now` 打进时间戳行和 ingressTime。
    public func makeFrame(tick: Tick, clock: TickClockSpec, now: HostTime = HostClock.now()) throws -> RenderedFrame {
        let tickTime = clock.time(of: tick)
        return try makeFrame(tick: tick, tickTime: tickTime, now: now)
    }

    /// 同上，直接给拍点时刻。
    public func makeFrame(tick: Tick, tickTime: HostTime, now: HostTime = HostClock.now()) throws -> RenderedFrame {
        var pb: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard r == kCVReturnSuccess, let pb else { throw Error.bufferCreateFailed(r) }
        let content = TestPattern.Content(
            frameNumber: UInt32(truncatingIfNeeded: tick.rawValue), hostTime: now, inputID: configuration.inputID,
            flash: TestPattern.isFlashTick(tick, frameRate: configuration.format.frameRate), background: configuration.background)
        CVPixelBufferLockBaseAddress(pb, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        let lbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let w = configuration.format.width, h = configuration.format.height
        TestPattern.draw(content, into: .nv12(luma: luma, lumaBytesPerRow: lbpr, chroma: chroma, chromaBytesPerRow: cbpr), width: w, height: h)
        if !noiseLuma.isEmpty {
            let k = Int(rng.next() % UInt64(noiseLuma.count))
            let off = Int(rng.next() % UInt64(h))
            let src = noiseLuma[k]
            for y in noiseRowStart..<h {
                memcpy(luma + y * lbpr, src + ((y + off) % h) * w, w)
            }
            if let chroma {
                let kc = Int(rng.next() % UInt64(noiseChroma.count))
                let csrc = noiseChroma[kc]
                let coff = Int(rng.next() % UInt64(h / 2))
                for cy in (noiseRowStart / 2)..<(h / 2) {
                    memcpy(chroma + cy * cbpr, csrc + ((cy + coff) % (h / 2)) * w, w)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        sequence += 1
        let frame = Frame(pixelBuffer: pb, pts: tickTime, duration: frameDuration, color: .bt709Limited, inputNumber: 0,
                          sequence: sequence, ingressTime: now)
        return RenderedFrame(tick: tick, tickTime: tickTime, program: frame, submitTime: now, gpuStart: now, gpuEnd: now)
    }

    /// 从 `ticks.lowerBound` 到 `ticks.upperBound`（不含）逐拍喂给所有消费者。
    /// 实时节拍：每拍先 mach_wait_until 拍点时刻；`onTick` 在每拍喂完后调（喂音频用）。
    public func feed(consumers: [any FrameConsumer], clock: TickClockSpec, ticks: Range<Tick>, pacing: Pacing,
                     onTick: ((Tick, HostTime) -> Void)? = nil) throws -> FeedReport {
        var report = FeedReport()
        report.firstTickTime = clock.time(of: ticks.lowerBound)
        report.pushDurations.reserveCapacity(ticks.count * consumers.count)
        let late = frameDuration
        for tick in ticks {
            let tickTime = clock.time(of: tick)
            switch pacing {
            case .realTime:
                mach_wait_until(tickTime.ticks)
                if (HostClock.now() - tickTime) > late { report.lateTicks += 1 }
            case .fastest(let ready):
                var spins = 0
                while !ready() {
                    spins += 1
                    if spins > 200_000 { break }
                    usleep(200)
                }
            }
            let frame = try makeFrame(tick: tick, tickTime: tickTime)
            for c in consumers {
                let t0 = HostClock.now()
                c.consume(frame)
                report.pushDurations.append(HostClock.now() - t0)
            }
            report.framesFed += 1
            onTick?(tick, tickTime)
        }
        return report
    }
}

/// SplitMix64：够快、可复现，噪声平面和随机偏移用它。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension TestPattern {
    /// full-range 灰阶 → limited Y（契约里的 limitedLuma 是内部函数，这里按同一公式算）。
    static func limitedLumaPublic(_ level: UInt8) -> UInt8 { UInt8((16 + 219 * Double(level) / 255).rounded()) }
}
