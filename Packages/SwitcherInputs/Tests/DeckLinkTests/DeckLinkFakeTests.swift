import CoreVideo
import Foundation
import Synchronization
import XCTest
import CSwitcherDeckLink
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
@testable import SwitcherDeckLink

/// 桥接层对着 Fake IDeckLinkInput 跑三条路径（prompt：格式变更、无信号、帧到达）+ 音频转换 + Swift 层 DeckLinkInput 的状态机。
/// 需要 SDK 头（Fake 实现的是 SDK 的 COM 接口）；没有：BLOCKED-SDK。
final class DeckLinkFakeTests: XCTestCase {
    /// 收集桥接层回调的容器（C 回调经 context 指到它）。
    final class Collector: @unchecked Sendable {
        struct VideoEvent: Sendable {
            let bytes: [UInt8]
            let width: Int
            let height: Int
            let format: OSType
            let info: sw_decklink_frame_info
            let surfaceID: UInt32
        }
        struct AudioEvent: Sendable {
            let planes: [[Float]]
            let info: sw_decklink_audio_info
        }
        let videos = Mutex<[VideoEvent]>([])
        let audios = Mutex<[AudioEvent]>([])
        let signals = Mutex<[Bool]>([])
        let formats = Mutex<[sw_decklink_video_format]>([])
        let errors = Mutex<[String]>([])

        func callbacks() -> sw_decklink_callbacks {
            var cb = sw_decklink_callbacks()
            cb.context = Unmanaged.passUnretained(self).toOpaque()
            cb.format_changed = { ctx, f in Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue().formats.withLock { $0.append(f!.pointee) } }
            cb.video_frame = { ctx, pb, info in
                let me = Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue()
                let pb = pb!
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
                let bpp = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA ? 4 : 2
                var bytes: [UInt8] = []
                bytes.reserveCapacity(w * h * bpp)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { bytes.append(contentsOf: UnsafeBufferPointer(start: base + y * stride, count: w * bpp)) }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                let sid = CVPixelBufferGetIOSurface(pb).map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
                me.videos.withLock { $0.append(VideoEvent(bytes: bytes, width: w, height: h, format: CVPixelBufferGetPixelFormatType(pb), info: info!.pointee, surfaceID: sid)) }
            }
            cb.audio_packet = { ctx, planes, info in
                let me = Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue()
                let i = info!.pointee
                var out: [[Float]] = []
                for c in 0..<Int(i.channel_count) { out.append(Array(UnsafeBufferPointer(start: planes![c], count: Int(i.frame_count)))) }
                me.audios.withLock { $0.append(AudioEvent(planes: out, info: i)) }
            }
            cb.signal_changed = { ctx, present in Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue().signals.withLock { $0.append(present != 0) } }
            cb.error = { ctx, msg in Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue().errors.withLock { $0.append(String(cString: msg!)) } }
            return cb
        }
    }

