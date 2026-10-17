import XCTest
import Foundation
import SwitcherContracts
@testable import SwitcherTestKit

/// W1-A3（prompt 62，问题单 G4-w1-testkit-frameprobe-wipe-zoom-progress）：
/// 1. 转场合成帧的自证解码：帧号行、时间戳行、ID 块三样互相印证，Wipe 的半新半旧码字、Fade 的第三色都不进 V4 / C3 的统计。
/// 2. Wipe / Zoom 的进度量法：与 W3-B 渲染侧同口径（第 s + k 拍 progress = k / D，偏差换算成帧 ≤ 1）。
final class TransitionProbeTests: XCTestCase {
    /// 合成素材用 720p：图案块 21 px，H.264 往返稳（RoundTripTests 量过），写一个 2 s 文件约 2 s。
    static let width = 1280
    static let height = 720
    /// 转场时长（拍）——与 g4 场景同一个数。
    static let duration = 24
    /// 转场命令拍。
    static let commandTick = 60

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1a3-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A（ID 0、灰 64、60 fps）→ 第 60 拍转场 24 拍 → B（ID 1、灰 192、30 fps），共 150 帧。
    private func spec(events: [SampleMovieWriter.Event]) -> SampleMovieWriter.Spec {
        var s = SampleMovieWriter.Spec()
        s.width = Self.width; s.height = Self.height
        s.seconds = 2.5
        s.bitrate = 4_000_000
        s.audio = .none
        s.frameRate = .fps60
        s.sourceA = SyntheticSourceSettings(frameRate: .fps60, width: Self.width, height: Self.height, background: .gray(level: 64), patternID: 0, audio: false)
        s.sourceB = SyntheticSourceSettings(frameRate: .fps30, width: Self.width, height: Self.height, background: .gray(level: 192), patternID: 1, audio: false)
        s.events = events
        return s
    }

    private func write(_ events: [SampleMovieWriter.Event], name: String) async throws -> URL {
        let url = tempDir().appendingPathComponent(name)
        _ = try await SampleMovieWriter.write(spec: spec(events: events), to: url)
        return url
    }

    private func probeOptions() -> FrameProbe.Options {
        var o = FrameProbe.Options()
        o.fps = 60
        o.inputFps = [0: 60, 1: 30]
        return o
    }

    // MARK: - V4：Wipe 的合成帧不算丢帧 / 倒退

    /// 硬边 leftToRight / topToBottom 各一段 Wipe：两路的帧号序列不许出现缺口或倒退，
    /// 解不出的帧全部落在转场中间拍里（[s + 1, s + D − 1]），且数量 = 解码区（码字行 / ID 块 / 中心采样区 / ID 邻域）真的被擦边切开的帧数。
    func testV4_wipeCompositeFramesDoNotCountAsDrops() async throws {
        for direction in [WipeDirection.leftToRight, .topToBottom] {
            let url = try await write([.wipe(tick: Self.commandTick, durationTicks: Self.duration, direction: direction, softness: 0)],
                                      name: "wipe-\(direction.rawValue).mov")
            let out = try await FrameProbe.stats(url, options: probeOptions())
            let frames = try await FrameProbe.frames(url, options: probeOptions()).frames
            let window = Int64(Self.commandTick + 1)...Int64(Self.commandTick + Self.duration - 1)
            let undecodableTicks = frames.filter { $0.inputID == nil }.map { Int64($0.index) }
            print("[W1-A3] V4 Wipe \(direction.rawValue)：解不出 \(undecodableTicks.count) 帧 \(undecodableTicks.map(String.init).joined(separator: ","))")
            for id in out.stats.inputs {
                XCTAssertEqual(id.droppedFrames, 0, "\(direction.rawValue)：输入 \(id.inputID) 不该有缺口 \(id.dropGaps)")
                XCTAssertEqual(id.backwardJumps, 0, "\(direction.rawValue)：输入 \(id.inputID) 不该有帧号倒退")
            }
            XCTAssertEqual(out.stats.inputs.count, 2, "两路都要出现")
            for t in undecodableTicks {
                XCTAssertTrue(window.contains(t), "\(direction.rawValue)：第 \(t) 拍不在转场中间，不该解不出")
            }
            XCTAssertEqual(undecodableTicks.count, Self.expectedCompositeTicks(direction: direction).count,
                           "\(direction.rawValue)：解不出的帧数应等于解码区被擦边切开的帧数")
            XCTAssertEqual(undecodableTicks, Self.expectedCompositeTicks(direction: direction), "\(direction.rawValue)：解不出的拍号")
        }
    }

