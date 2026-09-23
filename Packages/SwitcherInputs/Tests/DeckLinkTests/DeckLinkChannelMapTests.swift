import XCTest
import CSwitcherDeckLink
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherInputsHarness
@testable import SwitcherDeckLink

/// 提案 014：DeckLink 内嵌音频的声道映射（`InputSource.decklink(…, channels:)`）。
/// 前两条是纯计算，不需要 SDK；最后一条对着 Fake IDeckLinkInput 走一遍 8 路内嵌音频 → 环（没有 SDK 头时 BLOCKED-SDK）。
final class DeckLinkChannelMapTests: XCTestCase {
    private func timing() -> ProgramTiming { ProgramTiming(format: .hd1080p5994, t0: HostClock.now()) }

    func test014_deckLinkChannelsComeFromInputSource_explicitOptionsOverride() throws {
        let config = InputConfig(number: 1, name: "SDI 6/3", source: .decklink(deviceID: "peid:1", connection: .sdi, channels: [5, 2]))
        let input = try DeckLinkInput(config: config, timing: timing(), videoSlot: LockFreeFrameSlot(capacity: 3))
        XCTAssertEqual(input.options.channelMap, [5, 2])
        XCTAssertEqual(input.options.connection, .sdi, "008 的接口照旧从 case 取")

        var explicit = DeckLinkInput.Options()
        explicit.channelMap = [0, 1]
        XCTAssertEqual(try DeckLinkInput(config: config, timing: timing(), videoSlot: LockFreeFrameSlot(capacity: 3), options: explicit)
            .options.channelMap, [0, 1], "Options 非 nil = 显式给了，以它为准")

        let legacy = try JSONDecoder().decode(InputSource.self, from: Data(#"{"decklink":{"deviceID":"peid:1"}}"#.utf8))
        XCTAssertEqual(try DeckLinkInput(config: InputConfig(number: 1, name: "老文件", source: legacy), timing: timing(),
                                         videoSlot: LockFreeFrameSlot(capacity: 3)).options.channelMap, [], "老节目文件 = 取前几路")
    }

    func test014_embeddedAudioChannelCountCoversTheMapAndRoundsUpToWhatTheSDKAccepts() {
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 2, map: [], ringChannels: 2), 2, "默认不变")
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 2, map: [0, 1], ringChannels: 2), 2)
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 2, map: [5, 2], ringChannels: 2), 8, "要第 6 路 → 开 8 路")
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 2, map: [12], ringChannels: 2), 16)
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 2, map: [40], ringChannels: 2), 16, "SDK 最多 16 路")
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 2, map: [3, 4, 15], ringChannels: 2), 8, "用不上的项不算")
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 6, map: [], ringChannels: 2), 8, "SDK 只认 2 / 8 / 16，往上取")
        XCTAssertEqual(DeckLinkInput.embeddedAudioChannels(requested: 0, map: [5], ringChannels: 2), 0, "Options 显式关了音频就不开")
    }

    func test014_deckLinkFake_eightChannelEmbeddedAudio_mappedIntoRing() throws {
        guard SwitcherDeckLinkInfo.isSDKAvailable else {
            throw XCTSkip("BLOCKED-SDK：没有 DeckLink SDK 头，Fake IDeckLinkInput 编不出来")
        }
        let fake = try XCTUnwrap(sw_decklink_fake_create())
        defer { sw_decklink_fake_destroy(fake) }
        let ring = HarnessAudioRing(channelCount: 2, capacityFrames: 1 << 15)
        var options = DeckLinkInput.Options()
        options.channelMap = [5, 2]
        let input = DeckLinkInput(number: 4, name: "SDI 6/3", deviceID: "fake", timing: timing(),
                                  videoSlot: LockFreeFrameSlot(capacity: 3), audioRing: ring, options: options, fake: fake)
        try input.start()
        defer { input.stop() }
        XCTAssertTrue(waitUntil(timeoutMs: 2000) { input.deckLinkCounters.rebuilds == 1 }, "会话应建起来")
        var log = sw_decklink_fake_log()
        sw_decklink_fake_get_log(fake, &log)
        XCTAssertEqual(log.last_audio_channels, 8, "映射要第 6 路，内嵌音频应开 8 路")

        // 8 路交错 int32：第 k 路恒为 (k + 1) << 24 = (k + 1) / 128 满幅
        let frames = 800
        let channels = 8
        var audio = [Int32](repeating: 0, count: frames * channels)
        for i in 0..<frames { for k in 0..<channels { audio[i * channels + k] = Int32(k + 1) << 24 } }
        let width = 1920, height = 1080
        let bytes = [UInt8](repeating: 0x80, count: width * height * 2)
        let frameDuration: Int64 = 16_683_350
        let hardwareOffset: Int64 = 500_000_000
        for n in 0..<4 {
            var f = sw_decklink_fake_frame()
            f.width = Int32(width)
            f.height = Int32(height)
            f.row_bytes = Int32(width * 2)
            f.pixel_format = 0x32767579   // '2vuy'
            f.hw_duration_ns = frameDuration
            f.stream_time_ns = Int64(n) * frameDuration
            f.hw_timestamp_supported = 1
            f.audio_frames = Int32(frames)
            f.audio_channels = Int32(channels)
            f.audio_sample_type = 32
            f.audio_packet_time_ns = Int64(n) * frameDuration
            let hwNow = Int64(HostClock.now().nanoseconds) - hardwareOffset
            f.hw_time_ns = hwNow - frameDuration
            sw_decklink_fake_set_hardware_clock(fake, hwNow)
            audio.withUnsafeBufferPointer { a in
                bytes.withUnsafeBufferPointer { b in
                    f.bytes = UnsafeRawPointer(b.baseAddress)
                    f.audio_bytes = UnsafeRawPointer(a.baseAddress)
                    sw_decklink_fake_emit_frame(fake, &f)
                }
            }
            usleep(UInt32(frameDuration / 1000))
        }
        XCTAssertTrue(waitUntil(timeoutMs: 2000) { ring.availableFrames >= frames * 4 }, "四包音频都该进环：\(ring.availableFrames)")
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.initialize(repeating: 0, count: frames)
        right.initialize(repeating: 0, count: frames)
        defer { left.deallocate(); right.deallocate() }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { table.deallocate() }
        table[0] = left
        table[1] = right
        let read = ring.read(into: UnsafePointer(table), frameCount: frames)
        XCTAssertEqual(read.framesRead, frames)
        XCTAssertEqual(left[0], 6.0 / 128, "环的第 0 路 = 内嵌音频第 6 路（下标 5）")
        XCTAssertEqual(right[0], 3.0 / 128, "环的第 1 路 = 内嵌音频第 3 路（下标 2）")
        XCTAssertEqual(left[frames - 1], 6.0 / 128)
        XCTAssertEqual(right[frames - 1], 3.0 / 128)
    }
}
