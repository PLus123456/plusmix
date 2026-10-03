// 添加输入（W3-E 完整版）：左边八种类型（设计方案 §6：摄像头 / 采集卡、DeckLink、屏幕 / 窗口 / 应用、视频文件、图片、NDI、
// 纯音频设备、合成测试源），右边各自的参数页，底部编号 + 名字 + 确定。SwiftUI 表单放 NSHostingView 的 sheet 里。
// 只产生 InputConfig 并发 addInput 命令；运行实现由 InputFactory 接。
// W3-E2：DeckLink 页列设备（DeckLinkDevices）、选输入接口（卡支持的）与内嵌音频取哪两路；NDI 页发现源、选带宽模式 / 抖动缓冲 0–2 帧（提案 008）；
// 纯音频页用 SwitcherInputs.AudioInputDevices 列设备（第一项"系统默认输入" = 空串 uid，插拔时刷新），设备声道 > 2 时选取哪几路（提案 014）。
// 每种类型的参数页抽成 InputSourceFormView，输入设置窗的"来源"一节复用它（setInputSource，提案 012）。
// W5-B（02 X22）：编号用满时"添加"置灰并写明"本节目的输入已满（n 路）"，确定不加、面板不关（原来面板照关、命令被拒、只在底栏闪 4 秒）。
import AppKit
import AVFoundation
import SwiftUI
import SwitcherContracts
import SwitcherInputs
import SwitcherDeckLink
import SwitcherNDI

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
        init(_ kind: InputKind) {
            self = Self.allCases.first { $0.inputKind == kind } ?? .synthetic
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
    // DeckLink（提案 008 / 014）：空串 = 第一台有输入的卡；接口 nil = 不改卡上的当前设置；声道空 = 内嵌音频前两路
    var decklinkDeviceID = ""
    var decklinkConnection: SwitcherContracts.DeckLinkConnection?
    var decklinkChannels: [Int] = []
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
    /// 图片页多选（W5-H G14；红灯轮：只给签名）。
    static let imagePanelAllowsMultipleSelection = false
    mutating func setImagePaths(_ paths: [String]) { imagePath = paths.first ?? "" }
    var imageSelectionSummary: String { "" }
    // NDI（提案 008）
    var ndiSourceName = ""
    var ndiBandwidth: NDIBandwidth = .highest
    var ndiJitterBufferFrames = InputSource.defaultNDIJitterBufferFrames
    // 纯音频设备（W2-A2 / 提案 014）：空串 uid = 跟随系统默认输入；声道空 = 前两路
    var audioDeviceUID = ""
    var audioChannels: [Int] = []

    static let syntheticSizes: [(title: String, width: Int, height: Int)] = [("1920×1080", 1920, 1080), ("1280×720", 1280, 720), ("3840×2160", 3840, 2160)]
    static let syntheticRates: [FrameRate] = [.fps30, .fps5994, .fps60]
    static let screenRates: [FrameRate] = [.fps24, .fps25, .fps30, .fps50, .fps5994, .fps60]
    static let fileEndActions: [FileEndAction] = [.loop, .holdLastFrame, .black]

    init() {}

    /// 从现有来源填回表单（输入设置窗"来源"一节：改完 makeConfig 出来的来源与原来逐字段相同）。
    init(source: InputSource) {
        kind = Kind(source.kind)
        switch source {
        case .camera(let id): cameraUniqueID = id
        case .decklink(let id, let connection, let channels):
            decklinkDeviceID = id
            decklinkConnection = connection
            decklinkChannels = channels
        case .screen(let target, let rate, let audio):
            switch target {
            case .display(let id): screenKind = .display; displayID = id
            case .window(let id): screenKind = .window; windowID = id
            case .application(let b): screenKind = .application; applicationBundleID = b
            }
            screenFrameRate = rate
            captureAudio = audio
        case .file(let path, let end, let rate):
            filePath = path
            fileEndAction = end
            fileRate = rate
        case .image(let path): imagePath = path
        case .ndi(let name, let bandwidth, let jitter):
            ndiSourceName = name
            ndiBandwidth = bandwidth
            ndiJitterBufferFrames = jitter
        case .audio(let uid, let channels):
            audioDeviceUID = uid
            audioChannels = channels
        case .synthetic(let s):
            syntheticFrameRate = s.frameRate
            syntheticWidth = s.width
            syntheticHeight = s.height
            switch s.background {
            case .gray(let level): syntheticBackground = .gray; syntheticGray = level
            case .gradient: syntheticBackground = .gradient
            case .noise(let level, let amplitude, let seed):
                syntheticBackground = .noise
                syntheticGray = level
                noiseAmplitude = amplitude
                noiseSeed = Int(clamping: seed)
            }
            patternID = s.patternID
            jitterMs = s.jitterMs
            dropEveryN = s.dropEveryN
            clockDriftPpm = s.clockDriftPpm
            syntheticAudio = s.audio
            audioDriftPpm = s.audioDriftPpm
        }
    }

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

    /// 只出来源（输入设置窗换来源用）。
    func makeSource() throws -> InputSource {
        switch kind {
        case .synthetic:
            let background: TestPattern.Background
            switch syntheticBackground {
            case .gray: background = .gray(level: syntheticGray)
            case .gradient: background = .gradient
            case .noise: background = .noise(level: syntheticGray, amplitude: noiseAmplitude, seed: UInt64(max(0, noiseSeed)))
            }
            return .synthetic(settings: SyntheticSourceSettings(frameRate: syntheticFrameRate, width: syntheticWidth, height: syntheticHeight,
                                                                background: background, patternID: patternID, jitterMs: jitterMs, dropEveryN: dropEveryN,
                                                                clockDriftPpm: clockDriftPpm, audio: syntheticAudio, audioDriftPpm: audioDriftPpm))
        case .camera:
            guard let id = cameraUniqueID, !id.isEmpty else { throw ModelError.missing(L("addInput.field.camera")) }
            return .camera(uniqueID: id)
        case .decklink:
            return .decklink(deviceID: decklinkDeviceID.trimmingCharacters(in: .whitespaces), connection: decklinkConnection, channels: decklinkChannels)
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
            return .screen(target: target, frameRate: screenFrameRate, captureAudio: captureAudio)
        case .file:
            guard !filePath.isEmpty else { throw ModelError.missing(L("addInput.field.filePath")) }
            return .file(path: filePath, endAction: fileEndAction, rate: fileRate > 0 ? fileRate : 1)
        case .image:
            guard !imagePath.isEmpty else { throw ModelError.missing(L("addInput.field.imagePath")) }
            return .image(path: imagePath)
        case .ndi:
            let name = ndiSourceName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ModelError.missing(L("addInput.field.ndi")) }
            let jitter = min(max(ndiJitterBufferFrames, InputSource.ndiJitterBufferRange.lowerBound), InputSource.ndiJitterBufferRange.upperBound)
            return .ndi(sourceName: name, bandwidth: ndiBandwidth, jitterBufferFrames: jitter)
        case .audio:
            return .audio(deviceUID: audioDeviceUID, channels: audioChannels)
        }
    }

    func makeConfig() throws -> InputConfig {
        let source = try makeSource()
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
}

