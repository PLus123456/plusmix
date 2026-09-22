// 添加输入（W3-E 完整版）：左边八种类型（设计方案 §6：摄像头 / 采集卡、DeckLink、屏幕 / 窗口 / 应用、视频文件、图片、NDI、
// 纯音频设备、合成测试源），右边各自的参数页，底部编号 + 名字 + 确定。SwiftUI 表单放 NSHostingView 的 sheet 里。
// 只产生 InputConfig 并发 addInput 命令；运行实现由 InputFactory 接（DeckLink / NDI / 纯音频在 W3-A 合入前是占位）。
import AppKit
import AVFoundation
import SwiftUI
import SwitcherContracts
import SwitcherInputs
import SwitcherAudio

/// 表单内容 → InputConfig 的纯逻辑（可测）。
struct AddInputModel {
    enum Kind: Int, CaseIterable, Identifiable {
        case synthetic, camera, decklink, screen, file, image, ndi, audio
        var id: Int { rawValue }
        /// 对应的契约输入类型。
        var inputKind: InputKind {
            switch self {
            case .synthetic: .synthetic
            case .camera: .camera
            case .decklink: .decklink
            case .screen: .screen
            case .file: .file
            case .image: .image
            case .ndi: .ndi
            case .audio: .audio
            }
        }
        var title: String { L("addInput.kind.\(inputKind.rawValue)") }
    }
    enum ScreenKind: String, CaseIterable, Identifiable {
        case display, window, application
        var id: String { rawValue }
        var title: String { L("addInput.screenKind.\(rawValue)") }
    }
    enum SyntheticBackground: String, CaseIterable, Identifiable {
        case gray, gradient, noise
        var id: String { rawValue }
        var title: String { L("addInput.background.\(rawValue)") }
    }
    enum ModelError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self { case .missing(let what): L("addInput.error.missing", what) }
        }
    }

    var kind: Kind = .synthetic
    var number: Int = 1
    var name: String = ""
    // 合成源（SyntheticSourceSettings 的全部项）
    var syntheticFrameRate: FrameRate = .fps60
    var syntheticWidth = 1920
    var syntheticHeight = 1080
    var syntheticGray: UInt8 = 128
    var syntheticBackground: SyntheticBackground = .gray
    var noiseAmplitude: UInt8 = 24
    var noiseSeed = 7
    var patternID: Int? = nil
    var jitterMs: Double = 0
    var dropEveryN = 0
    var clockDriftPpm: Double = 0
    var syntheticAudio = false
    var audioDriftPpm: Double = 0
    // 摄像头 / 采集卡
    var cameraUniqueID: String?
    // DeckLink
    var decklinkDeviceID = ""
    // 屏幕 / 窗口 / 应用
    var screenKind: ScreenKind = .display
    var displayID: UInt32?
    var windowID: UInt32?
    var applicationBundleID: String?
    var screenFrameRate: FrameRate? = nil
    var captureAudio = false
    // 文件 / 图片
    var filePath: String = ""
    var fileEndAction: FileEndAction = .loop
    var fileRate: Double = 1
    var imagePath: String = ""
    // NDI
    var ndiSourceName = ""
    // 纯音频设备
    var audioDeviceUID: String?

    static let syntheticSizes: [(title: String, width: Int, height: Int)] = [("1920×1080", 1920, 1080), ("1280×720", 1280, 720), ("3840×2160", 3840, 2160)]
    static let syntheticRates: [FrameRate] = [.fps30, .fps5994, .fps60]
    static let screenRates: [FrameRate] = [.fps24, .fps25, .fps30, .fps50, .fps5994, .fps60]
    static let fileEndActions: [FileEndAction] = [.loop, .holdLastFrame, .black]

    /// 默认名字。
    var defaultName: String {
        switch kind {
        case .synthetic: L("addInput.defaultName.synthetic", number, "\(syntheticFrameRate)")
        case .camera: L("addInput.defaultName.camera", number)
        case .decklink: L("addInput.defaultName.decklink", number)
        case .screen: L("addInput.defaultName.screen", number)
        case .file: filePath.isEmpty ? L("addInput.defaultName.file", number) : (filePath as NSString).lastPathComponent
        case .image: imagePath.isEmpty ? L("addInput.defaultName.image", number) : (imagePath as NSString).lastPathComponent
        case .ndi: ndiSourceName.isEmpty ? L("addInput.defaultName.ndi", number) : ndiSourceName
        case .audio: L("addInput.defaultName.audio", number)
        }
    }

    func makeConfig() throws -> InputConfig {
        let source: InputSource
        switch kind {
        case .synthetic:
            let background: TestPattern.Background
            switch syntheticBackground {
            case .gray: background = .gray(level: syntheticGray)
            case .gradient: background = .gradient
            case .noise: background = .noise(level: syntheticGray, amplitude: noiseAmplitude, seed: UInt64(max(0, noiseSeed)))
            }
            source = .synthetic(settings: SyntheticSourceSettings(frameRate: syntheticFrameRate, width: syntheticWidth, height: syntheticHeight,
                                                                  background: background, patternID: patternID, jitterMs: jitterMs, dropEveryN: dropEveryN,
                                                                  clockDriftPpm: clockDriftPpm, audio: syntheticAudio, audioDriftPpm: audioDriftPpm))
        case .camera:
            guard let id = cameraUniqueID, !id.isEmpty else { throw ModelError.missing(L("addInput.field.camera")) }
            source = .camera(uniqueID: id)
        case .decklink:
            let id = decklinkDeviceID.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { throw ModelError.missing(L("addInput.field.decklink")) }
            source = .decklink(deviceID: id)
        case .screen:
            let target: ScreenTarget
            switch screenKind {
            case .display:
                guard let id = displayID else { throw ModelError.missing(L("addInput.field.display")) }
                target = .display(id: id)
            case .window:
                guard let id = windowID else { throw ModelError.missing(L("addInput.field.window")) }
                target = .window(id: id)
            case .application:
                guard let id = applicationBundleID, !id.isEmpty else { throw ModelError.missing(L("addInput.field.application")) }
                target = .application(bundleID: id)
            }
            source = .screen(target: target, frameRate: screenFrameRate, captureAudio: captureAudio)
        case .file:
            guard !filePath.isEmpty else { throw ModelError.missing(L("addInput.field.filePath")) }
            source = .file(path: filePath, endAction: fileEndAction, rate: fileRate > 0 ? fileRate : 1)
        case .image:
            guard !imagePath.isEmpty else { throw ModelError.missing(L("addInput.field.imagePath")) }
            source = .image(path: imagePath)
        case .ndi:
            let name = ndiSourceName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ModelError.missing(L("addInput.field.ndi")) }
            source = .ndi(sourceName: name)
        case .audio:
            guard let uid = audioDeviceUID, !uid.isEmpty else { throw ModelError.missing(L("addInput.field.audioDevice")) }
            source = .audio(deviceUID: uid)
        }
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        return InputConfig(number: number, name: finalName, source: source)
    }

    /// 空闲编号（1…maxInputs 里最小的没用的）。
    static func nextFreeNumber(in state: MixerState, maxInputs: Int) -> Int {
        let used = Set(state.inputs.map(\.number))
        return (1...max(1, maxInputs)).first { !used.contains($0) } ?? maxInputs
    }

    /// 摄像头列表（uniqueID, 名字）。
    static func cameras() -> [(id: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified)
        return session.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// 显示器列表。
    @MainActor
    static func displays() -> [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.displayNumber else { return nil }
            return (n, screen.displayTitle)
        }
    }

    /// 纯音频输入设备（Core Audio UID, 名字）：有输入声道的设备。
    static func audioInputDevices() -> [(uid: String, name: String)] {
        AudioHAL.devices().filter { $0.inputChannels > 0 }.map { ($0.uid, $0.name) }
    }
}

