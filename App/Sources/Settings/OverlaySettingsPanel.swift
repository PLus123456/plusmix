// 叠加设置独立窗（W5-K，prompt 97 交付 3，01a I1–I3 / 02 X21 / 04 Q40）：原来底栏"叠加…"弹的是 transient 浮层（点主窗口任何地方就关，
// 格子上的 1–4、转场列一碰就没了，边切边调做不到），四个通道上下全列、内容被裁。现在是走 PanelCoordinator 的普通窗口（不挡主窗口、不是 sheet、
// 不是主窗口的子窗口），顶部 Overlay 1–4 分段选通道、只显示当前通道，改一项立即发（即时生效）；"整幅 / 画中画"二选一（整幅时位置 / 锚点 / 边框收起）；
// 时长按秒显示（悬停写拍数）、给 0.5 / 1 / 2 s 快捷值，按节目帧率换成拍（契约里存拍）。入口：底栏"叠加…"、转场列 Overlay k 与格子 k 的右键"叠加设置…"
// （直达第 k 路）、菜单栏"切换 › Overlay ▸ › 叠加设置…"。新节目四通道默认淡入 0.5 s 在 ShowDocuments.emptyShow 里按帧率换拍（I3）。
// 只发命令：overlay（输入 / 开关）、setOverlay（位置 + 动画，含 slideFrom）、setOverlayDecoration（边框 + 锚点 + PVW 预览，三项整体替换）。
// "PVW 预览全部叠加"是渲染器的总开关（偏好设置，换 session 生效），与每通道的 previewOn 取或。
import AppKit
import SwiftUI
import SwitcherContracts

/// 位置预设（画中画）。full 只在"整幅"模式下用。
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

    /// 画中画模式下的位置下拉（整幅单独一个模式）。
    static let pictureInPicture: [OverlayPreset] = [.bottomRight, .bottomLeft, .topRight, .topLeft, .lowerThird, .custom]

    /// 由位置反查预设（没有匹配的算 custom）。
    static func matching(_ rect: NormalizedRect) -> OverlayPreset {
        allCases.first { $0.rect == rect } ?? .custom
    }
}

@MainActor
final class OverlaySettingsModel: ObservableObject {
    /// 整幅 / 画中画（I2）。
    enum Mode: String, CaseIterable, Identifiable {
        case fullscreen, pictureInPicture
        var id: String { rawValue }
        var title: String { L("overlay.mode.\(rawValue)") }
    }

    static let animationKinds: [OverlayAnimationKind] = [.cut, .fade, .slide, .zoom]
    /// 时长的快捷值（秒，I3）。
    static let quickDurations: [Double] = [0.5, 1, 2]
    /// 从整幅切到画中画时放在哪（右下 1/4）。
    static let defaultPictureInPicture = NormalizedRect.bottomRightQuarter
    static let borderWidthRange = 0.0...0.05

    @Published private(set) var state: MixerState
    /// 当前编辑的通道（顶部分段，1–4）。
    @Published var channel: Int {
        didSet { if !(1...MixerState.overlayCount).contains(channel) { channel = min(max(channel, 1), MixerState.overlayCount) } }
    }
    var send: ((Command) -> Void)?

    init(state: MixerState, channel: Int = 1) {
        self.state = state
        self.channel = min(max(channel, 1), MixerState.overlayCount)
    }

    /// 快照来了：只在这扇窗显示的东西变了才换（叠加的设置 / 开关 / 输入、输入表、节目格式）。淡入淡出期间 animProgress 每拍都变，不为它重画。
    func apply(state: MixerState) {
        guard Self.relevant(state) != Self.relevant(self.state) else { return }
        self.state = state
    }

    private static func relevant(_ s: MixerState) -> [AnyHashable] {
        let overlays = s.overlays.map { o -> OverlayState in
            var o = o
            o.animProgress = 0
            o.startTick = nil
            return o
        }
        return [AnyHashable(overlays), AnyHashable(s.inputs.map { [AnyHashable($0.number), AnyHashable($0.name)] }), AnyHashable(s.format)]
    }

    func overlay(_ channel: Int) -> OverlayState { state.overlays[channel - 1] }

