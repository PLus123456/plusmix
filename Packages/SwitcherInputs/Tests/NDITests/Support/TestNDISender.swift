import CSwitcherNDI
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherInputs
@testable import SwitcherNDI

/// 测试用的 NDI 发送端（直接用 CSwitcherNDI 的发送封装；产品里的发送在 SwitcherOutputs，依赖方向不许本包 import 它）。
/// 按拍点时钟实时送测试图案：帧号 = 拍号、输入 ID、闪光；UYVY（默认）或 BGRA（带 alpha）；可选 TestSignal 音频（click 与闪光共用 t0）。
final class TestNDISender: @unchecked Sendable {
    enum Format: Sendable { case uyvy, bgra(alpha: UInt8) }

    let name: String
    /// 网络上的完整源名 "机器名 (name)"。
    let sourceName: String
    private let handle: OpaquePointer
    private var thread: InputThread?
    let framesSent = Atomic<UInt64>(0)
    let audioBlocksSent = Atomic<UInt64>(0)
    let lateTicks = Atomic<UInt64>(0)
    private var destroyed = false

    init(name: String) throws {
        guard SwitcherNDIInfo.isSDKAvailable, sw_ndi_initialize() != 0 else { throw NDIInputError.sdkUnavailable }
        guard let h = sw_ndi_send_create(name, nil, 0, 0) else { throw NDIInputError.receiverCreateFailed }
        handle = h
        self.name = name
        sourceName = String(cString: sw_ndi_send_source_name(h))
    }

    deinit { destroy() }

    /// 起发送线程：从 `firstTick` 起每拍一帧，到 `lastTick`（nil = 直到 stop）。
    func start(width: Int, height: Int, clock: TickClockSpec, frameRate: FrameRate, format: Format = .uyvy, inputID: Int = 1,
               firstTick: Tick, lastTick: Tick? = nil, audio: Bool = false) {
        precondition(thread == nil)
        let t = InputThread(name: "test.ndi.sender", period: clock.duration(ofTicks: 1)) { [self] thread in
            // 画面：NV12 scratch（TestPattern.draw）→ UYVY，或直接 BGRA
            let lumaStride = width, chromaStride = width
            let luma = UnsafeMutablePointer<UInt8>.allocate(capacity: lumaStride * height)
            let chroma = UnsafeMutablePointer<UInt8>.allocate(capacity: chromaStride * (height / 2))
            let bytesPerPixel: Int
            if case .bgra = format { bytesPerPixel = 4 } else { bytesPerPixel = 2 }
            let packed = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * bytesPerPixel)
            defer {
                luma.deallocate()
                chroma.deallocate()
                packed.deallocate()
            }
            let fps = frameRate.framesPerSecond
            let signal = TestSignal(t0: clock.t0, clickPeriod: TestPattern.flashPeriod(frameRate: frameRate))
            var audioBuf = [Float](repeating: 0, count: 4096)
            var nextSample = signal.sampleIndex(at: clock.time(of: firstTick))
            var n = firstTick
            while !thread.isStopRequested {
                if let lastTick, n > lastTick { break }
                let due = clock.time(of: n)
                thread.sleep(until: due)
                if thread.isStopRequested { break }
                if HostClock.now() - due > HostDuration(milliseconds: 2) { lateTicks.add(1, ordering: .relaxed) }
                let content = TestPattern.Content(frameNumber: UInt32(truncatingIfNeeded: n.rawValue), hostTime: due, inputID: inputID,
                                                  flash: TestPattern.isFlashTick(n, frameRate: frameRate))
                var frame = sw_ndi_video_frame()
                frame.width = Int32(width)
                frame.height = Int32(height)
                frame.frame_rate_n = Int32(fps.numerator)
                frame.frame_rate_d = Int32(fps.denominator)
                frame.progressive = 1
                switch format {
                case .uyvy:
                    TestPattern.draw(content, into: .nv12(luma: UnsafeMutableRawPointer(luma), lumaBytesPerRow: lumaStride,
                                                          chroma: UnsafeMutableRawPointer(chroma), chromaBytesPerRow: chromaStride),
                                     width: width, height: height)
                    sw_ndi_pack_uyvy_from_nv12(luma, Int32(lumaStride), chroma, Int32(chromaStride), Int32(width), Int32(height), packed)
                    frame.fourcc = SW_NDI_FOURCC_UYVY
                    frame.line_stride = Int32(width * 2)
                case .bgra(let alpha):
                    TestPattern.draw(content, into: .bgra(base: UnsafeMutableRawPointer(packed), bytesPerRow: width * 4), width: width, height: height)
                    // 下半边 alpha = alpha（预乘：RGB 也按比例缩），上半边不透明（帧号 / 时间戳 / 输入 ID 块都在上半，别盖住）
                    if alpha != 255 {
                        for y in (height / 2)..<height {
                            let row = packed + y * width * 4
                            for x in 0..<width {
                                let p = row + x * 4
                                p[0] = UInt8((UInt32(p[0]) * UInt32(alpha) + 127) / 255)
                                p[1] = UInt8((UInt32(p[1]) * UInt32(alpha) + 127) / 255)
                                p[2] = UInt8((UInt32(p[2]) * UInt32(alpha) + 127) / 255)
                                p[3] = alpha
                            }
                        }
                    }
                    frame.fourcc = SW_NDI_FOURCC_BGRA
                    frame.line_stride = Int32(width * 4)
                }
                frame.data = UnsafePointer(packed)
                sw_ndi_send_video(self.handle, &frame)
                framesSent.add(1, ordering: .relaxed)
                if audio {
                    // 这一拍覆盖的样本：[sampleIndex(t_n), sampleIndex(t_{n+1}))
                    let end = signal.sampleIndex(at: clock.time(of: n + 1))
                    let count = Int(end - nextSample)
                    if count > 0 && count <= 2048 {
                        audioBuf.withUnsafeMutableBufferPointer { buf in
                            signal.render(into: buf.baseAddress!, frameCount: count, startingAt: nextSample)
                            // 两声道同内容：第二个平面紧跟第一个
                            (buf.baseAddress! + count).update(from: buf.baseAddress!, count: count)
                            var a = sw_ndi_audio_frame()
                            a.sample_rate = Int32(AudioFormat.sampleRate)
                            a.channels = 2
                            a.samples = Int32(count)
                            a.channel_stride = Int32(count * 4)
                            a.data = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self)
                            sw_ndi_send_audio(self.handle, &a)
                        }
                        audioBlocksSent.add(1, ordering: .relaxed)
                    }
                    nextSample = end
                }
                n += 1
            }
        }
        thread = t
        t.start()
    }

    /// 停发送线程（源还在网络上，只是没帧）。
    func stopSending() {
        thread?.stop()
        thread = nil
    }

    /// 销毁发送端（源从网络上消失）。
    func destroy() {
        stopSending()
        if !destroyed {
            destroyed = true
            sw_ndi_send_destroy(handle)
        }
    }

    /// 接收端回传的 tally。
    func tally(timeoutMs: UInt32 = 0) -> Tally {
        var p: Int32 = 0, v: Int32 = 0
        _ = sw_ndi_send_get_tally(handle, &p, &v, timeoutMs)
        return Tally(program: p != 0, preview: v != 0)
    }

    var connections: Int { Int(sw_ndi_send_connections(handle, 0)) }
}