/// 一个可选项（设备 / 窗口 / 应用）。
struct AddInputChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 表单的可观察模型：设备列表 + 表单值 + 错误。
@MainActor
final class AddInputFormModel: ObservableObject {
    @Published var model: AddInputModel
    @Published var errorMessage = ""
    @Published private(set) var cameras: [AddInputChoice] = []
    @Published private(set) var displays: [AddInputChoice] = []
    @Published private(set) var windows: [AddInputChoice] = []
    @Published private(set) var applications: [AddInputChoice] = []
    @Published private(set) var audioDevices: [AddInputChoice] = []
    @Published private(set) var screenListStatus = ""
    let freeNumbers: [Int]
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    init(state: MixerState, maxInputs: Int) {
        var m = AddInputModel()
        m.number = AddInputModel.nextFreeNumber(in: state, maxInputs: maxInputs)
        model = m
        let used = Set(state.inputs.map(\.number))
        freeNumbers = (1...max(1, maxInputs)).filter { !used.contains($0) }
        cameras = AddInputModel.cameras().map { AddInputChoice(id: $0.id, title: $0.name) }
        displays = AddInputModel.displays().map { AddInputChoice(id: String($0.id), title: $0.name) }
        audioDevices = AddInputModel.audioInputDevices().map { AddInputChoice(id: $0.uid, title: $0.name) }
        model.cameraUniqueID = cameras.first?.id
        model.displayID = AddInputModel.displays().first?.id
        model.audioDeviceUID = audioDevices.first?.id
    }

