// 输出设置窗各页的视图（W5-I，prompt 95）：输出总览（F8）、录制输出列表（K4 / K6–K8 / K10、V-15）、ISO 表（K9）、推流页（L3 / L5–L10 / L12）、
// 外部显示每屏单选（M2 / M5）、多画面格子编辑（M7）；每一节标题行带名字框（F9，renameOutput）。逻辑都在 OutputPagesModel.swift，这里只摆控件。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherRender
import SwitcherStreaming

// MARK: - 标题行（F9）

/// 一节的标题行："推流 1  输出 5" + 名字框（回车 / 离开输入框改名，renameOutput）。
struct OutputSectionHeader: View {
    @ObservedObject var model: OutputSettingsModel
    let output: OutputState
    let title: String
    let subtitle: String
    @State private var draft: String
    @FocusState private var focused: Bool

    init(model: OutputSettingsModel, output: OutputState, title: String, subtitle: String) {
        self.model = model
        self.output = output
        self.title = title
        self.subtitle = subtitle
        _draft = State(initialValue: output.name)
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { draft = output.name } else { model.rename(output.number, name) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Spacer()
            TextField(L("outputSettings.name"), text: $draft)
                .focused($focused)
                .onSubmit(commit)
                .frame(maxWidth: 220)
                .help(L("outputSettings.nameHelp"))
        }
        .onChange(of: focused) { old, new in if old, !new { commit() } }
        .onChange(of: output.name) { _, v in if !focused { draft = v } }
    }
}

/// 长路径：中间截断，完整路径放提示（V-15）。
struct PathText: View {
    let path: String
    var body: some View {
        Text(path).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
    }
}

@MainActor
enum OutputPageActions {
    /// 选目录（录制页 / ISO 页"更改目录…"）。
    static func chooseRecordDirectory(_ model: OutputSettingsModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.recordDirectory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { model.updateRecordFiles { $0.directory = url.path } }
    }
}

// MARK: - 输出总览（F8）

struct OutputOverviewPage: View {
    @ObservedObject var model: OutputSettingsModel

