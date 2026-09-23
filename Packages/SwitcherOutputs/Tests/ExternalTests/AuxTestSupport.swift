// W3-C2 的测试工装：契约语义的测试帧槽、TestPattern 的 1080p 帧（BGRA / NV12 / UYVY）、按帧率推帧的线程、离屏纹理读回。
// ExternalTests 不依赖 TestKit / Engine（依赖方向：TestKit 在 Outputs 之上；Package.swift 不归本会话），所以合成源用契约里的 TestPattern 自己画。
@preconcurrency import Metal
import AppKit
import CoreVideo
import Darwin
import Synchronization
import XCTest
import SwitcherContracts
@testable import SwitcherExternal

/// 测试用帧槽：契约 `FrameSlot` 的最小实现（统计口径同 CONTRACTS §2.3：consumed / reused / dropped）。
/// push 在推帧线程、latest 在读的线程（窗口里是主线程）；测试替身不在实时线程上，用锁。
final class TestFrameSlot: FrameSlot, @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var pending: [Frame] = []
    private var last: Frame?
    private var counts = FrameSlotStats()

    init(capacity: Int = 3) { self.capacity = capacity }

    func push(_ frame: Frame) {
        lock.withLock {
            counts.pushed += 1
            pending.append(frame)
            if pending.count > capacity {
                pending.removeFirst()   // 从未被返回过就被挤掉
                counts.dropped += 1
            }
        }
    }

    func latest(atOrBefore time: HostTime) -> Frame? {
        lock.withLock {
            if let index = pending.lastIndex(where: { $0.pts <= time }) {
                counts.dropped += UInt64(index)   // 被更新的帧跳过的旧帧
                let f = pending[index]
                pending.removeFirst(index + 1)
                last = f
                counts.consumed += 1
                return f
            }
            guard let last else { return nil }
            counts.consumed += 1
            counts.reused += 1
            return last
        }
    }

    var stats: FrameSlotStats { lock.withLock { counts } }
}

/// TestPattern 画的 1080p 帧。
enum PatternFrames {
    /// IOSurface 背后的像素缓冲（渲染器和 CVMetalTextureCache 都要 IOSurface）。
    static func pixelBuffer(_ format: OSType, width: Int = 1920, height: Int = 1080) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        let st = CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb)
        precondition(st == kCVReturnSuccess, "CVPixelBufferCreate \(st)")
        return pb!
    }

    /// 带噪声底纹的图案（每个像素都不一样，缩略格子放大回来不可能逐像素相等）。
    static func content(frameNumber: UInt32, inputID: Int = 3) -> TestPattern.Content {
        TestPattern.Content(frameNumber: frameNumber, hostTimeMs: frameNumber &* 17, inputID: inputID, flash: frameNumber % 60 == 0,
                            background: .noise(level: 128, amplitude: 60, seed: 11))
    }

    static func bgra(frameNumber: UInt32, width: Int = 1920, height: Int = 1080) -> CVPixelBuffer {
        let pb = pixelBuffer(kCVPixelFormatType_32BGRA, width: width, height: height)
        TestPattern.draw(content(frameNumber: frameNumber), into: pb)
        return pb
    }

    static func nv12(frameNumber: UInt32, fullRange: Bool = false, width: Int = 1920, height: Int = 1080) -> CVPixelBuffer {
        let pb = pixelBuffer(fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                             width: width, height: height)
        TestPattern.draw(content(frameNumber: frameNumber), into: pb)
        return pb
    }

    /// NV12 → UYVY（'2vuy'）：亮度照抄，色度取同一对 4:2:0 样本（纵向两行共用），这样与原 NV12 同一套码值。
    static func uyvy(from nv12: CVPixelBuffer) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(nv12), h = CVPixelBufferGetHeight(nv12)
        let out = pixelBuffer(kCVPixelFormatType_422YpCbCr8, width: w, height: h)
        CVPixelBufferLockBaseAddress(nv12, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(nv12, .readOnly)
        }
        let y = CVPixelBufferGetBaseAddressOfPlane(nv12, 0)!.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0)
        let c = CVPixelBufferGetBaseAddressOfPlane(nv12, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1)
        let o = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let obpr = CVPixelBufferGetBytesPerRow(out)
        for row in 0..<h {
            for pair in 0..<(w / 2) {
                let cb = c[(row / 2) * cbpr + pair * 2], cr = c[(row / 2) * cbpr + pair * 2 + 1]
                let base = row * obpr + pair * 4
                o[base] = cb                                 // U
                o[base + 1] = y[row * ybpr + pair * 2]       // Y0
                o[base + 2] = cr                             // V
                o[base + 3] = y[row * ybpr + pair * 2 + 1]   // Y1
            }
        }
        return out
    }

    static func frame(_ pb: CVPixelBuffer, input: Int = 1, sequence: UInt64 = 1, pts: HostTime = .now(),
                      duration: HostDuration = HostDuration(milliseconds: 1000.0 / 60), color: ColorInfo? = nil) -> Frame {
        let c: ColorInfo
        if let color {
            c = color
        } else {
            switch CVPixelBufferGetPixelFormatType(pb) {
            case kCVPixelFormatType_32BGRA: c = .sRGBFull
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: c = .bt709Full
            default: c = .bt709Limited
            }
        }
        return Frame(pixelBuffer: pb, pts: pts, duration: duration, color: c, inputNumber: input, sequence: sequence, ingressTime: pts)
    }
}

