import XCTest
import SwitcherContracts
import SwitcherInputsHarness
@testable import SwitcherInputs

/// 提案 014 的声道映射口径（`InputChannelMap`，纯音频设备与 DeckLink 共用）+ `AudioDeviceInput` 从 case 取映射。
final class InputChannelMapTests: XCTestCase {
    private func map(_ m: [Int], destinations: Int, source: Int) -> [Int] {
        (0..<destinations).map { InputChannelMap.sourceChannel(forDestination: $0, map: m, sourceChannels: source) }
    }

    // MARK: 口径

    func test014_emptyMapTakesTheFirstChannels() {
        XCTAssertEqual(map([], destinations: 2, source: 8), [0, 1])
        XCTAssertEqual(map([], destinations: 2, source: 2), [0, 1])
        XCTAssertEqual(map([], destinations: 2, source: 1), [0, 0], "单声道复制到所有声道")
        XCTAssertEqual(map([], destinations: 4, source: 2), [0, 1, 1, 1], "源声道比环少：缺的复制最后一路")
    }

    func test014_explicitMapPicksChannels_shortMapRepeatsLastEntry_extraEntriesIgnored() {
        XCTAssertEqual(map([4, 5], destinations: 2, source: 8), [4, 5])
        XCTAssertEqual(map([5, 2], destinations: 2, source: 8), [5, 2], "可以反着取")
        XCTAssertEqual(map([4], destinations: 2, source: 8), [4, 4], "单项 = 单声道话筒，复制到两个声道")
        XCTAssertEqual(map([1, 2, 3], destinations: 2, source: 8), [1, 2], "多出来的项忽略")
    }

    func test014_outOfRangeIndicesAreClamped() {
        XCTAssertEqual(map([9, -3], destinations: 2, source: 4), [3, 0])
        XCTAssertEqual(map([2, 3], destinations: 2, source: 1), [0, 0])
        XCTAssertEqual(InputChannelMap.sourceChannel(forDestination: 0, map: [5], sourceChannels: 0), 0, "没有源声道也不越界")
    }

    func test014_requiredSourceChannels() {
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [], destinationChannels: 2), 0, "空映射没有额外要求")
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [5, 2], destinationChannels: 2), 6)
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [4], destinationChannels: 2), 5)
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [3, 4, 15], destinationChannels: 2), 5, "用不上的项不算")
    }

    /// Codex N05（2026-10-22，分项 CI-05）：`requiredSourceChannels` 对原始下标 +1，`[Int.max]` 在这里溢出（SIGTRAP，整个 xctest 进程退出）；
    /// DeckLink 的 16 路封顶在它之后，来不及。修好：+1 饱和、结果再封顶 `maxSourceChannels`——越界的下标本来就要钳到源的声道范围（契约），
    /// 这里只决定"源至少开几路"，调用方再按自己的上限钳（DeckLink 16、Core Audio 设备按实际声道数）。
    func testN05_requiredSourceChannels_hugeIndexSaturatesAndCaps() {
        let cap = InputChannelMap.maxSourceChannels
        XCTAssertEqual(cap, 64)
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [Int.max], destinationChannels: 2), cap, "Int.max + 1 不溢出、封顶")
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [Int.max - 1], destinationChannels: 2), cap, "+1 正好到 Int.max，也封顶")
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [0, Int.max], destinationChannels: 2), cap)
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [Int.max, 3], destinationChannels: 1), cap, "环只有一路：只看第一项")
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [999], destinationChannels: 2), cap, "Codex 的对照 [999]：原来 1000，现在封顶")
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [cap - 1], destinationChannels: 2), cap, "封顶边界：要第 64 路正好 64")
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [cap - 2], destinationChannels: 2), cap - 1)
        XCTAssertEqual(InputChannelMap.requiredSourceChannels(map: [Int.min, -1], destinationChannels: 2), 0, "负下标不要求额外的路（用的时候钳到 0）")
        // 用的时候照旧钳到源的声道范围
        XCTAssertEqual(InputChannelMap.sourceChannel(forDestination: 0, map: [Int.max], sourceChannels: 16), 15)
        XCTAssertEqual(InputChannelMap.sourceChannel(forDestination: 1, map: [Int.min], sourceChannels: 16), 0)
    }

    // MARK: AudioDeviceInput 从 InputSource 取映射

    func test014_audioDeviceChannelsComeFromInputSource_explicitOptionsOverride() throws {
        let ring = HarnessAudioRing()
        let config = InputConfig(number: 3, name: "话筒 5/6", source: .audio(deviceUID: "usb:x", channels: [4, 5]))
        let input = try AudioDeviceInput(config: config, audioRing: ring)
        XCTAssertEqual(input.deviceUID, "usb:x")
        XCTAssertEqual(input.options.channelMap, [4, 5])

        var explicit = AudioDeviceInput.Options()
        explicit.channelMap = [0]
        XCTAssertEqual(try AudioDeviceInput(config: config, audioRing: ring, options: explicit).options.channelMap, [0],
                       "Options 非 nil = 调用方显式给了，以它为准")

        let legacy = try JSONDecoder().decode(InputSource.self, from: Data(#"{"audio":{"deviceUID":"usb:x"}}"#.utf8))
        let fromLegacy = try AudioDeviceInput(config: InputConfig(number: 3, name: "老文件", source: legacy), audioRing: ring)
        XCTAssertEqual(fromLegacy.options.channelMap, [], "老节目文件 = 取前几路")

        XCTAssertThrowsError(try AudioDeviceInput(config: InputConfig(number: 3, name: "x", source: .image(path: "/a.png")), audioRing: ring))
    }
}
