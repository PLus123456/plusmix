import XCTest
@testable import SwitcherContracts

/// MixerState 的不变量、默认值、tally 推导，以及 InputSettings 的范围钳制。
final class StateTests: XCTestCase {
    func testP1_mixerState_defaults() throws {
        let s = MixerState()
        XCTAssertEqual(s.format, .hd1080p60)
        XCTAssertEqual(s.overlays.count, MixerState.overlayCount)
        XCTAssertEqual(MixerState.overlayCount, 4)
        XCTAssertEqual(s.audio.buses.map(\.bus), [.master, .busA, .busB, .headphones])
        XCTAssertEqual(Bus.allCases.count, 4)
        XCTAssertEqual(s.program, MixerState.noInput)
        XCTAssertEqual(s.preview, MixerState.noInput)
        XCTAssertFalse(s.transition.isActive)
        XCTAssertEqual(s.transition.type, .fade)
        XCTAssertEqual(s.transition.durationTicks, 30)
        XCTAssertFalse(s.ftb.on)
        XCTAssertEqual(s.ftb.level, 0)
        XCTAssertFalse(s.audio.afv)
        XCTAssertTrue(s.inputs.isEmpty && s.outputs.isEmpty)
        XCTAssertNoThrow(try s.validate())
        XCTAssertEqual(TransitionType.allCases, [.cut, .fade, .wipe, .zoom, .stinger])
    }

    func testP1_mixerState_validateCatchesBrokenInvariants() {
        var s = Samples.mixerState()
        s.overlays.removeLast()
        XCTAssertThrowsError(try s.validate())
        s = Samples.mixerState()
        s.audio.buses.swapAt(0, 1)
        XCTAssertThrowsError(try s.validate())
        s = Samples.mixerState()
        s.inputs.append(s.inputs[0])
        XCTAssertThrowsError(try s.validate(), "输入编号重复")
        s = Samples.mixerState()
        s.inputs[0].number = 0
        XCTAssertThrowsError(try s.validate(), "编号 0 保留给“无输入”")
        s = Samples.mixerState()
        s.outputs.append(s.outputs[0])
        XCTAssertThrowsError(try s.validate(), "输出编号重复")
    }

    func testP1_mixerState_lookups() {
        let s = Samples.mixerState()
        XCTAssertEqual(s.input(1)?.name, "机位 1")
        XCTAssertNil(s.input(99))
        XCTAssertEqual(s.output(2)?.kind, .stream)
        XCTAssertNil(s.output(0))
        XCTAssertEqual(s.inputs.map(\.kind), [.camera, .screen, .file, .image, .decklink, .ndi, .audio, .synthetic])
        XCTAssertEqual(s.inputs.map(\.id), s.inputs.map(\.number))
    }

    /// tally 只在契约里算一次，UI / API / 多画面都读它（C3 一致性的前提）。
    func testP1_tally_derivation() {
        var s = MixerState()
        s.inputs = Samples.inputs()
        s.program = 1
        s.preview = 2
        XCTAssertEqual(s.tally(ofInput: 1), Tally(program: true, preview: false))
        XCTAssertEqual(s.tally(ofInput: 2), Tally(program: false, preview: true))
        XCTAssertEqual(s.tally(ofInput: 3), .off)
        XCTAssertEqual(s.tally(ofInput: 0), .off)
        // 转场进行中：PVW 也在 PGM 上
        s.transition.progress = 0.3
        s.transition.startTick = Tick(10)
        XCTAssertEqual(s.tally(ofInput: 2), Tally(program: true, preview: true))
        s.transition.progress = 0; s.transition.startTick = nil
        // 叠加通道开着（或还在退出动画）→ 在 PGM 上
        s.overlays[1].input = 4
        s.overlays[1].on = true
        XCTAssertEqual(s.tally(ofInput: 4), Tally(program: true, preview: false))
        s.overlays[1].on = false
        s.overlays[1].animProgress = 0.5
        XCTAssertEqual(s.tally(ofInput: 4).program, true)
        s.overlays[1].animProgress = 0
        XCTAssertEqual(s.tally(ofInput: 4), .off)
        // FTB 不改 tally
        s.ftb.on = true; s.ftb.level = 1
        XCTAssertEqual(s.tally(ofInput: 1).program, true)
        // program == preview 两个都亮
        s.preview = 1
        XCTAssertEqual(s.tally(ofInput: 1), Tally(program: true, preview: true))
        XCTAssertEqual(s.tallies.count, s.inputs.count)
        XCTAssertEqual(s.tallies[1], Tally(program: true, preview: true))
    }

    func testP1_inputSettings_clamped() {
        var a = InputAudioSettings()
        a.delayMs = 900; a.pan = 3; a.gainDb = 40
        var s = InputSettings(); s.audio = a
        s.crop = CropInsets(left: -1, top: 0.6, right: 0.6, bottom: 2)
        s.transform.scale = 0
        let c = s.clamped()
        XCTAssertEqual(c.audio.delayMs, 500)
        XCTAssertEqual(InputAudioSettings.delayRangeMs, 0...500)
        XCTAssertEqual(c.audio.pan, 1)
        XCTAssertEqual(c.audio.gainDb, InputAudioSettings.gainRangeDb.upperBound)
        XCTAssertEqual(c.crop.left, 0)
        XCTAssertEqual(c.crop.bottom, 0.4, accuracy: 1e-12, "下边让位：1 − top")
        XCTAssertLessThanOrEqual(c.crop.top + c.crop.bottom, 1, "上下裁切之和不能超过 1")
        XCTAssertGreaterThan(c.transform.scale, 0)
        XCTAssertEqual(InputSettings().clamped(), InputSettings())
        XCTAssertEqual(BusRouting.masterOnly[.master], true)
        XCTAssertEqual(BusRouting.masterOnly[.busA], false)
        var r = BusRouting.masterOnly; r[.headphones] = true
        XCTAssertTrue(r.headphones)
    }

    func testP1_snapshot_isImmutableReferenceToState() {
        let state = Samples.mixerState()
        let snap = MixerSnapshot(state: state, sequence: 12, tick: Tick(500))
        XCTAssertEqual(snap.state, state)
        XCTAssertEqual(snap.sequence, 12)
        XCTAssertEqual(snap.tick, Tick(500))
    }

    func testP1_renderInputTable_reusesStorage() {
        let table = RenderInputTable(capacity: 8)
        XCTAssertNil(table[inputNumber: 3])
        XCTAssertNil(table[inputNumber: 99], "越界读返回 nil 不崩")
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        let frame = Frame(pixelBuffer: pb!, pts: HostTime(ticks: 1), duration: HostDuration(ticks: 400_000), color: .bt709Limited, inputNumber: 3, sequence: 9, ingressTime: HostTime(ticks: 2))
        table[inputNumber: 3] = frame
        XCTAssertEqual(table[inputNumber: 3]?.sequence, 9)
        XCTAssertEqual(table[inputNumber: 3]?.pixelFormat, .bgra)
        XCTAssertEqual(frame.width, 64)
        table.removeAll()
        XCTAssertNil(table[inputNumber: 3])
        XCTAssertEqual(table.capacity, 8)
        XCTAssertEqual(PixelFormat(cvPixelFormatType: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), .nv12)
        XCTAssertEqual(PixelFormat.nv12.cvPixelFormatType(range: .limited), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(PixelFormat.uyvy.cvPixelFormatType(range: .limited), kCVPixelFormatType_422YpCbCr8)
        XCTAssertEqual(PixelFormat.bgra.planeCount, 1)
        XCTAssertEqual(PixelFormat.nv12.planeCount, 2)
    }
}