/// 声道映射（提案 014）的表单口径：前两路（空）/ 选两路（左、右）/ 单声道一路（两个声道都取它）。值是源的声道下标（从 0 起），界面上显示从 1 起。
struct ChannelMapChoice: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case firstTwo, pair, mono
        var id: String { rawValue }
        var title: String { L("addInput.channels.mode.\(rawValue)") }
    }
    var mode: Mode
    var left: Int
    var right: Int

    init(channels: [Int]) {
        switch channels.count {
        case 0: mode = .firstTwo; left = 0; right = 1
        case 1: mode = .mono; left = channels[0]; right = channels[0]
        default: mode = .pair; left = channels[0]; right = channels[1]
        }
    }

    var channels: [Int] {
        switch mode {
        case .firstTwo: []
        case .pair: [left, right]
        case .mono: [left]
        }
    }

    /// 摘要："第 5、6 路" / "第 5 路（单声道）"；空（前两路）为空串。
    static func summary(_ channels: [Int]) -> String {
        switch channels.count {
        case 0: ""
        case 1: L("channels.summary.mono", channels[0] + 1)
        default: L("channels.summary.pair", channels[0] + 1, channels[1] + 1)
        }
    }
}

/// 一个可选项（设备 / 窗口 / 应用）。
struct AddInputChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 表单的可观察模型：设备列表 + 表单值 + 错误。添加输入用 init(state:maxInputs:)，输入设置窗的"来源"一节用 init(editing:)。
@MainActor
final class AddInputFormModel: ObservableObject {
    @Published var model: AddInputModel
    @Published var errorMessage = ""
    @Published private(set) var cameras: [AddInputChoice] = []
    @Published private(set) var displays: [AddInputChoice] = []
    @Published private(set) var windows: [AddInputChoice] = []
    @Published private(set) var applications: [AddInputChoice] = []
    /// 纯音频设备：第一项"系统默认输入"（空串 uid）。
    @Published private(set) var audioDevices: [AddInputChoice] = []
    /// DeckLink：第一项"第一台有输入的卡"（空串）。
    @Published private(set) var decklinkDevices: [AddInputChoice] = []
    /// 网络上发现的 NDI 源名。
    @Published private(set) var ndiSources: [String] = []
    @Published private(set) var screenListStatus = ""
    @Published private(set) var ndiStatus = ""
    let freeNumbers: [Int]
    /// 这个节目最多几路（引擎的 maxInputs）。
    let maxInputs: Int
    /// 编号用满了（添加输入时没有空号；输入设置窗的"来源"一节永远有自己那个号）。
    var isFull: Bool { freeNumbers.isEmpty }
    var canAdd: Bool { !isFull }
    var fullMessage: String { L("addInput.full", maxInputs) }
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    private var audioInfos: [String: AudioInputDeviceInfo] = [:]
    private var decklinkInfos: [String: DeckLinkDeviceInfo] = [:]
    private var audioSubscription: AudioInputDevices.Subscription?
    private var ndiSearching = false

