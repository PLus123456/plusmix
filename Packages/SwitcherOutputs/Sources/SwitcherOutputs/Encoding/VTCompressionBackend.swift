import CoreMedia
import CoreVideo
import VideoToolbox
import SwitcherContracts

/// VideoToolbox 后端（设计方案 §8 编码行）：H.264 / HEVC 硬件编码，ProRes 走硬件 ProRes 引擎。
///
/// 属性（macOS 26 实测全部生效，见报告）：RealTime 开、AllowFrameReordering 关（无 B 帧）、MaxKeyFrameInterval、
/// AverageBitRate + DataRateLimits[bitrate × factor / 8 字节, 1 s] 做准 CBR（factor 默认 1.5：探针实测 1.0 会欠 30%，1.5 误差 1.5%、峰值 1.18）。
/// ProRes 不接受码率 / GOP 类属性（-12900），只设 RealTime / ExpectedFrameRate / 色彩。
public final class VTCompressionBackend: VideoEncoderBackend, @unchecked Sendable {
    /// 会话参数。
    public struct Configuration: Hashable, Sendable {
        /// 输出宽高与帧率（宽高可被 settings.width/height 覆盖）。
        public var format: ProgramFormat
        /// 编码器、码率、关键帧间隔。
        public var settings: VideoEncodeSettings
        /// DataRateLimits 的倍数（相对 AverageBitRate）。
        public var dataRateLimitFactor: Double
        /// 硬件编码器是否必需（找不到就报错，不回落软件）。
        public var requireHardware: Bool

        public init(format: ProgramFormat, settings: VideoEncodeSettings, dataRateLimitFactor: Double = 1.5, requireHardware: Bool = false) {
            self.format = format
            self.settings = settings
            self.dataRateLimitFactor = dataRateLimitFactor
            self.requireHardware = requireHardware
        }

        /// 实际输出宽。
        public var width: Int { settings.width ?? format.width }
        /// 实际输出高。
        public var height: Int { settings.height ?? format.height }
    }

    /// 某个属性设置的结果（报告"哪些 key 被忽略"用）。
    public struct PropertyOutcome: Hashable, Sendable {
        public let key: String
        public let status: OSStatus
        public let readback: String?
    }

    public let configuration: Configuration
    /// 每个属性 VTSessionSetProperty 的返回值与回读，prepare 后可读。
    public private(set) var propertyOutcomes: [PropertyOutcome] = []
    /// VT 报告的编码器 ID（例如 com.apple.videotoolbox.videoencoder.ave.avc）。
    public private(set) var encoderID: String?
    /// 是否在用硬件编码器。
    public private(set) var usingHardware: Bool = false

    private var session: VTCompressionSession?
    private var output: (@Sendable (EncodedVideoSample) -> Void)?
    private var dropped: (@Sendable () -> Void)?

    // 在途帧的元数据环：refcon = 槽号 + 1；VT 保证每帧回调恰好一次（RealTime + 无重排下在途 ≤ 十几帧）。
    private struct InFlight { var tick: Tick = .zero; var tickTime: HostTime = .zero; var inTime: HostTime = .zero }
    private static let inFlightSlots = 256
    // 用裸指针而不是 Array：编码线程写槽、VT 线程读槽，两边碰的是不同槽位，不经过 Swift 的独占性检查。
    private let inFlight: UnsafeMutablePointer<InFlight>
    private var nextSlot = 0
    private let frameDuration: CMTime

    public init(configuration: Configuration) {
        self.configuration = configuration
        frameDuration = configuration.format.frameDuration.cmTime
        inFlight = .allocate(capacity: VTCompressionBackend.inFlightSlots)
        inFlight.initialize(repeating: InFlight(), count: VTCompressionBackend.inFlightSlots)
    }

    deinit {
        invalidate()
        inFlight.deinitialize(count: VTCompressionBackend.inFlightSlots)
        inFlight.deallocate()
    }

    /// 错误。
    public enum Error: Swift.Error, Equatable {
        /// VTCompressionSessionCreate 失败。
        case sessionCreateFailed(OSStatus)
        /// VTCompressionSessionEncodeFrame 失败。
        case encodeFailed(OSStatus)
        /// 没 prepare 就 encode。
        case notPrepared
    }