    /// 摄像头权限提示（没授权时）。
    var cameraPermissionMessage: String? {
        let p = CapturePermission.status(for: .video)
        return p == .authorized ? nil : CapturePermission.message(for: p, mediaType: .video)
    }

    /// 窗口 / 应用列表要屏幕录制权限，用户选到才去取（ScreenCaptureKit）。
    func loadScreenLists() {
        guard windows.isEmpty, applications.isEmpty else { return }
        screenListStatus = L("addInput.screen.loading")
        Task { @MainActor [weak self] in
            do {
                let windows = try await ScreenTargets.windows()
                let apps = try await ScreenTargets.applications()
                guard let self else { return }
                self.windows = windows.filter { $0.isOnScreen }.map { AddInputChoice(id: String($0.id), title: "\($0.applicationName) — \($0.title)") }
                self.applications = apps.map { AddInputChoice(id: $0.bundleID, title: $0.name) }
                if self.model.windowID == nil, let first = self.windows.first { self.model.windowID = UInt32(first.id) }
                if self.model.applicationBundleID == nil { self.model.applicationBundleID = self.applications.first?.id }
                self.screenListStatus = L("addInput.screen.listed", self.windows.count, self.applications.count)
            } catch {
                self?.screenListStatus = L("addInput.screen.failed", "\(error)")
            }
        }
    }