    /// 解码区（帧号行、时间戳行、ID 块、中心采样区、ID 邻域条）在第 s + k 拍是否被硬边擦边切开。
    /// 擦边位置 = progress × 画面尺寸；新画面在 leftToRight 时盖左边、topToBottom 时盖上边（W3-B 的 `wipeAlpha`）。
    static func expectedCompositeTicks(direction: WipeDirection) -> [Int64] {
        let g = TestPattern.Geometry(width: width, height: height)
        let rects = PatternProbe.decodeRects(geometry: g, width: width, height: height)
        var ticks: [Int64] = []
        for k in 1..<duration {
            let progress = Double(k) / Double(duration)
            let edge = direction == .leftToRight ? progress * Double(width) : progress * Double(height)
            let split = rects.contains { r in
                let lo = Double(direction == .leftToRight ? r.x : r.y)
                let hi = lo + Double(direction == .leftToRight ? r.width : r.height)
                return edge > lo && edge < hi
            }
            // 解码区哪块都没被切开时，这几块还得都在擦边的同一侧；中心区与 ID 邻域分属两边同样是合成帧
            let sides = rects.map { r -> Bool in
                let mid = Double(direction == .leftToRight ? r.x : r.y) + Double(direction == .leftToRight ? r.width : r.height) / 2
                return mid < edge      // true = 新画面那边
            }
            if split || Set(sides).count > 1 { ticks.append(Int64(commandTick + k)) }
        }
        return ticks
    }

    // MARK: - V7：Wipe / Zoom 的进度曲线

    func testV7_wipeProgressCurveWithinOneFrame() async throws {
        for direction in [WipeDirection.leftToRight, .rightToLeft, .topToBottom, .bottomToTop] {
            for softness in [0.0, 0.1] {
                let url = try await write([.wipe(tick: Self.commandTick, durationTicks: Self.duration, direction: direction, softness: softness)],
                                          name: "wipe-\(direction.rawValue)-\(Int(softness * 100)).mov")
                var o = probeOptions()
                o.transitionAt = Int64(Self.commandTick)
                o.transitionDuration = Self.duration
                o.wipeDirection = direction
                let r = try await FrameProbe.wipe(url, options: o)
                print("[W1-A3] V7 Wipe \(direction.rawValue) 软边 \(softness)：最大偏差 \(String(format: "%.3f", r.curve.maxDeviationFrames)) 帧，单调 \(r.curve.monotonic)，样本 \(r.curve.samples.count)")
                XCTAssertEqual(r.curve.samples.count, Self.duration - 1, "第 s + 1 … s + D − 1 拍每拍一个样本")
                XCTAssertLessThanOrEqual(r.curve.maxDeviationFrames, FrameAnalysis.v7MaximumDeviationFrames, "\(direction.rawValue) 软边 \(softness)")
                XCTAssertTrue(r.curve.monotonic, "\(direction.rawValue) 软边 \(softness) 进度不单调")
                XCTAssertTrue(r.curve.passV7)
            }
        }
    }

    func testV7_zoomProgressCurveWithinOneFrame() async throws {
        let url = try await write([.zoom(tick: Self.commandTick, durationTicks: Self.duration)], name: "zoom.mov")
        var o = probeOptions()
        o.transitionAt = Int64(Self.commandTick)
        o.transitionDuration = Self.duration
        let r = try await FrameProbe.zoom(url, options: o)
        print("[W1-A3] V7 Zoom：最大偏差 \(String(format: "%.3f", r.curve.maxDeviationFrames)) 帧，单调 \(r.curve.monotonic)，样本 \(r.curve.samples.count)")
        XCTAssertEqual(r.curve.samples.count, Self.duration - 1)
        XCTAssertLessThanOrEqual(r.curve.maxDeviationFrames, FrameAnalysis.v7MaximumDeviationFrames)
        XCTAssertTrue(r.curve.monotonic)
        XCTAssertTrue(r.curve.passV7)
    }