    /// 添加输入：默认编号 = 最小空闲编号。
    convenience init(state: MixerState, maxInputs: Int) {
        var m = AddInputModel()
        m.number = AddInputModel.nextFreeNumber(in: state, maxInputs: maxInputs)
        let used = Set(state.inputs.map(\.number))
        self.init(model: m, freeNumbers: (1...max(1, maxInputs)).filter { !used.contains($0) }, maxInputs: maxInputs)
        model.cameraUniqueID = cameras.first?.id
        model.displayID = AddInputModel.displays().first?.id
    }

    /// 输入设置窗"来源"一节：表单填现有来源。
    convenience init(editing config: InputConfig) {
        var m = AddInputModel(source: config.source)
        m.number = config.number
        m.name = config.name
        self.init(model: m, freeNumbers: [config.number], maxInputs: max(config.number, 1))
        if model.cameraUniqueID == nil { model.cameraUniqueID = cameras.first?.id }
        if model.displayID == nil { model.displayID = AddInputModel.displays().first?.id }
    }

    private init(model: AddInputModel, freeNumbers: [Int], maxInputs: Int) {
        self.model = model
        self.freeNumbers = freeNumbers
        self.maxInputs = maxInputs
        cameras = AddInputModel.cameras().map { AddInputChoice(id: $0.id, title: $0.name) }
        displays = AddInputModel.displays().map { AddInputChoice(id: String($0.id), title: $0.name) }
        reloadAudioDevices()
        // 插拔 / 系统默认输入变了：重新列（回调在主队列上；关表单时 close() 摘掉）
        audioSubscription = AudioInputDevices.observeChanges(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.reloadAudioDevices() }
        }
        let cards = DeckLinkDevices.list().filter(\.hasInput)
        decklinkInfos = Dictionary(cards.map { ($0.persistentID, $0) }, uniquingKeysWith: { a, _ in a })
        decklinkDevices = [AddInputChoice(id: "", title: L("addInput.decklink.firstCard"))]
            + cards.map { AddInputChoice(id: $0.persistentID, title: L("addInput.decklink.device", $0.displayName, $0.inputConnections.names.joined(separator: " / "))) }
    }

    /// 摘掉设备插拔订阅（sheet / 输入设置窗关掉时调；重复调无害）。
    func close() {
        audioSubscription?.stop()
        audioSubscription = nil
    }

    var isObservingAudioDevices: Bool { audioSubscription != nil }

    /// 重新列纯音频设备（有输入声道的）。第一项"系统默认输入"= 空串 uid（W2-A2：跟随系统设置，换了默认输入会自动重建）。
    func reloadAudioDevices() {
        let list = AudioInputDevices.list().filter { $0.inputChannels > 0 }
        audioInfos = Dictionary(list.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        audioDevices = [AddInputChoice(id: "", title: L("addInput.audio.systemDefault"))]
            + list.map { d in
                AddInputChoice(id: d.uid, title: L("addInput.audio.device.line", d.name, d.inputChannels, d.supports48k ? "48 kHz" : L("addInput.audio.no48k"), d.transportType))
            }
    }

    /// 某个音频设备的输入声道数（空串 = 系统默认输入那台；不知道为 0）。
    func audioChannelCount(for uid: String) -> Int {
        if uid.isEmpty {
            guard let d = audioInfos.values.first(where: \.isDefaultInput) else { return 0 }
            return d.inputChannels
        }
        return audioInfos[uid]?.inputChannels ?? 0
    }

    /// 选中的音频设备的一行说明（默认输入是哪台 / 48 kHz / 传输类型）。
    func audioDeviceDetail(for uid: String) -> String {
        let info = uid.isEmpty ? audioInfos.values.first(where: \.isDefaultInput) : audioInfos[uid]
        guard let d = info else { return uid.isEmpty ? "" : L("addInput.audio.missing", uid) }
        // 两行：名字（连接方式）/ 声道与采样率；连接方式是 CoreAudio 的四字码（"bltn"），翻成人话，不认识的不写（V-14 / V-16）
        let rate = d.supports48k ? "48 kHz" : L("addInput.audio.no48k")
        let base = AudioTransportName.title(fourCC: d.transportType).map { L("addInput.audio.detail", d.name, $0, d.inputChannels, rate) }
            ?? L("addInput.audio.detailNoTransport", d.name, d.inputChannels, rate)
        return uid.isEmpty ? L("addInput.audio.followsDefault", base) : base
    }

    /// DeckLink 某张卡能选的输入接口（卡报的位集）；卡不在（没装驱动 / 手填的 ID）就列全部，卡上不支持的由卡自己拒。
    func decklinkConnections(for id: String) -> [SwitcherContracts.DeckLinkConnection] {
        let info = id.isEmpty ? decklinkInfos.values.sorted { $0.index < $1.index }.first : decklinkInfos[id]
        guard let supported = info?.inputConnections.supported, !supported.isEmpty else { return SwitcherContracts.DeckLinkConnection.allCases }
        return supported
    }

    /// DeckLink 内嵌音频路数（卡不告诉你有几路有信号，给 1–16 让用户选；DeckLinkInput 按映射自动开 2 / 8 / 16 路）。
    let decklinkChannelCount = 16

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

    /// 在网络上找 NDI 源（mDNS 最多等 1.5 s，放后台线程；SDK 没编进来 / 没装运行时就说明一句，照样能手填源名）。
    func loadNDISources() {
        guard !ndiSearching else { return }
        ndiSearching = true
        ndiStatus = L("addInput.ndi.searching")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[String], any Error> = Result { try NDIFinder.discover(timeoutMs: 1500).map(\.name) }
            await MainActor.run {
                guard let self else { return }
                self.ndiSearching = false
                switch result {
                case .success(let names):
                    self.ndiSources = names.sorted()
                    self.ndiStatus = names.isEmpty ? L("addInput.ndi.noneFound") : L("addInput.ndi.found", names.count)
                case .failure(let error):
                    self.ndiStatus = L("addInput.ndi.unavailable", "\(error)")
                }
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

/// 声道映射的三段式选择（提案 014）。channelCount = 源的声道数（纯音频设备报的；DeckLink 给 16）。
struct ChannelMapPicker: View {
    let channelCount: Int
    @Binding var channels: [Int]

    var body: some View {
        let choice = ChannelMapChoice(channels: channels)
        Picker(L("addInput.channels.mode"), selection: Binding(get: { choice.mode }, set: { var c = choice; c.mode = $0; channels = c.channels })) {
            ForEach(ChannelMapChoice.Mode.allCases) { Text($0.title).tag($0) }
        }
        switch choice.mode {
        case .firstTwo:
            EmptyView()
        case .pair:
            Picker(L("addInput.channels.left"), selection: Binding(get: { choice.left }, set: { var c = choice; c.left = $0; channels = c.channels })) { options }
            Picker(L("addInput.channels.right"), selection: Binding(get: { choice.right }, set: { var c = choice; c.right = $0; channels = c.channels })) { options }
        case .mono:
            Picker(L("addInput.channels.mono"), selection: Binding(get: { choice.left }, set: { var c = choice; c.left = $0; channels = c.channels })) { options }
        }
    }

    private var options: some View {
        ForEach(0..<max(channelCount, (channels.max() ?? 0) + 1), id: \.self) { Text(L("addInput.channels.number", $0 + 1)).tag($0) }
    }
}

/// 每种输入类型的参数页（Add Input sheet 与输入设置窗的"来源"一节共用）。放在 Form 里。
struct InputSourceFormView: View {
    @ObservedObject var form: AddInputFormModel

    var body: some View {
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
                ForEach(AddInputModel.syntheticRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
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
            Picker(L("addInput.decklink.card"), selection: $form.model.decklinkDeviceID) {
                ForEach(form.decklinkDevices) { Text($0.title).tag($0.id) }
                if !form.decklinkDevices.contains(where: { $0.id == form.model.decklinkDeviceID }) {
                    Text(form.model.decklinkDeviceID).tag(form.model.decklinkDeviceID)
                }
            }
            TextField(L("addInput.decklink.deviceID"), text: $form.model.decklinkDeviceID, prompt: Text(L("addInput.decklink.deviceIDPrompt")))
            Picker(L("addInput.decklink.connection"), selection: Binding(get: { form.model.decklinkConnection?.rawValue ?? "" },
                                                                          set: { form.model.decklinkConnection = SwitcherContracts.DeckLinkConnection(rawValue: $0) })) {
                Text(L("addInput.decklink.connection.keep")).tag("")
                ForEach(form.decklinkConnections(for: form.model.decklinkDeviceID), id: \.self) { Text(L("decklink.connection.\($0.rawValue)")).tag($0.rawValue) }
            }
            ChannelMapPicker(channelCount: form.decklinkChannelCount, channels: $form.model.decklinkChannels)
            Text(form.decklinkDevices.count > 1 ? L("addInput.decklink.hint") : L("addInput.decklink.noCards")).font(.caption).foregroundStyle(.secondary)
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
                ForEach(AddInputModel.screenRates, id: \.self) { Text(verbatim: "\($0)").tag(FrameRate?.some($0)) }
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
                TextField(L("addInput.file.path"), text: $form.model.filePath, prompt: Text(L("addInput.path.none")))   // 空着时有占位（V-17）
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
                TextField(L("addInput.image.path"), text: $form.model.imagePath, prompt: Text(L("addInput.path.none")))
                Button(L("common.browse")) { browse(image: true) }
            }
            Text(L("addInput.image.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ndiForm: some View {
        Section(L("addInput.ndi.title")) {
            if !form.ndiSources.isEmpty {
                Picker(L("addInput.ndi.found.picker"), selection: $form.model.ndiSourceName) {
                    ForEach(form.ndiSources, id: \.self) { Text($0).tag($0) }
                    if !form.ndiSources.contains(form.model.ndiSourceName) { Text(form.model.ndiSourceName).tag(form.model.ndiSourceName) }
                }
            }
            TextField(L("addInput.ndi.sourceName"), text: $form.model.ndiSourceName, prompt: Text(L("addInput.ndi.sourcePrompt")))
            HStack {
                Text(form.ndiStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("addInput.ndi.refresh")) { form.loadNDISources() }
            }
            Picker(L("addInput.ndi.bandwidth"), selection: $form.model.ndiBandwidth) {
                ForEach(NDIBandwidth.allCases, id: \.self) { Text(L("ndi.bandwidth.\($0.rawValue)")).tag($0) }
            }
            Stepper(value: $form.model.ndiJitterBufferFrames, in: InputSource.ndiJitterBufferRange) {
                Text(L("addInput.ndi.jitter", form.model.ndiJitterBufferFrames))
            }
            Text(L("addInput.ndi.hint")).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if form.ndiSources.isEmpty { form.loadNDISources() } }
    }

    private var audioForm: some View {
        Section(L("addInput.audio.title")) {
            Picker(L("addInput.audio.device"), selection: $form.model.audioDeviceUID) {
                ForEach(form.audioDevices) { Text($0.title).tag($0.id) }
                if !form.audioDevices.contains(where: { $0.id == form.model.audioDeviceUID }) {
                    Text(L("addInput.audio.missing", form.model.audioDeviceUID)).tag(form.model.audioDeviceUID)
                }
            }
            Text(form.audioDeviceDetail(for: form.model.audioDeviceUID)).font(.caption).foregroundStyle(.secondary)
            // 提案 014：设备输入声道 > 2（多路接口 / 小调音台）才问取第几路；已经设过映射的也显示（好改回去）
            if form.audioChannelCount(for: form.model.audioDeviceUID) > 2 || !form.model.audioChannels.isEmpty {
                ChannelMapPicker(channelCount: form.audioChannelCount(for: form.model.audioDeviceUID), channels: $form.model.audioChannels)
            }
            Text(form.audioDevices.count > 1 ? L("addInput.audio.hint") : L("addInput.audio.none")).font(.caption).foregroundStyle(.secondary)
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
                Form { InputSourceFormView(form: form) }
                    .formStyle(.grouped)
            }
            Divider()
            HStack {
                Picker(L("addInput.number"), selection: $form.model.number) {
                    ForEach(form.freeNumbers, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .frame(width: 130)
                .disabled(form.isFull)
                TextField(L("addInput.name"), text: $form.model.name, prompt: Text(form.model.defaultName))
                    .frame(width: 200)
                Text(form.isFull ? form.fullMessage : form.errorMessage).foregroundStyle(.red).lineLimit(1)
                Spacer()
                Button(L("common.cancel")) { form.onCancel?() }.keyboardShortcut(.cancelAction)
                Button(L("addInput.add")) { form.onConfirm?() }.keyboardShortcut(.defaultAction)
                    .disabled(!form.canAdd)
            }
            .padding(12)
        }
    }

    private var kindSelection: Binding<AddInputModel.Kind?> {
        Binding(get: { form.model.kind }, set: { if let k = $0 { form.model.kind = k; form.errorMessage = "" } })
    }
}

/// Sheet 本体。
@MainActor
final class AddInputSheetController: NSWindowController {
    let form: AddInputFormModel
    private let onConfirm: (InputConfig) -> Void

    /// 当前表单值（测试看）。
    var model: AddInputModel { form.model }

    /// kind = 打开时停在哪一页（底栏主体给上次添加用的类型，▴ / 菜单栏"按类型添加"给点的那一种；W5-F）。
    init(state: MixerState, maxInputs: Int, kind: AddInputModel.Kind = .synthetic, onConfirm: @escaping (InputConfig) -> Void) {
        self.onConfirm = onConfirm
        form = AddInputFormModel(state: state, maxInputs: maxInputs)
        form.model.kind = kind
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
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
        guard form.canAdd, let config = form.makeConfig() else { return }   // 满了：不加、面板不关（上面写着"已满"）
        onConfirm(config)
        close(returnCode: .OK)
    }

    private func cancel() { close(returnCode: .cancel) }

    // 测试入口
    func selectKindForTesting(_ kind: AddInputModel.Kind) { form.model.kind = kind }
    func confirmForTesting() { confirm() }
    func cancelForTesting() { cancel() }

    private func close(returnCode: NSApplication.ModalResponse) {
        form.close()
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            window.close()
        }
    }
}
