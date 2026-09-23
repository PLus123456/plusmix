// 多画面的名字标签（W3-B2 交付 3）：每格左下角画输入名字（PGM / PVW 格画 "PGM" / "PVW"），只在渲染器这一处画。
// 文字纹理在非渲染线程生成（CoreText → 位图 → 纹理），最多 64 个输入槽（= 布局表的格数上限），按输入编号分配、只给看得见的输入；
// 渲染线程每帧开头接手画好的那套（一次原子读 / 比较交换），只贴图。快照改名后下一帧就是新名字，渲染线程 0 分配。
import CoreGraphics
import Darwin
import Foundation
@preconcurrency import Metal
import Synchronization
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class MultiviewLabelTests: XCTestCase {
    /// 解析好布局的表（标签只给布局里看得见的输入）。
    func parsed(_ s: MixerState) -> MultiviewLayoutTable {
        let t = MultiviewLayoutTable()
        t.parse(state: s, width: 1920, height: 1080)
        return t
    }

    /// 槽按输入编号分配、只给看得见的输入、改名不换槽、看不见的腾出槽给新出现的、上限 64。
    func testMultiview_labelSlotsKeyedByInputNumberCappedAt64() throws {
        // 默认布局 8 路：8 个槽 + 空一个；末尾 PGM / PVW
        let s = ReferenceStates.fixed8()
        var c = LabelPainter.contents(for: s, layout: parsed(s), inputSlots: 9, keeping: nil)
        XCTAssertEqual(c.numbers, [1, 2, 3, 4, 5, 6, 7, 8, 0])
        XCTAssertEqual(c.texts.count, 9 + LabelSet.extraSlices)
        XCTAssertEqual(c.texts[0], "1  摄像机 1")
        XCTAssertEqual(c.texts[3], "4  PiP 画中画")
        XCTAssertEqual(c.texts[8], "")
        XCTAssertEqual(c.texts[9], "PGM")
        XCTAssertEqual(c.texts[10], "PVW")

        // 3×3 只看得见 1–7：输入 8 不占槽；沿用上一套的槽（输入 1–7 位置不动），改了名字的只换文字
        var s3 = ReferenceStates.withMultiviewPreset(s, "3x3")
        s3.inputs[2].name = "嘉宾 Guest"
        let keep = c.numbers
        c = LabelPainter.contents(for: s3, layout: parsed(s3), inputSlots: 9, keeping: keep)
        XCTAssertEqual(c.numbers, [1, 2, 3, 4, 5, 6, 7, 0, 0], "看不见的输入 8 腾出槽，其余不动")
        XCTAssertEqual(c.texts[2], "3  嘉宾 Guest")

        // 新出现的输入占第一个空槽，已有的不挪：自定义布局只放 9 和 2（输入 9 是新加的）
        var s9 = s3
        s9.inputs.append(InputConfig(number: 9, name: "", source: .image(path: "")))
        s9 = ReferenceStates.withMultiviewLayout(s9, MultiviewLayoutSettings(custom: [
            MultiviewCell(source: .input(number: 9), rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            MultiviewCell(source: .input(number: 2), rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
            MultiviewCell(source: .input(number: 42), rect: NormalizedRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),   // 状态里没有 42：不占槽
            MultiviewCell(source: .program, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        ]))
        c = LabelPainter.contents(for: s9, layout: parsed(s9), inputSlots: 9, keeping: c.numbers)
        XCTAssertEqual(c.numbers, [9, 2, 0, 0, 0, 0, 0, 0, 0], "输入 2 留在第 2 槽，新来的 9 占第 1 个空槽")
        XCTAssertEqual(c.texts[0], "9", "名字为空时只写编号")

        // 上限 64：70 路输入、自定义 64 格各放一路（第 65 格起被布局表截掉）→ 64 个槽全用上，65–70 没有标签
        var many = ReferenceStates.fixed8()
        many.inputs = (1...70).map { InputConfig(number: $0, name: "In \($0)", source: .image(path: "")) }
        many = ReferenceStates.withMultiviewLayout(many, MultiviewLayoutSettings(custom: (0..<70).map { i in
            MultiviewCell(source: .input(number: i + 1), rect: NormalizedRect(x: Double(i % 10) * 0.1, y: Double(i / 10) * 0.1, width: 0.1, height: 0.1))
        }))
        c = LabelPainter.contents(for: many, layout: parsed(many), inputSlots: LabelSet.maxInputSlots, keeping: nil)
        XCTAssertEqual(c.numbers, (1...64).map(Int32.init))
        XCTAssertEqual(LabelSet.maxInputSlots, MultiviewLayoutTable.capacity)

        // 纹理数组按上限建：要 1000 个也只建 64 + 2 片；查槽按编号
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let set = try LabelSet(device: device, inputSlots: 1000)
        XCTAssertEqual(set.inputSlots, 64)
        XCTAssertEqual(set.texture.arrayLength, 66)
        XCTAssertEqual(set.programSlice, 64)
        XCTAssertEqual(set.previewSlice, 65)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: LabelSet.width * LabelSet.height * 4, alignment: 16)
        defer { scratch.deallocate() }
        LabelPainter.update(set, from: s9, layout: parsed(s9), scratch: scratch)
        XCTAssertEqual(set.slice(forInput: 9), 0)
        XCTAssertEqual(set.slice(forInput: 2), 1)
        XCTAssertNil(set.slice(forInput: 3), "布局里看不见的输入没有槽")
        XCTAssertNil(set.slice(forInput: 42))
        XCTAssertNil(set.slice(forInput: 0))
        XCTAssertEqual(set.texts[set.programSlice], "PGM")
    }

    /// 标签线程与渲染线程的交接：画好的那套由渲染线程在帧开头接手；另一套在接手之前的帧没完成前不写；
    /// 交出去没被接手（多画面关了 / 引擎停了）就收回来重画；名字没变的新快照不重画。
    func testMultiview_labelHandshakeTakesBackUnadoptedSetAndWaitsForInflightFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let completed = FrameCounter()
        let labels = try LabelRenderer(device: device, inputSlots: 9, completedFrames: { completed.value })
        labels.start()
        defer { labels.stop() }
        func published() -> Int { labels.publishedCount.load(ordering: .acquiring) }
        func waitPublished(_ n: Int) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while published() < n && Date() < deadline { usleep(1000) }
            return published() >= n
        }
        var s = ReferenceStates.fixed8()

        // 1. 第一次：画好交出去，渲染线程第 10 帧接手
        labels.noteSnapshot(MixerSnapshot(state: s, sequence: 1, tick: .zero))
        XCTAssertTrue(waitPublished(1))
        let first = labels.acquire(frame: 10)
        let slot3 = try XCTUnwrap(first.slice(forInput: 3))
        XCTAssertEqual(first.texts[slot3], "3  Lower Third")
        XCTAssertTrue(labels.acquire(frame: 11) === first, "没有新画好的就一直用这套")

        // 2. 改名：要写的是另一套，它在第 10 帧之前的帧里可能还被 GPU 读着 → 那些帧没完成（completed < 10）就得等
        s.inputs[2].name = "嘉宾 Guest"
        labels.noteSnapshot(MixerSnapshot(state: s, sequence: 2, tick: .zero))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(published(), 1, "第 10 帧之前的帧没完成，标签线程不该动另一套")
        completed.value = 10
        XCTAssertTrue(waitPublished(2))
        let second = labels.acquire(frame: 12)
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.slice(forInput: 3), slot3, "改名不换槽")
        XCTAssertEqual(second.texts[slot3], "3  嘉宾 Guest")

        // 3. 交出去但渲染线程一直没接手时又改名：收回来重画那一套（它没被任何帧用过，不用等），再交出去
        completed.value = 12
        s.inputs[2].name = "Guest 2"
        labels.noteSnapshot(MixerSnapshot(state: s, sequence: 3, tick: .zero))
        XCTAssertTrue(waitPublished(3))
        s.inputs[2].name = "Guest 3"
        labels.noteSnapshot(MixerSnapshot(state: s, sequence: 4, tick: .zero))
        XCTAssertTrue(waitPublished(4))
        let third = labels.acquire(frame: 13)
        XCTAssertTrue(third === first, "收回重画的是渲染线程没在用的那一套")
        XCTAssertEqual(third.texts[slot3], "3  Guest 3")

        // 4. 名字没变的新快照（只切了 PGM）：不重画、不交接
        s.program = 2
        labels.noteSnapshot(MixerSnapshot(state: s, sequence: 5, tick: .zero))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(published(), 4)
        XCTAssertTrue(labels.acquire(frame: 14) === third)
    }

    /// 实时路径，60 fps 节奏：第 K 拍的快照把输入 3 改名 → 第 K + 1 拍的多画面就是新名字（与离线渲染新状态逐字节相同），
    /// 第 K 拍还是旧名字或新名字之一；整个过程渲染线程上 SwitcherRender 代码 0 次分配（MallocProbe）。
    func testMultiview_labelRenameShowsNextFrameWithoutRenderThreadAllocation() throws {
        try XCTSkipUnless(MallocProbe.isAvailable, "找不到 malloc_logger 符号")
        var options = MetalRendererOptions()
        options.multiviewOutput = true
        let renderer = try MetalRenderer(options: options)
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        let buffers = TestImages.phase2ReferenceBuffers()
        let inputs = buffers.sorted { $0.key < $1.key }.map { FakeInput(number: $0.key, buffers: [$0.value], color: .sRGBFull) }
        let before = ReferenceStates.fixed8()
        var after = before
        after.inputs[2].name = "嘉宾 Guest"
        let engine = FakeEngine(renderer: renderer, format: .hd1080p60, inputs: inputs, state: before)
        let renamed = MixerSnapshot(state: after, sequence: 7, tick: Tick(90))   // 在测试线程建好，钩子里只换引用
        let changeTick: Int64 = 91                                               // 第 90 拍的钩子换快照 → 第 91 拍第一次用到它
        engine.sink.keepTicks = [changeTick, changeTick + 1]
        let counting = SharedFlag()
        engine.beforeRender = { [weak engine] tick in
            if tick.rawValue == 60 { MallocProbe.start(); counting.value = true }
            if tick.rawValue == changeTick - 1 { engine?.publish(renamed) }
        }
        engine.afterRender = { tick, _ in
            if counting.value, tick.rawValue == 120 { MallocProbe.stop(); counting.value = false }
        }
        engine.run(seconds: 2.6)
        MallocProbe.stop()
        let published = renderer.labelPublishes
        var latencyMs: Double?
        if let publishedAt = renderer.lastLabelPublishTime,
           let changeTickTime = engine.sink.samples.first(where: { $0.tick.rawValue == changeTick })?.tickTime {
            latencyMs = (publishedAt - changeTickTime).milliseconds
        }
        renderer.shutdown()

        let list = MallocProbe.attributions()
        let own = list.filter(\.isOwn)
        let swiftOwned = list.filter { $0.directCaller.contains(":$s") }
        print("标签改名：第 \(changeTick) 拍第一次用新快照，标签线程共交接 \(published) 套，最后一次交接在第 \(changeTick) 拍拍点后 "
              + "\(latencyMs.map { String(format: "%.2f", $0) } ?? "?") ms；第 60–120 拍渲染线程共 \(list.count) 次分配，"
              + "SwitcherRender 代码 \(own.count) 次，全部 Swift 代码 \(swiftOwned.count) 次")
        for a in own.prefix(3) { print("   自己的分配：\(a.stack.prefix(12).joined(separator: " <- "))") }

        let offline = try OfflineRenderer()
        let old = try offline.render(state: before, pixelBuffers: buffers, size: CGSize(width: 1920, height: 1080)).multiviewNV12
        let new = try offline.render(state: after, pixelBuffers: buffers, size: CGSize(width: 1920, height: 1080)).multiviewNV12
        XCTAssertNotEqual(PixelBuffers.nv12Planes(old).luma, PixelBuffers.nv12Planes(new).luma, "两个名字的多画面应不同")
        let atChange = try XCTUnwrap(engine.sink.kept(changeTick)?.multiview, "第 \(changeTick) 拍应有多画面帧")
        let next = try XCTUnwrap(engine.sink.kept(changeTick + 1)?.multiview, "第 \(changeTick + 1) 拍应有多画面帧")
        let a = PixelBuffers.nv12Planes(atChange.pixelBuffer)
        XCTAssertTrue(a.luma == PixelBuffers.nv12Planes(old).luma || a.luma == PixelBuffers.nv12Planes(new).luma,
                      "第 \(changeTick) 拍应是旧名字或新名字之一（其余画面两者相同）")
        let b = PixelBuffers.nv12Planes(next.pixelBuffer)
        XCTAssertEqual(b.luma, PixelBuffers.nv12Planes(new).luma, "快照改名后的下一帧（第 \(changeTick + 1) 拍）应是新名字")
        XCTAssertEqual(b.chroma, PixelBuffers.nv12Planes(new).chroma)
        XCTAssertEqual(own.count, 0, "改名前后渲染线程上 SwitcherRender 代码不许分配")
        #if !DEBUG
        XCTAssertEqual(swiftOwned.count, 0, "release 下渲染线程上任何 Swift 代码都不该分配")
        #endif
        XCTAssertEqual(engine.skipped.load(ordering: .relaxed), 0)
    }
}

/// 测试里假装"已完成的帧数"。
final class FrameCounter: @unchecked Sendable {
    private let v = Atomic<UInt64>(0)
    var value: UInt64 {
        get { v.load(ordering: .acquiring) }
        set { v.store(newValue, ordering: .releasing) }
    }
}