    /// 擦边先扫过码字行、后扫过 ID 块的那几帧是"旧 ID + 新帧号"：两样都是纯的，只有节奏对不上。
    /// 这里直接合成这种帧（ID 0 的色块与底色，配 30 fps 那路的帧号 / 时间戳），自证必须按 rhythm 判掉。
    func testV4_mismatchedIdAndFrameNumberIsRejectedByRhythm() throws {
        let w = 640, h = 360
        let pool = try NV12PixelBufferPool(width: w, height: h, maximumBuffers: 2)
        var frames: [ProbeFrame] = []
        var readings: [PatternProbe.Reading] = []
        func push(tick: Int, id: Int, number: UInt32, ms: UInt32, gray: UInt8) throws {
            guard let pb = pool.take() else { return XCTFail("取不到缓冲") }
            TestPattern.draw(TestPattern.Content(frameNumber: number, hostTimeMs: ms, inputID: id, flash: false,
                                                 background: .gray(level: gray)), into: pb)
            let r = try XCTUnwrap(PatternProbe.read(pixelBuffer: pb))
            frames.append(ProbeFrame(index: tick, ptsSeconds: Double(tick) / 60, reading: r))
            readings.append(r)
        }
        // 0–15 拍：ID 0（60 fps，t0 = 1000 ms）；16–19 拍：同样是 ID 0 的画面，帧号 / 时间戳却是 30 fps 那路的
        for t in 0..<16 { try push(tick: t, id: 0, number: UInt32(t), ms: UInt32(1000 + t * 1000 / 60), gray: 64) }
        for t in 16..<20 { try push(tick: t, id: 0, number: UInt32(t / 2), ms: UInt32(1000 + t * 1000 / 60), gray: 64) }
        for t in 20..<36 { try push(tick: t, id: 1, number: UInt32(t / 2), ms: UInt32(1000 + (t / 2) * 1000 / 30), gray: 192) }
        let result = SelfCheck.apply(frames: frames, readings: readings, options: SelfCheck.Options())
        XCTAssertEqual(result.report.byReason[SelfCheck.Reason.rhythm.rawValue], 4, "四帧「旧 ID + 新帧号」都该按节奏判掉")
        for f in result.frames where (16..<20).contains(f.index) { XCTAssertNil(f.inputID, "第 \(f.index) 帧该判成解不出") }
        for f in result.frames where !(16..<20).contains(f.index) { XCTAssertNotNil(f.inputID, "第 \(f.index) 帧不该被误杀") }
        // W1-A6（T02 同一类）：报告里判掉的帧的"拍"按 pts 算——前面漏了第 5 拍，文件序号比拍号小 1，列出来的仍是第 16–19 拍
        let keep = frames.indices.filter { frames[$0].index != 5 }
        let dropped = keep.enumerated().map { pos, i in
            ProbeFrame(index: pos, ptsSeconds: frames[i].ptsSeconds, frameNumber: frames[i].frameNumber, inputID: frames[i].inputID,
                       genTimeMs: frames[i].genTimeMs, flash: frames[i].flash, gray: frames[i].gray)
        }
        let r2 = SelfCheck.apply(frames: dropped, readings: keep.map { readings[$0] }, options: SelfCheck.Options())
        XCTAssertEqual(r2.report.examples.map(\.index), [15, 16, 17, 18], "文件序号")
        XCTAssertEqual(r2.report.examples.map(\.tick), [16, 17, 18, 19], "节目拍号按 pts，不是 startTick + 序号")
        XCTAssertEqual(SelfCheck.apply(frames: dropped, readings: keep.map { readings[$0] }, options: SelfCheck.Options(), startTick: 100)
            .report.examples.map(\.tick), [116, 117, 118, 119])
    }