    // MARK: 输入 / 开关

    /// input nil = 选了"（无）"：发 `input: 0` 清空这一路（提案 034 ⑤；命令里的 nil 是"不换输入"，原来发 nil 清不掉——Codex N11）。
    func setInput(channel: Int, input: Int?) {
        send?(.overlay(channel: channel, on: overlay(channel).on, input: input ?? MixerState.noInput))
    }

    func setOn(channel: Int, on: Bool) {
        send?(.overlay(channel: channel, on: on, input: nil))
    }

    // MARK: 整幅 / 画中画、位置

    func mode(channel: Int) -> Mode { overlay(channel).rect == .full ? .fullscreen : .pictureInPicture }

    /// 整幅 = 位置 .full；画中画 = 原来不是整幅就不动，是整幅就放右下 1/4。锚点 / 边框留着（整幅时界面上收起）。
    func setMode(channel: Int, _ mode: Mode) {
        guard mode != self.mode(channel: channel) else { return }
        setRect(channel: channel, mode == .fullscreen ? .full : Self.defaultPictureInPicture)
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

    // MARK: 动画（时长按秒显示，契约里存拍）

    /// 节目帧率（拍 / 秒）。
    var framesPerSecond: Double { max(1, state.format.frameRate.approximateFramesPerSecond) }

    /// 秒 → 拍（按节目帧率四舍五入），钳进 0…`DurationLimits.maxTicks`（提案 034：原来填一个 20 位数就在 Int 换算上溢出、App 崩；超上限的命令总线也会拒）。
    func ticks(seconds: Double) -> Int {
        let t = (seconds * framesPerSecond).rounded()
        guard t > 0 else { return 0 }
        return t >= Double(DurationLimits.maxTicks) ? DurationLimits.maxTicks : Int(t)
    }

    func durationSeconds(channel: Int) -> Double { Double(overlay(channel).animation.durationTicks) / framesPerSecond }

    func setDurationSeconds(channel: Int, _ seconds: Double) {
        let o = overlay(channel)
        setAnimation(channel: channel, kind: o.animation.kind, durationTicks: ticks(seconds: seconds))
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

    /// 通道一行状态："显示中 · 输入 2 合成 2" / "没显示 · 还没指定输入"。
    func statusText(channel: Int) -> String {
        let o = overlay(channel)
        let input = o.input.map { n in L("overlay.status.input", n, state.input(n)?.name ?? L("monitor.missingInput", n)) } ?? L("overlay.status.noInput")
        return L(o.on ? "overlay.status.on" : "overlay.status.off", input)
    }
}

struct OverlaySettingsView: View {
    @ObservedObject var model: OverlaySettingsModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("overlay.channelPicker"), selection: $model.channel) {
                ForEach(1...MixerState.overlayCount, id: \.self) { Text(L("overlay.channel", $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Form { channelForm(model.channel) }
                .formStyle(.grouped)
            Divider()
            HStack {
                Text(model.statusText(channel: model.channel)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L("common.close")) { onClose() }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func channelForm(_ channel: Int) -> some View {
        let o = model.overlay(channel)
        let mode = model.mode(channel: channel)
        Section(L("overlay.section.source")) {
            Picker(L("overlay.input"), selection: Binding(get: { o.input ?? 0 }, set: { model.setInput(channel: channel, input: $0 == 0 ? nil : $0) })) {
                Text(L("overlay.noInput")).tag(0)
                ForEach(model.state.inputs) { Text(verbatim: "\($0.number) \($0.name)").tag($0.number) }
            }
            Toggle(L("overlay.on"), isOn: Binding(get: { o.on }, set: { model.setOn(channel: channel, on: $0) }))
            Toggle(L("overlay.previewOn"), isOn: Binding(get: { o.previewOn }, set: { model.setPreviewOn(channel: channel, on: $0) }))
                .help(L("overlay.previewOnHelp"))
        }
        Section(L("overlay.section.layout")) {
            Picker(L("overlay.mode"), selection: Binding(get: { mode }, set: { model.setMode(channel: channel, $0) })) {
                ForEach(OverlaySettingsModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if mode == .pictureInPicture {
                Picker(L("overlay.position"), selection: Binding(get: { OverlayPreset.matching(o.rect) }, set: { model.setPreset(channel: channel, $0) })) {
                    ForEach(OverlayPreset.pictureInPicture) { Text($0.title).tag($0) }
                }
                if OverlayPreset.matching(o.rect) == .custom {
                    HStack {
                        rectField(L("overlay.rect.x"), channel, \.x)
                        rectField(L("overlay.rect.y"), channel, \.y)
                        rectField(L("overlay.rect.width"), channel, \.width)
                        rectField(L("overlay.rect.height"), channel, \.height)
                    }
                }
                Picker(L("overlay.anchor"), selection: Binding(get: { o.anchor }, set: { model.setAnchor(channel: channel, $0) })) {
                    ForEach(OverlayAnchor.allCases, id: \.self) { Text(L("overlay.anchor.\($0.rawValue)")).tag($0) }
                }
                Toggle(L("overlay.border"), isOn: Binding(get: { o.border != nil }, set: { model.setBorderEnabled(channel: channel, on: $0) }))
                if let border = o.border {
                    Slider(value: Binding(get: { border.width }, set: { model.setBorderWidth(channel: channel, $0) }), in: OverlaySettingsModel.borderWidthRange) {
                        Text(L("overlay.borderWidth", border.width * 1080))
                    }
                    ColorPicker(L("overlay.borderColor"), selection: borderColorBinding(channel), supportsOpacity: false)
                }
            }
        }
        Section(L("overlay.section.animation")) {
            Picker(L("overlay.animation"), selection: Binding(get: { o.animation.kind }, set: { model.setAnimation(channel: channel, kind: $0, durationTicks: o.animation.durationTicks) })) {
                ForEach(OverlaySettingsModel.animationKinds, id: \.self) { Text(L("overlay.animation.\($0.rawValue)")).tag($0) }
            }
            HStack {
                TextField(L("overlay.durationSeconds"), value: Binding(get: { model.durationSeconds(channel: channel) }, set: { model.setDurationSeconds(channel: channel, $0) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .help(L("overlay.durationTicks", o.animation.durationTicks))
                ForEach(OverlaySettingsModel.quickDurations, id: \.self) { s in
                    Button(L("overlay.durationQuick", s)) { model.setDurationSeconds(channel: channel, s) }
                }
            }
            if o.animation.kind == .slide {
                Picker(L("overlay.slideFrom"), selection: Binding(get: { o.animation.slideFrom?.rawValue ?? "" }, set: { model.setSlideFrom(channel: channel, OverlayEdge(rawValue: $0)) })) {
                    Text(L("overlay.slideFrom.auto")).tag("")
                    ForEach(OverlayEdge.allCases, id: \.self) { Text(L("overlay.edge.\($0.rawValue)")).tag($0.rawValue) }
                }
            }
        }
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

/// 叠加设置窗：一个（再点入口 = 置前并切到那一路）；换 session 时关（模型绑的是旧 session）。
@MainActor
final class OverlaySettingsWindowController: PanelWindowController {
    let model: OverlaySettingsModel

    init(model: OverlaySettingsModel) {
        self.model = model
        let close = CloseBox()
        super.init(title: L("overlay.windowTitle"), size: NSSize(width: 460, height: 620), autosaveName: "OverlaySettings",
                   content: OverlaySettingsView(model: model, onClose: { close.action?() }), minSize: NSSize(width: 420, height: 440))
        close.action = { [weak self] in self?.close() }
    }

    func apply(state: MixerState) { model.apply(state: state) }

    /// SwiftUI 视图要在 super.init 之前建好，"关闭"按钮的动作之后再接上。
    private final class CloseBox { var action: (() -> Void)? }
}

/// Overlay k 小按钮的右键菜单："叠加设置…"（转场列与格子共用，tag = 通道）。
@MainActor
enum OverlaySettingsMenu {
    static func make(channel: Int, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: L("overlay.channel", channel))
        let item = NSMenuItem(title: L("overlay.settingsMenuItem"), action: action, keyEquivalent: "")
        item.target = target
        item.tag = channel
        menu.addItem(item)
        return menu
    }
}
