import XCTest
@testable import SwitcherContracts

/// 提案 031（用户 2026-10-17 批，P5-4 / prompt 115 落地；Codex 审查 D01：非法速率 / 超大定位值整个进程崩）：文件播放速率与定位秒数的不变量。
/// 同一条边界三处共用：API（CommandValidator，HTTP 400）、节目文件（`MixerState.validate()` → `MixerStateError.fileRate`）、FileInput 底层钳位（117）。
/// JSON 形态不变、命令数仍 42；老文件来源缺 rate = 1 照读。
final class Contracts031Tests: XCTestCase {
    /// 两个常量：速率 0.1…8（界面 rate 控件没有自己的范围，按 031 默认；W2-A4 实测 8 倍速带音频不饿）、定位上限一周。
    /// 非有限数、负数、越界都不在范围里（ClosedRange.contains 对 NaN 给 false）。
    func test031_constants_fileRateRangeAndMaxSeekSeconds() {
        XCTAssertEqual(FileSource.rateRange, 0.1...8)
        XCTAssertEqual(PlaybackLimits.maxSeekSeconds, 7 * 86_400)
        XCTAssertEqual(PlaybackLimits.maxSeekSeconds, 604_800)
        for r in [0.1, 0.5, 1, 1.5, 2, 8] { XCTAssertTrue(FileSource.rateRange.contains(r), "\(r)") }
        for r in [0, -1, 0.0001, 0.0999, 8.0001, 1e300, .nan, .infinity, -.infinity] { XCTAssertFalse(FileSource.rateRange.contains(r), "\(r)") }
    }

    /// 节目文件里 file 来源的 rate 越界 → `MixerStateError.fileRate(input:rate:)`；边界值、别的 kind 不受影响；Show.load 读到这种文件不打开（与别的不变量同一处理）。
    func test031_validateRejectsOutOfRangeFileRate_showLoadRefuses() throws {
        var s = MixerState(format: .hd1080p60)
        s.inputs = [InputConfig(number: 1, name: "合成", source: .synthetic(settings: SyntheticSourceSettings())),
                    InputConfig(number: 3, name: "片", source: .file(path: "/a.mov", endAction: .loop, rate: 1))]
        XCTAssertNoThrow(try s.validate())
        for ok in [0.1, 8] {
            s.inputs[1].source = .file(path: "/a.mov", endAction: .loop, rate: ok)
            XCTAssertNoThrow(try s.validate(), "边界 \(ok) 合法")
        }
        for bad in [0, -1, 0.0001, 8.5, 1e300, -.infinity] {
            s.inputs[1].source = .file(path: "/a.mov", endAction: .loop, rate: bad)
            XCTAssertThrowsError(try s.validate(), "\(bad)") { XCTAssertEqual($0 as? MixerStateError, .fileRate(input: 3, rate: bad)) }
        }
        s.inputs[1].source = .file(path: "/a.mov", endAction: .loop, rate: .nan)
        XCTAssertThrowsError(try s.validate()) { e in
            guard case .fileRate(let input, let rate)? = e as? MixerStateError else { return XCTFail("\(e)") }
            XCTAssertEqual(input, 3)
            XCTAssertTrue(rate.isNaN)
        }
        // 节目文件：Show.load 先搬迁再 validate，越界的速率读进来报错、不打开
        s.inputs[1].source = .file(path: "/a.mov", endAction: .loop, rate: 0)
        let data = try Show(name: "坏速率", state: s).save()
        XCTAssertThrowsError(try Show.load(from: data)) { XCTAssertEqual($0 as? MixerStateError, .fileRate(input: 3, rate: 0)) }
        s.inputs[1].source = .file(path: "/a.mov", endAction: .loop, rate: 2)
        XCTAssertNoThrow(try Show.load(from: try Show(name: "好速率", state: s).save()))
    }

    /// 031 之前手写 / 别的工具写的文件来源可能没有 rate：缺键 = 1 照读，整份节目读进来 validate 过；写出照旧总是写 rate（JSON 形态不变）。
    func test031_legacyFileSourceMissingRateReadsAsOne_jsonShapeUnchanged() throws {
        let decoded = try JSONDecoder().decode(InputSource.self, from: Data(#"{"file":{"endAction":"loop","path":"/a.mov"}}"#.utf8))
        XCTAssertEqual(decoded, .file(path: "/a.mov", endAction: .loop, rate: 1))
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try e.encode(InputSource.file(path: "/a.mov", endAction: .loop, rate: 1)), as: UTF8.self),
                       #"{"file":{"endAction":"loop","path":"/a.mov","rate":1}}"#, "写出照旧写 rate")
        XCTAssertEqual(try JSONDecoder().decode(InputSource.self, from: Data(#"{"file":{"endAction":"black","path":"/b.mov","rate":0.5}}"#.utf8)),
                       .file(path: "/b.mov", endAction: .black, rate: 0.5), "有 rate 照原值")
        // 整份节目：一路文件输入的 source 里删掉 rate 键 → 读进来 rate = 1、validate 过
        var state = MixerState(format: .hd1080p60)
        state.inputs = [InputConfig(number: 2, name: "片", source: .file(path: "/a.mov", endAction: .loop, rate: 1))]
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Show(name: "老", state: state).save()) as? [String: Any])
        var inputs = try XCTUnwrap(obj["inputs"] as? [[String: Any]])
        var source = try XCTUnwrap(inputs[0]["source"] as? [String: Any])
        var file = try XCTUnwrap(source["file"] as? [String: Any])
        file.removeValue(forKey: "rate")
        source["file"] = file
        inputs[0]["source"] = source
        obj["inputs"] = inputs
        let show = try Show.load(from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(show.inputs[0].source, .file(path: "/a.mov", endAction: .loop, rate: 1))
    }

    /// `InputSettings.clamped()`（setInputSettings / addInput 整体带进来的设置）：定位秒数钳到 [0, 一周]——与 seekPlayback 入口拒同一条边界（031 顺带）。
    func test031_clampedSeekSecondsCappedAtMaxSeek() {
        func clamped(_ seconds: Double?) -> Double? { InputSettings(playback: PlaybackSettings(seekSeconds: seconds, seekTick: Tick(1))).clamped().playback.seekSeconds }
        XCTAssertEqual(clamped(1e300), PlaybackLimits.maxSeekSeconds)
        XCTAssertEqual(clamped(PlaybackLimits.maxSeekSeconds + 0.5), PlaybackLimits.maxSeekSeconds)
        XCTAssertEqual(clamped(PlaybackLimits.maxSeekSeconds), PlaybackLimits.maxSeekSeconds)
        XCTAssertEqual(clamped(12.5), 12.5)
        XCTAssertEqual(clamped(-3), 0, "021：负数钳 0")
        XCTAssertEqual(clamped(.infinity), 0, "021：非有限给 0")
        XCTAssertNil(clamped(nil))
    }
}
