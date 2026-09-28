import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwitcherContracts
import VideoToolbox

/// 用 VideoToolbox 直接把合成源的帧编成 H.264 写 .mov（只为测试素材，不依赖 W1-E 的编码器）。
///
/// 画面由两路 `SyntheticVideoInput.Generator`（A：60 fps 灰 64 ID 0；B：30 fps 灰 192 ID 1）按契约挑帧规则
/// （每拍取 pts ≤ 拍点的最新帧）离线合成，脚本可在指定拍 Cut / Fade；Fade 第 s + k 拍 progress = k / D，
/// 混合在 NV12 上逐字节线性插值。音轨是 `TestSignal`（click 与闪光共用 t0），AAC / PCM / 无三选一，默认单声道（`audioChannels` ≥ 2 时每个声道同一路）。
/// 视频 PTS = n / fps，音频 PTS = 样本序号 / 48000，两者的零点都是 t0，所以文件里闪光与 click 严格同刻。
public enum SampleMovieWriter {
    /// 脚本事件。转场的几何与 W3-B 的渲染器一致：Fade = 逐像素混合，Wipe = 擦边位置 = 进度（软边取 50% 点），
    /// Zoom = 新画面绕画面中心按进度缩放。
    public enum Event: Hashable, Sendable {
        case cut(tick: Int)
        case fade(tick: Int, durationTicks: Int)
        case wipe(tick: Int, durationTicks: Int, direction: WipeDirection, softness: Double)
        case zoom(tick: Int, durationTicks: Int)
        var tick: Int {
            switch self {
            case .cut(let t), .fade(let t, _), .wipe(let t, _, _, _), .zoom(let t, _): t
            }
        }
        /// 转场类型。
        public var type: TransitionType {
            switch self {
            case .cut: .cut
            case .fade: .fade
            case .wipe: .wipe
            case .zoom: .zoom
            }
        }
        /// 时长（拍）；Cut 是 0。
        public var durationTicks: Int {
            switch self {
            case .cut: 0
            case .fade(_, let d), .wipe(_, let d, _, _), .zoom(_, let d): d
            }
        }
    }

    public enum AudioMode: Hashable, Sendable {
        case none
        case aac(bitrate: Int)
        case pcm16
    }

    public struct Spec: Hashable, Sendable {
        public var width = 1920
        public var height = 1080
        /// 节目帧率。
        public var frameRate: FrameRate = .fps60
        public var seconds: Double = 20
        /// H.264 平均码率（bit/s）。
        public var bitrate = 2_000_000
        public var keyFrameInterval = 120
        public var audio: AudioMode = .aac(bitrate: 128_000)
        /// 音轨声道数：1 = 单声道；≥ 2 = 每个声道放同一路 `TestSignal`（交错写）。录制器与推流出来的 AAC 都是立体声，
        /// frameprobe 读多声道音轨走的是另一条分支（先按声道取平均），W1-A4 的内存用例要的就是这条路。
        public var audioChannels = 1
        /// 源 A / B。
        public var sourceA = SyntheticSourceSettings(frameRate: .fps60, background: .gray(level: 64), patternID: 0, audio: false)
        public var sourceB = SyntheticSourceSettings(frameRate: .fps30, background: .gray(level: 192), patternID: 1, audio: false)
        /// 节目从 A 开始；事件按拍。
        public var events: [Event] = [.cut(tick: 400), .fade(tick: 700, durationTicks: 30)]
        /// 时间线原点（固定值，素材可复现）。
        public var t0 = HostTime(nanoseconds: 1_000_000_000)
        /// 画完后给亮度加 ±noise 的均匀噪声（压码率找解码极限用；0 = 不加）。
        public var noise = 0
        /// 强制软件编码器。
        public var softwareEncoder = false
        public init() {}
    }

    public struct Report: Hashable, Codable, Sendable {
        public var frames: Int
        public var videoBytes: Int
        public var fileBytes: Int
        public var averageKbps: Double
        public var encodeSeconds: Double
        public var audioSamples: Int
    }

    public enum WriterError: Error, CustomStringConvertible {
        case vt(String, OSStatus)
        case writer(String)
        public var description: String {
            switch self {
            case .vt(let what, let s): "VideoToolbox \(what) 失败：\(s)"
            case .writer(let s): "AVAssetWriter：\(s)"
            }
        }
    }

