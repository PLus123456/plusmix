// 叠加面板（W3-E 交付第 5 条；底栏"叠加…"弹出）：Overlay 1–4 各选一路输入、开关、位置预设（整幅 / 四角画中画 / 下三分之一 / 自定义）、
// 进出动画（切入 / 淡入 / 滑入 / 缩放 + 时长，滑入可选从哪条边）；W3-E2 加提案 010 的正式字段：PVW 预览（每通道）、边框（开 / 宽 / 色）、锚点（九宫）。
// 只发命令：overlay（输入 / 开关）、setOverlay（位置 + 动画，含 slideFrom）、setOverlayDecoration（边框 + 锚点 + PVW 预览，三项整体替换）。
// "PVW 预览全部叠加"是渲染器的总开关（偏好设置，换 session 生效），与每通道的 previewOn 取或。
import AppKit
import SwiftUI
import SwitcherContracts

/// 位置预设。
enum OverlayPreset: String, CaseIterable, Identifiable {
    case full, topLeft, topRight, bottomLeft, bottomRight, lowerThird, custom
    var id: String { rawValue }
    var title: String { L("overlay.preset.\(rawValue)") }

    /// 预设对应的位置；custom 为 nil。
    var rect: NormalizedRect? {
        switch self {
        case .full: .full
        case .topLeft: NormalizedRect(x: 0.03, y: 0.03, width: 0.3, height: 0.3)
        case .topRight: NormalizedRect(x: 0.67, y: 0.03, width: 0.3, height: 0.3)
        case .bottomLeft: NormalizedRect(x: 0.03, y: 0.67, width: 0.3, height: 0.3)
        case .bottomRight: .bottomRightQuarter
        case .lowerThird: NormalizedRect(x: 0, y: 0.75, width: 1, height: 0.25)
        case .custom: nil
        }
    }

    /// 由位置反查预设（没有匹配的算 custom）。
    static func matching(_ rect: NormalizedRect) -> OverlayPreset {
        allCases.first { $0.rect == rect } ?? .custom
    }
}

@MainActor
final class OverlayPanelModel: ObservableObject {
    @Published private(set) var state: MixerState
    var send: ((Command) -> Void)?
    static let animationKinds: [OverlayAnimationKind] = [.cut, .fade, .slide, .zoom]

    init(state: MixerState) { self.state = state }

    func apply(state: MixerState) { self.state = state }

    func overlay(_ channel: Int) -> OverlayState { state.overlays[channel - 1] }

    func setInput(channel: Int, input: Int?) {
        send?(.overlay(channel: channel, on: overlay(channel).on, input: input))
    }

    func setOn(channel: Int, on: Bool) {
        send?(.overlay(channel: channel, on: on, input: nil))
    }

    func setPreset(channel: Int, _ preset: OverlayPreset) {
        guard let rect = preset.rect else { return }
        setRect(channel: channel, rect)
    }

    func setRect(channel: Int, _ rect: NormalizedRect) {
        var o = overlay(channel)
        o.rect = rect
        state.overlays[channel - 1] = o
        send?(.setOverlay(channel: channel, rect: rect, animation: o.animation))
    }

    /// 动画方式 / 时长（slideFrom 保留：换回滑入时还是原来那条边）。
    func setAnimation(channel: Int, kind: OverlayAnimationKind, durationTicks: Int) {
        var o = overlay(channel)
        o.animation.kind = kind
        o.animation.durationTicks = max(0, durationTicks)
        state.overlays[channel - 1] = o
        send?(.setOverlay(channel: channel, rect: o.rect, animation: o.animation))
    }

    /// 滑入从哪条边；nil = 自动（离 rect 最近的边）。
    func setSlideFrom(channel: Int, _ edge: OverlayEdge?) {
        var o = overlay(channel)
        guard o.animation.slideFrom != edge else { return }
        o.animation.slideFrom = edge
        state.overlays[channel - 1] = o
        send?(.setOverlay(channel: channel, rect: o.rect, animation: o.animation))
    }

    // MARK: 装饰（提案 010：setOverlayDecoration 三项整体替换，本地先改再发）

    static let borderWidthRange = 0.0...0.05

    func setPreviewOn(channel: Int, on: Bool) { decorate(channel) { $0.previewOn = on } }
    func setAnchor(channel: Int, _ anchor: OverlayAnchor) { decorate(channel) { $0.anchor = anchor } }
    func setBorderEnabled(channel: Int, on: Bool) { decorate(channel) { $0.border = on ? ($0.border ?? OverlayBorder()) : nil } }
    func setBorderWidth(channel: Int, _ width: Double) {
        decorate(channel) { o in
            var b = o.border ?? OverlayBorder()
            b.width = min(max(width, Self.borderWidthRange.lowerBound), Self.borderWidthRange.upperBound)
            o.border = b
        }
    }
    func setBorderColor(channel: Int, _ color: RGB8) {
        decorate(channel) { o in
            var b = o.border ?? OverlayBorder()
            b.color = color
            o.border = b
        }
    }

