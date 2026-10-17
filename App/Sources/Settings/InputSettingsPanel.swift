// 输入设置窗（W3-E 交付第 2 条）：裁切 / 变换、延迟补偿（0–500 ms）、音频路由（四总线）、增益 / 静音 / 独听 / 声像、抠像参数、
// 效果链（W5-B 起叫"音频效果"，引擎还不读它：页顶横幅写"效果尚未作用到声音"）、来源。模型只发 setInputSettings / renameInput / setInputSource，快照回来再刷新表单。
// W3-E2：来源一节可编辑（提案 012 的 setInputSource：编号 / 名字 / 设置 / PGM / PVW / 叠加引用全保留，运行表按新来源重建这一路），
// 表单复用 Add Input 的 InputSourceFormView；摘要显示 DeckLink 接口、NDI 带宽 / 抖动缓冲（提案 008）与声道映射（提案 014）。
// W5-K（prompt 97 交付 2，01a H1 / H3–H9，02 X55）：
// - 分节按现场使用频率排：基本 → 抠像 → 裁切与位置 → 音频 → 音频效果 → 来源（以后的色彩 / 视频效果 / 图层 / 触发 / tally / 云台 / 高级按这个顺序往里插）；
// - 右栏下方嵌本路实时画面（多画面纹理裁这一格，Q55），标题行写这一路的 tally（在 PGM / 在 PVW）；抠像"在画面上取色"（3×3 平均）；
// - 滑杆旁有能输入的数值框和单项复位，每组有整组复位，抠像"恢复默认"，位置"复制位置 / 粘贴位置"（App 内剪贴板）；侧栏底部"从其他输入复制…"；
// - 名字失焦即改名（去掉"应用名字"按钮）；"延迟补偿"改叫"音频延迟补偿"；音频一节加"跟随视频（AFV）"开关（绑 InputAudioSettings.afv，X55）。
// 这个窗口在前时，没被文本框吃掉的按键照样走快捷键表（PanelCoordinator 给 PanelWindow 挂 keyHandler，X12）。
import AppKit
import Combine
import SwiftUI
import SwitcherContracts
import SwitcherRender

/// "复制位置 / 粘贴位置"的 App 内剪贴板（裁切 + 变换；不进系统剪贴板）。
@MainActor
enum InputSettingsClipboard {
    static var position: (crop: CropInsets, transform: Transform2D)?
}