    // MARK: 离线合成

    /// 离线节目：第 n 拍该输出哪一帧（纯函数，素材生成和测试共用）。
    public struct Program: Sendable {
        public let spec: Spec
        public let clock: TickClockSpec
        public let a: SyntheticVideoInput.Generator
        public let b: SyntheticVideoInput.Generator
        let sortedEvents: [Event]

        public init(spec: Spec) {
            self.spec = spec
            let timeline = SyntheticTimeline(t0: spec.t0, frameRate: spec.frameRate)
            clock = timeline.videoClock(driftPpm: 0)
            a = SyntheticVideoInput.Generator(timeline: SyntheticTimeline(t0: spec.t0, frameRate: spec.sourceA.frameRate), settings: spec.sourceA, patternID: spec.sourceA.patternID ?? 0)
            b = SyntheticVideoInput.Generator(timeline: SyntheticTimeline(t0: spec.t0, frameRate: spec.sourceB.frameRate), settings: spec.sourceB, patternID: spec.sourceB.patternID ?? 1)
            sortedEvents = spec.events.sorted { $0.tick < $1.tick }
        }

        /// 第 n 拍的合成状态。
        public struct Pick: Hashable, Sendable {
            /// 底层（旧画面）是 A 吗。
            public var baseIsA: Bool
            /// 底层源的帧序号。
            public var baseFrame: Int64
            /// 顶层源的帧序号（progress > 0 时有意义）。
            public var topFrame: Int64
            /// 新画面盖上去的比例 0–1。
            public var progress: Double
            /// 进行中的转场类型（progress > 0 时有意义）。
            public var type: TransitionType = .fade
            /// Wipe 的方向与软边。
            public var wipe = WipeParams()
        }

        /// 拍 n 时：当前节目源（Cut 立即换、转场到 D 拍换）与进行中转场的进度。
        public func pick(tick n: Int) -> Pick {
            var currentIsA = true
            var progress = 0.0
            var type = TransitionType.fade
            var wipe = WipeParams()
            for e in sortedEvents where e.tick <= n {
                if case .cut = e {
                    currentIsA.toggle()
                    progress = 0
                    continue
                }
                let k = n - e.tick
                if k >= e.durationTicks {
                    currentIsA.toggle()
                    progress = 0
                } else {
                    progress = Double(k) / Double(e.durationTicks)
                    type = e.type
                    if case .wipe(_, _, let direction, let softness) = e { wipe = WipeParams(direction: direction, softness: softness) }
                }
            }
            let t = clock.time(of: Tick(Int64(n)))
            let fa = a.clock.tick(at: t).rawValue, fb = b.clock.tick(at: t).rawValue
            return Pick(baseIsA: currentIsA, baseFrame: currentIsA ? fa : fb, topFrame: currentIsA ? fb : fa, progress: progress,
                        type: type, wipe: wipe)
        }

        /// 把第 n 拍画进 NV12 缓冲（`scratch` 是同尺寸的第二个缓冲，混合时用）。
        public func render(tick n: Int, into pb: CVPixelBuffer, scratch: CVPixelBuffer) {
            let p = pick(tick: n)
            let base = p.baseIsA ? a : b, top = p.baseIsA ? b : a
            TestPattern.draw(base.content(of: p.baseFrame), into: pb)
            if p.progress > 0 {
                TestPattern.draw(top.content(of: p.topFrame), into: scratch)
                switch p.type {
                case .wipe: SampleMovieWriter.wipeNV12(into: pb, top: scratch, progress: p.progress, wipe: p.wipe)
                case .zoom: SampleMovieWriter.zoomNV12(into: pb, top: scratch, progress: p.progress)
                default: SampleMovieWriter.blendNV12(into: pb, top: scratch, progress: p.progress)
                }
            }
            if spec.noise > 0 { SampleMovieWriter.addLumaNoise(pb, amplitude: spec.noise, seed: UInt64(n)) }
        }
    }