    private var fake: OpaquePointer!
    private let modeHp59: UInt32 = 0x48703539   // 'Hp59'
    private let modeHp60: UInt32 = 0x48703630   // 'Hp60'
    private let modehp60: UInt32 = 0x68703630   // 'hp60'（720p60）
    private let formatUYVY: UInt32 = 0x32767579  // '2vuy'
    private let formatBGRA: UInt32 = 0x42475241  // 'BGRA'
    private let noInputSource: UInt32 = 1 << 31
    private let displayModeChanged: UInt32 = 1 << 0
    private let detectedYCbCr422: UInt32 = 1 << 0
    private let detectedRGB444: UInt32 = 1 << 1
    private let progressive: UInt32 = 0x70726F67  // 'prog'

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard SwitcherDeckLinkInfo.isSDKAvailable else {
            throw XCTSkip("BLOCKED-SDK：没有 DeckLink SDK 头（~/SDKs/DeckLink、DECKLINK_SDK_DIR 或 NDI SDK 示例自带的副本），Fake IDeckLinkInput 编不出来")
        }
        fake = sw_decklink_fake_create()
        XCTAssertNotNil(fake)
    }

    override func tearDown() {
        if let fake { sw_decklink_fake_destroy(fake) }
        fake = nil
        super.tearDown()
    }

    private func hostNowNs() -> Int64 { Int64(HostClock.now().nanoseconds) }

    private func openSession(_ collector: Collector, audioChannels: Int32 = 2, sampleType: Int32 = 32) throws -> OpaquePointer {
        var cfg = sw_decklink_session_config()
        cfg.audio_channels = audioChannels
        cfg.audio_sample_type = sampleType
        cfg.calibration_shift = 5
        cfg.max_pool_buffers = 8
        var cb = collector.callbacks()
        var err = [CChar](repeating: 0, count: 256)
        let s = try XCTUnwrap(sw_decklink_session_open_fake(fake, &cfg, &cb, &err, err.count), String(cString: err))
        XCTAssertEqual(sw_decklink_session_start(s, &err, err.count), 0, String(cString: err))
        return s
    }

    /// 造一帧 UYVY：字节 (x + y) & 255。
    private func uyvyFrame(width: Int, height: Int, hwTimeNs: Int64, streamTimeNs: Int64, flags: UInt32 = 0) -> ([UInt8], sw_decklink_fake_frame) {
        var bytes = [UInt8](repeating: 0, count: width * height * 2)
        for y in 0..<height { for x in 0..<(width * 2) { bytes[y * width * 2 + x] = UInt8((x + y) & 255) } }
        var f = sw_decklink_fake_frame()
        f.width = Int32(width)
        f.height = Int32(height)
        f.row_bytes = Int32(width * 2)
        f.pixel_format = formatUYVY
        f.flags = flags
        f.hw_time_ns = hwTimeNs
        f.hw_duration_ns = 16_683_350   // 1001/60000 s
        f.stream_time_ns = streamTimeNs
        f.hw_timestamp_supported = 1
        return (bytes, f)
    }

    // MARK: 路径 1：帧到达

    func testDeckLink_fake_frameArrival_copiesPixels_calibratesTimestamp_poolReuses() throws {
        let collector = Collector()
        let s = try openSession(collector, audioChannels: 0)
        defer { sw_decklink_session_close(s) }
        var log = sw_decklink_fake_log()
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.callback_set, 1)
        XCTAssertEqual(log.enable_video_calls, 1)
        XCTAssertEqual(log.last_pixel_format, formatUYVY)
        XCTAssertEqual(log.last_input_flags, 1, "起流带 bmdVideoInputEnableFormatDetection")
        XCTAssertEqual(log.last_display_mode, modeHp59, "起始模式 = 设备列表第一个（1080p59.94）")
        XCTAssertEqual(log.start_calls, 1)
        XCTAssertEqual(log.enable_audio_calls, 0, "audio_channels = 0 不开音频")

        // 硬件钟 = host − 常数偏移（模拟一块有自己参考钟的卡）；帧的硬件时间 = 当前硬件时间 − 一帧（帧收完才回调）
        let hwOffset: Int64 = 5_000_000_000_000
        let frameDur: Int64 = 16_683_350
        var pushedSurfaces = Set<UInt32>()
        let n = 40
        // 帧数据造一次（debug 下逐字节填 4 MB 要十几毫秒，不能夹在"设钟"和 emit 之间，否则量到的是测试自己的耗时）
        let (bytes, template) = uyvyFrame(width: 1920, height: 1080, hwTimeNs: 0, streamTimeNs: 0)
        for k in 0..<n {
            var f = template
            f.stream_time_ns = Int64(k) * frameDur
            bytes.withUnsafeBufferPointer { p in
                f.bytes = UnsafeRawPointer(p.baseAddress)
                // 硬件钟 = host − 常数偏移，在 emit 前一刻设；帧的硬件时间 = 当前硬件时间 − 一帧（帧收完才回调）
                let hwNow = hostNowNs() - hwOffset
                f.hw_time_ns = hwNow - frameDur
                sw_decklink_fake_set_hardware_clock(fake, hwNow)
                sw_decklink_fake_emit_frame(fake, &f)
            }
            let ev = collector.videos.withLock { $0.last }!
            pushedSurfaces.insert(ev.surfaceID)
            if k == 0 {
                XCTAssertEqual(ev.width, 1920)
                XCTAssertEqual(ev.height, 1080)
                XCTAssertEqual(ev.format, kCVPixelFormatType_422YpCbCr8)
                XCTAssertEqual(ev.bytes, bytes, "像素逐字节拷进 CVPixelBuffer")
            }
            XCTAssertEqual(ev.info.sequence, UInt64(k + 1))
            XCTAssertEqual(ev.info.calibrated, 1)
            // pts = 帧硬件时间 + 偏移 ≈ 回调入口 − 一帧
            let ptsNs = Int64(HostTime(ticks: ev.info.pts_host).nanoseconds)
            let arrivalNs = Int64(HostTime(ticks: ev.info.arrival_host).nanoseconds)
            XCTAssertEqual(Double(arrivalNs - ptsNs), Double(frameDur), accuracy: 200_000, "帧 \(k)：pts = 到达 − 一帧（校准偏移吸收了硬件钟的常数差；容差 = 两次读钟之间的调度抖动）")
            XCTAssertEqual(ev.info.duration_host, Int64(HostDuration(nanoseconds: frameDur).ticks), "帧时长")
            usleep(2000)
        }
        var stats = sw_decklink_session_stats()
        sw_decklink_session_get_stats(s, &stats)
        XCTAssertEqual(stats.frames_received, UInt64(n))
        XCTAssertEqual(stats.frames_delivered, UInt64(n))
        XCTAssertEqual(stats.frames_no_source, 0)
        XCTAssertEqual(stats.frames_dropped_pool, 0)
        XCTAssertEqual(stats.has_hardware_clock, 1)
        XCTAssertEqual(Double(stats.calibration_offset_ns), Double(hwOffset), accuracy: 200_000, "校准偏移 ≈ 硬件钟与 host 的常数差")
        XCTAssertLessThan(stats.residual_max_abs_ns, 2_000_000, "残差 = 我们设钟到桥接层读钟之间的间隔（µs 级）")
        print("校准：偏移 \(stats.calibration_offset_ns) ns（真值 \(hwOffset)），残差最大 \(stats.residual_max_abs_ns) ns，RMS \(String(format: "%.0f", stats.residual_rms_ns)) ns，样本 \(stats.residual_samples)")
        XCTAssertEqual(collector.signals.withLock { $0 }, [true], "第一帧带信号 → signal_changed(1) 一次")
        XCTAssertLessThanOrEqual(pushedSurfaces.count, 8, "像素池复用（消费方立刻放手时只需几块）：见过 \(pushedSurfaces.count) 个 IOSurface")
    }

    func testDeckLink_fake_frameArrival_withoutHardwareClock_fallsBackToArrival() throws {
        let collector = Collector()
        sw_decklink_fake_set_hardware_clock_supported(fake, 0)
        let s = try openSession(collector, audioChannels: 0)
        defer { sw_decklink_session_close(s) }
        let (bytes, frame) = uyvyFrame(width: 1280, height: 720, hwTimeNs: 0, streamTimeNs: 0)
        var f = frame
        f.hw_timestamp_supported = 0
        bytes.withUnsafeBufferPointer { p in
            f.bytes = UnsafeRawPointer(p.baseAddress)
            sw_decklink_fake_emit_frame(fake, &f)
        }
        let ev = try XCTUnwrap(collector.videos.withLock { $0.last })
        XCTAssertEqual(ev.info.calibrated, 0)
        XCTAssertEqual(ev.info.pts_host, ev.info.arrival_host, "没有硬件钟：pts = 到达时刻")
        var stats = sw_decklink_session_stats()
        sw_decklink_session_get_stats(s, &stats)
        XCTAssertEqual(stats.has_hardware_clock, 0)
        XCTAssertTrue(collector.errors.withLock { $0 }.contains { $0.contains("硬件参考钟") }, "\(collector.errors.withLock { $0 })")
    }

    // MARK: 路径 2：格式变更

    func testDeckLink_fake_formatChange_reopensWithDetectedModeAndPixelFormat() throws {
        let collector = Collector()
        let s = try openSession(collector, audioChannels: 0)
        defer { sw_decklink_session_close(s) }
        // 检测到 720p60 RGB 4:4:4 → Pause → EnableVideoInput('hp60', BGRA, 格式检测) → Flush → Start
        sw_decklink_fake_emit_format_changed(fake, modehp60, 1280, 720, 1000, 60000, progressive, detectedRGB444, displayModeChanged)
        var log = sw_decklink_fake_log()
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.pause_calls, 1)
        XCTAssertEqual(log.enable_video_calls, 2, "起流 1 次 + 重开 1 次")
        XCTAssertEqual(log.last_display_mode, modehp60)
        XCTAssertEqual(log.last_pixel_format, formatBGRA, "RGB444 → 8-bit BGRA")
        XCTAssertEqual(log.last_input_flags, 1, "重开仍带格式检测")
        XCTAssertEqual(log.flush_calls, 1)
        XCTAssertEqual(log.start_calls, 2)
        XCTAssertEqual(log.callback_set, 1)
        let formats = collector.formats.withLock { $0 }
        XCTAssertEqual(formats.count, 1)
        XCTAssertEqual(formats.first?.width, 1280)
        XCTAssertEqual(formats.first?.height, 720)
        XCTAssertEqual(formats.first?.time_scale, 60000)
        XCTAssertEqual(formats.first?.frame_duration, 1000)
        XCTAssertEqual(formats.first?.pixel_format, formatBGRA)
        XCTAssertEqual(formats.first?.interlaced, 0)
        // 只有色彩空间变（同模式，YCbCr）→ 再重开成 UYVY
        sw_decklink_fake_emit_format_changed(fake, modehp60, 1280, 720, 1000, 60000, progressive, detectedYCbCr422, 1 << 2)
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.enable_video_calls, 3)
        XCTAssertEqual(log.last_pixel_format, formatUYVY)
        // 什么都没变的事件（events = 0，同像素格式）不重开
        sw_decklink_fake_emit_format_changed(fake, modehp60, 1280, 720, 1000, 60000, progressive, detectedYCbCr422, 0)
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.enable_video_calls, 3, "无变化不重开")
        // 之后来的 720p 帧按新格式交付
        let (bytes, frame) = uyvyFrame(width: 1280, height: 720, hwTimeNs: 0, streamTimeNs: 0)
        var f = frame
        bytes.withUnsafeBufferPointer { p in
            f.bytes = UnsafeRawPointer(p.baseAddress)
            sw_decklink_fake_emit_frame(fake, &f)
        }
        let ev = try XCTUnwrap(collector.videos.withLock { $0.last })
        XCTAssertEqual(ev.width, 1280)
        XCTAssertEqual(ev.height, 720)
        XCTAssertEqual(ev.bytes, bytes)
        var stats = sw_decklink_session_stats()
        sw_decklink_session_get_stats(s, &stats)
        XCTAssertEqual(stats.format_changes, 2)
        XCTAssertEqual(stats.reopen_failures, 0)
        XCTAssertEqual(stats.current_format.width, 1280)
    }

    // MARK: 路径 3：无信号

    func testDeckLink_fake_noInputSource_signalLostOnce_noFrames_recovers() throws {
        let collector = Collector()
        let s = try openSession(collector, audioChannels: 0)
        defer { sw_decklink_session_close(s) }
        let (bytes, good) = uyvyFrame(width: 1920, height: 1080, hwTimeNs: 0, streamTimeNs: 0)
        var f = good
        bytes.withUnsafeBufferPointer { p in
            f.bytes = UnsafeRawPointer(p.baseAddress)
            sw_decklink_fake_emit_frame(fake, &f)
        }
        XCTAssertEqual(collector.signals.withLock { $0 }, [true])
        // 线拔了：卡继续按帧率回调，帧带 bmdFrameHasNoInputSource、没有像素
        for _ in 0..<10 {
            var nf = good
            nf.flags = noInputSource
            nf.bytes = nil
            sw_decklink_fake_emit_frame(fake, &nf)
        }
        XCTAssertEqual(collector.signals.withLock { $0 }, [true, false], "无信号只报一次")
        XCTAssertEqual(collector.videos.withLock { $0.count }, 1, "无信号帧不交付")
        var stats = sw_decklink_session_stats()
        sw_decklink_session_get_stats(s, &stats)
        XCTAssertEqual(stats.frames_no_source, 10)
        XCTAssertEqual(stats.frames_received, 11)
        XCTAssertEqual(stats.signal_present, 0)
        // 信号回来
        bytes.withUnsafeBufferPointer { p in
            f.bytes = UnsafeRawPointer(p.baseAddress)
            sw_decklink_fake_emit_frame(fake, &f)
        }
        XCTAssertEqual(collector.signals.withLock { $0 }, [true, false, true])
        XCTAssertEqual(collector.videos.withLock { $0.count }, 2)
        sw_decklink_session_get_stats(s, &stats)
        XCTAssertEqual(stats.signal_present, 1)
    }

    // MARK: 音频

    func testDeckLink_fake_audio_int32AndInt16_toFloatPlanes_timeFromStreamClock() throws {
        for sampleType: Int32 in [32, 16] {
            // 每轮换一个新的假设备（它的调用记录是累计的）
            sw_decklink_fake_destroy(fake)
            fake = sw_decklink_fake_create()
            let collector = Collector()
            let s = try openSession(collector, audioChannels: 2, sampleType: sampleType)
            defer { sw_decklink_session_close(s) }
            var log = sw_decklink_fake_log()
            sw_decklink_fake_get_log(fake, &log)
            XCTAssertEqual(log.enable_audio_calls, 1)
            XCTAssertEqual(log.last_audio_sample_rate, 48000)
            XCTAssertEqual(log.last_audio_sample_type, UInt32(sampleType))
            XCTAssertEqual(log.last_audio_channels, 2)
            let hwOffset: Int64 = 1_000_000_000
            let frames = 800
            // 交错：L = i / 800 满幅比例，R = −L
            var i32 = [Int32](repeating: 0, count: frames * 2)
            var i16 = [Int16](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let v = Double(i) / Double(frames)
                i32[i * 2] = Int32(v * 2_147_483_647)
                i32[i * 2 + 1] = -i32[i * 2]
                i16[i * 2] = Int16(v * 32767)
                i16[i * 2 + 1] = -i16[i * 2]
            }
            let (bytes, frame) = uyvyFrame(width: 1280, height: 720, hwTimeNs: 0, streamTimeNs: 100_000_000)
            var f = frame
            f.audio_frames = Int32(frames)
            f.audio_channels = 2
            f.audio_sample_type = sampleType
            f.audio_packet_time_ns = 100_000_000 - 16_666_667   // 包首在流时间 83.33 ms
            let emit = { (audioPtr: UnsafeRawPointer) in
                bytes.withUnsafeBufferPointer { p in
                    f.bytes = UnsafeRawPointer(p.baseAddress)
                    f.audio_bytes = audioPtr
                    let hwNow = self.hostNowNs() - hwOffset
                    f.hw_time_ns = hwNow - 16_683_350
                    sw_decklink_fake_set_hardware_clock(self.fake, hwNow)
                    sw_decklink_fake_emit_frame(self.fake, &f)
                }
            }
            if sampleType == 32 { i32.withUnsafeBufferPointer { emit(UnsafeRawPointer($0.baseAddress!)) } } else { i16.withUnsafeBufferPointer { emit(UnsafeRawPointer($0.baseAddress!)) } }
            let a = try XCTUnwrap(collector.audios.withLock { $0.last })
            XCTAssertEqual(a.info.channel_count, 2)
            XCTAssertEqual(a.info.frame_count, Int32(frames))
            XCTAssertEqual(a.info.sample_rate, 48000)
            XCTAssertEqual(a.planes[0][400], 0.5, accuracy: sampleType == 32 ? 1e-6 : 1e-4)
            XCTAssertEqual(a.planes[1][400], -0.5, accuracy: sampleType == 32 ? 1e-6 : 1e-4)
            XCTAssertEqual(a.planes[0][0], 0)
            // 包首 host time = 校准(包流时间 + (帧硬件时间 − 帧流时间)) = host(帧硬件时间) − 16.67 ms ≈ 到达 − 一帧 − 16.67 ms
            let v = try XCTUnwrap(collector.videos.withLock { $0.last })
            let audioNs = Int64(HostTime(ticks: a.info.host_time).nanoseconds)
            let ptsNs = Int64(HostTime(ticks: v.info.pts_host).nanoseconds)
            XCTAssertEqual(Double(ptsNs - audioNs), 16_666_667, accuracy: 50_000, "音频包首比该帧硬件时刻早 16.67 ms（流时间差）")
            var stats = sw_decklink_session_stats()
            sw_decklink_session_get_stats(s, &stats)
            XCTAssertEqual(stats.audio_packets, 1)
        }
    }

    // MARK: 停 / 关：回调不再来

    func testDeckLink_fake_stopDisablesStreamsAndClearsCallback() throws {
        let collector = Collector()
        let s = try openSession(collector)
        sw_decklink_session_stop(s)
        var log = sw_decklink_fake_log()
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.stop_calls, 1)
        XCTAssertEqual(log.disable_video_calls, 1)
        XCTAssertEqual(log.disable_audio_calls, 1)
        XCTAssertEqual(log.callback_set, 0, "停流后回调摘掉")
        let (bytes, frame) = uyvyFrame(width: 1280, height: 720, hwTimeNs: 0, streamTimeNs: 0)
        var f = frame
        bytes.withUnsafeBufferPointer { p in
            f.bytes = UnsafeRawPointer(p.baseAddress)
            sw_decklink_fake_emit_frame(fake, &f)
        }
        XCTAssertEqual(collector.videos.withLock { $0.count }, 0, "停流后没有帧")
        sw_decklink_session_close(s)
    }

    // MARK: Swift 层：DeckLinkInput 对着 Fake

    func testDeckLink_input_overFake_stateMachine_framesToSlot_audioToRing_watchdog() throws {
        let format = ProgramFormat.hd1080p5994
        let timing = ProgramTiming(format: format, t0: HostClock.now())
        let slot = LockFreeFrameSlot(capacity: 3)
        let ring = RecordingRing(channelCount: 2)
        var options = DeckLinkInput.Options()
        options.noSignalMultiplier = 3
        options.audioChannels = 2
        let input = DeckLinkInput(number: 4, name: "DeckLink 假", deviceID: "fake", timing: timing, videoSlot: slot, audioRing: ring, options: options, fake: fake)
        XCTAssertEqual(input.state, .noSignal)
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 2000) { input.deckLinkCounters.rebuilds == 1 }, "会话应建起来")
        XCTAssertEqual(input.state, .noSignal, "起流后还没信号")
        XCTAssertEqual(input.currentFormat?.width, 1920)
        XCTAssertEqual(input.currentFormat?.framesPerSecond ?? 0, 59.94, accuracy: 0.01)
        XCTAssertTrue(input.lastError?.contains("等待信号") ?? false, input.lastError ?? "-")
        // 帧到达 → live，帧进槽，pts 校准
        let hwOffset: Int64 = 777_000_000
        let frameDur: Int64 = 16_683_350
        var seq = 0
        let (goodBytes, goodTemplate) = uyvyFrame(width: 1920, height: 1080, hwTimeNs: 0, streamTimeNs: 0)
        var audio = [Int32](repeating: 1 << 29, count: 800 * 2)
        func emitGood(count: Int) {
            for _ in 0..<count {
                var f = goodTemplate
                f.stream_time_ns = Int64(seq) * frameDur
                audio.withUnsafeMutableBufferPointer { ap in
                    goodBytes.withUnsafeBufferPointer { p in
                        f.bytes = UnsafeRawPointer(p.baseAddress)
                        f.audio_bytes = UnsafeRawPointer(ap.baseAddress)
                        f.audio_frames = 800
                        f.audio_channels = 2
                        f.audio_sample_type = 32
                        f.audio_packet_time_ns = Int64(seq) * frameDur
                        let hwNow = hostNowNs() - hwOffset
                        f.hw_time_ns = hwNow - frameDur
                        sw_decklink_fake_set_hardware_clock(fake, hwNow)
                        sw_decklink_fake_emit_frame(fake, &f)
                    }
                }
                seq += 1
                usleep(UInt32(frameDur / 1000))
            }
        }
        emitGood(count: 6)
        XCTAssertEqual(input.state, .live)
        XCTAssertNil(input.lastError)
        let picked = try XCTUnwrap(slot.latest(atOrBefore: HostClock.now()))
        XCTAssertEqual(picked.inputNumber, 4)
        XCTAssertEqual(picked.pixelFormat, .uyvy)
        XCTAssertEqual(picked.color, .bt709Limited)
        XCTAssertEqual(Double((picked.ingressTime - picked.pts).milliseconds), 16.68, accuracy: 1.0, "d = ingress − pts ≈ 一帧（帧收完才回调）")
        XCTAssertEqual(slot.stats.pushed, 6)
        let c = input.deckLinkCounters
        XCTAssertEqual(c.framesPushed, 6)
        XCTAssertEqual(c.audioBlocksWritten, 6)
        XCTAssertEqual(c.audioFramesWritten, 4800)
        XCTAssertTrue(c.hasHardwareClock)
        XCTAssertEqual(Double(c.calibrationOffsetNs), Double(hwOffset), accuracy: 200_000)
        XCTAssertEqual(ring.blocks.withLock { $0.count }, 6)
        XCTAssertEqual(ring.blocks.withLock { $0.first?.sample } ?? 0, 0.25, accuracy: 1e-6, "int32 1<<29 → 0.25")
        XCTAssertEqual(c.currentFormat.hasPrefix("1920x1080 UYVY 60000/1001"), true, c.currentFormat)
        // 无信号帧 → noSignal + 文案；再来好帧 → live
        var nf = uyvyFrame(width: 1920, height: 1080, hwTimeNs: 0, streamTimeNs: 0).1
        nf.flags = noInputSource
        nf.bytes = nil
        sw_decklink_fake_emit_frame(fake, &nf)
        XCTAssertEqual(input.state, .noSignal)
        XCTAssertTrue(input.lastError?.contains("无信号") ?? false, input.lastError ?? "-")
        emitGood(count: 1)
        XCTAssertEqual(input.state, .live)
        // 格式变更 → currentFormat 更新
        sw_decklink_fake_emit_format_changed(fake, modehp60, 1280, 720, 1000, 60000, progressive, detectedYCbCr422, displayModeChanged)
        XCTAssertTrue(waitUntil(timeoutMs: 1000) { input.currentFormat?.width == 1280 })
        XCTAssertEqual(input.currentFormat?.framesPerSecond ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(input.deckLinkCounters.formatChanges, 1)
        // 看门狗：一次回调都不来（卡被拔 / 驱动停）→ 3 个帧间隔后 noSignal
        let quietFrom = HostClock.now()
        XCTAssertTrue(waitUntil(timeoutMs: 1000, pollMs: 1) { input.state == .noSignal }, "没有回调应 noSignal")
        let quietMs = (HostClock.now() - quietFrom).milliseconds
        print("看门狗：无回调 → noSignal 用时 \(String(format: "%.1f", quietMs)) ms（门限 3 × 16.67 = 50 ms，定时器周期 = 一帧）")
        XCTAssertLessThanOrEqual(quietMs, 50 + 17 + 10)
        XCTAssertGreaterThanOrEqual(input.deckLinkCounters.watchdogTimeouts, 1)
        XCTAssertTrue(input.lastError?.contains("没有回调") ?? false, input.lastError ?? "-")
        // 回调回来 → live
        emitGood(count: 2)
        XCTAssertEqual(input.state, .live)
        // 契约计数
        let ic = input.counters
        XCTAssertEqual(ic.framesPushed, 9)
        XCTAssertGreaterThanOrEqual(ic.liveTransitions, 3)
        XCTAssertEqual(ic.rebuilds, 1)
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
        var log = sw_decklink_fake_log()
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.callback_set, 0)
        XCTAssertEqual(log.stop_calls, 1)
    }

    /// 音频环替身：记每块的首样本。
    final class RecordingRing: AudioRing, @unchecked Sendable {
        struct Block: Sendable {
            let hostTime: HostTime
            let frameCount: Int
            let sample: Float
        }
        let channelCount: Int
        let sampleRate = AudioFormat.sampleRate
        let capacityFrames = 1 << 16
        let raw: UnsafeMutablePointer<sw_audio_ring>
        let blocks = Mutex<[Block]>([])
        init(channelCount: Int) {
            self.channelCount = channelCount
            raw = .allocate(capacity: 1)
            raw.initialize(to: sw_audio_ring())
        }
        deinit { raw.deallocate() }
        var availableFrames: Int { 0 }
        var stats: AudioRingStats { AudioRingStats() }
        func write(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int {
            blocks.withLock { $0.append(Block(hostTime: hostTime, frameCount: frameCount, sample: planes[0][0])) }
            return frameCount
        }
        func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult { AudioReadResult(framesRead: 0, firstFrameHostTime: nil) }
    }
}

/// 等到条件成立或超时。
func waitUntil(timeoutMs: Double, pollMs: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = HostClock.now() + HostDuration(milliseconds: timeoutMs)
    while HostClock.now() < deadline {
        if condition() { return true }
        usleep(UInt32(pollMs * 1000))
    }
    return condition()
}
