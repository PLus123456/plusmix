// 输出设置窗（W3-E 交付第 3 条）：录制（格式、码率、关键帧间隔、目录、停止后转 MP4）、ISO 路选择、推流目的地列表
// （RTMP / RTMPS / SRT、地址、密钥、每路编码参数）、外部输出、NDI 发送、虚拟摄像头开关与安装状态。
// 全部落在 MixerState.outputs（addOutput / removeOutput / setOutputSettings）；ISO = 一路 source = .input(n) 的录制输出
// （契约："ISO = 同一拍发多条 startRecord"；W3-C 做同拍起步）。契约没有"改名 / 改 enabled"的命令，改这两项 = 删掉再加回同编号（提案 012）。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class OutputSettingsModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case record, iso, stream, external, ndi, virtualCamera
        var id: String { rawValue }
        var title: String { L("outputSettings.tab.\(rawValue)") }
    }

    @Published var tab: Tab
    @Published private(set) var state: MixerState
    @Published private(set) var virtualCameraStatus: String = ""
    var send: ((Command) -> Void)?
    /// 新建录制输出的默认目录。
    let defaultRecordDirectory: String
    /// 节目名（示例文件名用）。
    var showName: String
    private let virtualCamera = VirtualCameraSupport()
    /// 测试宿主不去问系统扩展（没有扩展包，只会报错）。
    let queriesSystemExtensions: Bool

    init(state: MixerState, tab: Tab, defaultRecordDirectory: String, showName: String, queriesSystemExtensions: Bool) {
        self.state = state
        self.tab = tab
        self.defaultRecordDirectory = defaultRecordDirectory
        self.showName = showName
        self.queriesSystemExtensions = queriesSystemExtensions
        virtualCameraStatus = virtualCamera.status.text
        virtualCamera.onChange = { [weak self] s in self?.virtualCameraStatus = s.text }
    }

    func apply(state: MixerState) { self.state = state }

    static let videoCodecs: [VideoCodec] = [.h264, .hevc, .prores422, .prores422HQ, .prores4444]
    static let audioCodecs: [AudioCodec] = [.aac, .pcm]
    static let containers: [RecordContainer] = [.mov, .mp4]
    static let resolutionPresets: [(title: String, width: Int?, height: Int?)] = [
        (L("outputSettings.resolution.program"), nil, nil), ("1920×1080", 1920, 1080), ("1280×720", 1280, 720), ("3840×2160", 3840, 2160), ("854×480", 854, 480),
    ]

    func nextOutputNumber() -> Int { (state.outputs.map(\.number).max() ?? 0) + 1 }

    /// 改开关（提案 012 的 setOutputEnabled）：本地先改，再发命令。record / stream 走 startRecord / startStream，被 reducer 拒。
    private func setEnabled(_ number: Int, _ on: Bool) {
        guard let i = state.outputs.firstIndex(where: { $0.number == number }), state.outputs[i].enabled != on else { return }
        state.outputs[i].enabled = on
        send?(.setOutputEnabled(output: number, on: on))
    }

    /// 改设置：本地先改（表单立刻响应），再发 setOutputSettings。
    func updateOutput(_ number: Int, _ body: (inout OutputSettings) -> Void) {
        guard let i = state.outputs.firstIndex(where: { $0.number == number }) else { return }
        var settings = state.outputs[i].settings
        body(&settings)
        guard settings != state.outputs[i].settings else { return }
        state.outputs[i].settings = settings
        send?(.setOutputSettings(output: number, settings: settings))
    }

    func removeOutput(_ number: Int) {
        state.outputs.removeAll { $0.number == number }
        send?(.removeOutput(output: number))
    }

    /// 改名（提案 012 的 renameOutput）：不再删了重加，运行表不会看到"消失 → 再出现"。
    func rename(_ number: Int, _ name: String) {
        guard let i = state.outputs.firstIndex(where: { $0.number == number }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != state.outputs[i].name else { return }
        state.outputs[i].name = trimmed
        send?(.renameOutput(output: number, name: trimmed))
    }

    private func add(_ output: OutputState) {
        state.outputs.append(output)
        state.outputs.sort { $0.number < $1.number }
        send?(.addOutput(config: output))
    }

    // MARK: 录制（PGM 那一路）

    var recordOutput: OutputState? { state.outputs.first { $0.kind == .record && $0.settings.source == .program } }

    /// 没有录制输出就先加一个默认的（同底栏"录制"按钮）。
    func updateRecord(_ body: (inout OutputSettings) -> Void) {
        if recordOutput == nil {
            var o = ShowDocuments.emptyShow(recordDirectory: defaultRecordDirectory).outputs[0]
            o.number = nextOutputNumber()
            add(o)
        }
        guard let r = recordOutput else { return }
        updateOutput(r.number) { s in
            if s.video == nil { s.video = VideoEncodeSettings() }
            if s.audio == nil { s.audio = AudioEncodeSettings() }
            if s.record == nil { s.record = RecordSettings(directory: self.defaultRecordDirectory) }
            body(&s)
        }
    }

    /// 录制表单的绑定（读当前录制输出，没有就默认值）。
    func recordBinding<T>(_ keyPath: WritableKeyPath<OutputSettings, T>, default defaultValue: T) -> Binding<T> {
        Binding(get: { self.recordOutput?.settings[keyPath: keyPath] ?? defaultValue }, set: { v in self.updateRecord { $0[keyPath: keyPath] = v } })
    }

    /// 示例文件名。
    var recordExampleFileName: String {
        guard let r = recordOutput, let record = r.settings.record else { return "" }
        return record.outputURL(showName: showName, outputName: r.name).lastPathComponent
    }

    // MARK: ISO

    /// 已选 ISO 的输入编号。
    var isoInputs: Set<Int> {
        Set(state.outputs.compactMap { o -> Int? in
            guard o.kind == .record, case .input(let n) = o.settings.source else { return nil }
            return n
        })
    }

    func setISO(input: Int, on: Bool) {
        let existing = state.outputs.first { $0.kind == .record && $0.settings.source == .input(number: input) }
        if on {
            guard existing == nil else { return }
            let base = recordOutput?.settings
            let settings = OutputSettings(source: .input(number: input), video: base?.video ?? VideoEncodeSettings(), audio: base?.audio ?? AudioEncodeSettings(),
                                          record: base?.record ?? RecordSettings(directory: defaultRecordDirectory))
            add(OutputState(number: nextOutputNumber(), kind: .record, name: L("outputSettings.iso.name", input), enabled: false, settings: settings))
        } else if let existing {
            removeOutput(existing.number)
        }
    }

    // MARK: 推流

    var streamOutputs: [OutputState] { state.outputs.filter { $0.kind == .stream } }

    @discardableResult
    func addStream(url: String, key: String) -> Int {
        let n = nextOutputNumber()
        let settings = OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(), stream: StreamSettings(url: url, streamKey: key))
        add(OutputState(number: n, kind: .stream, name: L("outputSettings.stream.name", streamOutputs.count + 1), enabled: false, settings: settings))
        return n
    }

    func outputBinding<T>(_ number: Int, _ keyPath: WritableKeyPath<OutputSettings, T>, default defaultValue: T) -> Binding<T> {
        Binding(get: { self.state.output(number)?.settings[keyPath: keyPath] ?? defaultValue }, set: { v in self.updateOutput(number) { $0[keyPath: keyPath] = v } })
    }

    // MARK: 外部显示

    var externalOutputs: [OutputState] { state.outputs.filter { $0.kind == .externalDisplay } }

    @discardableResult
    func addExternalDisplay(screenNumber: UInt32, source: OutputSource) -> Int {
        let n = nextOutputNumber()
        let screenName = NSScreen.screen(number: screenNumber)?.localizedName ?? "\(screenNumber)"
        add(OutputState(number: n, kind: .externalDisplay, name: L("outputSettings.external.name", screenName), enabled: true,
                        // fallbackToMain 显式写 false：保持 G4 的行为（显示器不在就收起窗口等它回来）。
                        // 契约的默认是 true，面板上的开关归 W3-E2。
                        settings: OutputSettings(source: source, display: DisplayOutputSettings(displayID: screenNumber, fallbackToMain: false))))
        return n
    }

    func setExternalDisplay(_ number: Int, screenNumber: UInt32?, source: OutputSource?) {
        updateOutput(number) { s in
            if let screenNumber {
                var d = s.display ?? DisplayOutputSettings()
                d.displayID = screenNumber
                s.display = d
            }
            if let source { s.source = source }
        }
    }

    // MARK: NDI 发送

    var ndiOutputs: [OutputState] { state.outputs.filter { $0.kind == .ndi } }

    @discardableResult
    func addNDI(name: String, groups: String, conversion: String, source: OutputSource) -> Int {
        let n = nextOutputNumber()
        var extra: [String: JSONValue] = [OutputExtras.ndiConversion: .string(conversion)]
        if !groups.isEmpty { extra[OutputExtras.ndiGroups] = .string(groups) }
        add(OutputState(number: n, kind: .ndi, name: name, enabled: true, settings: OutputSettings(source: source, extra: extra)))
        return n
    }

    func setNDI(_ number: Int, groups: String? = nil, conversion: String? = nil, source: OutputSource? = nil) {
        updateOutput(number) { s in
            if let groups { s.extra[OutputExtras.ndiGroups] = groups.isEmpty ? nil : .string(groups) }
            if let conversion { s.extra[OutputExtras.ndiConversion] = .string(conversion) }
            if let source { s.source = source }
        }
    }

    // MARK: 虚拟摄像头

    var virtualCameraOutput: OutputState? { state.outputs.first { $0.kind == .virtualCamera } }

    func setVirtualCamera(enabled: Bool, source: OutputSource) {
        if let o = virtualCameraOutput {
            if o.settings.source != source { updateOutput(o.number) { $0.source = source } }
            setEnabled(o.number, enabled)
        } else {
            add(OutputState(number: nextOutputNumber(), kind: .virtualCamera, name: L("outputSettings.vcam.name"), enabled: enabled, settings: OutputSettings(source: source)))
        }
    }

    func refreshVirtualCameraStatus() {
        guard queriesSystemExtensions else { virtualCameraStatus = L("vcam.status.unavailableInTests"); return }
        virtualCamera.refresh()
    }
    func installVirtualCamera() {
        guard queriesSystemExtensions else { return }
        virtualCamera.install()
    }
    func uninstallVirtualCamera() {
        guard queriesSystemExtensions else { return }
        virtualCamera.uninstall()
    }

    /// 输出来源选项：PGM / PVW / 多画面 / 每路输入。
    var sourceChoices: [OutputSource] { [.program, .preview, .multiview] + state.inputs.map { .input(number: $0.number) } }
}

