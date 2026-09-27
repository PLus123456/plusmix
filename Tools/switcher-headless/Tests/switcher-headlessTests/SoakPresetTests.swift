import XCTest
import SwitcherContracts
@testable import switcher_headless

/// W4-A 的两个预设（prompt 70 第 1、3 条）：soak = 8 路合成源 + 内置摄像头 + 一个文件，每 30 s 切换、每 5 min 开关叠加，
/// 2 路推流 + 1 路录制 + NDI 发送；perf-e4 = 只有一路文件输入在 PGM 上（E4：文件输入 → 编码 → 录制）。
final class SoakPresetTests: XCTestCase {
    private let fps = 60.0
    private let camera = SoakFactory.CameraDevice(uniqueID: "TEST-CAMERA-0001", name: "测试相机")
    private let clip = "/tmp/switcher-e4/source.mov"

    // MARK: 节目

    func testS1_soakShowHasEightSyntheticPlusCameraAndFile() throws {
        let show = SoakFactory.show(camera: camera, filePath: clip)
        try show.makeState().validate()
        let synthetic = show.inputs.filter { if case .synthetic = $0.source { return true } else { return false } }
        XCTAssertEqual(synthetic.map(\.number), Array(1...8), "8 路合成源（G4 的噪声底纹 + 5–8 号抠像）")
        guard case .camera(let id)? = show.inputs.first(where: { $0.number == SoakFactory.cameraInput })?.source else {
            return XCTFail("没有 \(SoakFactory.cameraInput) 号摄像头输入")
        }
        XCTAssertEqual(id, camera.uniqueID)
        guard case .file(let path, let end, let rate)? = show.inputs.first(where: { $0.number == SoakFactory.fileInput })?.source else {
            return XCTFail("没有 \(SoakFactory.fileInput) 号文件输入")
        }
        XCTAssertEqual(path, clip)
        XCTAssertEqual(end, .loop, "8 小时里文件要一直循环")
        XCTAssertEqual(rate, 1)
        // A2 / A3 只看 1 号的 click：摄像头 / 文件的声音不进 Master
        for n in [SoakFactory.cameraInput, SoakFactory.fileInput] {
            XCTAssertEqual(show.inputs.first { $0.number == n }?.settings.audio.routing.master, false, "输入 \(n) 不许进 Master")
        }
        XCTAssertEqual(show.inputs.first { $0.number == 1 }?.settings.audio.routing.master, true, "1 号的 click 进 Master")
    }

    func testS1_soakShowOutputsRecordStreamsNDIAndMultiview() throws {
        let show = SoakFactory.show(camera: camera, filePath: clip)
        let byKind = Dictionary(grouping: show.outputs, by: \.kind)
        XCTAssertEqual(byKind[.record]?.map(\.number), [1])
        XCTAssertEqual(byKind[.multiview]?.map(\.number), [2])
        XCTAssertEqual(byKind[.stream]?.map(\.number), [3, 4], "2 路推流：--stream 第 i 个对节目里第 i 个推流输出的编号")
        XCTAssertEqual(byKind[.ndi]?.map(\.number), [5])
        XCTAssertTrue(show.outputs.allSatisfy(\.enabled))
        // 多画面：PVW / PGM + 每路有画面的输入各一格（Stinger 的 PNG 不占格）
        let cells = show.outputs.first { $0.kind == .multiview }?.settings.multiview?.custom ?? []
        let inputCells = cells.compactMap { cell -> Int? in if case .input(let n) = cell.source { return n } else { return nil } }
        XCTAssertEqual(inputCells, Array(1...8) + [SoakFactory.cameraInput, SoakFactory.fileInput])
        for cell in cells {
            XCTAssertGreaterThanOrEqual(cell.rect.x, 0); XCTAssertGreaterThanOrEqual(cell.rect.y, 0)
            XCTAssertLessThanOrEqual(cell.rect.x + cell.rect.width, 1.0001); XCTAssertLessThanOrEqual(cell.rect.y + cell.rect.height, 1.0001)
        }
    }

    func testS1_soakOverlaysCarryCameraAndFile() throws {
        let show = SoakFactory.show(camera: camera, filePath: clip)
        XCTAssertEqual(show.mixer.overlays.prefix(4).map(\.input), [SoakFactory.cameraInput, SoakFactory.fileInput, 7, 8])
        XCTAssertTrue(show.mixer.overlays.allSatisfy { !$0.on }, "开局全关，场景每 5 min 翻一路")
    }

    func testS1_soakShowWithoutCameraFallsBackToSyntheticOverlay() throws {
        let show = SoakFactory.show(camera: nil, filePath: nil)
        try show.makeState().validate()
        XCTAssertNil(show.inputs.first { $0.number == SoakFactory.cameraInput })
        XCTAssertNil(show.inputs.first { $0.number == SoakFactory.fileInput })
        XCTAssertEqual(show.mixer.overlays.prefix(4).map(\.input), [5, 6, 7, 8], "没有摄像头 / 文件时叠加退回 G4 的 5–8 号")
    }

    // MARK: 场景

