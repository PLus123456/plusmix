import CoreVideo
import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherNDISend
#if canImport(NDI)
import NDI
#endif

/// D08（Codex 2026-10-13 审查 §1.3）：NDI 输出的源选"输入 n"时，原始输入帧直接进发送器，而 NV12ToUYVY 只收 NV12
/// （GPU 分支同样的守卫）——图片 / 屏幕（BGRA）、NDI / DeckLink 输入（UYVY / BGRA）每帧转换失败、只加 conversionFailures，
/// 接收端没画面，Stats 仍写 publishing。现在按像素格式分路：NV12 走原来的转换，UYVY / BGRA 直接交给 NDI（SDK 原生认），
/// 别的格式送不了；连续送不出去 → 这一路 Stats `state = failed`、`last_error` 写像素格式。
final class NDIDirectFormatTests: XCTestCase {
    private let format = ProgramFormat.hd1080p60

    /// 三种像素缓冲各一帧（NV12 1920×1080、UYVY 1280×720、BGRA 1600×900）进发送器：GPU / CPU / auto 三种转换方式下都送出去，
    /// 收到 = 送出 = 3、转换失败 0、state = publishing（SDK 不在时干跑也走一样的路，state 是 unavailable）。
    func testD08_threePixelFormats_oneFrameEach_allSentInEveryConversionMode() throws {
        for mode in NDISender.Configuration.Conversion.allCases {
            let sender = NDISender(configuration: .init(name: "d08-\(mode.rawValue)", format: format, source: .input(number: 1),
                                                        conversion: mode, queueDepth: 8, dryRun: true))
            try sender.start()
            sender.send(frame: NDITestFrames.frame(NDITestFrames.nv12(width: 1920, height: 1080, y: 100, cb: 140, cr: 120), sequence: 1))
            sender.send(frame: NDITestFrames.frame(NDITestFrames.uyvy(width: 1280, height: 720, y: 150, cb: 110, cr: 150), sequence: 2))
            sender.send(frame: NDITestFrames.frame(NDITestFrames.bgra(width: 1600, height: 900, b: 40, g: 160, r: 220), sequence: 3))
            XCTAssertTrue(waitUntil(5) { let c = sender.countersSnapshot; return c.framesSent + c.conversionFailures + c.skipped >= 3 }, "\(mode)：三帧都处理完")
            let c = sender.countersSnapshot
            let e = sender.statsEntry(previous: nil, windowSeconds: 1)
            sender.stop()
            XCTAssertEqual(c.framesReceived, 3, "\(mode)")
            XCTAssertEqual(c.framesSent, 3, "\(mode)：NV12 转 UYVY、UYVY / BGRA 直送，三帧都送出去：\(c)")
            XCTAssertEqual(c.conversionFailures, 0, "\(mode)：\(c)")
            XCTAssertEqual(c.skipped, 0, "\(mode)")
            XCTAssertEqual(e.state, NDISender.isAvailable ? "publishing" : "unavailable", "\(mode)")
            XCTAssertEqual(e.lastError, NDISender.isAvailable ? "" : "NDI SDK 不在（编译时没探测到）", "\(mode)")
        }
    }

