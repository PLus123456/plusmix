// 虚拟摄像头扩展（CMIOExtension API，macOS 12.3+）：一个 provider → 一个设备 → 两条流。
//   source stream：给 FaceTime / QuickTime 等读，1080p NV12，帧率跟主程序送来的帧。
//   sink stream：Switcher 主程序经 CoreMediaIO 客户端 API 往里写 PGM 帧（IOSurface，PTS = 拍点时刻 host time）；
//                每收到一帧就原样从 source stream 发出去，不拷像素。没有主程序在送时，按 placeholderFrameRate 产占位画面（深灰 + 移动的白条），
//                让选到摄像头的 App 看得见"设备活着"。
// 常量（设备名 / UID / 流 UID / 允许写 sink 的签名 ID 前缀）来自 Packages/SwitcherOutputs/Sources/VirtualCamera/Shared/（project.yml 按路径编进来）。
// 线程：CMIOExtension 在自己的队列上调 start / stop / 属性；占位画面在 timerQueue；consumeSampleBuffer 的回调在扩展队列。共享状态用一把锁。
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

private let log = OSLog(subsystem: "app.switcher.camera-extension", category: "provider")

/// 固定的设备 / 流 ID（跨启动稳定，系统按它记住设备）。
private enum FixedIDs {
    static let device = UUID(uuidString: "3D7C2B9A-5F1E-4C8B-9A6D-1E2F3A4B5C6D")!
    static let sourceStream = UUID(uuidString: "3D7C2B9A-5F1E-4C8B-9A6D-1E2F3A4B5C6E")!
    static let sinkStream = UUID(uuidString: "3D7C2B9A-5F1E-4C8B-9A6D-1E2F3A4B5C6F")!
}

