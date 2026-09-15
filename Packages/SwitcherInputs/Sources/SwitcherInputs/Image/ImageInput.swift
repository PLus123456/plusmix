import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import SwitcherContracts

/// 图片输入（设计方案 §6 "图片"）：一次解码成预乘 BGRA 的 IOSurface 缓冲（PNG alpha 保留、EXIF 方向已转正），
/// 大图预缩放到节目分辨率上限（保持长宽比、不放大），之后帧槽里永远是同一帧：自带的拍点线程每拍把它以 pts = 拍点 重新 push
/// （帧槽不靠 reused 撑画面，Stats 里 fps = 节目帧率、dup = 0）。没有音频。
public final class ImageInput: Input, @unchecked Sendable {
    /// 可调参数。
    public struct Options: Sendable, Hashable {
        /// 比拍点早多久 push。
        public var pushLead = HostDuration(milliseconds: 2)
        /// 缩放上限；nil = 节目分辨率。
        public var maxWidth: Int?
        public var maxHeight: Int?
        public init() {}
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .image
    public let videoSlot: (any FrameSlot)?
    public let audioRing: (any AudioRing)? = nil
    public var state: InputState { stateBox.value }
    public let path: String
    public let options: Options
    public var timing: ProgramTiming {
        get { timingBox.withLock { $0 } }
        set { timingBox.withLock { $0 = newValue } }
    }
    /// 解码（缩放后）的像素尺寸；start 前为 0。
    public var imageWidth: Int { decoded.withLock { $0.map { CVPixelBufferGetWidth($0.buffer) } ?? 0 } }
    public var imageHeight: Int { decoded.withLock { $0.map { CVPixelBufferGetHeight($0.buffer) } ?? 0 } }
    public var lastError: String? { errorBox.withLock { $0 } }
    public var counters: InputCounters { countersBox.snapshot(state: stateBox) }

    private let timingBox: Mutex<ProgramTiming>
    private let slot: any FrameSlot
    private let stateBox = InputStateBox()
    private let countersBox = InputCountersBox()
    private let decoded = Mutex<BufferBox?>(nil)
    private let errorBox = Mutex<String?>(nil)
    private var thread: InputThread?
    private let running = Atomic<Bool>(false)

    public enum ImageInputError: Error, CustomStringConvertible {
        case notAnImageSource(InputKind)
        case open(String)
        public var description: String {
            switch self {
            case .notAnImageSource(let k): "不是图片来源：\(k)"
            case .open(let m): m
            }
        }
    }

    public init(number: Int, name: String, path: String, timing: ProgramTiming, videoSlot: any FrameSlot, options: Options = Options()) throws {
        precondition(number >= 1, "输入编号从 1 起")
        self.number = number
        self.name = name
        self.path = path
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
    }

    /// 从 InputSource.image 构造。
    public convenience init(config: InputConfig, timing: ProgramTiming, videoSlot: any FrameSlot, options: Options = Options()) throws {
        guard case .image(let path) = config.source else { throw ImageInputError.notAnImageSource(config.source.kind) }
        try self.init(number: config.number, name: config.name, path: path, timing: timing, videoSlot: videoSlot, options: options)
    }

    /// 解码（同步，可能几十毫秒）并起拍点线程。解不开时 state = error 并抛出。
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let timing = self.timing
        let maxW = options.maxWidth ?? timing.format.width
        let maxH = options.maxHeight ?? timing.format.height
        let pb: CVPixelBuffer
        do {
            pb = try ImageInput.decode(path: path, maxWidth: maxW, maxHeight: maxH)
        } catch {
            let message = "\(error)"
            errorBox.withLock { $0 = message }
            stateBox.set(.error(message: message))
            running.store(false, ordering: .releasing)
            throw ImageInputError.open(message)
        }
        let box = BufferBox(pb)
        decoded.withLock { $0 = box }
        errorBox.withLock { $0 = nil }
        countersBox.surfaces.note(pb)
        let t = InputThread(name: "image-\(number)", period: timing.frameDuration) { [self] thread in
            run(thread: thread, buffer: box.buffer, timing: timing)
        }
        thread = t
        t.start()
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        thread?.stop()
        thread = nil
        stateBox.set(.noSignal)
    }

    /// 把 CVPixelBuffer 带进线程闭包（写完即冻结，之后只读；契约 Frame 同一理由）。
    final class BufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ b: CVPixelBuffer) { buffer = b }
    }

    // MARK: 拍点线程

    private func run(thread: InputThread, buffer: CVPixelBuffer, timing: ProgramTiming) {
        let lead = options.pushLead
        let duration = timing.frameDuration
        var tick = timing.nextTick(atOrAfter: HostClock.now() + lead)
        var sequence: UInt64 = 0
        while !thread.isStopRequested {
            let tickTime = timing.time(of: tick)
            thread.sleep(until: tickTime - lead)
            if thread.isStopRequested { break }
            // 落后 2 拍以上（被抢占）：跳到当前拍
            let nowTick = timing.tick(at: HostClock.now())
            if tick + 2 < nowTick { tick = nowTick; continue }
            sequence += 1
            slot.push(Frame(pixelBuffer: buffer, pts: tickTime, duration: duration, color: .sRGBFull,
                            inputNumber: number, sequence: sequence, ingressTime: HostClock.now()))
            countersBox.framesReceived.add(1, ordering: .relaxed)
            countersBox.framesPushed.add(1, ordering: .relaxed)
            if sequence == 1 { stateBox.set(.live) }
            tick += 1
        }
    }

    // MARK: 解码

    enum DecodeError: Error, CustomStringConvertible {
        case notFound(String)
        case unreadable(String)
        case createFailed(String, CVReturn)
        var description: String {
            switch self {
            case .notFound(let p): "图片不存在：\(p)"
            case .unreadable(let p): "读不出图片：\(p)"
            case .createFailed(let p, let r): "建像素缓冲失败（\(r)）：\(p)"
            }
        }
    }

    /// 解码 + 转正 + 缩放到 maxWidth × maxHeight 以内（不放大）→ 预乘 BGRA、sRGB、IOSurface 背后。
    static func decode(path: String, maxWidth: Int, maxHeight: Int) throws -> CVPixelBuffer {
        guard FileManager.default.fileExists(atPath: path) else { throw DecodeError.notFound(path) }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw DecodeError.unreadable(path) }
        // 用缩略图接口一次完成解码 + EXIF 转正 + 按长边缩放（不放大）
        let longest = max(maxWidth, maxHeight)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DecodeError.unreadable(path) }
        // 再按两边一起收进节目框（长边限制只保证了一边）
        var w = image.width, h = image.height
        if w > maxWidth || h > maxHeight {
            let scale = min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h))
            w = max(2, Int((Double(w) * scale).rounded(.down)))
            h = max(2, Int((Double(h) * scale).rounded(.down)))
        }
        w &= ~1; h &= ~1   // 偶数尺寸（4:2:0 消费者友好）
        let pb = try PixelBuffers.make(width: max(w, 2), height: max(h, 2), format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw DecodeError.createFailed(path, -1) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // BGRA 预乘：小端 32 位 + premultipliedFirst（ARGB 大端 = BGRA 小端字节序）
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: cs, bitmapInfo: info) else { throw DecodeError.createFailed(path, -2) }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}