    /// 自证用的读数必须与契约的 `TestPattern.decode` 逐字段一致（纯帧上）：解码口径只有一份。
    func testW1A3_patternProbeMatchesContractDecode() throws {
        let w = 640, h = 360
        let pool = try NV12PixelBufferPool(width: w, height: h, maximumBuffers: 2)
        for id in [0, 5, 15] {
            for (n, ms) in [(UInt32(0), UInt32(0)), (1234, 56789), (TestPattern.dataMask, TestPattern.dataMask)] {
                guard let pb = pool.take() else { return XCTFail("取不到缓冲") }
                let content = TestPattern.Content(frameNumber: n, hostTimeMs: ms, inputID: id, flash: n % 2 == 0,
                                                  background: .gray(level: UInt8(8 + 16 * id)))
                TestPattern.draw(content, into: pb)
                let contract = try XCTUnwrap(TestPattern.decode(pixelBuffer: pb))
                let probe = try XCTUnwrap(PatternProbe.read(pixelBuffer: pb))
                XCTAssertEqual(probe.decoded, contract, "ID \(id) 帧号 \(n)")
                XCTAssertEqual(probe.decoded.frameNumber, n)
                XCTAssertEqual(probe.decoded.inputID, id)
                XCTAssertLessThanOrEqual(probe.blockImpurity, 0.01, "纯帧的码字块必须是纯黑 / 纯白")
                XCTAssertLessThanOrEqual(probe.idSpread, 0.01, "纯帧的 ID 块四象限必须一致")
                XCTAssertLessThanOrEqual(probe.idDistance, 1.5, "纯帧的 ID 色必须落在调色板上")
                XCTAssertEqual(probe.centerGray, probe.cornerGray, accuracy: 0.5, "纯帧的中心与 ID 邻域同色")
            }
        }
    }

    // MARK: - C3：Fade 的混合色永远不解成第三路

    /// 16 色两两 Fade：调色板有整整五对的中点正好落在第三种颜色上（7+9 = 15、2+3 = 7、0+9 = 11、0+2 = 8、1+2 = 15，距离 < 0.4），
    /// 光看颜色无论什么阈值都躲不开，所以判据必须是三样互相印证。两种情形都测：
    /// - 两路帧号 / 时间戳不同（一般情形）：码字块电平在中段一半是灰的，纯度检查判掉；
    /// - 两路帧号 / 时间戳完全相同（g4 的 3、4 号：同 t0、同 59.94、无漂移）：码字一模一样，只剩底色能判。
    func testC3_fadeBlendNeverDecodesAsThirdInput() throws {
        let w = 640, h = 360
        let pool = try NV12PixelBufferPool(width: w, height: h, maximumBuffers: 4)
        let ratios = stride(from: 0.05, through: 0.95, by: 0.05).map { $0 }
        var decodedThird = 0, checked = 0
        for sameWord in [false, true] {
            for i in 0..<TestPattern.paletteSize {
                for j in (i + 1)..<TestPattern.paletteSize {
                    var sequence: [(ProbeFrame, PatternProbe.Reading)] = []
                    func draw(_ id: Int, tick: Int, into pb: CVPixelBuffer) {
                        // 每路自己的节奏：ID i 的第 n 帧 = 第 n 拍（60 fps），时间戳 = 1000 + n × 16.667 ms；
                        // sameWord 时两路共用 ID 0 的帧号与时间戳（码字一模一样）
                        let source = sameWord ? 0 : id
                        let n = UInt32(tick * (source % 2 == 0 ? 1 : 1))
                        let ms = UInt32(1000 + Double(tick) * 1000.0 / 60 + Double(source) * 7)
                        TestPattern.draw(TestPattern.Content(frameNumber: n, hostTimeMs: ms, inputID: id, flash: tick % 60 == 0,
                                                             background: .gray(level: UInt8(8 + 16 * id))), into: pb)
                    }
                    // 前后各 10 帧纯色，中间是混合帧
                    var tick = 0
                    func push(_ body: (CVPixelBuffer) -> Void) {
                        guard let pb = pool.take() else { return XCTFail("取不到缓冲") }
                        body(pb)
                        let reading = PatternProbe.read(pixelBuffer: pb)!
                        sequence.append((ProbeFrame(index: tick, ptsSeconds: Double(tick) / 60, reading: reading), reading))
                        tick += 1
                    }
                    for _ in 0..<10 { push { draw(i, tick: tick, into: $0) } }
                    let blendStart = tick
                    for t in ratios {
                        push { pb in
                            guard let top = pool.take() else { return XCTFail("取不到缓冲") }
                            draw(i, tick: tick, into: pb)
                            draw(j, tick: tick, into: top)
                            SampleMovieWriter.blendNV12(into: pb, top: top, progress: t)
                        }
                    }
                    let blendEnd = tick
                    for _ in 0..<10 { push { draw(j, tick: tick, into: $0) } }
                    let checkedFrames = SelfCheck.apply(frames: sequence.map(\.0), readings: sequence.map(\.1), options: SelfCheck.Options()).frames
                    for f in checkedFrames where f.index >= blendStart && f.index < blendEnd {
                        checked += 1
                        if let id = f.inputID, id != i, id != j {
                            decodedThird += 1
                            XCTFail("\(sameWord ? "同码字" : "异码字") \(i) → \(j) 的第 \(f.index - blendStart) 个混合帧解成了第三路 \(id)")
                        }
                    }
                    // 两端的纯色帧必须照常解出来（自证不许误杀）
                    for f in checkedFrames where f.index < blendStart {
                        XCTAssertEqual(f.inputID, i, "纯色帧被自证误杀：\(i) → \(j) 第 \(f.index) 帧")
                    }
                    for f in checkedFrames where f.index >= blendEnd {
                        XCTAssertEqual(f.inputID, j, "纯色帧被自证误杀：\(i) → \(j) 第 \(f.index) 帧")
                    }
                }
            }
        }
        print("[W1-A3] C3：\(checked) 个混合帧，解成第三路 \(decodedThird) 个")
        XCTAssertEqual(decodedThird, 0)
    }