/// 按帧率往帧槽推帧的线程（轮换几块预先画好的缓冲，pts = ingressTime = 推的那一刻）。
final class FramePusher: @unchecked Sendable {
    private final class Flag: Sendable { let value = Atomic<Bool>(false) }
    private let stopFlag = Flag()
    private let pushedCount = Atomic<UInt64>(0)
    private var thread: Thread?
    let slot: any FrameSlot
    let buffers: [CVPixelBuffer]
    let framesPerSecond: Double
    let input: Int

    init(slot: any FrameSlot, buffers: [CVPixelBuffer], framesPerSecond: Double = 60, input: Int = 1) {
        self.slot = slot
        self.buffers = buffers
        self.framesPerSecond = framesPerSecond
        self.input = input
    }

    var pushed: UInt64 { pushedCount.load(ordering: .acquiring) }

    func start() {
        let t = Thread { [self] in
            let period = HostDuration(seconds: 1 / framesPerSecond)
            let t0 = HostTime.now()
            var n: UInt64 = 0
            while !stopFlag.value.load(ordering: .relaxed) {
                let due = t0 + period * Int(n)
                mach_wait_until(due.ticks)
                let now = HostTime.now()
                slot.push(Frame(pixelBuffer: buffers[Int(n % UInt64(buffers.count))], pts: now, duration: period,
                                color: .bt709Limited, inputNumber: input, sequence: n + 1, ingressTime: now))
                pushedCount.add(1, ordering: .releasing)
                n += 1
            }
        }
        t.name = "test.aux.pusher"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        stopFlag.value.store(true, ordering: .relaxed)
        usleep(30_000)
    }
}

/// 离屏读回。
enum TextureReadback {
    /// 建一张能当渲染目标、CPU 能读的 BGRA8 纹理（"外部显示纹理"的离屏替身，格式同 CAMetalLayer 的 drawable）。
    static func makeTarget(device: any MTLDevice, width: Int, height: Int) -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    /// BGRA 字节（行紧排）。
    static func bytes(of texture: any MTLTexture) -> [UInt8] {
        let bpr = texture.width * 4
        var out = [UInt8](repeating: 0, count: bpr * texture.height)
        out.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return out
    }

    /// OfflineRenderer 的 PGM（CGImage 由 BGRA 字节直接包成，dataProvider 就是原始字节，不经色彩管理）。
    static func bytes(of image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let bpr = image.width * 4
        precondition(image.bytesPerRow == bpr)
        return [UInt8](data)
    }

    /// CVPixelBuffer（BGRA）的字节（行紧排）。
    static func bytes(ofBGRA pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * 4 * h)
        for row in 0..<h { for i in 0..<(w * 4) { out[row * w * 4 + i] = base[row * bpr + i] } }
        return out
    }

    /// 不相等的像素在哪（诊断用）：按 x / y 奇偶分的个数、前几个的坐标与两边的值。
    static func describeDifferences(_ a: [UInt8], _ b: [UInt8], width: Int, limit: Int = 6) -> String {
        var parity = [0, 0, 0, 0], samples: [String] = []
        var i = 0
        while i < a.count {
            if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                let p = i / 4, x = p % width, y = p / width
                parity[(x & 1) + 2 * (y & 1)] += 1
                if samples.count < limit { samples.append("(\(x),\(y)) BGR \(a[i]),\(a[i + 1]),\(a[i + 2]) vs \(b[i]),\(b[i + 1]),\(b[i + 2])") }
            }
            i += 4
        }
        return "x偶y偶 \(parity[0]) x奇y偶 \(parity[1]) x偶y奇 \(parity[2]) x奇y奇 \(parity[3])；" + samples.joined(separator: "；")
    }

    /// 两份 BGRA 字节里 B / G / R 三个通道的最大差、不相等的像素数。
    static func compareRGB(_ a: [UInt8], _ b: [UInt8]) -> (maxDiff: Int, differingPixels: Int) {
        precondition(a.count == b.count)
        var maxDiff = 0, differing = 0
        var i = 0
        while i < a.count {
            let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            if d > 0 { differing += 1; maxDiff = max(maxDiff, d) }
            i += 4
        }
        return (maxDiff, differing)
    }
}

extension XCTestCase {
    /// 转主线程事件循环（display link 回调、通知都在主线程上）。
    @MainActor
    func pumpEvents(seconds: Double) {
        _ = NSApplication.shared
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// 转事件循环直到条件成立或超时。
    @MainActor
    func pumpEvents(until timeout: Double, _ condition: () -> Bool) -> Bool {
        _ = NSApplication.shared
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return condition()
    }

    @MainActor
    func launchTestApp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if !NSApp.isRunning { NSApp.finishLaunching() }
    }
}