    /// 生成配置；失败把原因写进 errorMessage。
    func makeConfig() -> InputConfig? {
        do {
            errorMessage = ""
            return try model.makeConfig()
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }
}

/// Sheet 内容。
struct AddInputView: View {
    @ObservedObject var form: AddInputFormModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(AddInputModel.Kind.allCases, selection: kindSelection) { kind in
                    Text(kind.title).tag(kind)
                }
                .listStyle(.sidebar)
                .frame(width: 170)
                .accessibilityLabel(L("addInput.kindList"))
                Divider()
                Form { formBody }
                    .formStyle(.grouped)
            }
            Divider()
            HStack {
                Picker(L("addInput.number"), selection: $form.model.number) {
                    ForEach(form.freeNumbers, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 130)
                TextField(L("addInput.name"), text: $form.model.name, prompt: Text(form.model.defaultName))
                    .frame(width: 200)
                Text(form.errorMessage).foregroundStyle(.red).lineLimit(1)
                Spacer()
                Button(L("common.cancel")) { form.onCancel?() }.keyboardShortcut(.cancelAction)
                Button(L("addInput.add")) { form.onConfirm?() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var kindSelection: Binding<AddInputModel.Kind?> {
        Binding(get: { form.model.kind }, set: { if let k = $0 { form.model.kind = k; form.errorMessage = "" } })
    }

    @ViewBuilder
    private var formBody: some View {
        switch form.model.kind {
        case .synthetic: syntheticForm
        case .camera: cameraForm
        case .decklink: decklinkForm
        case .screen: screenForm
        case .file: fileForm
        case .image: imageForm
        case .ndi: ndiForm
        case .audio: audioForm
        }
    }

    private var syntheticForm: some View {
        Section(L("addInput.synthetic.title")) {
            Text(L("addInput.synthetic.hint")).font(.caption).foregroundStyle(.secondary)
            Picker(L("addInput.synthetic.frameRate"), selection: $form.model.syntheticFrameRate) {
                ForEach(AddInputModel.syntheticRates, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker(L("addInput.synthetic.size"), selection: sizeSelection) {
                ForEach(Array(AddInputModel.syntheticSizes.enumerated()), id: \.offset) { i, s in Text(s.title).tag(i) }
            }
            Picker(L("addInput.synthetic.background"), selection: $form.model.syntheticBackground) {
                ForEach(AddInputModel.SyntheticBackground.allCases) { Text($0.title).tag($0) }
            }
            if form.model.syntheticBackground != .gradient {
                Slider(value: grayBinding, in: 16...235, step: 1) { Text(L("addInput.synthetic.gray")) }
                LabeledContent(L("addInput.synthetic.grayValue"), value: "\(form.model.syntheticGray)")
            }
            if form.model.syntheticBackground == .noise {
                Stepper(value: noiseAmplitudeBinding, in: 1...63) { Text(L("addInput.synthetic.noiseAmplitude", Int(form.model.noiseAmplitude))) }
                TextField(L("addInput.synthetic.noiseSeed"), value: $form.model.noiseSeed, format: .number)
            }
            TextField(L("addInput.synthetic.patternID"), value: $form.model.patternID, format: .number, prompt: Text(L("addInput.synthetic.patternIDAuto")))
            TextField(L("addInput.synthetic.jitterMs"), value: $form.model.jitterMs, format: .number)
            TextField(L("addInput.synthetic.dropEveryN"), value: $form.model.dropEveryN, format: .number)
            TextField(L("addInput.synthetic.clockDriftPpm"), value: $form.model.clockDriftPpm, format: .number)
            Toggle(L("addInput.synthetic.audio"), isOn: $form.model.syntheticAudio)
            if form.model.syntheticAudio {
                TextField(L("addInput.synthetic.audioDriftPpm"), value: $form.model.audioDriftPpm, format: .number)
            }
        }
    }

    private var sizeSelection: Binding<Int> {
        Binding(get: {
            AddInputModel.syntheticSizes.firstIndex { $0.width == form.model.syntheticWidth && $0.height == form.model.syntheticHeight } ?? 0
        }, set: { i in
            let s = AddInputModel.syntheticSizes[max(0, min(i, AddInputModel.syntheticSizes.count - 1))]
            form.model.syntheticWidth = s.width
            form.model.syntheticHeight = s.height
        })
    }
    private var grayBinding: Binding<Double> {
        Binding(get: { Double(form.model.syntheticGray) }, set: { form.model.syntheticGray = UInt8(max(0, min(255, $0))) })
    }
    private var noiseAmplitudeBinding: Binding<Int> {
        Binding(get: { Int(form.model.noiseAmplitude) }, set: { form.model.noiseAmplitude = UInt8(max(0, min(255, $0))) })
    }

    private var cameraForm: some View {
        Section(L("addInput.camera.title")) {
            Picker(L("addInput.camera.device"), selection: optionalString($form.model.cameraUniqueID)) {
                ForEach(form.cameras) { Text($0.title).tag($0.id) }
            }
            Text(form.cameras.isEmpty ? L("addInput.camera.none") : L("addInput.camera.count", form.cameras.count)).font(.caption).foregroundStyle(.secondary)
            if let p = form.cameraPermissionMessage { Text(p).font(.caption).foregroundStyle(.secondary) }
            Text(L("addInput.camera.micHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var decklinkForm: some View {
        Section(L("addInput.decklink.title")) {
            TextField(L("addInput.decklink.deviceID"), text: $form.model.decklinkDeviceID)
            Text(L("addInput.decklink.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var screenForm: some View {
        Section(L("addInput.screen.title")) {
            Picker(L("addInput.screen.kind"), selection: $form.model.screenKind) {
                ForEach(AddInputModel.ScreenKind.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: form.model.screenKind) { _, new in if new != .display { form.loadScreenLists() } }
            switch form.model.screenKind {
            case .display:
                Picker(L("addInput.screen.display"), selection: displaySelection) {
                    ForEach(form.displays) { Text($0.title).tag($0.id) }
                }
            case .window:
                Picker(L("addInput.screen.window"), selection: windowSelection) {
                    ForEach(form.windows) { Text($0.title).tag($0.id) }
                }
                Text(form.screenListStatus).font(.caption).foregroundStyle(.secondary)
            case .application:
                Picker(L("addInput.screen.application"), selection: optionalString($form.model.applicationBundleID)) {
                    ForEach(form.applications) { Text($0.title).tag($0.id) }
                }
                Text(form.screenListStatus).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("addInput.screen.frameRate"), selection: $form.model.screenFrameRate) {
                Text(L("addInput.screen.frameRateProgram")).tag(FrameRate?.none)
                ForEach(AddInputModel.screenRates, id: \.self) { Text("\($0)").tag(FrameRate?.some($0)) }
            }
            Toggle(L("addInput.screen.captureAudio"), isOn: $form.model.captureAudio)
            Text(L("addInput.screen.permissionHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displaySelection: Binding<String> {
        Binding(get: { form.model.displayID.map(String.init) ?? "" }, set: { form.model.displayID = UInt32($0) })
    }
    private var windowSelection: Binding<String> {
        Binding(get: { form.model.windowID.map(String.init) ?? "" }, set: { form.model.windowID = UInt32($0) })
    }
    private func optionalString(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private var fileForm: some View {
        Section(L("addInput.file.title")) {
            HStack {
                TextField(L("addInput.file.path"), text: $form.model.filePath)
                Button(L("common.browse")) { browse(image: false) }
            }
            Picker(L("addInput.file.endAction"), selection: $form.model.fileEndAction) {
                ForEach(AddInputModel.fileEndActions, id: \.self) { Text(L("addInput.file.endAction.\($0.rawValue)")).tag($0) }
            }
            TextField(L("addInput.file.rate"), value: $form.model.fileRate, format: .number)
            Text(L("addInput.file.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var imageForm: some View {
        Section(L("addInput.image.title")) {
            HStack {
                TextField(L("addInput.image.path"), text: $form.model.imagePath)
                Button(L("common.browse")) { browse(image: true) }
            }
            Text(L("addInput.image.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ndiForm: some View {
        Section(L("addInput.ndi.title")) {
            TextField(L("addInput.ndi.sourceName"), text: $form.model.ndiSourceName, prompt: Text(L("addInput.ndi.sourcePrompt")))
            Text(L("addInput.ndi.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioForm: some View {
        Section(L("addInput.audio.title")) {
            Picker(L("addInput.audio.device"), selection: optionalString($form.model.audioDeviceUID)) {
                ForEach(form.audioDevices) { Text($0.title).tag($0.id) }
            }
            Text(form.audioDevices.isEmpty ? L("addInput.audio.none") : L("addInput.audio.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func browse(image: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = image ? [.image] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if image { form.model.imagePath = url.path } else { form.model.filePath = url.path }
        }
    }
}

/// Sheet 本体。
@MainActor
final class AddInputSheetController: NSWindowController {
    let form: AddInputFormModel
    private let onConfirm: (InputConfig) -> Void

    /// 当前表单值（测试看）。
    var model: AddInputModel { form.model }

    init(state: MixerState, maxInputs: Int, onConfirm: @escaping (InputConfig) -> Void) {
        self.onConfirm = onConfirm
        form = AddInputFormModel(state: state, maxInputs: maxInputs)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = L("addInput.title")
        super.init(window: panel)
        let host = NSHostingView(rootView: AddInputView(form: form))
        host.sizingOptions = []
        panel.contentView = host
        form.onConfirm = { [weak self] in self?.confirm() }
        form.onCancel = { [weak self] in self?.cancel() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func confirm() {
        guard let config = form.makeConfig() else { return }
        onConfirm(config)
        close(returnCode: .OK)
    }

    private func cancel() { close(returnCode: .cancel) }

    // 测试入口
    func selectKindForTesting(_ kind: AddInputModel.Kind) { form.model.kind = kind }
    func confirmForTesting() { confirm() }
    func cancelForTesting() { cancel() }

    private func close(returnCode: NSApplication.ModalResponse) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            window.close()
        }
    }
}