    /// 送不了的像素格式（'yuvs' = YUY2，NDI 不认、我们也不转）：偶尔一两帧不翻状态；连续 30 帧之后 state = failed、
    /// last_error 带像素格式；来一帧能送的就回到 publishing（last_error 留着，下一次 start 才清，同 022 口径）。
    func testD08_unsupportedPixelFormatStreak_marksFailedWithFormat_thenRecovers() throws {
        let sender = NDISender(configuration: .init(name: "d08-fail", format: format, source: .input(number: 2),
                                                    conversion: .cpu, queueDepth: 8, dryRun: true))
        try sender.start()
        let bad = NDITestFrames.yuvs(width: 640, height: 360)
        func feedBad(_ n: Int, from start: Int) {
            for i in 0..<n {
                sender.send(frame: NDITestFrames.frame(bad, sequence: UInt64(start + i)))
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        feedBad(3, from: 0)
        XCTAssertTrue(waitUntil(5) { sender.countersSnapshot.conversionFailures == 3 })
        XCTAssertEqual(sender.statsEntry(previous: nil, windowSeconds: 1).state, NDISender.isAvailable ? "publishing" : "unavailable",
                       "偶尔几帧送不出去不翻状态")
        feedBad(27, from: 3)
        XCTAssertTrue(waitUntil(5) { sender.countersSnapshot.conversionFailures == 30 }, "\(sender.countersSnapshot)")
        let failed = sender.statsEntry(previous: nil, windowSeconds: 1)
        if NDISender.isAvailable {
            XCTAssertEqual(failed.state, "failed", "连续 30 帧送不出去：这一路 failed（原实现仍写 publishing）")
            XCTAssertEqual(failed.uptimeS, 0, "failed 的 uptime_s 写 0（022）")
        }
        XCTAssertTrue(failed.lastError.contains("yuvs"), "last_error 写像素格式：\(failed.lastError)")
        XCTAssertEqual(sender.countersSnapshot.framesSent, 0)
        // 换成能送的帧：回到 publishing
        sender.send(frame: NDITestFrames.frame(NDITestFrames.bgra(width: 640, height: 360, b: 1, g: 2, r: 3), sequence: 100))
        XCTAssertTrue(waitUntil(5) { sender.countersSnapshot.framesSent == 1 })
        let recovered = sender.statsEntry(previous: nil, windowSeconds: 1)
        sender.stop()
        XCTAssertEqual(recovered.state, NDISender.isAvailable ? "publishing" : "unavailable", "送出去一帧就回到 publishing")
        XCTAssertTrue(recovered.lastError.contains("yuvs"), "last_error 是最近一次错误，start 之前不清：\(recovered.lastError)")
        // 下一次 start 清掉
        try sender.start()
        XCTAssertEqual(sender.statsEntry(previous: nil, windowSeconds: 1).lastError, NDISender.isAvailable ? "" : "NDI SDK 不在（编译时没探测到）")
        sender.stop()
    }

    /// 真接收端回环（本机装了 NDI SDK）：同一进程里起一个 NDI 接收端连到发送器，依次送 UYVY 1280×720、BGRA 1600×900、NV12 1920×1080
    /// 的纯色帧，接收端各收到一帧：尺寸 = 送的那一帧的原尺寸（直送不裁）、中心像素颜色对（NDI 压缩有损，容差 ±14）。
    func testD08_realReceiverLoopback_UYVY_BGRA_NV12() throws {
        #if canImport(NDI)
        let name = "Switcher D08 loop \(ProcessInfo.processInfo.processIdentifier)"
        let sender = NDISender(configuration: .init(name: name, format: format, source: .input(number: 3), conversion: .auto, queueDepth: 3))
        try sender.start()
        defer { sender.stop() }
        let receiver = try XCTUnwrap(NDILoopbackReceiver(sourceSuffix: "(\(name))", timeout: 15), "15 s 内没发现自己的 NDI 源（\(name)）")
        let cases: [(label: String, frame: Frame, size: (Int, Int), rgb: (Double, Double, Double))] = [
            ("UYVY", NDITestFrames.frame(NDITestFrames.uyvy(width: 1280, height: 720, y: 150, cb: 110, cr: 150), sequence: 1), (1280, 720),
             NDITestFrames.rgb709(y: 150, cb: 110, cr: 150)),
            ("BGRA", NDITestFrames.frame(NDITestFrames.bgra(width: 1600, height: 900, b: 40, g: 160, r: 220), sequence: 2), (1600, 900), (220, 160, 40)),
            ("NV12", NDITestFrames.frame(NDITestFrames.nv12(width: 1920, height: 1080, y: 100, cb: 140, cr: 120), sequence: 3), (1920, 1080),
             NDITestFrames.rgb709(y: 100, cb: 140, cr: 120)),
        ]
        for c in cases {
            let got = receiver.receive(width: c.size.0, height: c.size.1, timeout: 10) { sender.send(frame: c.frame) }
            guard let got else {
                XCTFail("\(c.label)：10 s 内没收到 \(c.size.0)×\(c.size.1) 的帧（收到过的尺寸 \(receiver.seenSizes)）：\(sender.countersSnapshot)")
                continue
            }
            print("D08 回环 \(c.label)：收到 \(got.width)×\(got.height) FourCC \(got.fourCC) 中心 RGB \(got.rgb)，期望 \(c.rgb)")
            XCTAssertEqual(abs(got.rgb.0 - c.rgb.0), 0, accuracy: 14, "\(c.label) R")
            XCTAssertEqual(abs(got.rgb.1 - c.rgb.1), 0, accuracy: 14, "\(c.label) G")
            XCTAssertEqual(abs(got.rgb.2 - c.rgb.2), 0, accuracy: 14, "\(c.label) B")
        }
        let counters = sender.countersSnapshot
        XCTAssertEqual(counters.conversionFailures, 0, "\(counters)")
        XCTAssertEqual(sender.statsEntry(previous: nil, windowSeconds: 1).state, "publishing")
        #else
        throw XCTSkip("BLOCKED-SDK：没有 NDI SDK（/Library/NDI SDK for Apple），真接收端回环要它")
        #endif
    }
}

/// 造纯色像素缓冲（IOSurface 背后）与 Frame。
enum NDITestFrames {
    static func make(_ type: OSType, width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let st = CVPixelBufferCreate(nil, width, height, type, attrs as CFDictionary, &pb)
        precondition(st == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate \(type) \(st)")
        return pb!
    }

    static func nv12(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer {
        let pb = make(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: width, height: height)
        CVPixelBufferLockBaseAddress(pb, [])
        let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        memset(yp, Int32(y), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * height)
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<(height / 2) { for col in 0..<(width / 2) { cp[row * cs + col * 2] = cb; cp[row * cs + col * 2 + 1] = cr } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// UYVY = CoreVideo '2vuy'（Cb Y0 Cr Y1）。
    static func uyvy(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer {
        let pb = make(kCVPixelFormatType_422YpCbCr8, width: width, height: height)
        fillPacked(pb, height: height, pattern: [cb, y, cr, y])
        return pb
    }

    /// 'yuvs' = YUY2（Y0 Cb Y1 Cr）：NDI 不认、我们也不转。
    static func yuvs(width: Int, height: Int) -> CVPixelBuffer {
        let pb = make(kCVPixelFormatType_422YpCbCr8_yuvs, width: width, height: height)
        fillPacked(pb, height: height, pattern: [128, 128, 128, 128])
        return pb
    }

    static func bgra(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255) -> CVPixelBuffer {
        let pb = make(kCVPixelFormatType_32BGRA, width: width, height: height)
        fillPacked(pb, height: height, pattern: [b, g, r, a])
        return pb
    }

    private static func fillPacked(_ pb: CVPixelBuffer, height: Int, pattern: [UInt8]) {
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for i in 0..<(stride * height) { base[i] = pattern[i % pattern.count] }
        CVPixelBufferUnlockBaseAddress(pb, [])
    }

    static func frame(_ pb: CVPixelBuffer, sequence: UInt64) -> Frame {
        let now = HostClock.now()
        let color: ColorInfo = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA ? .sRGBFull : .bt709Limited
        return Frame(pixelBuffer: pb, pts: now, duration: HostDuration(milliseconds: 1000.0 / 60), color: color,
                     inputNumber: 1, sequence: sequence, ingressTime: now)
    }

    /// BT.709 视频范围 YCbCr → 8 bit RGB（期望值；NDI 对 HD 尺寸按 Rec.709）。
    static func rgb709(y: Double, cb: Double, cr: Double) -> (Double, Double, Double) {
        let yy = 1.164383 * (y - 16), u = cb - 128, v = cr - 128
        func clamp(_ x: Double) -> Double { min(255, max(0, x)) }
        return (clamp(yy + 1.792741 * v), clamp(yy - 0.213249 * u - 0.532909 * v), clamp(yy + 2.112402 * u))
    }
}

extension XCTestCase {
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2000)
        }
        return condition()
    }
}

#if canImport(NDI)
/// 同进程的 NDI 接收端（直接用 SDK 的 C 接口）：按名字后缀找源、BGRX_BGRA 收、读中心像素。
final class NDILoopbackReceiver {
    struct Received {
        var width: Int
        var height: Int
        var fourCC: String
        var rgb: (Double, Double, Double)
    }

    private let finder: NDIlib_find_instance_t
    private let recv: NDIlib_recv_instance_t
    private(set) var seenSizes: Set<String> = []

    init?(sourceSuffix: String, timeout: TimeInterval) {
        guard NDIlib_initialize() else { return nil }
        var fd = NDIlib_find_create_t()
        fd.show_local_sources = true
        guard let f = NDIlib_find_create_v2(&fd) else { return nil }
        finder = f
        var found: NDIlib_source_t?
        let deadline = Date().addingTimeInterval(timeout)
        while found == nil && Date() < deadline {
            _ = NDIlib_find_wait_for_sources(f, 500)
            var n: UInt32 = 0
            if let list = NDIlib_find_get_current_sources(f, &n) {
                for i in 0..<Int(n) where String(cString: list[i].p_ndi_name).hasSuffix(sourceSuffix) { found = list[i] }
            }
        }
        guard let source = found else { NDIlib_find_destroy(f); return nil }
        var rd = NDIlib_recv_create_v3_t()
        rd.source_to_connect_to = source
        rd.color_format = NDIlib_recv_color_format_BGRX_BGRA
        rd.bandwidth = NDIlib_recv_bandwidth_highest
        rd.allow_video_fields = false
        guard let r = NDIlib_recv_create_v3(&rd) else { NDIlib_find_destroy(f); return nil }
        recv = r
    }

    deinit {
        NDIlib_recv_destroy(recv)
        NDIlib_find_destroy(finder)
    }

    /// 一边调 `pump`（发送端喂帧）一边收，直到收到 width × height 的视频帧或超时。
    func receive(width: Int, height: Int, timeout: TimeInterval, pump: () -> Void) -> Received? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pump()
            var v = NDIlib_video_frame_v2_t()
            let t = NDIlib_recv_capture_v3(recv, &v, nil, nil, 20)
            guard t == NDIlib_frame_type_video else { continue }
            defer { NDIlib_recv_free_video_v2(recv, &v) }
            seenSizes.insert("\(v.xres)x\(v.yres)")
            guard Int(v.xres) == width, Int(v.yres) == height, let data = v.p_data else { continue }
            let stride = Int(v.line_stride_in_bytes)
            let p = data + (Int(v.yres) / 2) * stride + (Int(v.xres) / 2) * 4
            let cc = v.FourCC.rawValue
            let fourCC = String(bytes: [UInt8(cc & 0xFF), UInt8((cc >> 8) & 0xFF), UInt8((cc >> 16) & 0xFF), UInt8(cc >> 24)], encoding: .ascii) ?? "?"
            return Received(width: Int(v.xres), height: Int(v.yres), fourCC: fourCC, rgb: (Double(p[2]), Double(p[1]), Double(p[0])))
        }
        return nil
    }
}
#endif