    public func prepare(output: @escaping @Sendable (EncodedVideoSample) -> Void, dropped: @escaping @Sendable () -> Void) throws {
        self.output = output
        self.dropped = dropped
        let codecType: CMVideoCodecType
        switch configuration.settings.codec {
        case .h264: codecType = kCMVideoCodecType_H264
        case .hevc: codecType = kCMVideoCodecType_HEVC
        case .prores422: codecType = kCMVideoCodecType_AppleProRes422
        case .prores422HQ: codecType = kCMVideoCodecType_AppleProRes422HQ
        case .prores4444: codecType = kCMVideoCodecType_AppleProRes4444
        }
        var spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        if configuration.requireHardware {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        // 输入永远是 NV12（BT.709 limited）IOSurface；ProRes 硬件也直接吃 NV12（探针 7）。
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: PixelFormat.nv12.cvPixelFormatType(range: .limited),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
        ]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(configuration.width), height: Int32(configuration.height), codecType: codecType,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: VTCompressionBackend.outputCallback, refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s)
        guard status == noErr, let s else { throw Error.sessionCreateFailed(status) }
        session = s
        applyProperties(to: s)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    private func applyProperties(to s: VTCompressionSession) {
        let settings = configuration.settings
        let isProRes: Bool
        switch settings.codec {
        case .h264, .hevc: isProRes = false
        case .prores422, .prores422HQ, .prores4444: isProRes = true
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: key, value: value)
            var back: CFTypeRef?
            VTSessionCopyProperty(s, key: key, allocator: nil, valueOut: &back)
            propertyOutcomes.append(PropertyOutcome(key: key as String, status: st, readback: back.map { "\($0)" }))
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.format.frameRate.approximateFramesPerSecond as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if !isProRes {
            set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.keyframeIntervalFrames as CFNumber)
            // 0 = 不按时长切关键帧，只按帧数（E3 的口径是帧）
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0 as CFNumber)
            set(kVTCompressionPropertyKey_AverageBitRate, settings.bitrateBps as CFNumber)
            let bytesPerWindow = Int((Double(settings.bitrateBps) / 8 * configuration.dataRateLimitFactor).rounded())
            set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerWindow as NSNumber, 1 as NSNumber] as CFArray)
            switch settings.codec {
            case .h264:
                set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
                set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
            case .hevc:
                set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
            default: break
            }
        }
        var id: CFTypeRef?
        if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &id) == noErr, let id {
            encoderID = "\(id)"
        }
        var hw: CFTypeRef?
        if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw) == noErr,
           let b = hw as? Bool {
            usingHardware = b
        }
    }

    public func encode(_ frame: RenderedFrame, forceKeyframe: Bool) throws {
        guard let session else { throw Error.notPrepared }
        let slot = nextSlot
        nextSlot = (nextSlot + 1) % VTCompressionBackend.inFlightSlots
        inFlight[slot] = InFlight(tick: frame.tick, tickTime: frame.tickTime, inTime: HostClock.now())
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame.program.pixelBuffer, presentationTimeStamp: frame.tickTime.cmTime,
            duration: frameDuration, frameProperties: props,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: slot + 1), infoFlagsOut: nil)
        if status != noErr { throw Error.encodeFailed(status) }
    }

    public func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // VT 回调：在 VT 自己的线程；这里只读槽、包装样本、转交。
    private static let outputCallback: VTCompressionOutputCallback = { refcon, frameRefcon, status, flags, sampleBuffer in
        guard let refcon else { return }
        let backend = Unmanaged<VTCompressionBackend>.fromOpaque(refcon).takeUnretainedValue()
        backend.handleOutput(frameRefcon: frameRefcon, status: status, flags: flags, sampleBuffer: sampleBuffer)
    }

    private func handleOutput(frameRefcon: UnsafeMutableRawPointer?, status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        let now = HostClock.now()
        let slot = frameRefcon.map { Int(bitPattern: $0) - 1 } ?? -1
        let meta = (slot >= 0 && slot < VTCompressionBackend.inFlightSlots) ? inFlight[slot] : InFlight()
        if flags.contains(.frameDropped) || status != noErr || sampleBuffer == nil {
            dropped?()
            return
        }
        guard let sb = sampleBuffer else { return }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool, notSync {
            isKeyframe = false
        }
        let sample = EncodedVideoSample(
            sampleBuffer: sb, tick: meta.tick, tickTime: meta.tickTime, isKeyframe: isKeyframe,
            byteCount: CMSampleBufferGetTotalSampleSize(sb), encodeLatency: now - meta.inTime, outputTime: now)
        output?(sample)
    }
}