// MARK: - Provider

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: VirtualCameraConstants.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            os_log(.error, log: log, "加不上设备：%{public}@", "\(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {
        deviceSource.clientDisconnected(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Switcher" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CameraStreamSource!
    private var sinkStream: CameraStreamSource!
    private let formatDescription: CMFormatDescription
    private let streamFormat: CMIOExtensionStreamFormat
    private var pool: CVPixelBufferPool?

    private let lock = NSLock()
    private var sourceClients = 0
    private var sinkStreaming = false
    private var sinkClient: CMIOExtensionClient?
    private var placeholderTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "app.switcher.camera-extension.placeholder", qos: .userInteractive)
    private var placeholderIndex: UInt64 = 0
    /// 主程序送进来、转发出去的帧数（诊断）。
    private var forwarded: UInt64 = 0

    init(localizedName: String) {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       width: Int32(VirtualCameraConstants.width), height: Int32(VirtualCameraConstants.height),
                                       extensions: nil, formatDescriptionOut: &fd)
        formatDescription = fd!
        let frame = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraConstants.nominalFrameRate))
        streamFormat = CMIOExtensionStreamFormat(formatDescription: formatDescription, maxFrameDuration: CMTime(value: 1, timescale: 24),
                                                 minFrameDuration: frame, validFrameDurations: nil)
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: FixedIDs.device, legacyDeviceID: VirtualCameraConstants.deviceUID, source: self)
        sourceStream = CameraStreamSource(localizedName: VirtualCameraConstants.sourceStreamName, streamID: FixedIDs.sourceStream,
                                          direction: .source, streamFormat: streamFormat, device: self)
        sinkStream = CameraStreamSource(localizedName: VirtualCameraConstants.sinkStreamName, streamID: FixedIDs.sinkStream,
                                        direction: .sink, streamFormat: streamFormat, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            os_log(.error, log: log, "加不上流：%{public}@", "\(error)")
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: VirtualCameraConstants.width,
            kCVPixelBufferHeightKey as String: VirtualCameraConstants.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = VirtualCameraConstants.deviceModel }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: 流的起停（CameraStreamSource 调）

    func startStreaming(_ stream: CameraStreamSource, client: CMIOExtensionClient?) {
        lock.lock()
        if stream === sourceStream {
            sourceClients += 1
            let needPlaceholder = !sinkStreaming && placeholderTimer == nil
            lock.unlock()
            if needPlaceholder { startPlaceholder() }
        } else {
            sinkStreaming = true
            sinkClient = client
            lock.unlock()
            stopPlaceholder()
            if let client { consumeNext(from: client) }
        }
    }

    func stopStreaming(_ stream: CameraStreamSource) {
        lock.lock()
        if stream === sourceStream {
            sourceClients = max(0, sourceClients - 1)
            let stopNow = sourceClients == 0
            lock.unlock()
            if stopNow { stopPlaceholder() }
        } else {
            sinkStreaming = false
            sinkClient = nil
            let restart = sourceClients > 0
            lock.unlock()
            if restart { startPlaceholder() }
        }
    }

    func clientDisconnected(_ client: CMIOExtensionClient) {
        lock.lock()
        let wasSink = sinkClient === client
        lock.unlock()
        if wasSink { stopStreaming(sinkStream) }
    }

    /// sink 只让 Switcher 主程序写（签名 ID 前缀）；开发期 ad-hoc 签名的 signingID 也是 bundle ID，能过；拿不到签名 ID 的放行并记日志。
    func authorizeSink(client: CMIOExtensionClient) -> Bool {
        guard let id = client.signingID else {
            os_log(.info, log: log, "sink 客户端没有签名 ID，放行（开发期）")
            return true
        }
        let ok = id.hasPrefix(VirtualCameraConstants.allowedClientSigningIDPrefix)
        if !ok { os_log(.error, log: log, "拒绝往 sink 写的客户端：%{public}@", id) }
        return ok
    }

    // MARK: 主程序 → sink → source

    /// 从 sink 取一帧，原样从 source 发出去，再取下一帧（直到 sink 停）。hostTimeInNanoseconds = 帧的 PTS（主程序打的拍点 host time）。
    private func consumeNext(from client: CMIOExtensionClient) {
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, _, _, _, error in
            guard let self else { return }
            let streaming = self.lock.withLock { self.sinkStreaming }
            guard streaming else { return }
            if let sampleBuffer {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ns = pts.isNumeric ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000_000) : mach_absolute_time_nanoseconds()
                self.sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: ns)
                self.lock.withLock { self.forwarded += 1 }
            } else if let error {
                os_log(.error, log: log, "sink 取帧失败：%{public}@", "\(error)")
            }
            self.consumeNext(from: client)
        }
    }

    // MARK: 占位画面

    private func startPlaceholder() {
        lock.lock()
        guard placeholderTimer == nil else { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / VirtualCameraConstants.placeholderFrameRate), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.sendPlaceholderFrame() }
        placeholderTimer = t
        lock.unlock()
        t.resume()
    }

    private func stopPlaceholder() {
        lock.lock()
        let t = placeholderTimer
        placeholderTimer = nil
        lock.unlock()
        t?.cancel()
    }

    /// 深灰底 + 一根从左到右移动的白条（每帧移 8 像素），NV12 直接写平面。
    private func sendPlaceholderFrame() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
        let index = lock.withLock { () -> UInt64 in placeholderIndex += 1; return placeholderIndex }
        CVPixelBufferLockBaseAddress(pb, [])
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            memset(y, 40, bpr * h)
            let barX = Int((index * 8) % UInt64(w - 32))
            for row in 0..<h {
                memset(y + row * bpr + barX, 235, 32)
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * (h / 2))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return }
        let now = mach_absolute_time_nanoseconds()
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCameraConstants.placeholderFrameRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        sourceStream.stream.send(sb, discontinuity: [], hostTimeInNanoseconds: now)
    }
}

/// mach_absolute_time → 纳秒。
private func mach_absolute_time_nanoseconds() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let t = mach_absolute_time()
    return t * UInt64(info.numer) / UInt64(info.denom)
}

// MARK: - Stream

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let direction: CMIOExtensionStream.Direction
    private let streamFormat: CMIOExtensionStreamFormat
    private unowned let device: CameraDeviceSource
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction, streamFormat: CMIOExtensionStreamFormat, device: CameraDeviceSource) {
        self.direction = direction
        self.streamFormat = streamFormat
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCameraConstants.nominalFrameRate)) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = VirtualCameraConstants.sinkQueueDepth }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        direction == .sink ? device.authorizeSink(client: client) : true
    }

    func startStream() throws {
        device.startStreaming(self, client: nil)
    }

    func stopStream() throws {
        device.stopStreaming(self)
    }

    /// sink 方向：系统告诉我们是哪个客户端在写（macOS 13+ 的带 client 版本）。
    func startStream(for client: CMIOExtensionClient) throws {
        device.startStreaming(self, client: client)
    }
}