    private func decorate(_ channel: Int, _ body: (inout OverlayState) -> Void) {
        guard channel >= 1, channel <= MixerState.overlayCount else { return }
        var o = overlay(channel)
        body(&o)
        guard o != overlay(channel) else { return }
        state.overlays[channel - 1] = o
        send?(.setOverlayDecoration(channel: channel, border: o.border, anchor: o.anchor, previewOn: o.previewOn))
    }
}

struct OverlayPanelView: View {
    @ObservedObject var model: OverlayPanelModel

    var body: some View {
        Form {
            ForEach(1...MixerState.overlayCount, id: \.self) { channel in
                let o = model.overlay(channel)
                Section(L("overlay.channel", channel)) {
                    Picker(L("overlay.input"), selection: Binding(get: { o.input ?? 0 }, set: { model.setInput(channel: channel, input: $0 == 0 ? nil : $0) })) {
                        Text(L("overlay.noInput")).tag(0)
                        ForEach(model.state.inputs) { Text("\($0.number) \($0.name)").tag($0.number) }
                    }
                    Toggle(L("overlay.on"), isOn: Binding(get: { o.on }, set: { model.setOn(channel: channel, on: $0) }))
                    Picker(L("overlay.position"), selection: Binding(get: { OverlayPreset.matching(o.rect) }, set: { model.setPreset(channel: channel, $0) })) {
                        ForEach(OverlayPreset.allCases) { Text($0.title).tag($0) }
                    }
                    if OverlayPreset.matching(o.rect) == .custom {
                        HStack {
                            rectField(L("overlay.rect.x"), channel, \.x)
                            rectField(L("overlay.rect.y"), channel, \.y)
                            rectField(L("overlay.rect.width"), channel, \.width)
                            rectField(L("overlay.rect.height"), channel, \.height)
                        }
                    }
                    Picker(L("overlay.animation"), selection: Binding(get: { o.animation.kind }, set: { model.setAnimation(channel: channel, kind: $0, durationTicks: o.animation.durationTicks) })) {
                        ForEach(OverlayPanelModel.animationKinds, id: \.self) { Text(L("overlay.animation.\($0.rawValue)")).tag($0) }
                    }
                    Stepper(value: Binding(get: { o.animation.durationTicks }, set: { model.setAnimation(channel: channel, kind: o.animation.kind, durationTicks: $0) }), in: 0...600, step: 5) {
                        Text(L("overlay.duration", o.animation.durationTicks))
                    }
                    if o.animation.kind == .slide {
                        Picker(L("overlay.slideFrom"), selection: Binding(get: { o.animation.slideFrom?.rawValue ?? "" }, set: { model.setSlideFrom(channel: channel, OverlayEdge(rawValue: $0)) })) {
                            Text(L("overlay.slideFrom.auto")).tag("")
                            ForEach(OverlayEdge.allCases, id: \.self) { Text(L("overlay.edge.\($0.rawValue)")).tag($0.rawValue) }
                        }
                    }
                    Picker(L("overlay.anchor"), selection: Binding(get: { o.anchor }, set: { model.setAnchor(channel: channel, $0) })) {
                        ForEach(OverlayAnchor.allCases, id: \.self) { Text(L("overlay.anchor.\($0.rawValue)")).tag($0) }
                    }
                    Toggle(L("overlay.previewOn"), isOn: Binding(get: { o.previewOn }, set: { model.setPreviewOn(channel: channel, on: $0) }))
                        .help(L("overlay.previewOnHelp"))
                    Toggle(L("overlay.border"), isOn: Binding(get: { o.border != nil }, set: { model.setBorderEnabled(channel: channel, on: $0) }))
                    if let border = o.border {
                        Slider(value: Binding(get: { border.width }, set: { model.setBorderWidth(channel: channel, $0) }), in: OverlayPanelModel.borderWidthRange) {
                            Text(L("overlay.borderWidth", border.width * 1080))
                        }
                        ColorPicker(L("overlay.borderColor"), selection: borderColorBinding(channel), supportsOpacity: false)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 640)
    }

    private func borderColorBinding(_ channel: Int) -> Binding<Color> {
        Binding(get: {
            let c = model.overlay(channel).border?.color ?? RGB8(red: 255, green: 255, blue: 255)
            return Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            model.setBorderColor(channel: channel, RGB8(red: byte(ns.redComponent), green: byte(ns.greenComponent), blue: byte(ns.blueComponent)))
        })
    }

    private func rectField(_ label: String, _ channel: Int, _ keyPath: WritableKeyPath<NormalizedRect, Double>) -> some View {
        TextField(label, value: Binding(get: { model.overlay(channel).rect[keyPath: keyPath] }, set: { v in
            var r = model.overlay(channel).rect
            r[keyPath: keyPath] = min(max(v, 0), 1)
            model.setRect(channel: channel, r)
        }), format: .number.precision(.fractionLength(2)))
        .frame(width: 70)
    }
}

/// 弹出面板的控制器（NSPopover 用）。
@MainActor
final class OverlayPanelController: NSViewController {
    let model: OverlayPanelModel
    var send: ((Command) -> Void)? {
        didSet { model.send = send }
    }

    init(state: MixerState) {
        model = OverlayPanelModel(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: OverlayPanelView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        view = host
    }

    func apply(state: MixerState) { model.apply(state: state) }
}