@MainActor
final class InputSettingsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case general, keyer, geometry, audio, effects, source
        var id: String { rawValue }
        var title: String { L("inputSettings.section.\(rawValue)") }
    }

    /// "从其他输入复制…"能勾的几组（H4）。
    enum CopyGroup: String, CaseIterable, Identifiable {
        case geometry, keyer, audio, effects
        var id: String { rawValue }
    }

    let number: Int
    @Published var section: Section = .general
    @Published private(set) var config: InputConfig
    @Published private(set) var settings: InputSettings
    /// 名字编辑框的值（回车 / 失焦时 rename）。
    @Published var name: String
    var send: ((Command) -> Void)?
    /// 我们刚发出去还没回来的设置：快照没赶上前别用旧值盖掉表单。
    private var pending: InputSettings?
    private var pendingSince = Date.distantPast

    init(config: InputConfig) {
        number = config.number
        self.config = config
        settings = config.settings
        name = config.name
    }

    /// 改一项：本地先改（表单立刻响应），再整体替换发给状态机（reducer 会 clamped）。
    /// 播放的目标与定位请求（提案 021）以快照为准：格子 / 快捷键 / API 随时在改暂停、发定位，表单里那份可能旧了；整份替换只带上这里能改的 restartOnProgram（W5-N）。
    func update(_ body: (inout InputSettings) -> Void) {
        var s = settings
        body(&s)
        guard s != settings else { return }
        var playback = config.settings.playback
        playback.restartOnProgram = s.playback.restartOnProgram
        s.playback = playback
        settings = s
        pending = s
        pendingSince = Date()
        send?(.setInputSettings(input: number, settings: s))
    }

    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != config.name else { name = config.name; return }
        name = trimmed
        send?(.renameInput(input: number, name: trimmed))
    }

    /// 名字框失焦 / 回车 / 关窗：改了就改名（H7，没有单独的"应用名字"按钮）。
    func commitName() { rename(name) }

    /// 名字框正在编辑（快照回来别把还没提交的字盖掉）。
    var isEditingName = false

    /// 快照回来：我们发的到了（相等或被 clamped 后 300 ms 内没再发）就接受。顺带算本路画面切哪一格、tally、别的输入。
    func apply(state: MixerState) {
        updatePreview(state: state)
        let t = state.tally(ofInput: number)
        if t != tally { tally = t }
        let others = state.inputs.filter { $0.number != number }
        if others != otherInputs { otherInputs = others }
        guard let c = state.input(number) else { return }
        let oldSource = config.source
        if c != config { config = c }   // 快照每拍都来（转场中），没变不重画
        // 来源被别处换了（API / 另一个窗口）且表单没被动过：表单跟着换；动过的留着（用户还没点应用）
        if c.source != oldSource, let form = sourceForm, (try? form.model.makeSource()) == oldSource {
            var m = AddInputModel(source: c.source)
            m.number = number
            m.name = c.name
            form.model = m
        }
        if name != c.name, pending == nil, !isEditingName { name = c.name }
        if let p = pending {
            if c.settings == p || Date().timeIntervalSince(pendingSince) > 0.3 {
                pending = nil
                settings = c.settings
            }
        } else if c.settings != settings {
            settings = c.settings
        }
    }

    /// SwiftUI 绑定：读本地值，写走 update。
    func bind<T>(_ keyPath: WritableKeyPath<InputSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { v in self.update { $0[keyPath: keyPath] = v } })
    }

    /// 延迟补偿的 Int 绑定（0–500）。
    var delayBinding: Binding<Double> {
        Binding(get: { Double(self.settings.audio.delayMs) }, set: { v in self.update { $0.audio.delayMs = Int(v.rounded()) } })
    }

    /// 音频一节的"跟随视频（AFV）"开关（X55）：绑 InputAudioSettings.afv，走 setInputSettings（与调音台条子上的开关同一份数）。
    var followVideoBinding: Binding<Bool> { bind(\.audio.afv) }

    /// "音频效果"页顶部的横幅：音频引擎还不读每路效果链（W5-B，X07；102 接上后 AudioEffectsSupport 翻了就没了）。
    var effectsBanner: String? { AudioEffectsSupport.banner(applied: AudioEffectsSupport.inputEffectsApplied) }

    var effectsBinding: Binding<EffectChainEditor> {
        Binding(get: { EffectChainEditor(slots: self.settings.effects) }, set: { e in self.update { $0.effects = e.slots } })
    }

    var keyColorBinding: Binding<Color> {
        Binding(get: {
            let k = self.settings.keyer.keyColor
            return Color(red: Double(k.red) / 255, green: Double(k.green) / 255, blue: Double(k.blue) / 255)
        }, set: { c in
            guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
            let rgb = RGB8(red: UInt8(max(0, min(255, (ns.redComponent * 255).rounded()))), green: UInt8(max(0, min(255, (ns.greenComponent * 255).rounded()))),
                           blue: UInt8(max(0, min(255, (ns.blueComponent * 255).rounded()))))
            self.update { $0.keyer.keyColor = rgb }
        })
    }

    // MARK: 复位 / 恢复默认 / 复制粘贴位置（H5）

    func resetCrop() { update { $0.crop = .none } }
    func resetTransform() { update { $0.transform = .identity } }
    /// 抠像恢复默认：键色 / 容差 / 柔化 / 溢色回到契约默认值，开没开不动。
    func restoreKeyerDefaults() { update { s in s.keyer = KeyerSettings(enabled: s.keyer.enabled) } }
    /// 音频一节整组复位：增益 / 声像 / 音频延迟补偿回到默认（静音、独听、送哪些总线、跟随视频是开关，不在"复位"里动）。
    func resetAudio() {
        update { s in
            let d = InputAudioSettings()
            s.audio.gainDb = d.gainDb
            s.audio.pan = d.pan
            s.audio.delayMs = d.delayMs
        }
    }

    func copyPosition() { InputSettingsClipboard.position = (settings.crop, settings.transform) }
    var canPastePosition: Bool { InputSettingsClipboard.position != nil }
    func pastePosition() {
        guard let p = InputSettingsClipboard.position else { return }
        update { $0.crop = p.crop; $0.transform = p.transform }
    }

    // MARK: 从其他输入复制（H4）

    /// 本节目里别的输入（"从其他输入复制…"的来源下拉）。
    @Published private(set) var otherInputs: [InputConfig] = []

    /// 把另一路的几组设置抄过来：一次 setInputSettings。
    func copy(from input: Int, groups: Set<CopyGroup>) {
        guard let source = otherInputs.first(where: { $0.number == input })?.settings, !groups.isEmpty else { return }
        update { s in
            if groups.contains(.geometry) { s.crop = source.crop; s.transform = source.transform }
            if groups.contains(.keyer) { s.keyer = source.keyer }
            if groups.contains(.audio) { s.audio = source.audio }
            if groups.contains(.effects) { s.effects = source.effects }
        }
    }

    // MARK: 本路画面 / tally / 取色（H3 / H6）

    /// 预览裁多画面纹理的哪一格（nil = 布局里没有这一路）。
    @Published private(set) var previewRect: NormalizedRect?
    /// 多画面纹理的尺寸（= 节目分辨率）。
    private(set) var textureSize = NSSize(width: 1920, height: 1080)
    @Published private(set) var tally = Tally.off
    /// 标题行的 tally："在 PGM" / "在 PVW" / 空。
    var tallyText: String { tally.program ? L("inputSettings.tally.program") : (tally.preview ? L("inputSettings.tally.preview") : "") }
    /// 纯音频输入（没有画面可看、可取色）。
    var isAudioOnly: Bool {
        if config.kind == .audio { return true }
        if case .file(let path, _, _) = config.source { return MediaFileInfo.isAudioFile(path) }
        return false
    }

    private struct PreviewKey: Equatable {
        let layout: MultiviewLayoutSettings?
        let inputs: [Int]
        let width: Int
        let height: Int
    }
    private var previewKey: PreviewKey?

    /// 与输入条缩略图同一算法（InputStripView.thumbnailRect）：按当前多画面布局找这一路的格子，切掉底部名字条。布局或路数变了才重算。
    private func updatePreview(state: MixerState) {
        let key = PreviewKey(layout: MultiviewLayout.layoutSettings(in: state), inputs: state.inputs.map(\.number), width: state.format.width, height: state.format.height)
        guard key != previewKey else { return }
        previewKey = key
        textureSize = NSSize(width: key.width, height: key.height)
        let placement = MultiviewLayout.placements(settings: key.layout, inputs: key.inputs, width: key.width, height: key.height)
            .first { $0.source == .input(number: number) }
        let rect = placement.map { InputStripView.thumbnailRect(for: $0, width: key.width, height: key.height) }
        if rect != previewRect { previewRect = rect }
    }

    /// 正在"在画面上取色"。
    @Published private(set) var isPickingKeyColor = false
    /// 最近一次取到的颜色（测试看）。
    private(set) var lastPickedColor: RGB8?
    /// 取一点的颜色（窗口控制器接上：读多画面纹理；参数是这一格画面里的位置 0–1）。
    var sampleColor: ((CGPoint) -> RGB8?)?

    func startPickingKeyColor() { isPickingKeyColor = true }
    func cancelPickingKeyColor() { isPickingKeyColor = false }

    /// 取色状态下在画面上点了一下：3×3 平均写进键色（一次 setInputSettings），退出取色。不在取色状态什么都不做。
    @discardableResult
    func pickKeyColor(atNormalizedPoint point: CGPoint) -> RGB8? {
        guard isPickingKeyColor, let rgb = sampleColor?(point) else { return nil }
        isPickingKeyColor = false
        lastPickedColor = rgb
        update { $0.keyer.keyColor = rgb }
        return rgb
    }

    // MARK: 来源（提案 012：setInputSource）

    /// 来源一节的表单（第一次打开那一节时建：要列设备、挂音频设备插拔订阅）。
    private(set) var sourceForm: AddInputFormModel?
    private var sourceFormChange: AnyCancellable?
    @Published private(set) var sourceError = ""
    /// 节目帧率（来源一节摄像头页算协商结果用）。
    var programFrameRate: FrameRate = .fps60

    func sourceFormModel() -> AddInputFormModel {
        if let f = sourceForm { return f }
        let format = ProgramFormat(width: Int(textureSize.width), height: Int(textureSize.height), frameRate: programFrameRate)
        let f = AddInputFormModel(editing: config, programFormat: format)
        // "应用"按钮的可用状态跟着表单变；表单改完（objectWillChange 在改之前发，下一轮再看）只差播完 / 速率的当场生效
        sourceFormChange = f.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyInPlaceSourceChange() } }
        }
        sourceForm = f
        return f
    }

    /// 表单出来的来源与当前的不同（表单不完整也算不同：点应用会报缺什么）。
    var sourceChanged: Bool {
        guard let form = sourceForm else { return false }
        return (try? form.model.makeSource()) != config.source
    }

    /// 换来源：setInputSource（编号 / 名字 / 设置 / PGM / PVW / 叠加引用都保留；运行表按"编号 + 来源"变了重建这一路）。
    func applySource() {
        guard let form = sourceForm else { return }
        do {
            let source = try form.model.makeSource()
            sourceError = ""
            guard source != config.source else { return }
            send?(.setInputSource(input: number, source: source))
        } catch {
            sourceError = "\(error)"
        }
    }

    /// 来源一节的说明（文件输入多一句：只改播完 / 速率当场生效、不重建）。
    var sourceHint: String {
        if case .file = config.source { return L("inputSettings.source.changeHint") + L("inputSettings.source.fileInPlaceHint") }
        return L("inputSettings.source.changeHint")
    }

    /// 文件输入只改了"播完"/"播放速率"（同一个文件）：当场发 setInputSource——运行表就地改、不重建这一路、位置接着走（W5-N，02 V04）；
    /// 别的改动（换文件、换类型）照旧等"应用来源"。
    private func applyInPlaceSourceChange() {
        guard let form = sourceForm, let source = try? form.model.makeSource(), source != config.source,
              InputRuntime.inPlaceFileChange(from: config.source, to: source) != nil else { return }
        send?(.setInputSource(input: number, source: source))
    }

    // MARK: 播放（文件输入，提案 021）

    /// ▶ / ⏸：按快照里的目标翻（与格子同一条命令）。
    func togglePaused() { send?(.setPlayback(input: number, paused: !config.settings.playback.paused)) }

    /// 回到开头（seekPlayback 0；暂停中就停在第一帧）。
    func restartPlayback() { send?(.seekPlayback(input: number, seconds: 0)) }

    /// 是文件输入（"播放"小节只对它出）。
    var isFileSource: Bool {
        if case .file = config.source { return true }
        return false
    }

    /// 表单改回当前来源。
    func revertSource() {
        guard let form = sourceForm else { return }
        var m = AddInputModel(source: config.source)
        m.number = number
        m.name = config.name
        form.model = m
        sourceError = ""
    }

    /// 窗口关掉：没提交的名字提交掉、退出取色、摘掉表单的设备插拔订阅。
    func close() {
        commitName()
        isPickingKeyColor = false
        sourceForm?.close()
    }

    /// 声道映射（提案 014）的摘要后缀："（第 5、6 路）"；空（前两路）没有后缀。
    static func channelsSuffix(_ channels: [Int]) -> String {
        channels.isEmpty ? "" : L("inputSettings.source.channels", ChannelMapChoice.summary(channels))
    }

    /// 来源摘要。
    var sourceSummary: String {
        switch config.source {
        case .camera(let id): return L("inputSettings.source.camera", id)
        case .decklink(let id, let connection, let channels):
            let card = id.isEmpty ? L("addInput.decklink.firstCard") : id
            let port = connection.map { L("decklink.connection.\($0.rawValue)") } ?? L("addInput.decklink.connection.keep")
            return L("inputSettings.source.decklink", card, port) + Self.channelsSuffix(channels)
        case .screen(let target, let rate, let audio):
            let t: String
            switch target {
            case .display(let id): t = L("inputSettings.source.screen.display", Int(id))
            case .window(let id): t = L("inputSettings.source.screen.window", Int(id))
            case .application(let b): t = L("inputSettings.source.screen.application", b)
            }
            return L("inputSettings.source.screen", t, rate.map { "\($0)" } ?? L("addInput.screen.frameRateProgram"), audio ? L("common.on") : L("common.off"))
        case .file(let path, let end, let rate): return L("inputSettings.source.file", path, L("addInput.file.endAction.\(end.rawValue)"), rate)
        case .image(let path): return L("inputSettings.source.image", path)
        case .ndi(let name, let bandwidth, let jitter): return L("inputSettings.source.ndi", name, L("ndi.bandwidth.\(bandwidth.rawValue)"), jitter)
        case .audio(let uid, let channels):
            return L("inputSettings.source.audio", uid.isEmpty ? L("addInput.audio.systemDefault") : uid) + Self.channelsSuffix(channels)
        case .synthetic(let s): return L("inputSettings.source.synthetic", "\(s.frameRate)", s.width, s.height)
        }
    }
}