    // MARK: - T02（W1-A6，prompt 121）：录制漏帧之后，转场落点按 pts 换算的节目拍号判

    /// Codex T02 的真文件版：VideoToolbox 写一个漏了第 20 / 30 拍的 720p 文件（3 s：第 100 拍 Cut 到 B、第 130 拍 Fade 30 拍回 A），
    /// **不给 --fps**（gate4 的 switches / fade 就是这么调的）。容器的 nominalFrameRate 是"样本数 / 时长"= 178 / 3 ≈ 59.33
    /// （W1-A6 探针），拿它乘 pts 同样偏一拍；按相邻帧 pts 差估的帧率是 60：Cut 落在第 100 拍、Fade 偏差不到 1 帧。
    func testV6_V7_T02_droppedFramesInRecording_transitionsLandOnPtsTicks() async throws {
        var s = spec(events: [.cut(tick: 100), .fade(tick: 130, durationTicks: 30)])
        s.seconds = 3
        s.droppedTicks = [20, 30]
        let url = tempDir().appendingPathComponent("t02-dropped.mov")
        let written = try await SampleMovieWriter.write(spec: s, to: url)
        XCTAssertEqual(written.frames, 178)
        var o = FrameProbe.Options()
        o.inputFps = [0: 60, 1: 30]
        let loaded = try await FrameProbe.load(url, options: o, withAudio: false)
        XCTAssertEqual(loaded.frames.count, 178)
        print("[W1-A6] T02 真文件：178 帧 / 3 s，容器 nominalFrameRate \(loaded.info.nominalFps)")
        let sw = try await FrameProbe.switches(url, options: o).switches
        let cut = try XCTUnwrap(sw.switches.first { $0.kind == "cut" })
        XCTAssertEqual(cut.index, 98, "文件里第 98 帧（前面漏了两帧）")
        XCTAssertEqual(cut.tick, 100, "第 100 拍的 Cut")
        XCTAssertTrue(cut.cleanCut)
        XCTAssertEqual(sw.missingFrames, [20, 30]); XCTAssertEqual(sw.missingFrameCount, 2)
        XCTAssertEqual(sw.fps ?? 0, 60, accuracy: 1e-6, "按相邻帧 pts 差估，不是容器的 \(loaded.info.nominalFps)")
        o.fadeAt = 130
        o.fadeDuration = 30
        let fd = try await FrameProbe.fade(url, options: o).fade
        XCTAssertEqual(fd.fades.count, 1)
        let fade = try XCTUnwrap(fd.fades.first)
        XCTAssertEqual(fade.direction, "B→A")
        XCTAssertEqual(fade.startTick, 131)
        XCTAssertEqual(fade.samples.count, 29)
        XCTAssertLessThanOrEqual(fade.maxDeviationFrames, FrameAnalysis.v7MaximumDeviationFrames, "按下标取拍时整体错 2 帧")
        XCTAssertTrue(fade.passV7)
        XCTAssertEqual(fade.missingFrameCount, 0, "Fade 窗口里没漏"); XCTAssertEqual(fd.missingFrames, [20, 30])
        print("[W1-A6] T02 真文件：Cut 第 \(cut.tick) 拍（文件第 \(cut.index) 帧），Fade 最大偏差 \(String(format: "%.3f", fade.maxDeviationFrames)) 帧")
    }
}
