// Overlay 1–4（设计方案 §1.1、§5 步骤 3；W3-B 交付 1）：顺序、位置、边框、进出动画（cut / fade / slide / zoom）、PVW 预览、通道独立。
import CoreGraphics
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class OverlayTests: XCTestCase {
    static let size = CGSize(width: TestImages.width, height: TestImages.height)
    nonisolated(unsafe) static let renderer: OfflineRenderer = {
        do { return try OfflineRenderer() } catch { fatalError("建不出离线渲染器：\(error)") }
    }()
    static let inputs = TestImages.phase2ReferenceInputs()

    func render(_ state: MixerState, target: OfflineRenderTarget = .program, overlaysInPreview: Bool = false) throws -> Bitmap {
        Self.renderer.overlaysInPreview = overlaysInPreview
        defer { Self.renderer.overlaysInPreview = false }
        return Bitmap(try Self.renderer.renderOffline(state: state, inputs: Self.inputs, size: Self.size, target: target))
    }

    /// 叠加顺序：两个画中画重叠，Overlay 3（输入 8）盖住 Overlay 1（输入 7）；只开 1 时重叠处是 7。
    func testV8_overlayOrder_channel1BelowChannel3WhenOverlapping() throws {
        let s = ReferenceStates.overlayOrder()
        let both = try render(s)
        // 重叠区 (0.5–0.7, 0.5–0.7) 里取 (0.55, 0.55)：在输入 8 的画中画 (0.5,0.5,0.4,0.4) 内相对位置 (0.125, 0.125) → 输入 8 的外圈（黄）
        let p = both.pixel(Int(0.55 * 1920), Int(0.55 * 1080))
        XCTAssertTrue(p.r > 200 && p.g > 170 && p.b < 60, "重叠处应是输入 8 的黄，得 \(p)")
        var only1 = s
        only1.overlays[2].on = false
        only1.overlays[2].animProgress = 0
        let q = try render(only1).pixel(Int(0.55 * 1920), Int(0.55 * 1080))
        // 输入 7 的画中画 (0.3,0.3,0.4,0.4) 内相对位置 (0.625, 0.625) → 输入 7 的中心块（深红）
        XCTAssertTrue(q.r > 100 && q.g < 40 && q.b < 40, "只开 1 时应是输入 7 的深红中心块，得 \(q)")
        // 关掉 1，只剩 3：非重叠的 1 的区域 (0.35, 0.35) 回到 PGM 底（输入 1 渐变灰）
        var only3 = s
        only3.overlays[0].on = false
        only3.overlays[0].animProgress = 0
        let r = try render(only3).pixel(Int(0.35 * 1920), Int(0.35 * 1080))
        XCTAssertLessThan(abs(r.r - r.g) + abs(r.g - r.b), 6, "关掉 1 后其区域应是 PGM 底")
    }

    /// 画中画位置跟 rect 走：四个不同位置，画中画中心处是输入 4 的中心格（棋盘 (4,4) 位置的黄亮格 / 暗格），rect 外是底。
    func testV8_pipPositionFollowsRect() throws {
        let rects = [NormalizedRect(x: 0.05, y: 0.05, width: 0.25, height: 0.25), NormalizedRect(x: 0.7, y: 0.05, width: 0.25, height: 0.25),
                     NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), NormalizedRect(x: 0.6, y: 0.65, width: 0.35, height: 0.3)]
        for r in rects {
            var s = ReferenceStates.fixed8()
            s.overlays[0] = OverlayState()
            s.overlays[2] = OverlayState(input: 4, on: true, rect: r, animProgress: 1)
            let bm = try render(s)
            // rect 内接 16:9 fit：rect 的宽高比不一定 16:9，内容居中 fit；取 rect 中心偏右下一点（棋盘右下象限 = 黄系）
            let cx = Int((r.x + r.width * 0.6) * 1920), cy = Int((r.y + r.height * 0.6) * 1080)
            let p = bm.pixel(cx, cy)
            XCTAssertTrue((p.r > 180 && p.g > 180 && p.b < 100) || (p.r < 90 && p.g < 90 && p.b < 40), "\(r)：画中画右下象限应是黄 / 暗黄棋盘，得 \(p)")
            // rect 外 20 px 是底（灰渐变）
            let ox = max(2, Int(r.x * 1920) - 20), oy = Int((r.y + r.height / 2) * 1080)
            let o = bm.pixel(ox, oy)
            XCTAssertLessThan(abs(o.r - o.g) + abs(o.g - o.b), 6, "\(r)：rect 外应是 PGM 底，得 \(o)")
        }
    }

    /// 画中画边框：效果格 "border"（提案 010 过渡做法）→ rect 外扩一圈白；没有效果格就没有边框。
    func testV8_pipBorderDrawnFromEffectSlot() throws {
        let s = ReferenceStates.pipBorder()
        let bm = try render(s)
        // rect (0.05, 0.05, 0.3, 0.3) → x 96–672、y 54–378；边框 0.006 × 1080 = 6.48 px
        let onBorder = bm.pixel(93, 216)
        XCTAssertTrue(onBorder.r > 240 && onBorder.g > 240 && onBorder.b > 240, "rect 左边外 3 px 应是白边，得 \(onBorder)")
        let above = bm.pixel(300, 51)
        XCTAssertTrue(above.r > 240 && above.g > 240 && above.b > 240, "rect 上边外 3 px 应是白边，得 \(above)")
        let outside = bm.pixel(84, 216)
        XCTAssertFalse(outside.r > 240 && outside.g > 240 && outside.b > 240, "边框外 12 px 应是底，得 \(outside)")
        var noBorder = s
        noBorder.inputs[3].settings.effects = []
        let q = try render(noBorder).pixel(93, 216)
        XCTAssertFalse(q.r > 240 && q.g > 240 && q.b > 240, "没有效果格不该有边框，得 \(q)")
        // 彩色边框 + 自定义宽度
        var red = s
        red.inputs[3].settings.effects = [ReferenceStates.borderEffect(width: 0.02, color: (255, 0, 0))]
        let rr = try render(red).pixel(80, 216)   // 0.02 × 1080 = 21.6 px
        XCTAssertTrue(rr.r > 240 && rr.g < 20 && rr.b < 20, "红边 0.02，得 \(rr)")
        // 解析：宽度钳到 0–0.1，颜色缺省白
        let d = OverlayDecoration.border(for: red.inputs[3])
        XCTAssertEqual(d?.width, 0.02)
        XCTAssertEqual(OverlayDecoration.border(for: InputConfig(number: 1, name: "", source: .image(path: ""), settings: InputSettings(effects: [EffectSlot(id: "border", params: ["width": 5])])))?.width, 0.1)
        XCTAssertNil(OverlayDecoration.border(for: InputConfig(number: 1, name: "", source: .image(path: ""), settings: InputSettings(effects: [EffectSlot(id: "border", enabled: false)]))))
    }

    /// 进出动画的几何（纯函数）：cut / fade / slide / zoom 对 animProgress 的解释。
    func testOverlay_animationPlacementRules() {
        let pip = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        // cut：p > 0 就完整显示
        var o = OverlayState(input: 4, on: true, rect: pip, animProgress: 0.3, animation: OverlayAnimation(kind: .cut, durationTicks: 0))
        var p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.opacity, 1)
        XCTAssertEqual(p.rect, pip)
        // fade：不透明度 = p，位置不变
        o.animation = OverlayAnimation(kind: .fade, durationTicks: 10)
        p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.opacity, 0.3, accuracy: 1e-6)
        XCTAssertEqual(p.rect, pip)
        // slide：离最近的边（右下 1/4：右、下并列 → 底边），p = 0.5 时 y 从 0.5 挪到 0.75；p = 0 完全出画；p = 1 到位
        o.animation = OverlayAnimation(kind: .slide, durationTicks: 10)
        o.animProgress = 0.5
        p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.opacity, 1)
        XCTAssertEqual(p.rect.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.rect.y, 0.75, accuracy: 1e-9)
        XCTAssertEqual(p.rect.width, 0.5)
        o.animProgress = 0
        XCTAssertGreaterThanOrEqual(OverlayRenderer.placement(o).rect.y, 1, "p = 0 应完全在画外")
        o.animProgress = 1
        XCTAssertEqual(OverlayRenderer.placement(o).rect, pip)
        // slide 方向：左上角的从左边进；顶部条从上边进；整幅从底边进
        XCTAssertEqual(OverlayRenderer.slideEdge(for: NormalizedRect(x: 0.02, y: 0.3, width: 0.3, height: 0.3)), .left)
        XCTAssertEqual(OverlayRenderer.slideEdge(for: NormalizedRect(x: 0.3, y: 0.02, width: 0.4, height: 0.2)), .top)
        XCTAssertEqual(OverlayRenderer.slideEdge(for: NormalizedRect(x: 0.65, y: 0.3, width: 0.3, height: 0.3)), .right)
        XCTAssertEqual(OverlayRenderer.slideEdge(for: .full), .bottom)
        let left = OverlayRenderer.placement(OverlayState(input: 4, on: true, rect: NormalizedRect(x: 0.02, y: 0.3, width: 0.3, height: 0.3), animProgress: 0.5, animation: OverlayAnimation(kind: .slide, durationTicks: 10)))
        XCTAssertEqual(left.rect.x, 0.02 - 0.5 * 0.32, accuracy: 1e-9)
        XCTAssertEqual(left.rect.y, 0.3)
        // zoom：绕 rect 中心缩放，尺寸 = p × 原尺寸
        o.animation = OverlayAnimation(kind: .zoom, durationTicks: 10)
        o.animProgress = 0.5
        p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.opacity, 1)
        XCTAssertEqual(p.rect.x, 0.625, accuracy: 1e-9)
        XCTAssertEqual(p.rect.y, 0.625, accuracy: 1e-9)
        XCTAssertEqual(p.rect.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.rect.height, 0.25, accuracy: 1e-9)
        // p = 0：任何动画都不可见
        for kind in [OverlayAnimationKind.cut, .fade, .slide, .zoom] {
            var z = o
            z.animation.kind = kind
            z.animProgress = 0
            XCTAssertFalse(OverlayRenderer.isDrawable(z), "\(kind) p = 0 不该画")
        }
    }

    /// 滑入 50%（画中画从底边上来一半）：rect 变成 (0.5, 0.75, 0.5, 0.5)，只剩上半可见；缩放 50%：居中 1/4 大小。渲染结果与几何一致。
    func testV8_slideAndZoomAnimationsRender() throws {
        var slide = ReferenceStates.fixed8()
        slide.overlays[0] = OverlayState()
        slide.overlays[2] = OverlayState(input: 4, on: true, rect: .bottomRightQuarter, animProgress: 0.5, animation: OverlayAnimation(kind: .slide, durationTicks: 20), startTick: Tick(0))
        let sb = try render(slide)
        // 画中画现在占 y 810–1080、x 960–1920，显示的是输入 4 的上半（红 / 绿象限）
        let inside = sb.pixel(1200, 900)
        XCTAssertTrue(inside.r > inside.g && inside.r > inside.b, "滑到一半的画中画上半应是输入 4 的红象限，得 \(inside)")
        let vacated = sb.pixel(1200, 700)
        XCTAssertLessThan(abs(vacated.r - vacated.g) + abs(vacated.g - vacated.b), 6, "原 rect 的上半应露出 PGM 底，得 \(vacated)")
        var zoom = ReferenceStates.fixed8()
        zoom.overlays[0] = OverlayState()
        zoom.overlays[2] = OverlayState(input: 4, on: true, rect: .bottomRightQuarter, animProgress: 0.5, animation: OverlayAnimation(kind: .zoom, durationTicks: 20), startTick: Tick(0))
        let zb = try render(zoom)
        // 缩到 (0.625, 0.625, 0.25, 0.25) → x 1200–1680、y 675–945；中心 (1440, 810) 是输入 4 的中心附近
        let center = zb.pixel(1440, 810)
        XCTAssertGreaterThan(center.r + center.g + center.b, 60, "缩放后的画中画中心应有内容，得 \(center)")
        let outsideZoom = zb.pixel(1000, 600)
        XCTAssertLessThan(abs(outsideZoom.r - outsideZoom.g) + abs(outsideZoom.g - outsideZoom.b), 6, "缩放后原 rect 左上角应露出底，得 \(outsideZoom)")
        // 淡入 50%：像素 = 0.5 × 输入 + 0.5 × 底
        var fade = ReferenceStates.fixed8()
        fade.overlays[0] = OverlayState()
        fade.overlays[2] = OverlayState(input: 4, on: true, rect: .bottomRightQuarter, animProgress: 0.5, animation: OverlayAnimation(kind: .fade, durationTicks: 20), startTick: Tick(0))
        let full = try render(ReferenceStates.fixed8().with { $0.overlays[0] = OverlayState() })
        let half = try render(fade)
        let base = try render(ReferenceStates.fixed8().with { $0.overlays = Array(repeating: OverlayState(), count: 4) })
        let x = 1680, y = 945
        let f = full.pixel(x, y), h = half.pixel(x, y), b = base.pixel(x, y)
        XCTAssertEqual(Double(h.r), (Double(f.r) + Double(b.r)) / 2, accuracy: 2)
        XCTAssertEqual(Double(h.g), (Double(f.g) + Double(b.g)) / 2, accuracy: 2)
        XCTAssertEqual(Double(h.b), (Double(f.b) + Double(b.b)) / 2, accuracy: 2)
    }

    /// PVW 预览叠加：overlaysInPreview 关时 PVW 是纯输入 2；开时 PVW 叠着与 PGM 同一套叠加（画中画右下、下三分之一）。
    func testOverlay_previewShowsOverlaysWhenOptionOn() throws {
        let s = ReferenceStates.fixed8()
        let plain = try render(s, target: .preview)
        let withOverlays = try render(s, target: .preview, overlaysInPreview: true)
        // 右下 1/4 中心：关 = 输入 2 的灰阶（灰），开 = 画中画的棋盘（黄系）
        let p0 = plain.pixel(1680, 945), p1 = withOverlays.pixel(1680, 945)
        XCTAssertLessThan(abs(p0.r - p0.g) + abs(p0.g - p0.b), 6, "关闭时 PVW 右下是输入 2 的灰阶，得 \(p0)")
        XCTAssertTrue((p1.r > 180 && p1.g > 180 && p1.b < 100) || (p1.r < 90 && p1.g < 90 && p1.b < 40), "开启时 PVW 右下应是画中画，得 \(p1)")
        // PGM 不受该选项影响
        XCTAssertEqual(try render(s).bgra, try render(s, overlaysInPreview: true).bgra)
    }

    // MARK: P3（提案 010 落地：正式字段 / previewOn / slideFrom / anchor）

    /// 正式字段 `OverlayState.border` 与过渡做法 `effects["border"]` 给同一个边框时逐像素相同；正式字段优先。
    func testP3_borderOfficialFieldMatchesEffectSlotPixelForPixel() throws {
        let legacy = ReferenceStates.pipBorder()                       // 输入 4 的效果格，白边 0.006
        var official = legacy
        official.inputs[3].settings.effects = []
        official.overlays[2].border = OverlayBorder()                  // 同样的默认白边 0.006
        XCTAssertEqual(try render(official).bgra, try render(legacy).bgra, "正式字段与过渡字段的边框应逐像素相同")

        // 彩色 + 自定义宽度也相同
        var legacyRed = legacy
        legacyRed.inputs[3].settings.effects = [ReferenceStates.borderEffect(width: 0.02, color: (255, 0, 0))]
        var officialRed = official
        officialRed.overlays[2].border = OverlayBorder(width: 0.02, color: RGB8(red: 255, green: 0, blue: 0))
        XCTAssertEqual(try render(officialRed).bgra, try render(legacyRed).bgra)

        // 正式字段优先：两边都给、值不同 → 按正式字段画
        var both = legacy
        both.overlays[2].border = OverlayBorder(width: 0.02, color: RGB8(red: 255, green: 0, blue: 0))
        XCTAssertEqual(try render(both).bgra, try render(officialRed).bgra, "正式字段优先于效果格")

        // 解析层：border == nil 时回落到效果格，都没有就是 nil
        XCTAssertEqual(OverlayDecoration.border(for: official.overlays[2], config: official.inputs[3])?.width, 0.006)
        XCTAssertEqual(OverlayDecoration.border(for: legacy.overlays[2], config: legacy.inputs[3])?.width, 0.006)
        var none = official
        none.overlays[2].border = nil
        XCTAssertNil(OverlayDecoration.border(for: none.overlays[2], config: none.inputs[3]))
        // 宽度钳到 0–0.1
        XCTAssertEqual(OverlayDecoration.resolve(OverlayBorder(width: 5)).width, 0.1)
        XCTAssertEqual(OverlayDecoration.resolve(OverlayBorder(width: -1)).width, 0)
    }

    /// `previewOn` 只开一路时 PVW 只出现那一路；总开关 `overlaysInPreview` 与它取或；PGM 不受影响。
    func testP3_previewOnShowsOnlyThatChannel() throws {
        var s = ReferenceStates.fixed8()
        s.overlays = Array(repeating: OverlayState(), count: 4)
        let left = NormalizedRect(x: 0.02, y: 0.02, width: 0.3, height: 0.3)
        let right = NormalizedRect(x: 0.68, y: 0.68, width: 0.3, height: 0.3)
        s.overlays[0] = OverlayState(input: 7, on: true, rect: left, animProgress: 1)    // 输入 7 外圈青
        s.overlays[2] = OverlayState(input: 8, on: true, rect: right, animProgress: 1)   // 输入 8 外圈黄
        func edge(_ bm: Bitmap, _ r: NormalizedRect) -> (r: Int, g: Int, b: Int, a: Int) {
            bm.pixel(Int((r.x + r.width * 0.1) * 1920), Int((r.y + r.height * 0.5) * 1080))
        }
        func isCyan(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Bool { c.g > 150 && c.b > 170 && c.r < 40 }
        func isYellow(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Bool { c.r > 180 && c.g > 150 && c.b < 60 }

        // 一路都没开 previewOn：PVW 是纯输入（v8-preview-pvw.png 的口径）
        let none = try render(s, target: .preview)
        XCTAssertFalse(isCyan(edge(none, left)))
        XCTAssertFalse(isYellow(edge(none, right)))

        // 只开通道 1 的 previewOn：PVW 只有它
        var only1 = s
        only1.overlays[0].previewOn = true
        let bm1 = try render(only1, target: .preview)
        XCTAssertTrue(isCyan(edge(bm1, left)), "通道 1 开了 previewOn，PVW 应有它，得 \(edge(bm1, left))")
        XCTAssertFalse(isYellow(edge(bm1, right)), "通道 3 没开，PVW 不该有它，得 \(edge(bm1, right))")

        // 只开通道 3
        var only3 = s
        only3.overlays[2].previewOn = true
        let bm3 = try render(only3, target: .preview)
        XCTAssertFalse(isCyan(edge(bm3, left)))
        XCTAssertTrue(isYellow(edge(bm3, right)))

        // 总开关：两路都画，与"两路都开 previewOn"逐像素相同
        var both = s
        both.overlays[0].previewOn = true
        both.overlays[2].previewOn = true
        XCTAssertEqual(try render(s, target: .preview, overlaysInPreview: true).bgra, try render(both, target: .preview).bgra)

        // PGM 不受 previewOn 影响
        XCTAssertEqual(try render(only1).bgra, try render(s).bgra)
    }

    /// `slideFrom` 四条边各一帧：半程时画中画从指定的那条边平移进来（不给就是离 rect 最近的边）。
    func testP3_slideFromEachEdge() throws {
        let pip = NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        var base = ReferenceStates.fixed8()
        base.overlays = Array(repeating: OverlayState(), count: 4)
        base.overlays[0] = OverlayState(input: 7, on: true, rect: pip, animProgress: 0.5,
                                        animation: OverlayAnimation(kind: .slide, durationTicks: 20))
        // 纯函数：四条边的位置
        let expected: [(OverlayEdge, (Double, Double))] = [
            (.left, (pip.x - 0.5 * (pip.x + pip.width), pip.y)),
            (.right, (pip.x + 0.5 * (1 - pip.x), pip.y)),
            (.top, (pip.x, pip.y - 0.5 * (pip.y + pip.height))),
            (.bottom, (pip.x, pip.y + 0.5 * (1 - pip.y))),
        ]
        for (edge, want) in expected {
            var s = base
            s.overlays[0].animation.slideFrom = edge
            let p = OverlayRenderer.placement(s.overlays[0])
            XCTAssertEqual(p.rect.x, want.0, accuracy: 1e-9, "slideFrom \(edge) 的 x")
            XCTAssertEqual(p.rect.y, want.1, accuracy: 1e-9, "slideFrom \(edge) 的 y")
            XCTAssertEqual(p.rect.width, pip.width, "平移不改尺寸")
            XCTAssertEqual(p.rect.height, pip.height)
            XCTAssertEqual(p.opacity, 1)
            // 真画一帧：画中画在指定方向那一侧
            let bm = try render(s)
            let cx = Int((p.rect.x + p.rect.width / 2) * 1920), cy = Int((p.rect.y + p.rect.height / 2) * 1080)
            if cx > 4, cx < 1916, cy > 4, cy < 1076 {
                let c = bm.pixel(cx, cy)
                XCTAssertNotEqual(abs(c.r - c.g) + abs(c.g - c.b), 0, "移到的位置上应有画中画（不是纯灰底），得 \(c)")
            }
        }
        // 不给 slideFrom：与"最近的边"一致（这个 rect 四边等距，按底 > 顶 > 左 > 右 的优先级取底）
        XCTAssertNil(base.overlays[0].animation.slideFrom)
        XCTAssertEqual(OverlayRenderer.placement(base.overlays[0]).rect.y, pip.y + 0.5 * (1 - pip.y), accuracy: 1e-9)
    }

    /// `anchor`：缩放动画绕锚点缩（默认 center 与 P3 之前逐字相同）。
    func testP3_zoomAnchor() throws {
        let pip = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)
        var o = OverlayState(input: 7, on: true, rect: pip, animProgress: 0.5, animation: OverlayAnimation(kind: .zoom, durationTicks: 20))
        // center（默认）：四周各缩一半
        var p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.rect.x, pip.x + pip.width * 0.5 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.rect.y, pip.y + pip.height * 0.5 * 0.5, accuracy: 1e-9)
        // topLeft：左上角不动
        o.anchor = .topLeft
        p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.rect.x, pip.x, accuracy: 1e-9)
        XCTAssertEqual(p.rect.y, pip.y, accuracy: 1e-9)
        // bottomRight：右下角不动
        o.anchor = .bottomRight
        p = OverlayRenderer.placement(o)
        XCTAssertEqual(p.rect.x + p.rect.width, pip.x + pip.width, accuracy: 1e-9)
        XCTAssertEqual(p.rect.y + p.rect.height, pip.y + pip.height, accuracy: 1e-9)
        // 缩到 1 时锚点无关
        o.animProgress = 1
        for a in OverlayAnchor.allCases {
            o.anchor = a
            XCTAssertEqual(OverlayRenderer.placement(o).rect, pip, "progress = 1 时 \(a) 都是原 rect")
        }
    }

    /// 每通道独立：四个通道各放一路，逐个关掉只影响自己。
    func testOverlay_channelsAreIndependent() throws {
        var s = ReferenceStates.fixed8()
        s.overlays = Array(repeating: OverlayState(), count: 4)
        let rects = [NormalizedRect(x: 0.02, y: 0.02, width: 0.3, height: 0.3), NormalizedRect(x: 0.68, y: 0.02, width: 0.3, height: 0.3),
                     NormalizedRect(x: 0.02, y: 0.68, width: 0.3, height: 0.3), NormalizedRect(x: 0.68, y: 0.68, width: 0.3, height: 0.3)]
        let sources = [7, 8, 7, 8]
        for i in 0..<4 { s.overlays[i] = OverlayState(input: sources[i], on: true, rect: rects[i], animProgress: 1) }
        func centerColor(_ bm: Bitmap, _ r: NormalizedRect) -> (r: Int, g: Int, b: Int, a: Int) {
            bm.pixel(Int((r.x + r.width * 0.1) * 1920), Int((r.y + r.height * 0.5) * 1080))   // 左侧边带 = 外圈纯色
        }
        let all = try render(s)
        for i in 0..<4 {
            let c = centerColor(all, rects[i])
            if sources[i] == 7 { XCTAssertTrue(c.g > 150 && c.b > 170 && c.r < 40, "通道 \(i + 1) 应是青，得 \(c)") }
            else { XCTAssertTrue(c.r > 200 && c.g > 170 && c.b < 60, "通道 \(i + 1) 应是黄，得 \(c)") }
        }
        for off in 0..<4 {
            var t = s
            t.overlays[off].on = false
            t.overlays[off].animProgress = 0
            let bm = try render(t)
            for i in 0..<4 {
                let c = centerColor(bm, rects[i])
                if i == off {
                    XCTAssertLessThan(abs(c.r - c.g) + abs(c.g - c.b), 6, "关掉通道 \(off + 1) 后其区域应是底，得 \(c)")
                } else {
                    XCTAssertGreaterThan(abs(c.r - c.g) + abs(c.g - c.b), 60, "关掉通道 \(off + 1) 不该影响通道 \(i + 1)，得 \(c)")
                }
            }
        }
    }
}

extension MixerState {
    /// 测试用：改一份。
    func with(_ edit: (inout MixerState) -> Void) -> MixerState {
        var s = self
        edit(&s)
        return s
    }
}