    /// out = base × (1 − p) + top × p，逐字节四舍五入，两个平面都混。
    public static func blendNV12(into base: CVPixelBuffer, top: CVPixelBuffer, progress: Double) {
        CVPixelBufferLockBaseAddress(base, [])
        CVPixelBufferLockBaseAddress(top, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(top, .readOnly)
            CVPixelBufferUnlockBaseAddress(base, [])
        }
        let p = Float(progress), q = 1 - p
        for plane in 0..<2 {
            guard let bp = CVPixelBufferGetBaseAddressOfPlane(base, plane), let tp = CVPixelBufferGetBaseAddressOfPlane(top, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(base, plane)
            let width = CVPixelBufferGetWidthOfPlane(base, plane) * (plane == 0 ? 1 : 2)
            let bbpr = CVPixelBufferGetBytesPerRowOfPlane(base, plane), tbpr = CVPixelBufferGetBytesPerRowOfPlane(top, plane)
            for y in 0..<rows {
                let br = (bp + y * bbpr).assumingMemoryBound(to: UInt8.self)
                let tr = (tp + y * tbpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    br[x] = UInt8((Float(br[x]) * q + Float(tr[x]) * p).rounded())
                }
            }
        }
    }

    /// Wipe：新画面整幅盖上，每个像素按自己在画面里的位置算遮罩 alpha（与 W3-B `Compositor.metal` 的 `wipeAlpha` 逐字一致：
    /// 硬边 `f < e`，软边 `1 − smoothstep(e − s/2, e + s/2, f)`，擦边位置 e = 进度，f 按方向取归一化坐标）。
    /// 色度按 2×2 块中心算 alpha（渲染器是逐像素算完再下采样，边上差半个色度样本，对帧号 / 灰度的判读没有影响）。
    public static func wipeNV12(into base: CVPixelBuffer, top: CVPixelBuffer, progress: Double, wipe: WipeParams) {
        CVPixelBufferLockBaseAddress(base, [])
        CVPixelBufferLockBaseAddress(top, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(top, .readOnly)
            CVPixelBufferUnlockBaseAddress(base, [])
        }
        let w = CVPixelBufferGetWidth(base), h = CVPixelBufferGetHeight(base)
        let e = Float(min(max(progress, 0), 1)), soft = Float(min(max(wipe.softness, 0), 1))
        func alpha(_ px: Float, _ py: Float) -> Float {
            let f: Float
            switch wipe.direction {
            case .leftToRight: f = px
            case .rightToLeft: f = 1 - px
            case .topToBottom: f = py
            case .bottomToTop: f = 1 - py
            case .diagonal: f = (px + py) * 0.5
            }
            if soft <= 0 { return f < e ? 1 : 0 }
            let t = min(max((f - (e - 0.5 * soft)) / soft, 0), 1)
            return 1 - t * t * (3 - 2 * t)
        }
        for plane in 0..<2 {
            guard let bp = CVPixelBufferGetBaseAddressOfPlane(base, plane), let tp = CVPixelBufferGetBaseAddressOfPlane(top, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(base, plane)
            let columns = CVPixelBufferGetWidthOfPlane(base, plane)
            let bbpr = CVPixelBufferGetBytesPerRowOfPlane(base, plane), tbpr = CVPixelBufferGetBytesPerRowOfPlane(top, plane)
            for y in 0..<rows {
                let br = (bp + y * bbpr).assumingMemoryBound(to: UInt8.self)
                let tr = (tp + y * tbpr).assumingMemoryBound(to: UInt8.self)
                let py = plane == 0 ? (Float(y) + 0.5) / Float(h) : (Float(2 * y) + 1) / Float(h)
                for x in 0..<columns {
                    let px = plane == 0 ? (Float(x) + 0.5) / Float(w) : (Float(2 * x) + 1) / Float(w)
                    let p = alpha(px, py), q = 1 - p
                    if plane == 0 {
                        br[x] = UInt8((Float(br[x]) * q + Float(tr[x]) * p).rounded())
                    } else {
                        br[2 * x] = UInt8((Float(br[2 * x]) * q + Float(tr[2 * x]) * p).rounded())
                        br[2 * x + 1] = UInt8((Float(br[2 * x + 1]) * q + Float(tr[2 * x + 1]) * p).rounded())
                    }
                }
            }
        }
    }

    /// Zoom：新画面绕画面中心按进度缩放（尺度 = 进度，`PixelRect.scaled`），盖在旧画面上，不透明。
    /// 取样用最近邻（素材只用来量新画面的边在哪，内部细节不参与判定）。
    public static func zoomNV12(into base: CVPixelBuffer, top: CVPixelBuffer, progress: Double) {
        CVPixelBufferLockBaseAddress(base, [])
        CVPixelBufferLockBaseAddress(top, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(top, .readOnly)
            CVPixelBufferUnlockBaseAddress(base, [])
        }
        let w = Double(CVPixelBufferGetWidth(base)), h = Double(CVPixelBufferGetHeight(base))
        let scale = min(max(progress, 0), 1)
        let dw = w * scale, dh = h * scale
        let x0 = (w - dw) / 2, y0 = (h - dh) / 2
        guard dw >= 1, dh >= 1 else { return }
        for plane in 0..<2 {
            guard let bp = CVPixelBufferGetBaseAddressOfPlane(base, plane), let tp = CVPixelBufferGetBaseAddressOfPlane(top, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(base, plane)
            let columns = CVPixelBufferGetWidthOfPlane(base, plane)
            let bbpr = CVPixelBufferGetBytesPerRowOfPlane(base, plane), tbpr = CVPixelBufferGetBytesPerRowOfPlane(top, plane)
            let sub = plane == 0 ? 1.0 : 2.0
            for y in 0..<rows {
                let py = (Double(y) + 0.5) * sub
                guard py >= y0, py < y0 + dh else { continue }
                let sy = min(rows - 1, max(0, Int((py - y0) / scale / sub)))
                let br = (bp + y * bbpr).assumingMemoryBound(to: UInt8.self)
                let tr = (tp + sy * tbpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<columns {
                    let px = (Double(x) + 0.5) * sub
                    guard px >= x0, px < x0 + dw else { continue }
                    let sx = min(columns - 1, max(0, Int((px - x0) / scale / sub)))
                    if plane == 0 {
                        br[x] = tr[sx]
                    } else {
                        br[2 * x] = tr[2 * sx]
                        br[2 * x + 1] = tr[2 * sx + 1]
                    }
                }
            }
        }
    }

    /// 亮度加 ±amplitude 均匀噪声（钳在 16–235）。
    public static func addLumaNoise(_ pb: CVPixelBuffer, amplitude: Int, seed: UInt64) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let rows = CVPixelBufferGetHeightOfPlane(pb, 0), width = CVPixelBufferGetWidthOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var rng = SplitMix64(seed: seed &+ 0x5EED)
        let span = UInt64(2 * amplitude + 1)
        for y in 0..<rows {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let n = Int(rng.next() % span) - amplitude
                row[x] = UInt8(min(235, max(16, Int(row[x]) + n)))
            }
        }
    }

    // MARK: 写文件

    /// 写 .mov。`progress` 每 100 帧回调一次。
    public static func write(spec: Spec, to url: URL, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Report {
        try? FileManager.default.removeItem(at: url)
        let program = Program(spec: spec)
        let fps = spec.frameRate.framesPerSecond
        let totalFrames = Int((spec.seconds * fps.doubleValue).rounded())
        // 时标必须是帧率分子的倍数，否则 59.94 的 1001/60000 会被 .mov 默认的 600 时标四舍五入（实测第 60 帧 1.0017 s 而不是 1.001）
        let timescale = SampleMovieWriter.timescale(for: fps)
        let frameTicks = CMTimeValue(fps.denominator) * CMTimeValue(Int64(timescale) / fps.numerator)

        let pool = try NV12PixelBufferPool(width: spec.width, height: spec.height, maximumBuffers: 16)
        let scratch = try NV12PixelBufferPool(width: spec.width, height: spec.height, maximumBuffers: 2)
        let sink = try Sink(url: url, spec: spec, seconds: spec.seconds)
        let session = try makeSession(spec: spec, sink: sink)

        let started = HostClock.now()
        for n in 0..<totalFrames {
            guard let pb = pool.take(), let tmp = scratch.take() else { throw WriterError.vt("pool", -1) }
            program.render(tick: n, into: pb, scratch: tmp)
            let pts = CMTime(value: CMTimeValue(n) * frameTicks, timescale: timescale)
            let dur = CMTime(value: frameTicks, timescale: timescale)
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: dur,
                                                         frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
                sink.handleVideo(status: status, sample: sb)
            }
            guard status == noErr else { throw WriterError.vt("EncodeFrame", status) }
            if let error = sink.failure { throw error }
            if (n + 1) % 100 == 0 { progress?(n + 1) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        if let error = sink.failure { throw error }
        try await sink.finish()
        let encodeSeconds = (HostClock.now() - started).seconds
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Report(frames: totalFrames, videoBytes: sink.videoBytes, fileBytes: fileBytes,
                      averageKbps: Double(sink.videoBytes) * 8 / spec.seconds / 1000, encodeSeconds: encodeSeconds, audioSamples: sink.audioWritten)
    }

    /// 写原始 NV12 帧目录（`%06d.nv12`，Y 平面接 CbCr 平面，无 padding），给 frameprobe 的目录输入做素材。
    public static func writeRawFrames(spec: Spec, to directory: URL, frames: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let program = Program(spec: spec)
        let pool = try NV12PixelBufferPool(width: spec.width, height: spec.height, maximumBuffers: 2)
        let scratch = try NV12PixelBufferPool(width: spec.width, height: spec.height, maximumBuffers: 2)
        for n in 0..<frames {
            guard let pb = pool.take(), let tmp = scratch.take() else { throw WriterError.vt("pool", -1) }
            program.render(tick: n, into: pb, scratch: tmp)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            var data = Data()
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let rows = CVPixelBufferGetHeightOfPlane(pb, plane)
                // 两个平面每行都是 width 字节（CbCr 交错、半宽）
                for y in 0..<rows { data.append(Data(bytes: base + y * bpr, count: spec.width)) }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            try data.write(to: directory.appendingPathComponent(String(format: "%06d.nv12", n)))
        }
    }

    // MARK: 内部

    /// 帧率分子的倍数且 ≥ 600：60 → 6000，59.94（60000/1001）→ 60000，30 → 3000。
    static func timescale(for fps: Rational) -> CMTimeScale {
        var t = fps.numerator
        while t < 600 { t *= 10 }
        return CMTimeScale(t)
    }

    static func makeSession(spec: Spec, sink: Sink) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        var encoderSpec: [CFString: Any] = [:]
        if spec.softwareEncoder {
            encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = false
        } else {
            encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
        }
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(spec.width), height: Int32(spec.height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: encoderSpec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let s = session else { throw WriterError.vt("SessionCreate", status) }
        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let r = VTSessionSetProperty(s, key: key, value: value)
            guard r == noErr || r == kVTPropertyNotSupportedErr else { throw WriterError.vt("SetProperty \(key)", r) }
        }
        try set(kVTCompressionPropertyKey_AverageBitRate, spec.bitrate as CFNumber)
        try set(kVTCompressionPropertyKey_DataRateLimits, [spec.bitrate / 8, 1] as CFArray)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, spec.frameRate.approximateFramesPerSecond as CFNumber)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, spec.keyFrameInterval as CFNumber)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return s
    }

    /// 收编码输出、管 AVAssetWriter。视频输入在第一个样本到达时按其格式描述创建（直通，不再编码）。
    /// 音轨与视频交错写：非实时模式下 AVAssetWriter 要求各轨大致齐头，一条轨落后太多另一条就 isReadyForMoreMediaData = false；
    /// 所以每追加一帧视频就把音频写到"视频 pts + 1 s"，视频输入不 ready 时先喂音频而不是死等（死等会让 VT 回调超时、会话报 −17691）。
    final class Sink: @unchecked Sendable {
        let writer: AVAssetWriter
        let spec: Spec
        let signal: TestSignal
        let totalAudioSamples: Int
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        var videoBytes = 0
        var audioWritten = 0
        var failure: Error?
        /// 声道数（`Spec.audioChannels`，至少 1）。
        let channels: Int
        private var chunk = [Float](repeating: 0, count: 4096)
        /// 多声道时的交错缓冲（chunk 的每个样本抄到每个声道）。
        private var interleaved: [Float]

        init(url: URL, spec: Spec, seconds: Double) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            self.spec = spec
            channels = max(1, spec.audioChannels)
            interleaved = channels > 1 ? [Float](repeating: 0, count: 4096 * channels) : []
            signal = SyntheticTimeline(t0: spec.t0, frameRate: spec.frameRate).audioSignal(driftPpm: 0)
            totalAudioSamples = spec.audio == .none ? 0 : Int(seconds * Double(signal.sampleRate))
        }

        func handleVideo(status: OSStatus, sample: CMSampleBuffer?) {
            guard failure == nil else { return }
            guard status == noErr, let sample else { failure = WriterError.vt("encode callback", status); return }
            if videoInput == nil {
                do { try startWriting(formatHint: sample) } catch { failure = error; return }
            }
            videoBytes += CMSampleBufferGetTotalSampleSize(sample)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            do {
                while !videoInput!.isReadyForMoreMediaData {
                    if try !feedAudio(upTo: pts + 1) { usleep(200) }
                }
                guard videoInput!.append(sample) else { throw WriterError.writer(writer.error?.localizedDescription ?? "append video") }
                _ = try feedAudio(upTo: pts + 1)
            } catch {
                failure = error
            }
        }

        private func startWriting(formatHint sample: CMSampleBuffer) throws {
            guard let fd = CMSampleBufferGetFormatDescription(sample) else { throw WriterError.writer("没有格式描述") }
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
            vi.expectsMediaDataInRealTime = false
            vi.mediaTimeScale = SampleMovieWriter.timescale(for: spec.frameRate.framesPerSecond)
            writer.movieTimeScale = vi.mediaTimeScale
            writer.add(vi)
            videoInput = vi
            var settings: [String: Any]?
            switch spec.audio {
            case .none:
                break
            case .aac(let bitrate):
                settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: signal.sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate]
            case .pcm16:
                settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: signal.sampleRate, AVNumberOfChannelsKey: channels,
                            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            }
            if let settings {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                ai.expectsMediaDataInRealTime = false
                writer.add(ai)
                audioInput = ai
                let frameBytes = UInt32(4 * channels)
                var asbd = AudioStreamBasicDescription(mSampleRate: Double(signal.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: frameBytes, mFramesPerPacket: 1,
                                                       mBytesPerFrame: frameBytes, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
                var format: CMAudioFormatDescription?
                let fs = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                        extensions: nil, formatDescriptionOut: &format)
                guard fs == noErr, let format else { throw WriterError.writer("音频格式描述 \(fs)") }
                audioFormat = format
            }
            guard writer.startWriting() else { throw WriterError.writer(writer.error?.localizedDescription ?? "startWriting") }
            writer.startSession(atSourceTime: .zero)
        }

        /// 把音频写到 `seconds`（不超过总长）。返回是否写了东西（false = 没得写或输入没 ready）。
        @discardableResult
        func feedAudio(upTo seconds: Double) throws -> Bool {
            guard let audioInput, let audioFormat else { return false }
            var wrote = false
            while audioWritten < totalAudioSamples && Double(audioWritten) / Double(signal.sampleRate) < seconds && audioInput.isReadyForMoreMediaData {
                let n = min(chunk.count, totalAudioSamples - audioWritten)
                let start = Int64(audioWritten)
                chunk.withUnsafeMutableBufferPointer { signal.render(into: $0.baseAddress!, frameCount: n, startingAt: start) }
                if channels > 1 {
                    for i in 0..<n {
                        for c in 0..<channels { interleaved[i * channels + c] = chunk[i] }
                    }
                }
                let bytes = n * 4 * channels
                var block: CMBlockBuffer?
                let bs = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
                guard bs == noErr, let block else { throw WriterError.writer("CMBlockBuffer \(bs)") }
                try (channels > 1 ? interleaved : chunk).withUnsafeBytes { raw in
                    let r = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                    guard r == noErr else { throw WriterError.writer("ReplaceDataBytes \(r)") }
                }
                var sample: CMSampleBuffer?
                let pts = CMTime(value: start, timescale: CMTimeScale(signal.sampleRate))
                let ss = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: n,
                                                                              presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
                guard ss == noErr, let sample else { throw WriterError.writer("音频样本 \(ss)") }
                guard audioInput.append(sample) else { throw WriterError.writer(writer.error?.localizedDescription ?? "append audio") }
                audioWritten += n
                wrote = true
            }
            return wrote
        }

        func finish() async throws {
            guard let videoInput else { throw WriterError.writer("没有编出任何帧") }
            videoInput.markAsFinished()
            while audioWritten < totalAudioSamples {
                if try !feedAudio(upTo: .infinity) { usleep(200) }
            }
            audioInput?.markAsFinished()
            await writer.finishWriting()
            if writer.status != .completed { throw WriterError.writer(writer.error?.localizedDescription ?? "finishWriting \(writer.status.rawValue)") }
        }
    }
}
