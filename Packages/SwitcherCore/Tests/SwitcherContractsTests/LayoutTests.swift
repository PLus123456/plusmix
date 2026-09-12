import XCTest
@testable import SwitcherContracts

/// C 头文件里的音频环布局：Swift 看到的 offset 与 layout.c 的 _Static_assert、CONTRACTS.md 一致。
final class LayoutTests: XCTestCase {
    func testP1_audioRingHeader_layoutIsFrozen() {
        XCTAssertEqual(MemoryLayout<sw_audio_stamp>.size, 16)
        XCTAssertEqual(MemoryLayout<sw_audio_stamp>.offset(of: \.host_time), 8)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.size, 256)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.alignment, 8, "自然对齐 8；64 字节对齐由分配方保证")
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.layout_version), 0)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.channels), 4)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.sample_rate), 8)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.capacity_frames), 12)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.stamp_capacity), 16)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.planes), 24)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.stamps), 88)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.write_index), 128)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.stamp_write), 136)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.overruns), 144)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.read_index), 192)
        XCTAssertEqual(MemoryLayout<sw_audio_ring>.offset(of: \.underruns), 200)
        XCTAssertEqual(sw_audio_ring_layout_version, 1)
        XCTAssertEqual(SW_AUDIO_RING_LAYOUT_VERSION, 1)
        XCTAssertEqual(SW_AUDIO_SAMPLE_RATE, 48_000)
        XCTAssertEqual(SW_AUDIO_MAX_CHANNELS, 8)
        XCTAssertEqual(SW_AUDIO_DEFAULT_BLOCK_FRAMES, 256)
        XCTAssertEqual(AudioFormat.sampleRate, 48_000)
        XCTAssertEqual(AudioFormat.maxChannels, 8)
        XCTAssertEqual(AudioFormat.defaultBlockFrames, 256)
    }

    func testP1_audioRingHeader_inlineHelpers() {
        // 实现分配环头时要自己保证 64 字节对齐（两条计数缓存线才真的独占）
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<sw_audio_ring>.size, alignment: 64)
        defer { raw.deallocate() }
        let ring = raw.initializeMemory(as: sw_audio_ring.self, repeating: sw_audio_ring(), count: 1)
        ring.pointee.capacity_frames = 1024
        ring.pointee.write_index = 300
        ring.pointee.read_index = 44
        XCTAssertEqual(sw_audio_ring_available(ring), 256)
        XCTAssertEqual(sw_audio_ring_free_space(ring), 768)
        XCTAssertEqual(sw_audio_ring_offset(ring, 1030), 6)
        XCTAssertEqual(sw_audio_ring_offset(ring, 1024), 0)
        // 指针本身 64 字节对齐
        XCTAssertEqual(Int(bitPattern: ring) % 64, 0)
    }
}