    var body: some View {
        Section(L("outputSettings.overview.title")) {
            let rows = model.overviewRows
            if rows.isEmpty {
                Text(L("outputSettings.overview.empty")).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["kind", "name", "source", "on", "status"], id: \.self) { c in
                            Text(L("outputSettings.overview.column.\(c)")).font(.caption).foregroundStyle(.secondary)
                        }
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.kindTitle)
                            Text(row.name).lineLimit(1)
                            Text(row.source).lineLimit(1)
                            Text(row.on ? L("outputSettings.overview.on") : L("outputSettings.overview.off"))
                                .foregroundStyle(row.on ? Color.primary : Color.secondary)
                            Text(row.status).lineLimit(1).truncationMode(.tail).help(row.status)
                            Button(L("outputSettings.overview.open")) { model.openDetail(row.number) }
                                .buttonStyle(.link)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.openDetail(row.number) }
                    }
                }
            }
            Text(L("outputSettings.overview.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 录制（K4 / K6–K8 / K10）

struct RecordPage: View {
    @ObservedObject var model: OutputSettingsModel

    private var files: Binding<RecordSettings> {
        Binding(get: { OutputLinkage.recordMaster(in: model.state)?.settings.record ?? RecordSettings(directory: model.defaultRecordDirectory) },
                set: { v in model.updateRecordFiles { $0 = v } })
    }

    var body: some View {
        Group {
            if let note = model.recordLiveNote {
                Section { Text(note).foregroundStyle(.orange) }
            }
            if let note = model.recordDeferredNote {
                Section { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                Text(model.recordPlanLine)
            }
            // 全部录制路共用的"文件"一节（K10）：改的是录制 1，其余录制路跟（在录的停了再跟）
            Section(L("outputSettings.record.fileShared")) {
                LabeledContent(L("outputSettings.record.directory")) {
                    HStack {
                        PathText(path: model.recordDirectory)
                        Button(L("outputSettings.record.chooseDirectory")) { OutputPageActions.chooseRecordDirectory(model) }
                    }
                }
                TextField(L("outputSettings.record.fileNamePattern"), text: files.fileNamePattern)
                LabeledContent(L("outputSettings.record.example"), value: model.recordExampleFileName)
                // 文件格式（W5-B，K5）：原来的"容器"与"停止后转 MP4"合成一个单选，只写 remuxToMP4
                Picker(L("outputSettings.record.fileFormat"), selection: Binding(get: { model.recordFileFormat }, set: { model.recordFileFormat = $0 })) {
                    ForEach(OutputSettingsModel.RecordFileFormat.allCases) { Text($0.title).tag($0) }
                }
                if let note = model.recordLegacyContainerNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: files.fragmentIntervalSeconds, in: 0.5...10, step: 0.5) {
                    Text(L("outputSettings.record.fragmentInterval", files.wrappedValue.fragmentIntervalSeconds))
                }
                Text(L("outputSettings.record.hint")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.recordList) { output in
                RecordOutputSection(model: model, output: output)
            }
            Section {
                Button(L("outputSettings.record.add")) { model.addRecordOutput() }
                Text(L("outputSettings.record.addHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 录制页的一路：参与录制、来源、自己的格式（编码）、状态、删除。
struct RecordOutputSection: View {
    @ObservedObject var model: OutputSettingsModel
    let output: OutputState

    private var number: Int { output.number }
    private var isMaster: Bool { OutputLinkage.recordMaster(in: model.state)?.number == number }

    var body: some View {
        let video = OutputSettingsView.video(of: number, in: model)
        let audio = OutputSettingsView.audio(of: number, in: model)
        Section {
            Toggle(L("outputSettings.record.armed"), isOn: Binding(get: { model.isRecordArmed(number) }, set: { model.setRecordArmed(number, on: $0) }))
                .help(L("outputSettings.record.armedHelp"))
            Picker(L("outputSettings.source"), selection: Binding(get: { output.settings.source }, set: { model.setRecordSource(number, $0) })) {
                ForEach(model.recordSourceChoices, id: \.self) { Text($0.title(in: model.state)).tag($0) }
            }
            if isMaster {
                Text(L("outputSettings.record.masterNote")).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("outputSettings.codec"), selection: video.codec) {
                ForEach(OutputSettingsModel.videoCodecs, id: \.self) { Text(L("codec.\($0.rawValue)")).tag($0) }
            }
            OutputSettingsView.resolutionPicker(video)
            OutputSettingsView.bitrateField(video)
            Stepper(value: video.keyframeIntervalFrames, in: 1...600, step: 1) {
                Text(L("outputSettings.keyframe.label", model.keyframeText(number)))
            }
            Picker(L("outputSettings.audioCodec"), selection: audio.codec) {
                ForEach(OutputSettingsModel.audioCodecs, id: \.self) { Text(L("codec.\($0.rawValue)")).tag($0) }
            }
            OutputSettingsView.audioBitrateField(audio)
            LabeledContent(L("outputSettings.record.status"), value: model.recordStatus(output: number))
            Button(L("outputSettings.record.remove")) { model.removeOutput(number) }
                .disabled(output.enabled)
                .help(output.enabled ? L("outputSettings.record.removeLocked") : "")
        } header: {
            OutputSectionHeader(model: model, output: output, title: model.recordTitle(number), subtitle: L("outputSettings.outputNumber", number))
        }
    }
}

// MARK: - ISO 表（K9 / K10）

struct ISOPage: View {
    @ObservedObject var model: OutputSettingsModel

    var body: some View {
        Group {
            Section {
                HStack {
                    Text(model.isoFormatLine)
                    Spacer()
                    Button(L("outputSettings.iso.changeFormat")) { model.tab = .record }
                }
                HStack {
                    Text(L("outputSettings.record.directory"))
                    PathText(path: model.recordDirectory)
                    Spacer()
                    Button(L("outputSettings.iso.changeDirectory")) { OutputPageActions.chooseRecordDirectory(model) }
                }
                if let note = model.recordDeferredNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Section(L("outputSettings.iso.title")) {
                let rows = model.isoRows
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["record", "name", "status", "dropped", "directory"], id: \.self) { c in
                            Text(L("outputSettings.iso.column.\(c)")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow {
                            Toggle(L("outputSettings.iso.column.record"), isOn: Binding(get: { row.checked }, set: { model.setISORow(row.id, on: $0) }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .accessibilityLabel(row.title)
                                .disabled(row.locked)
                                .help(row.locked ? L("outputSettings.iso.lockedHelp") : "")
                            Text(row.title).lineLimit(1)
                            Text(row.status).lineLimit(1)
                            Text(row.dropped).monospacedDigit()
                            PathText(path: row.directory.isEmpty ? "—" : row.directory).frame(maxWidth: 200, alignment: .leading)
                        }
                    }
                }
                if rows.count <= 1, model.state.inputs.isEmpty {
                    Text(L("outputSettings.iso.noInputs")).foregroundStyle(.secondary)
                }
                if model.isoHiddenInputCount > 0 || model.isoShowAllInputs {
                    Toggle(L("outputSettings.iso.showAll", model.isoHiddenInputCount), isOn: $model.isoShowAllInputs)
                }
                Text(model.isoEstimateText).font(.caption).foregroundStyle(.secondary)
                Text(L("outputSettings.iso.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 推流（L3 / L5–L10 / L12）

struct StreamPage: View {
    @ObservedObject var model: OutputSettingsModel
    @State private var newStreamURL = ""
    @State private var newStreamKey = ""

    var body: some View {
        Group {
            Section {
                HStack {
                    Button(L("outputSettings.stream.startAll")) { model.startAllStreams() }
                        .disabled(!model.streamOutputs.contains { !$0.enabled && model.canStartStream($0.number) })
                    Button(L("outputSettings.stream.stopAll")) { model.stopAllStreams() }
                        .disabled(!model.streamOutputs.contains(where: \.enabled))
                    Spacer()
                }
            }
            ForEach(model.streamOutputs) { output in
                StreamDestinationSection(model: model, output: output)
            }
            Section(L("outputSettings.stream.add")) {
                TextField(L("outputSettings.stream.url"), text: $newStreamURL, prompt: Text(L("outputSettings.stream.urlPrompt")))
                SecureField(L("outputSettings.stream.key"), text: $newStreamKey)
                Button(L("outputSettings.stream.addButton")) {
                    let url = newStreamURL.trimmingCharacters(in: .whitespaces)
                    model.addStream(url: url, key: newStreamKey)
                    newStreamURL = ""
                    newStreamKey = ""
                }
                Text(L("outputSettings.stream.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(model.totalUplinkText)
                Text(L("outputSettings.stream.totalUplinkHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 推流页的一个目的地。段首起停开关 + 状态行（L3）；在推的路地址 / 密钥 / 编码锁住并注明"停止后可改"、"删除"灰掉（W5-B，L12）；
/// 地址 / 密钥回车或失焦才提交，地址里的 user:pass@ 打码显示（L10）；起不来的写明原因、不锁，给"重试"与"停用这一路"（L13）。
struct StreamDestinationSection: View {
    @ObservedObject var model: OutputSettingsModel
    let output: OutputState
    @State private var draftURL: String
    @State private var draftKey: String
    @State private var showAuth = false
    @FocusState private var focus: Field?
    enum Field: Hashable { case url, key }

    init(model: OutputSettingsModel, output: OutputState) {
        self.model = model
        self.output = output
        _draftURL = State(initialValue: StreamAddress.masked(output.settings.stream?.url ?? ""))
        _draftKey = State(initialValue: output.settings.stream?.streamKey ?? "")
    }

    private var number: Int { output.number }
    private var locked: Bool { model.isStreamLocked(number) }
    private var savedURL: String { output.settings.stream?.url ?? "" }
    private var savedKey: String { output.settings.stream?.streamKey ?? "" }
    private var follows: Bool { model.streamFollowsFirst(number) }

    private func commit() {
        let url = StreamAddress.unmasked(draftURL.trimmingCharacters(in: .whitespaces), original: savedURL)
        guard !locked, url != savedURL || draftKey != savedKey else { return }
        model.commitStreamAddress(number, url: url, key: draftKey)
        draftURL = StreamAddress.masked(url)
    }

    private var authSummary: String {
        if StreamAddress.scheme(of: savedURL) == "srt" {
            return StreamAddress.srtPassphrase(of: savedURL).isEmpty ? L("outputSettings.stream.auth.none") : L("outputSettings.stream.auth.passphraseSet")
        }
        guard let c = model.streamCredentials(number) else { return L("outputSettings.stream.auth.none") }
        return L("outputSettings.stream.auth.userSet", c.user)
    }

    var body: some View {
        let video = OutputSettingsView.video(of: number, in: model)
        let audio = OutputSettingsView.audio(of: number, in: model)
        let stream = OutputSettingsView.stream(of: number, in: model)
        let service = model.streamService(number)
        Section {
            HStack {
                Toggle(L("outputSettings.stream.running"), isOn: Binding(get: { output.enabled }, set: { model.setStreamRunning(number, on: $0) }))
                    .toggleStyle(.switch)
                    .disabled(!output.enabled && !model.canStartStream(number))
                Text(model.streamStatusLine(output: number)).foregroundStyle(.secondary).lineLimit(1)
            }
            if output.enabled, model.failures[number] != nil {
                Text(L("outputSettings.stream.failedHint")).font(.caption).foregroundStyle(.red)
                HStack {
                    Button(L("outputSettings.stream.retry")) { model.retryStream(number) }
                    Button(L("outputSettings.stream.disable")) { model.disableStream(number) }
                }
            }
            if let note = model.streamLockNote(number) {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Picker(L("outputSettings.stream.service"), selection: Binding(get: { service.id }, set: { model.applyStreamService(number, id: $0) })) {
                ForEach(OutputSettingsModel.streamServices) { Text($0.title).tag($0.id) }
            }
            .disabled(locked)
            if !service.hintText.isEmpty {
                Text(service.hintText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Group {
                TextField(L("outputSettings.stream.url"), text: $draftURL)
                    .focused($focus, equals: .url).onSubmit(commit)
                SecureField(L("outputSettings.stream.key"), text: $draftKey)
                    .focused($focus, equals: .key).onSubmit(commit)
                HStack {
                    Text(authSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("outputSettings.stream.auth")) { showAuth = true }
                }
            }
            .disabled(locked)
            .help(locked ? L("outputSettings.stream.lockedHelp") : "")
            if !model.isStreamLeader(number) {
                Toggle(L("outputSettings.stream.followFirst"), isOn: Binding(get: { follows }, set: { model.setStreamFollowsFirst(number, on: $0) }))
                    .disabled(locked)
            }
            Picker(L("outputSettings.stream.quality"), selection: Binding(get: { model.streamQualityID(number) }, set: { model.applyStreamQuality(number, id: $0) })) {
                ForEach(StreamQualityTier.all) { Text($0.title(for: model.format)).tag($0.id) }
                Text(L("outputSettings.stream.quality.custom")).tag(OutputSettingsModel.customQualityID)
            }
            .disabled(locked || follows)
            DisclosureGroup(L("outputSettings.stream.encodeDetails"), isExpanded: Binding(get: { model.expandedEncodeDetails.contains(number) },
                                                                                       set: { if $0 { model.expandedEncodeDetails.insert(number) } else { model.expandedEncodeDetails.remove(number) } })) {
                Group {
                    Picker(L("outputSettings.codec"), selection: video.codec) {
                        ForEach([VideoCodec.h264, .hevc], id: \.self) { Text(L("codec.\($0.rawValue)")).tag($0) }
                    }
                    OutputSettingsView.resolutionPicker(video)
                    OutputSettingsView.bitrateField(video)
                    Stepper(value: Binding(get: { model.keyframeSeconds(number) }, set: { model.setKeyframeSeconds(number, $0) }), in: 0.5...10, step: 0.5) {
                        Text(L("outputSettings.keyframe.label", model.keyframeText(number)))
                    }
                    OutputSettingsView.audioBitrateField(audio)
                }
                .disabled(follows)
                Stepper(value: stream.reconnectMaxSeconds, in: 1...300, step: 1) {
                    Text(L("outputSettings.stream.reconnect", output.settings.stream?.reconnectMaxSeconds ?? 30))
                }
            }
            .disabled(locked)
            Button(L("outputSettings.stream.remove")) { model.removeOutput(number) }
                .disabled(locked)
                .help(locked ? L("outputSettings.stream.lockedHelp") : "")
        } header: {
            OutputSectionHeader(model: model, output: output, title: model.streamTitle(number), subtitle: model.streamSubtitle(number))
        }
        // 离开输入框 = 提交；别处（API / 另一个窗口）改了地址、而这一格没在编辑：草稿跟上
        .onChange(of: focus) { old, new in if old != nil, old != new { commit() } }
        .onChange(of: savedURL) { _, v in if focus != .url { draftURL = StreamAddress.masked(v) } }
        .onChange(of: savedKey) { _, v in if focus != .key { draftKey = v } }
        .sheet(isPresented: $showAuth) {
            StreamAuthSheet(model: model, number: number, isSRT: StreamAddress.scheme(of: savedURL) == "srt", isPresented: $showAuth)
        }
    }
}

/// "鉴权…"：RTMP / RTMPS 写地址的 user:pass@（Adobe 鉴权），SRT 写 passphrase。
struct StreamAuthSheet: View {
    @ObservedObject var model: OutputSettingsModel
    let number: Int
    let isSRT: Bool
    @Binding var isPresented: Bool
    @State private var user = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSRT ? L("outputSettings.stream.auth.srtTitle") : L("outputSettings.stream.auth.title")).font(.headline)
            Form {
                if !isSRT {
                    TextField(L("outputSettings.stream.auth.user"), text: $user)
                    SecureField(L("outputSettings.stream.auth.password"), text: $password)
                } else {
                    SecureField(L("outputSettings.stream.auth.passphrase"), text: $password)
                }
            }
            Text(isSRT ? L("outputSettings.stream.auth.srtHint") : L("outputSettings.stream.auth.hint"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L("outputSettings.stream.auth.clear")) {
                    user = ""
                    password = ""
                }
                Spacer()
                Button(L("common.cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(L("outputSettings.stream.auth.save")) {
                    error = model.setStreamAuth(number, user: user, password: password)
                    if error == nil { isPresented = false }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let url = model.state.output(number)?.settings.stream?.url else { return }
            if isSRT {
                password = StreamAddress.srtPassphrase(of: url)
            } else if let c = model.streamCredentials(number) {
                user = c.user
                password = c.password
            }
        }
    }
}

// MARK: - 外部显示（M2 / M5：每块屏单选，与底栏菜单同一份数据）

struct ExternalDisplayPage: View {
    @ObservedObject var model: OutputSettingsModel

    private static func tag(_ source: OutputSource?) -> String {
        switch source {
        case nil: "off"
        case .program?: "program"
        case .preview?: "preview"
        case .multiview?: "multiview"
        case .input(let n)?: "input-\(n)"
        }
    }

    private func source(from tag: String) -> OutputSource? {
        ExternalDisplayRouting.sources(in: model.state).first { Self.tag($0) == tag }
    }

    var body: some View {
        Group {
            Section(L("outputSettings.external.screens")) {
                let rows = model.screenRows
                if rows.isEmpty { Text(L("externalMenu.noDisplays")).foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    Picker(L("outputSettings.external.screenPicker", row.title), selection: Binding(get: { Self.tag(row.source) },
                                                                                               set: { model.pickScreen(row.id, source: source(from: $0)) })) {
                        Text(L("outputSettings.external.off")).tag("off")
                        ForEach(ExternalDisplayRouting.sources(in: model.state), id: \.self) { s in Text(s.title(in: model.state)).tag(Self.tag(s)) }
                    }
                }
                Text(L("outputSettings.external.screensHint")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.externalOutputs) { output in
                ExternalOutputSection(model: model, output: output)
            }
        }
    }
}

/// 一路外部显示输出的细项：开关、显示器、来源、退回主屏、状态、删除。
struct ExternalOutputSection: View {
    @ObservedObject var model: OutputSettingsModel
    let output: OutputState

    var body: some View {
        Section {
            Toggle(L("outputSettings.external.enabled"), isOn: Binding(get: { output.enabled }, set: { model.setOutputEnabled(output.number, on: $0) }))
            Picker(L("outputSettings.external.screen"), selection: Binding(get: { OutputExtras.displayNumber(of: output) ?? 0 },
                                                                          set: { model.setExternalDisplay(output.number, screenNumber: $0, source: nil) })) {
                ForEach(model.screenChoices(including: OutputExtras.displayNumber(of: output)), id: \.id) { c in Text(c.title).tag(c.id) }
            }
            Picker(L("outputSettings.source"), selection: Binding(get: { output.settings.source }, set: { model.setExternalDisplay(output.number, screenNumber: nil, source: $0) })) {
                ForEach(model.sourceChoices, id: \.self) { Text($0.title(in: model.state)).tag($0) }
            }
            if let note = model.sourceNote(for: output.settings.source) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L("outputSettings.external.fallbackToMain"), isOn: Binding(get: { output.settings.display?.fallbackToMain ?? false },
                                                                               set: { model.setExternalFallback(output.number, on: $0) }))
                .help(L("outputSettings.external.fallbackHelp"))
            LabeledContent(L("outputSettings.external.status"), value: model.displayStatus(output: output.number, kind: "externalDisplay") ?? "—")
            Button(L("outputSettings.external.close")) { model.removeOutput(output.number) }
        } header: {
            OutputSectionHeader(model: model, output: output, title: L("outputSettings.external.title"), subtitle: L("outputSettings.outputNumber", output.number))
        }
    }
}

// MARK: - 多画面布局（M7：格子编辑）

struct MultiviewPage: View {
    @ObservedObject var model: OutputSettingsModel

    var body: some View {
        let layout = model.multiviewLayout
        Group {
            Section {
                Picker(L("outputSettings.multiview.preset"), selection: Binding(get: { layout.preset }, set: { model.setMultiviewPreset($0) })) {
                    ForEach(MultiviewLayout.presetNames, id: \.self) { Text(L("outputSettings.multiview.preset.\($0)")).tag($0) }
                }
                .disabled(!layout.custom.isEmpty)
                Toggle(L("outputSettings.multiview.safeArea"), isOn: Binding(get: { layout.safeArea }, set: { model.setMultiviewSafeArea($0) }))
                Toggle(L("outputSettings.multiview.meters"), isOn: Binding(get: { layout.meters }, set: { model.setMultiviewMeters($0) }))
                Text(L("outputSettings.multiview.hint")).font(.caption).foregroundStyle(.secondary)
            } header: {
                if let o = model.multiviewOutput {
                    OutputSectionHeader(model: model, output: o, title: L("outputSettings.multiview.title"), subtitle: L("outputSettings.outputNumber", o.number))
                } else {
                    Text(L("outputSettings.multiview.title"))
                }
            }
            Section(L("outputSettings.multiview.cells")) {
                if layout.custom.isEmpty {
                    Text(L("outputSettings.multiview.noCustom")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L("outputSettings.multiview.convert")) { model.convertMultiviewPresetToCustom() }
                        Button(L("outputSettings.multiview.addCell")) { model.addMultiviewCell() }
                    }
                } else {
                    Text(L("outputSettings.multiview.customActive", layout.custom.count)).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(layout.custom.enumerated()), id: \.offset) { index, cell in
                        MultiviewCellRow(model: model, index: index, cell: cell)
                    }
                    HStack {
                        Button(L("outputSettings.multiview.addCell")) { model.addMultiviewCell() }
                        Button(L("outputSettings.multiview.clearCustom")) { model.clearMultiviewCustomCells() }
                    }
                }
            }
        }
    }
}

/// 一个自定义格子：来源 + x / y / w / h（归一化 0–1）+ 删除。
struct MultiviewCellRow: View {
    @ObservedObject var model: OutputSettingsModel
    let index: Int
    let cell: MultiviewCell

    private func field(_ key: String, _ value: Double, _ set: @escaping @MainActor @Sendable (Double) -> Void) -> some View {
        TextField(L(key), value: Binding(get: { value }, set: { v in MainActor.assumeIsolated { set(v) } }), format: .number.precision(.fractionLength(0...3)))
            .frame(width: 64)
            .help(L("outputSettings.multiview.cellRectHelp"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker(L("outputSettings.multiview.cellSource", index + 1), selection: Binding(get: { cell.source }, set: { model.setMultiviewCell(at: index, source: $0) })) {
                    ForEach(model.multiviewCellSources, id: \.self) { Text($0.title(in: model.state)).tag($0) }
                }
                Button(L("outputSettings.multiview.removeCell")) { model.removeMultiviewCell(at: index) }
            }
            HStack {
                field("outputSettings.multiview.x", cell.rect.x) { model.setMultiviewCell(at: index, x: $0) }
                field("outputSettings.multiview.y", cell.rect.y) { model.setMultiviewCell(at: index, y: $0) }
                field("outputSettings.multiview.w", cell.rect.width) { model.setMultiviewCell(at: index, width: $0) }
                field("outputSettings.multiview.h", cell.rect.height) { model.setMultiviewCell(at: index, height: $0) }
            }
        }
    }
}