/// 滑杆 + 能输入的数值框 + 单项复位（H5）。数值框显示的是 value × scale（裁切按百分比显示）。
struct SliderField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var scale: Double = 1
    var digits: Int = 2
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range) { Text(label) }
            TextField(label, value: Binding(get: { value * scale }, set: { value = min(max($0 / scale, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(digits)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .accessibilityLabel(L("inputSettings.resetItemNamed", label))
                .buttonStyle(.borderless)
                .help(L("inputSettings.resetItem"))
        }
    }
}

struct InputSettingsView: View {
    /// 效果页显示"限幅器"那一节吗：每路不装限幅（W5-P，W4C3 第 3 条），不显示；已有的限幅格列在"其他效果"里原样留着。
    static let effectsShowLimiter = false
    @ObservedObject var model: InputSettingsModel
    let preview: InputPreviewContainer
    @FocusState private var nameFocused: Bool
    @State private var showingCopySheet = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(InputSettingsModel.Section.allCases, selection: sectionSelection) { s in Text(s.title).tag(s) }
                    .listStyle(.sidebar)
                    .accessibilityLabel(L("inputSettings.sectionList"))
                Divider()
                Button(L("inputSettings.copyFrom")) { showingCopySheet = true }
                    .disabled(model.otherInputs.isEmpty)
                    .padding(8)
            }
            .frame(width: 160)
            Divider()
            VStack(spacing: 0) {
                header
                Form { sectionBody }.formStyle(.grouped)
                Divider()
                previewPane
            }
        }
        .sheet(isPresented: $showingCopySheet) { CopyFromInputSheet(model: model) }
    }

    private var sectionSelection: Binding<InputSettingsModel.Section?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })
    }

    /// 标题行：编号 · 名字 + 这一路的 tally（H3）。
    private var header: some View {
        HStack(spacing: 8) {
            Text(L("inputSettings.header", model.number, model.config.name)).font(.headline).lineLimit(1)
            if !model.tallyText.isEmpty {
                Text(model.tallyText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: model.tally.program ? Theme.tallyProgram : Theme.tallyPreview), in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 本路实时画面（多画面纹理裁这一格；取色时十字光标）。
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.isPickingKeyColor ? L("inputSettings.preview.picking") : L("inputSettings.preview.title")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isPickingKeyColor {
                    Button(L("common.cancel")) { model.cancelPickingKeyColor() }.controlSize(.small)
                }
            }
            ZStack {
                InputPreviewRepresentable(container: preview)
                if model.isAudioOnly {
                    Text(L("inputSettings.preview.audioOnly")).font(.caption).foregroundStyle(.secondary)
                } else if model.previewRect == nil {
                    Text(L("cell.notInMultiview")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(10)
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.section {
        case .general: general
        case .keyer: keyer
        case .geometry: geometry
        case .audio: audio
        case .effects:
            if let banner = model.effectsBanner {
                Section {
                    Text(banner).font(.headline).foregroundStyle(.orange)
                    Text(L("effects.notEffectiveHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }
            EffectChainView(editor: model.effectsBinding, showsLimiter: Self.effectsShowLimiter)
        case .source: source
        }
    }

    private var general: some View {
        Section(L("inputSettings.general.title")) {
            LabeledContent(L("inputSettings.general.number"), value: "\(model.number)")
            TextField(L("inputSettings.general.name"), text: $model.name)
                .focused($nameFocused)
                .onSubmit { model.commitName() }
                .onChange(of: nameFocused) { _, focused in
                    model.isEditingName = focused
                    if !focused { model.commitName() }   // 失焦即改名（H7）
                }
            Text(L("inputSettings.general.nameHint")).font(.caption).foregroundStyle(.secondary)
            LabeledContent(L("inputSettings.general.kind"), value: L("addInput.kind.\(model.config.kind.rawValue)"))
        }
    }

    private var geometry: some View {
        Group {
            Section(L("inputSettings.crop.title")) {
                SliderField(label: L("inputSettings.crop.left"), value: model.bind(\.crop.left), range: 0...1, scale: 100, digits: 0) { model.update { $0.crop.left = 0 } }
                SliderField(label: L("inputSettings.crop.top"), value: model.bind(\.crop.top), range: 0...1, scale: 100, digits: 0) { model.update { $0.crop.top = 0 } }
                SliderField(label: L("inputSettings.crop.right"), value: model.bind(\.crop.right), range: 0...1, scale: 100, digits: 0) { model.update { $0.crop.right = 0 } }
                SliderField(label: L("inputSettings.crop.bottom"), value: model.bind(\.crop.bottom), range: 0...1, scale: 100, digits: 0) { model.update { $0.crop.bottom = 0 } }
                Button(L("inputSettings.crop.reset")) { model.resetCrop() }
            }
            Section(L("inputSettings.transform.title")) {
                SliderField(label: L("inputSettings.transform.scale"), value: model.bind(\.transform.scale), range: 0.05...4) { model.update { $0.transform.scale = 1 } }
                SliderField(label: L("inputSettings.transform.offsetX"), value: model.bind(\.transform.offsetX), range: -1...1) { model.update { $0.transform.offsetX = 0 } }
                SliderField(label: L("inputSettings.transform.offsetY"), value: model.bind(\.transform.offsetY), range: -1...1) { model.update { $0.transform.offsetY = 0 } }
                SliderField(label: L("inputSettings.transform.rotation"), value: model.bind(\.transform.rotationDegrees), range: -180...180, digits: 0) {
                    model.update { $0.transform.rotationDegrees = 0 }
                }
                Toggle(L("inputSettings.transform.flipH"), isOn: model.bind(\.transform.flipHorizontal))
                Toggle(L("inputSettings.transform.flipV"), isOn: model.bind(\.transform.flipVertical))
                HStack {
                    Button(L("inputSettings.transform.reset")) { model.resetTransform() }
                    Spacer()
                    Button(L("inputSettings.position.copy")) { model.copyPosition() }
                    Button(L("inputSettings.position.paste")) { model.pastePosition() }.disabled(!model.canPastePosition)
                }
            }
        }
    }

    private var audio: some View {
        Group {
            Section(L("inputSettings.audio.title")) {
                SliderField(label: L("inputSettings.audio.gain"), value: model.bind(\.audio.gainDb), range: InputAudioSettings.gainRangeDb, digits: 1) { model.update { $0.audio.gainDb = 0 } }
                Toggle(L("inputSettings.audio.muted"), isOn: model.bind(\.audio.muted))
                Toggle(L("inputSettings.audio.solo"), isOn: model.bind(\.audio.solo))
                SliderField(label: L("inputSettings.audio.pan"), value: model.bind(\.audio.pan), range: -1...1) { model.update { $0.audio.pan = 0 } }
                SliderField(label: L("inputSettings.audio.delay"), value: model.delayBinding,
                            range: Double(InputAudioSettings.delayRangeMs.lowerBound)...Double(InputAudioSettings.delayRangeMs.upperBound), digits: 0) {
                    model.update { $0.audio.delayMs = 0 }
                }
                Text(L("inputSettings.audio.delayHint")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("inputSettings.audio.afv"), isOn: model.followVideoBinding)
                Text(L("inputSettings.audio.afvHint")).font(.caption).foregroundStyle(.secondary)
                Button(L("inputSettings.audio.reset")) { model.resetAudio() }
            }
            Section(L("inputSettings.routing.title")) {
                Toggle(L("bus.master"), isOn: model.bind(\.audio.routing.master))
                Toggle(L("bus.busA"), isOn: model.bind(\.audio.routing.busA))
                Toggle(L("bus.busB"), isOn: model.bind(\.audio.routing.busB))
                Toggle(L("bus.headphones"), isOn: model.bind(\.audio.routing.headphones))
            }
        }
    }

    private var keyer: some View {
        Section(L("inputSettings.keyer.title")) {
            Toggle(L("inputSettings.keyer.enabled"), isOn: model.bind(\.keyer.enabled))
            HStack {
                ColorPicker(L("inputSettings.keyer.keyColor"), selection: model.keyColorBinding, supportsOpacity: false)
                Spacer()
                Button(L("inputSettings.keyer.pickFromPreview")) { model.isPickingKeyColor ? model.cancelPickingKeyColor() : model.startPickingKeyColor() }
                    .disabled(model.isAudioOnly || model.previewRect == nil)
                    .help(L("inputSettings.keyer.pickHelp"))
            }
            SliderField(label: L("inputSettings.keyer.tolerance"), value: model.bind(\.keyer.tolerance), range: 0...1) { model.update { $0.keyer.tolerance = KeyerSettings().tolerance } }
            SliderField(label: L("inputSettings.keyer.softness"), value: model.bind(\.keyer.softness), range: 0...1) { model.update { $0.keyer.softness = KeyerSettings().softness } }
            SliderField(label: L("inputSettings.keyer.spill"), value: model.bind(\.keyer.spillSuppression), range: 0...1) {
                model.update { $0.keyer.spillSuppression = KeyerSettings().spillSuppression }
            }
            Button(L("inputSettings.keyer.restoreDefaults")) { model.restoreKeyerDefaults() }
            Text(L("inputSettings.keyer.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var source: some View {
        let form = model.sourceFormModel()
        Section(L("inputSettings.source.title")) {
            LabeledContent(L("inputSettings.source.current"), value: model.sourceSummary)
            Picker(L("inputSettings.source.kind"), selection: Binding(get: { form.model.kind }, set: { form.model.kind = $0 })) {
                ForEach(AddInputModel.Kind.displayOrder) { Text($0.title).tag($0) }
            }
        }
        InputSourceFormView(form: form)
        Section {
            HStack {
                Button(L("inputSettings.source.apply")) { model.applySource() }.disabled(!model.sourceChanged)
                Button(L("inputSettings.source.revert")) { model.revertSource() }.disabled(!model.sourceChanged)
            }
            if !model.sourceError.isEmpty { Text(model.sourceError).foregroundStyle(.red) }
            Text(model.sourceHint).font(.caption).foregroundStyle(.secondary)
        }
        if model.isFileSource {
            Section(L("inputSettings.playback.title")) {
                HStack {
                    Button(model.config.settings.playback.paused ? L("inputSettings.playback.play") : L("inputSettings.playback.pause")) { model.togglePaused() }
                    Button(L("inputSettings.playback.restart")) { model.restartPlayback() }
                }
                Toggle(L("inputSettings.playback.restartOnProgram"), isOn: model.bind(\.playback.restartOnProgram))
                Text(L("inputSettings.playback.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "从其他输入复制…"（H4）：选一路来源输入，勾要抄的组，确定后一次 setInputSettings。
private struct CopyFromInputSheet: View {
    @ObservedObject var model: InputSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: Int?
    @State private var groups = Set(InputSettingsModel.CopyGroup.allCases)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(L("inputSettings.copy.source"), selection: Binding(get: { source ?? model.otherInputs.first?.number ?? 0 }, set: { source = $0 })) {
                    ForEach(model.otherInputs) { Text(verbatim: "\($0.number) \($0.name)").tag($0.number) }
                }
                ForEach(InputSettingsModel.CopyGroup.allCases) { g in
                    Toggle(L("inputSettings.copy.group.\(g.rawValue)"), isOn: Binding(get: { groups.contains(g) }, set: { on in
                        if on { groups.insert(g) } else { groups.remove(g) }
                    }))
                }
                Text(L("inputSettings.copy.hint", model.number)).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("inputSettings.copy.apply")) {
                    if let n = source ?? model.otherInputs.first?.number { model.copy(from: n, groups: groups) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty || model.otherInputs.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 380, height: 320)
    }
}

@MainActor
final class InputSettingsWindowController: PanelWindowController {
    let model: InputSettingsModel
    /// 本路实时画面（多画面纹理裁这一格）与它的点击容器（取色）。
    let previewView: MetalDisplayView
    let previewContainer: InputPreviewContainer
    private var pickingToken: AnyCancellable?
    private var rectToken: AnyCancellable?
    private weak var source: (any DisplayFrameSource)?

    init(model: InputSettingsModel) {
        self.model = model
        let display = MetalDisplayView(frame: .zero)
        display.target = .multiview
        display.maxFramesPerSecond = 30
        previewView = display
        let container = InputPreviewContainer(display: display)
        previewContainer = container
        // 存档名带编号（W5-A / X44：原来所有输入共用一个，同时开几路都跳到同一个存档位置、叠在一起）
        super.init(title: L("inputSettings.windowTitle", model.number, model.config.name), size: NSSize(width: 720, height: 680),
                   autosaveName: Self.autosaveName(input: model.number), content: InputSettingsView(model: model, preview: container),
                   minSize: NSSize(width: 600, height: 520))
        container.onPick = { [weak model] p in model?.pickKeyColor(atNormalizedPoint: p) }
        model.sampleColor = { [weak self] p in self?.sample(p) }
        pickingToken = model.$isPickingKeyColor.sink { [weak container] on in container?.isPicking = on }
        rectToken = model.$previewRect.sink { [weak self] rect in self?.applyPreviewRect(rect) }
    }

    static func autosaveName(input number: Int) -> String { "InputSettings-\(number)" }

    /// 接上画面来源（本 session 的渲染器）与节目格式。
    func attach(source: (any DisplayFrameSource)?, format: ProgramFormat) {
        self.source = source
        previewView.source = source
        previewContainer.textureSize = NSSize(width: format.width, height: format.height)
        model.programFrameRate = format.frameRate
        applyPreviewRect(model.previewRect)
    }

    private func applyPreviewRect(_ rect: NormalizedRect?) {
        previewContainer.sourceRect = rect ?? .full
        previewView.isHidden = rect == nil || model.isAudioOnly
    }

    /// 取色：这一格画面里的位置 → 多画面纹理里的像素 → 3×3 平均。
    private func sample(_ p: CGPoint) -> RGB8? {
        guard let source, let rect = model.previewRect, let frame = source.latestDisplayFrame(for: .multiview) else { return nil }
        let texture = frame.texture
        let x = Int(((rect.x + rect.width * Double(p.x)) * Double(texture.width)).rounded(.down))
        let y = Int(((rect.y + rect.height * Double(p.y)) * Double(texture.height)).rounded(.down))
        return PixelSampler.average3x3(texture: texture, queue: source.displayCommandQueue, x: x, y: y)
    }

    func apply(state: MixerState) {
        model.apply(state: state)
        window?.title = L("inputSettings.windowTitle", model.number, model.config.name)
    }

    override func windowWillClose(_ notification: Notification) {
        model.close()
        super.windowWillClose(notification)
    }
}