struct OutputSettingsView: View {
    @ObservedObject var model: OutputSettingsModel
    @State private var newStreamURL = ""
    @State private var newStreamKey = ""
    @State private var newNDIName = "Switcher"
    @State private var newExternalScreen: UInt32 = NSScreen.main?.displayNumber ?? 0
    @State private var newExternalSource: OutputSource = .program

    var body: some View {
        HStack(spacing: 0) {
            List(OutputSettingsModel.Tab.allCases, selection: tabSelection) { t in Text(t.title).tag(t) }
                .listStyle(.sidebar)
                .frame(width: 150)
                .accessibilityLabel(L("outputSettings.tabList"))
            Divider()
            Form { tabBody }.formStyle(.grouped)
        }
    }

    private var tabSelection: Binding<OutputSettingsModel.Tab?> {
        Binding(get: { model.tab }, set: { if let t = $0 { model.tab = t } })
    }

    @ViewBuilder
    private var tabBody: some View {
        switch model.tab {
        case .record: recordTab
        case .iso: isoTab
        case .stream: streamTab
        case .external: externalTab
        case .ndi: ndiTab
        case .virtualCamera: virtualCameraTab
        }
    }

    // MARK: 录制

    private var recordVideo: Binding<VideoEncodeSettings> {
        model.recordBinding(\.video, default: nil).map(get: { $0 ?? VideoEncodeSettings() }, set: { Optional($0) })
    }
    private var recordAudio: Binding<AudioEncodeSettings> {
        model.recordBinding(\.audio, default: nil).map(get: { $0 ?? AudioEncodeSettings() }, set: { Optional($0) })
    }
    private func video(of number: Int) -> Binding<VideoEncodeSettings> {
        model.outputBinding(number, \.video, default: nil).map(get: { $0 ?? VideoEncodeSettings() }, set: { Optional($0) })
    }
    private func audio(of number: Int) -> Binding<AudioEncodeSettings> {
        model.outputBinding(number, \.audio, default: nil).map(get: { $0 ?? AudioEncodeSettings() }, set: { Optional($0) })
    }
    private func stream(of number: Int) -> Binding<StreamSettings> {
        model.outputBinding(number, \.stream, default: nil).map(get: { $0 ?? StreamSettings(url: "") }, set: { Optional($0) })
    }

