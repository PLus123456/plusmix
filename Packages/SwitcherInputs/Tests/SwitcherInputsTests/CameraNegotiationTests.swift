import CoreMedia
import XCTest
import SwitcherContracts
@testable import SwitcherInputs

/// 摄像头格式协商（纯函数）：候选表照 macOS 26 探针里真实设备的格式抄。
final class CameraNegotiationTests: XCTestCase {
    typealias C = CameraFormatNegotiation.Candidate
    let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let yuvs = kCVPixelFormatType_422YpCbCr8_yuvs

    /// MacBook Pro 内置摄像头（探针）：全部 420v、15–30 fps。
    var builtIn: [C] {
        [(640, 480), (1280, 720), (1760, 1328), (1328, 1760), (1552, 1552), (1920, 1080), (1080, 1920)].enumerated().map {
            C(index: $0.offset, mediaSubType: v420, width: $0.element.0, height: $0.element.1, frameRateRanges: [15...30])
        }
    }
    /// iPhone 连续互通相机（探针）：同尺寸各有 30 与 60 两档。
    var iPhone: [C] {
        [(640, 480, 30.0), (640, 480, 60.0), (1280, 720, 30.0), (1280, 720, 60.0), (1920, 1080, 30.0), (1920, 1080, 60.0), (1920, 1440, 30.0)].enumerated().map {
            C(index: $0.offset, mediaSubType: v420, width: $0.element.0, height: $0.element.1, frameRateRanges: [1...$0.element.2])
        }
    }

    func testCameraNegotiation_builtIn30fpsCamera_in60fpsProgram_picks1080pAt30() {
        let choice = CameraFormatNegotiation.choose(builtIn, program: .hd1080p60)!
        XCTAssertEqual(choice.candidate.width, 1920)
        XCTAssertEqual(choice.candidate.height, 1080)
        XCTAssertEqual(choice.frameRate, 30)
        XCTAssertFalse(choice.matchesProgramFrameRate)
    }

    func testCameraNegotiation_frameRateBeatsResolution() {
        // 1080p 只有 30、720p 有 60：60 fps 节目选 720p60
        let choice = CameraFormatNegotiation.choose(iPhone.filter { !($0.width == 1920 && $0.height == 1080 && $0.frameRateRanges[0].upperBound == 60) },
                                                    program: .hd1080p60)!
        XCTAssertEqual(choice.candidate.width, 1280)
        XCTAssertEqual(choice.frameRate, 60)
        XCTAssertTrue(choice.matchesProgramFrameRate)
        // 都有 60 时选 1080p60
        let full = CameraFormatNegotiation.choose(iPhone, program: .hd1080p60)!
        XCTAssertEqual(full.candidate.width, 1920)
        XCTAssertEqual(full.candidate.height, 1080)
        XCTAssertEqual(full.frameRate, 60)
    }

    func testCameraNegotiation_30fpsProgram_locksTo30_andPrefersExactSize() {
        let choice = CameraFormatNegotiation.choose(iPhone, program: .hd1080p30)!
        XCTAssertEqual(choice.frameRate, 30)
        XCTAssertEqual(choice.candidate.width, 1920)
        XCTAssertEqual(choice.candidate.height, 1080)
        XCTAssertEqual(choice.candidate.index, 4, "同为 1080p 且都能给 30，取靠前的 30 档而不是 60 档")
    }

    func testCameraNegotiation_5994Program_acceptsRangeContaining5994() {
        let cands = [C(index: 0, mediaSubType: v420, width: 1920, height: 1080, frameRateRanges: [1...60])]
        let choice = CameraFormatNegotiation.choose(cands, program: .hd1080p5994)!
        XCTAssertTrue(choice.matchesProgramFrameRate)
        XCTAssertEqual(choice.frameRate, 60000.0 / 1001, accuracy: 1e-9)
    }

    func testCameraNegotiation_uvcCard_prefersNativeNV12WhenOtherwiseEqual_andSmallestLargerSize() {
        // UVC 卡：yuvs 1080p60、420v 1080p60、yuvs 4K30
        let cands = [
            C(index: 0, mediaSubType: yuvs, width: 1920, height: 1080, frameRateRanges: [60...60]),
            C(index: 1, mediaSubType: v420, width: 1920, height: 1080, frameRateRanges: [60...60]),
            C(index: 2, mediaSubType: yuvs, width: 3840, height: 2160, frameRateRanges: [30...30]),
        ]
        let choice = CameraFormatNegotiation.choose(cands, program: .hd1080p60)!
        XCTAssertEqual(choice.candidate.index, 1, "同尺寸同帧率，原生 420v 优先")
        // 720p 节目：没有 720p → 两边都 ≥ 的里最小的（1080p）
        let choice720 = CameraFormatNegotiation.choose(cands, program: .hd720p60)!
        XCTAssertEqual(choice720.candidate.width, 1920)
        // 2160p30 节目：4K30 精确匹配
        let choice4k = CameraFormatNegotiation.choose(cands, program: .uhd2160p30)!
        XCTAssertEqual(choice4k.candidate.index, 2)
    }

    func testCameraNegotiation_onlyHigherRates_picksClosestAbove() {
        let cands = [C(index: 0, mediaSubType: v420, width: 1280, height: 720, frameRateRanges: [50...50, 100...120])]
        let choice = CameraFormatNegotiation.choose(cands, program: .hd1080p30)!
        XCTAssertEqual(choice.frameRate, 50)
        XCTAssertFalse(choice.matchesProgramFrameRate)
        XCTAssertNil(CameraFormatNegotiation.choose([], program: .hd1080p60))
    }
}