    func testS1_soakScenarioSwitchesEvery30Seconds() {
        let scenario = SoakFactory.scenario(minutes: 60, fps: fps)
        XCTAssertEqual(scenario.durationTicks, 60 * 60 * 60)
        let switchTicks = switchEvents(scenario).map(\.tick)
        XCTAssertEqual(switchTicks.count, 119, "60 分钟里第 30 s、60 s … 3570 s 各一次")
        XCTAssertEqual(switchTicks.first, 1800)
        for (a, b) in zip(switchTicks, switchTicks.dropFirst()) { XCTAssertEqual(b - a, 1800, "每 30 s 一次") }
        // 转场按 Cut / Fade / Wipe / Zoom / Stinger 轮流，8 小时里每种都跑满
        let kinds = switchEvents(scenario).map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(5)), [.cut, .fade, .wipe, .zoom, .stinger])
        XCTAssertEqual(Set(kinds), Set(TransitionType.allCases))
    }

    func testS1_soakScenarioTogglesAnOverlayEvery5Minutes() {
        let scenario = SoakFactory.scenario(minutes: 60, fps: fps)
        let toggles = scenario.events.compactMap { e -> (tick: Int64, channel: Int, on: Bool)? in
            if case .overlay(let ch, let on, _) = e.command { return (e.tick.rawValue, ch, on) }
            return nil
        }
        XCTAssertEqual(toggles.count, 12, "60 分钟 12 次")
        for (a, b) in zip(toggles, toggles.dropFirst()) { XCTAssertEqual(b.tick - a.tick, 18000, "每 5 min 一次") }
        XCTAssertEqual(toggles.map(\.channel).prefix(8), [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(toggles.map(\.on).prefix(8), [true, true, true, true, false, false, false, false])
        // 与 30 s 的切换点错开（叠加动画不和转场叠在同一拍）
        let switchTicks = Set(switchEvents(scenario).map(\.tick))
        for t in toggles { XCTAssertFalse(switchTicks.contains(t.tick)) }
    }

    func testA3_soakProgramOnlyCyclesPatternSources() {
        // A2 / A3 靠 PGM 上的闪光帧配 1 号的 click：PGM 只能轮 1–8 号合成源（摄像头 / 文件 / PNG 右上角亮了会被当成闪光）
        let scenario = SoakFactory.scenario(minutes: 480, fps: fps)
        var pgm = 1, pvw = 2
        var seen = Set<Int>()
        for e in scenario.events {
            switch e.command {
            case .cut, .fade, .autoTransition: (pgm, pvw) = (pvw, pgm)
            case .setPreview(let n): pvw = n
            default: break
            }
            seen.insert(pgm)
            XCTAssertNotEqual(pgm, pvw, "拍 \(e.tick.rawValue)：PGM 与 PVW 相同，下一次切换就不换画面了")
        }
        XCTAssertEqual(seen, Set(1...8))
        XCTAssertEqual(scenario.durationTicks, 480 * 60 * 60)
        XCTAssertEqual(switchEvents(scenario).count, 959)
    }

    func testS1_soakScenarioEventsSortedAndNonCutSettlesBeforeNext() {
        let scenario = SoakFactory.scenario(minutes: 30, fps: fps)
        let ticks = scenario.events.map(\.tick.rawValue)
        XCTAssertEqual(ticks, ticks.sorted())
        // setTransition 在 t − 1、autoTransition 在 t，PVW 在转场结束后（t + 24 + 1）才推到下一路
        for (i, e) in scenario.events.enumerated() {
            if case .setTransition(_, let d) = e.command {
                XCTAssertEqual(d, SoakFactory.transitionTicks)
                guard case .autoTransition = scenario.events[i + 1].command else { return XCTFail("setTransition 后面不是 autoTransition") }
                XCTAssertEqual(scenario.events[i + 1].tick.rawValue, e.tick.rawValue + 1)
            }
        }
    }

    // MARK: E4

    func testE4_perfShowPutsFileAloneOnProgram() throws {
        let show = SoakFactory.perfE4Show(filePath: clip)
        try show.makeState().validate()
        XCTAssertEqual(show.inputs.count, 1)
        guard case .file(let path, let end, let rate) = show.inputs[0].source else { return XCTFail("不是文件输入") }
        XCTAssertEqual(path, clip)
        XCTAssertEqual(end, .holdLastFrame, "片段放完停在末帧，不回卷（对源时不会把第二圈的开头当成第一圈的结尾）")
        XCTAssertEqual(rate, 1)
        XCTAssertEqual(show.mixer.program, show.inputs[0].number)
        XCTAssertEqual(show.mixer.format, .hd1080p60)
        XCTAssertEqual(show.outputs.map(\.kind), [.record])
        XCTAssertTrue(show.mixer.overlays.allSatisfy { !$0.on })
    }

    // MARK: 工具

    private func switchEvents(_ scenario: Scenario) -> [(tick: Int64, kind: TransitionType)] {
        var out: [(Int64, TransitionType)] = []
        var pending: TransitionType?
        for e in scenario.events {
            switch e.command {
            case .cut: out.append((e.tick.rawValue, .cut))
            case .fade: out.append((e.tick.rawValue, .fade))
            case .setTransition(let t, _): pending = t
            case .autoTransition:
                if let t = pending { out.append((e.tick.rawValue, t)) }
                pending = nil
            default: break
            }
        }
        return out
    }
}