    private var recordTab: some View {
        Group {
            Section(L("outputSettings.record.format")) {
                Picker(L("outputSettings.codec"), selection: recordVideo.codec) {
                    ForEach(OutputSettingsModel.videoCodecs, id: \.self) { Text(L("codec.\($0.rawValue)")).tag($0) }
                }
                Picker(L("outputSettings.record.container"), selection: recordSettingsBinding.container) {
                    ForEach(OutputSettingsModel.containers, id: \.self) { Text($0 == .mov ? ".mov" : ".mp4").tag($0) }
                }
                resolutionPicker(recordVideo)
                bitrateField(recordVideo)
                Stepper(value: recordVideo.keyframeIntervalFrames, in: 1...600, step: 1) {
                    Text(L("outputSettings.keyframeInterval", model.recordOutput?.settings.video?.keyframeIntervalFrames ?? 120))
                }
                Picker(L("outputSettings.audioCodec"), selection: recordAudio.codec) {
                    ForEach(OutputSettingsModel.audioCodecs, id: \.self) { Text(L("codec.\($0.rawValue)")).tag($0) }
                }
                audioBitrateField(recordAudio)
            }
            Section(L("outputSettings.record.file")) {
                HStack {
                    TextField(L("outputSettings.record.directory"), text: recordSettingsBinding.directory)
                    Button(L("common.browse")) { chooseDirectory() }
                }
                TextField(L("outputSettings.record.fileNamePattern"), text: recordSettingsBinding.fileNamePattern)
                LabeledContent(L("outputSettings.record.example"), value: model.recordExampleFileName)
                Stepper(value: recordSettingsBinding.fragmentIntervalSeconds, in: 0.5...10, step: 0.5) {
                    Text(L("outputSettings.record.fragmentInterval", model.recordOutput?.settings.record?.fragmentIntervalSeconds ?? 1))
                }
                Toggle(L("outputSettings.record.remux"), isOn: recordSettingsBinding.remuxToMP4)
                Text(L("outputSettings.record.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recordSettingsBinding: Binding<RecordSettings> {
        let fallback = RecordSettings(directory: model.defaultRecordDirectory)
        return model.recordBinding(\.record, default: nil).map(get: { $0 ?? fallback }, set: { Optional($0) })
    }

    private func resolutionPicker(_ video: Binding<VideoEncodeSettings>) -> some View {
        let v = video.wrappedValue
        let index = OutputSettingsModel.resolutionPresets.firstIndex { $0.width == v.width && $0.height == v.height } ?? 0
        return Picker(L("outputSettings.resolution"), selection: Binding(get: { index }, set: { i in
            let p = OutputSettingsModel.resolutionPresets[max(0, min(i, OutputSettingsModel.resolutionPresets.count - 1))]
            var nv = video.wrappedValue
            nv.width = p.width
            nv.height = p.height
            video.wrappedValue = nv
        })) {
            ForEach(Array(OutputSettingsModel.resolutionPresets.enumerated()), id: \.offset) { i, p in Text(p.title).tag(i) }
        }
    }

    private func bitrateField(_ video: Binding<VideoEncodeSettings>) -> some View {
        TextField(L("outputSettings.bitrateKbps"), value: Binding(get: { video.wrappedValue.bitrateBps / 1000 }, set: { kbps in
            var nv = video.wrappedValue
            nv.bitrateBps = max(100, kbps) * 1000
            video.wrappedValue = nv
        }), format: .number)
    }

    private func audioBitrateField(_ audio: Binding<AudioEncodeSettings>) -> some View {
        TextField(L("outputSettings.audioBitrateKbps"), value: Binding(get: { audio.wrappedValue.bitrateBps / 1000 }, set: { kbps in
            var na = audio.wrappedValue
            na.bitrateBps = max(32, kbps) * 1000
            audio.wrappedValue = na
        }), format: .number)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.updateRecord { $0.record?.directory = url.path } }
    }

    // MARK: ISO

    private var isoTab: some View {
        Section(L("outputSettings.iso.title")) {
            Text(L("outputSettings.iso.hint")).font(.caption).foregroundStyle(.secondary)
            ForEach(model.state.inputs) { input in
                Toggle(L("outputSettings.iso.input", input.number, input.name), isOn: Binding(get: { model.isoInputs.contains(input.number) },
                                                                                                set: { model.setISO(input: input.number, on: $0) }))
            }
            if model.state.inputs.isEmpty { Text(L("outputSettings.iso.noInputs")).foregroundStyle(.secondary) }
        }
    }

    // MARK: 推流

    private var streamTab: some View {
        Group {
            ForEach(model.streamOutputs) { output in
                Section(L("outputSettings.stream.section", output.number, output.name)) {
                    TextField(L("outputSettings.stream.url"), text: stream(of: output.number).url)
                    SecureField(L("outputSettings.stream.key"), text: stream(of: output.number).streamKey)
                    Stepper(value: stream(of: output.number).reconnectMaxSeconds, in: 1...300, step: 1) {
                        Text(L("outputSettings.stream.reconnect", output.settings.stream?.reconnectMaxSeconds ?? 30))
                    }
                    Picker(L("outputSettings.codec"), selection: video(of: output.number).codec) {
                        ForEach([VideoCodec.h264, .hevc], id: \.self) { Text(L("codec.\($0.rawValue)")).tag($0) }
                    }
                    resolutionPicker(video(of: output.number))
                    bitrateField(video(of: output.number))
                    Stepper(value: video(of: output.number).keyframeIntervalFrames, in: 1...600) {
                        Text(L("outputSettings.keyframeInterval", output.settings.video?.keyframeIntervalFrames ?? 120))
                    }
                    audioBitrateField(audio(of: output.number))
                    Button(L("outputSettings.stream.remove")) { model.removeOutput(output.number) }
                }
            }
            Section(L("outputSettings.stream.add")) {
                TextField(L("outputSettings.stream.url"), text: $newStreamURL, prompt: Text(L("outputSettings.stream.urlPrompt")))
                SecureField(L("outputSettings.stream.key"), text: $newStreamKey)
                Button(L("outputSettings.stream.addButton")) {
                    guard !newStreamURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    model.addStream(url: newStreamURL.trimmingCharacters(in: .whitespaces), key: newStreamKey)
                    newStreamURL = ""
                    newStreamKey = ""
                }
                Text(L("outputSettings.stream.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 外部显示

    private var externalTab: some View {
        Group {
            ForEach(model.externalOutputs) { output in
                Section(L("outputSettings.external.section", output.number, output.name)) {
                    screenPicker(Binding(get: { OutputExtras.displayNumber(of: output) ?? 0 }, set: { model.setExternalDisplay(output.number, screenNumber: $0, source: nil) }))
                    sourcePicker(Binding(get: { output.settings.source }, set: { model.setExternalDisplay(output.number, screenNumber: nil, source: $0) }))
                    Button(L("outputSettings.external.close")) { model.removeOutput(output.number) }
                }
            }
            Section(L("outputSettings.external.add")) {
                screenPicker($newExternalScreen)
                sourcePicker($newExternalSource)
                Button(L("outputSettings.external.open")) { model.addExternalDisplay(screenNumber: newExternalScreen, source: newExternalSource) }
                Text(L("outputSettings.external.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func screenPicker(_ b: Binding<UInt32>) -> some View {
        Picker(L("outputSettings.external.screen"), selection: b) {
            ForEach(NSScreen.screens, id: \.displayNumber) { s in Text(s.displayTitle).tag(s.displayNumber ?? 0) }
        }
    }

    private func sourcePicker(_ b: Binding<OutputSource>) -> some View {
        Picker(L("outputSettings.source"), selection: b) {
            ForEach(model.sourceChoices, id: \.self) { Text($0.title(in: model.state)).tag($0) }
        }
    }

    // MARK: NDI

    private var ndiTab: some View {
        Group {
            ForEach(model.ndiOutputs) { output in
                Section(L("outputSettings.ndi.section", output.number, output.name)) {
                    sourcePicker(Binding(get: { output.settings.source }, set: { model.setNDI(output.number, source: $0) }))
                    TextField(L("outputSettings.ndi.groups"), text: Binding(get: { OutputExtras.string(output, OutputExtras.ndiGroups) ?? "" }, set: { model.setNDI(output.number, groups: $0) }))
                    Picker(L("outputSettings.ndi.conversion"), selection: Binding(get: { OutputExtras.string(output, OutputExtras.ndiConversion) ?? "auto" }, set: { model.setNDI(output.number, conversion: $0) })) {
                        ForEach(OutputExtras.ndiConversions, id: \.self) { Text(L("outputSettings.ndi.conversion.\($0)")).tag($0) }
                    }
                    Button(L("outputSettings.ndi.remove")) { model.removeOutput(output.number) }
                }
            }
            Section(L("outputSettings.ndi.add")) {
                TextField(L("outputSettings.ndi.name"), text: $newNDIName)
                Button(L("outputSettings.ndi.addButton")) {
                    guard !newNDIName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    model.addNDI(name: newNDIName.trimmingCharacters(in: .whitespaces), groups: "", conversion: "auto", source: .program)
                }
                Text(L("outputSettings.ndi.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 虚拟摄像头

    private var virtualCameraTab: some View {
        Section(L("outputSettings.vcam.title")) {
            Toggle(L("outputSettings.vcam.enabled"), isOn: Binding(get: { model.virtualCameraOutput?.enabled ?? false },
                                                                   set: { model.setVirtualCamera(enabled: $0, source: model.virtualCameraOutput?.settings.source ?? .program) }))
            sourcePicker(Binding(get: { model.virtualCameraOutput?.settings.source ?? .program },
                                 set: { model.setVirtualCamera(enabled: model.virtualCameraOutput?.enabled ?? false, source: $0) }))
            LabeledContent(L("outputSettings.vcam.status"), value: model.virtualCameraStatus)
            HStack {
                Button(L("outputSettings.vcam.check")) { model.refreshVirtualCameraStatus() }
                Button(L("outputSettings.vcam.install")) { model.installVirtualCamera() }
                Button(L("outputSettings.vcam.uninstall")) { model.uninstallVirtualCamera() }
            }
            LabeledContent(L("outputSettings.vcam.bundleID"), value: VirtualCameraSupport.extensionBundleID)
            Text(L("outputSettings.vcam.hint")).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if model.queriesSystemExtensions { model.refreshVirtualCameraStatus() } }
    }
}

extension Binding {
    /// 可选值 ↔ 非可选值的映射（表单里 nil 用默认值显示）。
    func map<T>(get: @escaping (Value) -> T, set: @escaping (T) -> Value) -> Binding<T> {
        Binding<T>(get: { get(self.wrappedValue) }, set: { self.wrappedValue = set($0) })
    }
}

@MainActor
final class OutputSettingsWindowController: PanelWindowController {
    let model: OutputSettingsModel

    init(model: OutputSettingsModel) {
        self.model = model
        super.init(title: L("outputSettings.windowTitle"), size: NSSize(width: 720, height: 560), autosaveName: "OutputSettings", content: OutputSettingsView(model: model))
    }

    func apply(state: MixerState) { model.apply(state: state) }
}
