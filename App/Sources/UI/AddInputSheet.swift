// 添加输入（W3-E 完整版）：左边八种类型（设计方案 §6：摄像头 / 采集卡、DeckLink、屏幕 / 窗口 / 应用、视频文件、图片、NDI、
// 纯音频设备、合成测试源），右边各自的参数页，底部编号 + 名字 + 确定。SwiftUI 表单放 NSHostingView 的 sheet 里。
// 只产生 InputConfig 并发 addInput 命令；运行实现由 InputFactory 接。
// W3-E2：DeckLink 页列设备（DeckLinkDevices）、选输入接口（卡支持的）与内嵌音频取哪两路；NDI 页发现源、选带宽模式 / 抖动缓冲 0–2 帧（提案 008）；
// 纯音频页用 SwitcherInputs.AudioInputDevices 列设备（第一项"系统默认输入" = 空串 uid，插拔时刷新），设备声道 > 2 时选取哪几路（提案 014）。
// 每种类型的参数页抽成 InputSourceFormView，输入设置窗的"来源"一节复用它（setInputSource，提案 012）。
// W5-B（02 X22）：编号用满时"添加"置灰并写明"本节目的输入已满（n 路）"，确定不加、面板不关（原来面板照关、命令被拒、只在底栏闪 4 秒）。
// W5-K（prompt 97 交付 1，01a G2–G12）：左栏按"设备 / 网络 / 屏幕 / 媒体 / 测试"分组带图标、第一次停在摄像头、记住上次的类型与各类的设备 / 路径（AddInputHistory）；
// 权限被拒 / SDK 没编进来 / 驱动没装时页顶横幅（AddInputEnvironment）；sheet 可缩放并记住尺寸；每页第一行是给操作员看的说明；摄像头页写协商结果、帧率对不上标黄；
// NDI® 页开着持续找、双击直接加；屏幕页缩略图网格；视频 / 图片页最近 10 个文件与文件信息；音频设备下拉不再写四字码；视频文件页收纯音频文件（Q57）。
import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
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
        fill(from: source)
    }

    /// 把一个来源的字段填进表单（只填这一类的字段、不换当前页；添加面板按"上次用的"预填各类，W5-K / G2）。
    mutating func fill(from source: InputSource) {
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

/// 屏幕页的一格（G10）：整块显示器 / 单个窗口 / 某个应用。缩略图要屏幕录制权限（没有就画图标），每格各取一帧小图。
struct ScreenTile: Identifiable, Hashable {
    var kind: AddInputModel.ScreenKind
    /// 显示器编号 / 窗口编号 / bundle id。
    var key: String
    var title: String
    var subtitle: String
    var id: String { "\(kind.rawValue):\(key)" }
}

/// 表单的可观察模型：设备列表 + 表单值 + 错误。添加输入用 init(state:maxInputs:history:environment:)，输入设置窗的"来源"一节用 init(editing:)。
@MainActor
final class AddInputFormModel: ObservableObject {
    /// 添加面板（有本机记忆、双击直接加）还是输入设置的"来源"一节（只改表单）。
    enum Purpose { case add, edit }

    @Published var model: AddInputModel {
        didSet { modelChanged(from: oldValue) }
    }
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
    /// 正在找 NDI 源（页上转圈）。
    @Published private(set) var ndiSearching = false
    /// 屏幕页的格子与缩略图（G10）。
    @Published private(set) var screenTiles: [ScreenTile] = []
    @Published private(set) var screenThumbnails: [String: NSImage] = [:]
    /// 选好的视频 / 图片的信息（G12）。
    @Published private(set) var fileInfo: MediaFileInfo?
    /// 最近文件变了（清空之后让页面重读）。
    @Published private var recentFilesVersion = 0
    let freeNumbers: [Int]
    /// 这个节目最多几路（引擎的 maxInputs）。
    let maxInputs: Int
    /// 节目格式（摄像头页算协商结果用）。
    let programFormat: ProgramFormat
    let purpose: Purpose
    /// 编号用满了（添加输入时没有空号；输入设置窗的"来源"一节永远有自己那个号）。
    var isFull: Bool { freeNumbers.isEmpty }
    var canAdd: Bool { !isFull }
    var fullMessage: String { L("addInput.full", maxInputs) }
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 权限 / SDK / 驱动状态与"打开系统设置…""看说明"（测试注入，W5-K / G6）。
    let environment: AddInputEnvironment
    /// 本机记忆（上次的类型与设备 / 路径、最近文件；W5-K / G2 / G11）。
    let history: AddInputHistory?
    /// NDI 页开着时多久重找一次（G9）。
    var ndiRefreshInterval: TimeInterval = 4
    /// 已经找过几次 NDI 源（测试看持续刷新）。
    private(set) var ndiSearchCount = 0
    private var audioInfos: [String: AudioInputDeviceInfo] = [:]
    private var decklinkInfos: [String: DeckLinkDeviceInfo] = [:]
    private var cameraInfos: [String: CameraDeviceInfo] = [:]
    private var windowInfos: [ScreenTargets.WindowInfo] = []
    private var applicationInfos: [ScreenTargets.ApplicationInfo] = []
    private var audioSubscription: AudioInputDevices.Subscription?
    private var ndiTimer: Timer?
    private var thumbnailTask: Task<Void, Never>?
    private var fileInfoTask: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?

    /// 添加输入：默认编号 = 最小空闲编号；各类按本机记忆预填上次的设备 / 路径（G2）。
    convenience init(state: MixerState, maxInputs: Int, history: AddInputHistory? = nil, environment: AddInputEnvironment = .live) {
        var m = AddInputModel()
        m.number = AddInputModel.nextFreeNumber(in: state, maxInputs: maxInputs)
        if let history {
            for kind in AddInputModel.Kind.displayOrder {
                if let source = history.lastSource(for: kind) { m.fill(from: source) }
            }
        }
        let used = Set(state.inputs.map(\.number))
        self.init(model: m, freeNumbers: (1...max(1, maxInputs)).filter { !used.contains($0) }, maxInputs: maxInputs, programFormat: state.format,
                  purpose: .add, history: history, environment: environment)
        // 记住的摄像头 / 显示器不在了：退到第一个
        if !cameras.contains(where: { $0.id == model.cameraUniqueID }) { model.cameraUniqueID = cameras.first?.id }
        if !displays.contains(where: { $0.id == model.displayID.map(String.init) }) { model.displayID = AddInputModel.displays().first?.id }
    }

    /// 输入设置窗"来源"一节：表单填现有来源。
    convenience init(editing config: InputConfig, programFormat: ProgramFormat = MixerState().format) {
        var m = AddInputModel(source: config.source)
        m.number = config.number
        m.name = config.name
        self.init(model: m, freeNumbers: [config.number], maxInputs: max(config.number, 1), programFormat: programFormat,
                  purpose: .edit, history: nil, environment: .live)
        if model.cameraUniqueID == nil { model.cameraUniqueID = cameras.first?.id }
        if model.displayID == nil { model.displayID = AddInputModel.displays().first?.id }
    }

    private init(model: AddInputModel, freeNumbers: [Int], maxInputs: Int, programFormat: ProgramFormat, purpose: Purpose,
                 history: AddInputHistory?, environment: AddInputEnvironment) {
        self.model = model
        self.freeNumbers = freeNumbers
        self.maxInputs = maxInputs
        self.programFormat = programFormat
        self.purpose = purpose
        self.history = history
        self.environment = environment
        let cameraList = CameraDevices.list()
        cameraInfos = Dictionary(cameraList.map { ($0.uniqueID, $0) }, uniquingKeysWith: { a, _ in a })
        cameras = cameraList.map { AddInputChoice(id: $0.uniqueID, title: $0.name) }
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
        // 去系统设置里授权回来：横幅按新状态重画（权限状态不发通知，App 回到前台时看一眼）
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        kindChanged()
    }

    /// 摘掉设备插拔订阅、停掉 NDI 定时重找与缩略图（sheet / 输入设置窗关掉时调；重复调无害）。
    func close() {
        audioSubscription?.stop()
        audioSubscription = nil
        stopNDIRefresh()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        fileInfoTask?.cancel()
        fileInfoTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    var isObservingAudioDevices: Bool { audioSubscription != nil }

    // MARK: 表单变了

    private func modelChanged(from old: AddInputModel) {
        if old.kind != model.kind {
            errorMessage = ""
            kindChanged()
            return
        }
        if model.kind == .file, old.filePath != model.filePath { refreshFileInfo() }
        if model.kind == .image, old.imagePath != model.imagePath { refreshFileInfo() }
        if model.kind == .screen, old.screenKind != model.screenKind { reloadScreenTiles() }
    }

    /// 换了页：NDI 页开着才定时重找（G9）；屏幕页列格子（G10）；视频 / 图片页读文件信息（G12）。
    private func kindChanged() {
        if model.kind == .ndi { startNDIRefresh() } else { stopNDIRefresh() }
        if model.kind == .screen { reloadScreenTiles() }
        if model.kind == .file || model.kind == .image { refreshFileInfo() } else { fileInfo = nil }
    }

    // MARK: 横幅（G6）

    /// 当前页顶部的横幅（权限被拒 / SDK 没编进来 / 驱动没装）。
    var banner: AddInputBanner? { environment.banner(for: model.kind) }

    /// 有横幅时"添加"旁边的一句：照样能加，格子上先显示错误，授权 / 装好之后这一路自己恢复。
    var addNote: String? { banner.map { $0.isPermission ? L("addInput.addNote.permission") : L("addInput.addNote.install") } }

    /// 横幅上的按钮。
    func perform(_ action: AddInputBanner.Action) {
        switch action {
        case .openSystemSettings(let url): environment.openURL(url)
        case .showHelp(let anchor): environment.openHelp(anchor)
        }
    }

    // MARK: 音频设备（V-16：说明拆两行、连接方式翻成人话）

    /// 重新列纯音频设备（有输入声道的）。第一项"系统默认输入"= 空串 uid（W2-A2：跟随系统设置，换了默认输入会自动重建）。
    func reloadAudioDevices() {
        let list = AudioInputDevices.list().filter { $0.inputChannels > 0 }
        audioInfos = Dictionary(list.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        audioDevices = [AddInputChoice(id: "", title: L("addInput.audio.systemDefault"))]
            + list.map { d in AddInputChoice(id: d.uid, title: Self.audioDeviceTitle(name: d.name, channels: d.inputChannels, transport: d.transportType)) }
    }

    /// 下拉里一项："名字（2 声道 · USB）"；连接方式是 CoreAudio 的四字码，翻成人话，不认识的不写（原来原样写 "bltn"，V-16）。
    static func audioDeviceTitle(name: String, channels: Int, transport: String) -> String {
        if let t = AudioTransportName.title(fourCC: transport) { return L("addInput.audio.device.line", name, channels, t) }
        return L("addInput.audio.device.lineNoTransport", name, channels)
    }

    /// 某个音频设备的输入声道数（空串 = 系统默认输入那台；不知道为 0）。
    func audioChannelCount(for uid: String) -> Int {
        if uid.isEmpty {
            guard let d = audioInfos.values.first(where: \.isDefaultInput) else { return 0 }
            return d.inputChannels
        }
        return audioInfos[uid]?.inputChannels ?? 0
    }

    /// 选中的音频设备的说明（两行：名字（连接方式）/ 声道与采样率；默认输入写现在是哪台）。
    func audioDeviceDetail(for uid: String) -> String {
        let info = uid.isEmpty ? audioInfos.values.first(where: \.isDefaultInput) : audioInfos[uid]
        guard let d = info else { return uid.isEmpty ? "" : L("addInput.audio.missing", uid) }
        let rate = d.supports48k ? "48 kHz" : L("addInput.audio.no48k")
        let base = AudioTransportName.title(fourCC: d.transportType).map { L("addInput.audio.detail", d.name, $0, d.inputChannels, rate) }
            ?? L("addInput.audio.detailNoTransport", d.name, d.inputChannels, rate)
        return uid.isEmpty ? L("addInput.audio.followsDefault", base) : base
    }

    // MARK: DeckLink

    /// DeckLink 某张卡能选的输入接口（卡报的位集）；卡不在（没装驱动 / 手填的 ID）就列全部，卡上不支持的由卡自己拒。
    func decklinkConnections(for id: String) -> [SwitcherContracts.DeckLinkConnection] {
        let info = id.isEmpty ? decklinkInfos.values.sorted { $0.index < $1.index }.first : decklinkInfos[id]
        guard let supported = info?.inputConnections.supported, !supported.isEmpty else { return SwitcherContracts.DeckLinkConnection.allCases }
        return supported
    }

    /// DeckLink 内嵌音频路数（卡不告诉你有几路有信号，给 1–16 让用户选；DeckLinkInput 按映射自动开 2 / 8 / 16 路）。
    let decklinkChannelCount = 16

    // MARK: 摄像头（G8：协商结果）

    /// 摄像头还没授权过（被拒的由横幅说）：一句"第一次加的时候系统会问"。
    var cameraPermissionMessage: String? {
        environment.cameraPermission() == .notDetermined ? L("addInput.camera.permissionFirstTime") : nil
    }

    /// 选中的摄像头会以什么格式采集（与引擎起这一路时同一个纯函数）；设备没报格式为 nil。
    var cameraNegotiation: CameraNegotiationSummary? {
        guard let id = model.cameraUniqueID, let info = cameraInfos[id] else { return nil }
        return CameraNegotiationSummary.make(candidates: info.formats, program: programFormat)
    }

    // MARK: 屏幕（G10：缩略图网格）

    /// 窗口 / 应用列表要屏幕录制权限，用户选到才去取（ScreenCaptureKit）。
    func loadScreenLists() {
        guard windowInfos.isEmpty, applicationInfos.isEmpty else { return }
        screenListStatus = L("addInput.screen.loading")
        Task { @MainActor [weak self] in
            do {
                let windows = try await ScreenTargets.windows()
                let apps = try await ScreenTargets.applications()
                guard let self else { return }
                self.windowInfos = windows.filter { $0.isOnScreen && !$0.title.isEmpty }
                self.applicationInfos = apps.filter { !$0.name.isEmpty }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.windows = self.windowInfos.map { AddInputChoice(id: String($0.id), title: "\($0.applicationName) — \($0.title)") }
                self.applications = self.applicationInfos.map { AddInputChoice(id: $0.bundleID, title: $0.name) }
                if self.model.windowID == nil, let first = self.windowInfos.first { self.model.windowID = first.id }
                if self.model.applicationBundleID == nil { self.model.applicationBundleID = self.applicationInfos.first?.bundleID }
                self.screenListStatus = L("addInput.screen.listed", self.windowInfos.count, self.applicationInfos.count)
                self.reloadScreenTiles()
            } catch {
                self?.screenListStatus = L("addInput.screen.failed", "\(error.localizedDescription)")
            }
        }
    }

    /// 按"抓取"那一项列格子：显示器随时有；窗口 / 应用要先列出来（要屏幕录制权限）。
    func reloadScreenTiles() {
        switch model.screenKind {
        case .display:
            screenTiles = NSScreen.screens.compactMap { screen in
                guard let n = screen.displayNumber else { return nil }
                let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
                return ScreenTile(kind: .display, key: String(n), title: screen.displayTitle, subtitle: size)
            }
        case .window:
            if windowInfos.isEmpty { loadScreenLists() }
            screenTiles = windowInfos.map { ScreenTile(kind: .window, key: String($0.id), title: $0.title, subtitle: $0.applicationName) }
        case .application:
            if applicationInfos.isEmpty { loadScreenLists() }
            screenTiles = applicationInfos.map { ScreenTile(kind: .application, key: $0.bundleID, title: $0.name, subtitle: $0.bundleID) }
        }
        loadThumbnails()
    }

    /// 格子是不是现在选中的那个。
    func isSelected(_ tile: ScreenTile) -> Bool {
        switch tile.kind {
        case .display: model.screenKind == .display && model.displayID.map(String.init) == tile.key
        case .window: model.screenKind == .window && model.windowID.map(String.init) == tile.key
        case .application: model.screenKind == .application && model.applicationBundleID == tile.key
        }
    }

    func select(_ tile: ScreenTile) {
        switch tile.kind {
        case .display: model.displayID = UInt32(tile.key)
        case .window: model.windowID = UInt32(tile.key)
        case .application: model.applicationBundleID = tile.key
        }
    }

    /// 应用格子画应用图标（不用截屏）。
    func icon(for tile: ScreenTile) -> NSImage? {
        guard tile.kind == .application, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tile.key) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// 显示器 / 窗口各取一帧小图（ScreenCaptureKit 截图；没有屏幕录制权限就不取，格子画图标）。
    private func loadThumbnails() {
        guard environment.screenRecordingAllowed() else { return }
        let wanted = screenTiles.filter { $0.kind != .application && screenThumbnails[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            for tile in wanted {
                if Task.isCancelled { return }
                let filter: SCContentFilter
                switch tile.kind {
                case .display:
                    guard let d = content.displays.first(where: { String($0.displayID) == tile.key }) else { continue }
                    filter = SCContentFilter(display: d, excludingWindows: [])
                case .window:
                    guard let w = content.windows.first(where: { String($0.windowID) == tile.key }) else { continue }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                case .application:
                    continue
                }
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 180
                config.showsCursor = false
                config.preservesAspectRatio = true
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
                self?.screenThumbnails[tile.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    // MARK: NDI®（G9：开着就持续找、双击直接加）

    /// 在网络上找 NDI 源（mDNS 最多等 1.5 s，放后台线程；SDK 没编进来 / 没装运行时就说明一句，照样能手填源名）。
    func loadNDISources() {
        guard !ndiSearching else { return }
        ndiSearching = true
        ndiSearchCount += 1
        if ndiSources.isEmpty { ndiStatus = L("addInput.ndi.searching") }
        let discover = environment.discoverNDI
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[String], any Error> = Result { try discover() }
            await MainActor.run {
                guard let self else { return }
                self.ndiSearching = false
                switch result {
                case .success(let names):
                    let sorted = names.sorted()
                    if sorted != self.ndiSources { self.ndiSources = sorted }
                    self.ndiStatus = names.isEmpty ? L("addInput.ndi.noneFound") : L("addInput.ndi.found", names.count)
                case .failure(let error):
                    self.ndiStatus = L("addInput.ndi.unavailable", "\(error)")
                }
            }
        }
    }

    private func startNDIRefresh() {
        guard purpose == .add else {
            if ndiSources.isEmpty { loadNDISources() }   // 输入设置的"来源"一节：进页找一次
            return
        }
        guard ndiTimer == nil else { return }
        loadNDISources()
        let timer = Timer(timeInterval: ndiRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadNDISources() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ndiTimer = timer
    }

    private func stopNDIRefresh() {
        ndiTimer?.invalidate()
        ndiTimer = nil
    }

    /// 双击一个源：添加面板里直接加这一路；输入设置里只选上。
    func activateNDISource(_ name: String) {
        model.ndiSourceName = name
        if purpose == .add { onConfirm?() }
    }

    // MARK: 视频 / 图片：最近文件（G11）与文件信息（G12）

    /// 视频 / 图片页的最近文件（新的在前、最多 10 个；不在了的灰着）。添加面板才有。
    var recentFiles: [AddInputRecentFile] {
        _ = recentFilesVersion
        guard let history, model.kind == .file || model.kind == .image else { return [] }
        return history.recentFiles(for: model.kind).map { AddInputRecentFile(path: $0, exists: FileManager.default.fileExists(atPath: $0)) }
    }

    /// 单击：填进路径。
    func selectRecentFile(_ file: AddInputRecentFile) {
        if model.kind == .image { model.imagePath = file.path } else { model.filePath = file.path }
    }

    /// 双击：直接加（文件不在了不加）。
    func addRecentFile(_ file: AddInputRecentFile) {
        guard file.exists else { return }
        selectRecentFile(file)
        onConfirm?()
    }

    /// "清空"。
    func clearRecentFiles() {
        history?.clearRecentFiles(for: model.kind)
        recentFilesVersion += 1
    }

    /// 选好文件后读信息（视频文件异步读，图片当场读）。
    func refreshFileInfo() {
        fileInfoTask?.cancel()
        fileInfoTask = nil
        switch model.kind {
        case .image:
            fileInfo = model.imagePath.isEmpty ? nil : MediaFileInfo.loadImage(path: model.imagePath)
        case .file:
            let path = model.filePath
            guard !path.isEmpty else { fileInfo = nil; return }
            fileInfoTask = Task { @MainActor [weak self] in
                let info = await MediaFileInfo.loadMovie(path: path)
                guard let self, !Task.isCancelled, self.model.filePath == path else { return }
                self.fileInfo = info
            }
        default:
            fileInfo = nil
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
/// 每页第一行是给操作员看的说明：能接什么、要什么前提（G7；实现口径在手册里）。
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

    private func about(_ key: String) -> some View {
        Text(L(key)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var syntheticForm: some View {
        Section(L("addInput.synthetic.title")) {
            about("addInput.synthetic.about")
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
            about("addInput.camera.about")
            Picker(L("addInput.camera.device"), selection: optionalString($form.model.cameraUniqueID)) {
                ForEach(form.cameras) { Text($0.title).tag($0.id) }
            }
            // 协商结果（G8）：帧率和节目对不上标黄，写明会重复帧还是丢帧
            if let n = form.cameraNegotiation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: n.frameRateMismatch ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(n.frameRateMismatch ? Color.yellow : Color.secondary)
                        .accessibilityHidden(true)
                    Text(n.text).foregroundStyle(n.frameRateMismatch ? Color.yellow : Color.secondary)
                }
                .font(.callout)
            }
            Text(form.cameras.isEmpty ? L("addInput.camera.none") : L("addInput.camera.count", form.cameras.count)).font(.caption).foregroundStyle(.secondary)
            if let p = form.cameraPermissionMessage { Text(p).font(.caption).foregroundStyle(.secondary) }
            Text(L("addInput.camera.micHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var decklinkForm: some View {
        Section(L("addInput.decklink.title")) {
            about("addInput.decklink.about")
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
            about("addInput.screen.about")
            Picker(L("addInput.screen.kind"), selection: $form.model.screenKind) {
                ForEach(AddInputModel.ScreenKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            // 缩略图网格（G10）：点一格选它；窗口 / 应用要先有屏幕录制权限才列得出来
            if form.screenTiles.isEmpty {
                Text(form.model.screenKind == .display ? L("addInput.screen.noDisplays") : form.screenListStatus).font(.caption).foregroundStyle(.secondary)
            } else {
                ScreenTileGrid(form: form)
            }
            Picker(L("addInput.screen.frameRate"), selection: $form.model.screenFrameRate) {
                Text(L("addInput.screen.frameRateProgram")).tag(FrameRate?.none)
                ForEach(AddInputModel.screenRates, id: \.self) { Text(verbatim: "\($0)").tag(FrameRate?.some($0)) }
            }
            Toggle(L("addInput.screen.captureAudio"), isOn: $form.model.captureAudio)
        }
    }

    private func optionalString(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    @ViewBuilder
    private var fileForm: some View {
        Section(L("addInput.file.title")) {
            about("addInput.file.about")
            HStack {
                TextField(L("addInput.file.path"), text: $form.model.filePath, prompt: Text(L("addInput.path.none")))   // 空着时有占位（V-17）
                Button(L("common.browse")) { browse(image: false) }
            }
            fileInfoRows
            Picker(L("addInput.file.endAction"), selection: $form.model.fileEndAction) {
                ForEach(AddInputModel.fileEndActions, id: \.self) { Text(L("addInput.file.endAction.\($0.rawValue)")).tag($0) }
            }
            TextField(L("addInput.file.rate"), value: $form.model.fileRate, format: .number)
        }
        recentFilesSection
    }

    @ViewBuilder
    private var imageForm: some View {
        Section(L("addInput.image.title")) {
            about("addInput.image.about")
            HStack {
                TextField(L("addInput.image.path"), text: $form.model.imagePath, prompt: Text(L("addInput.path.none")))
                Button(L("common.browse")) { browse(image: true) }
            }
            fileInfoRows
        }
        recentFilesSection
    }

    /// 文件信息（G12）；纯音频文件写明这一版加上会报错（Q57）。
    @ViewBuilder
    private var fileInfoRows: some View {
        if let info = form.fileInfo {
            Text(info.summary).font(.caption).foregroundStyle(.secondary)
            if info.isAudioOnly {
                Text(L("addInput.file.audioOnlyNote")).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 最近 10 个文件（G11）：单击填入、双击直接加；不在了的灰着；"清空"。只在添加面板里有。
    @ViewBuilder
    private var recentFilesSection: some View {
        if form.purpose == .add {
            Section(L("addInput.recent.title")) {
                let files = form.recentFiles
                if files.isEmpty {
                    Text(L("addInput.recent.none")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        RecentFileRow(file: file, selected: file.path == (form.model.kind == .image ? form.model.imagePath : form.model.filePath))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { form.addRecentFile(file) }
                            .onTapGesture { form.selectRecentFile(file) }
                            .help(file.exists ? L("addInput.recent.tip") : L("addInput.recent.missingTip"))
                    }
                    Button(L("addInput.recent.clear")) { form.clearRecentFiles() }
                }
            }
        }
    }

    private var ndiForm: some View {
        Section(L("addInput.ndi.title")) {
            about("addInput.ndi.about")
            HStack(spacing: 6) {
                if form.ndiSearching { ProgressView().controlSize(.small).accessibilityLabel(L("addInput.ndi.searching")) }
                Text(form.ndiStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("addInput.ndi.refresh")) { form.loadNDISources() }
            }
            // 网络上的源（G9）：开着这一页每隔几秒重找；单击选、双击直接加
            if !form.ndiSources.isEmpty {
                List(form.ndiSources, id: \.self, selection: ndiSelection) { name in
                    Text(name)
                }
                .frame(minHeight: 90, idealHeight: 140, maxHeight: 200)
                .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { names in
                    if let name = names.first { form.activateNDISource(name) }
                })
                .accessibilityLabel(L("addInput.ndi.found.picker"))
            }
            TextField(L("addInput.ndi.sourceName"), text: $form.model.ndiSourceName, prompt: Text(L("addInput.ndi.sourcePrompt")))
            Picker(L("addInput.ndi.bandwidth"), selection: $form.model.ndiBandwidth) {
                ForEach(NDIBandwidth.allCases, id: \.self) { Text(L("ndi.bandwidth.\($0.rawValue)")).tag($0) }
            }
            Stepper(value: $form.model.ndiJitterBufferFrames, in: InputSource.ndiJitterBufferRange) {
                Text(L("addInput.ndi.jitter", form.model.ndiJitterBufferFrames))
            }
            Text(L("addInput.ndi.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ndiSelection: Binding<String?> {
        Binding(get: { form.ndiSources.contains(form.model.ndiSourceName) ? form.model.ndiSourceName : nil },
                set: { if let name = $0 { form.model.ndiSourceName = name } })
    }

    private var audioForm: some View {
        Section(L("addInput.audio.title")) {
            about("addInput.audio.about")
            Picker(L("addInput.audio.device"), selection: $form.model.audioDeviceUID) {
                ForEach(form.audioDevices) { Text($0.title).tag($0.id) }
                if !form.audioDevices.contains(where: { $0.id == form.model.audioDeviceUID }) {
                    Text(L("addInput.audio.missing", form.model.audioDeviceUID)).tag(form.model.audioDeviceUID)
                }
            }
            Text(form.audioDeviceDetail(for: form.model.audioDeviceUID)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // 提案 014：设备输入声道 > 2（多路接口 / 小调音台）才问取第几路；已经设过映射的也显示（好改回去）
            if form.audioChannelCount(for: form.model.audioDeviceUID) > 2 || !form.model.audioChannels.isEmpty {
                ChannelMapPicker(channelCount: form.audioChannelCount(for: form.model.audioDeviceUID), channels: $form.model.audioChannels)
            }
            if form.audioDevices.count <= 1 { Text(L("addInput.audio.none")).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func browse(image: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = image ? [.image] : MediaFileInfo.movieContentTypes   // 视频文件页也收 mp3 / wav / m4a / aac（Q57）
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if image { form.model.imagePath = url.path } else { form.model.filePath = url.path }
        }
    }
}

/// 最近文件的一行：文件名 + 所在目录；不在了的灰着、写"（不在了）"。
private struct RecentFileRow: View {
    let file: AddInputRecentFile
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.exists ? "doc" : "questionmark.folder").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.exists ? file.name : L("addInput.recent.missing", file.name)).lineLimit(1).truncationMode(.middle)
                Text(file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true) }
        }
        .opacity(file.exists ? 1 : 0.45)
    }
}

/// 屏幕页的缩略图网格（G10）。
private struct ScreenTileGrid: View {
    @ObservedObject var form: AddInputFormModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
            ForEach(form.screenTiles) { tile in
                let selected = form.isSelected(tile)
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                        if let image = form.screenThumbnails[tile.id] {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else if let icon = form.icon(for: tile) {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(18)
                        } else {
                            Image(systemName: tile.kind == .display ? "display" : "macwindow").font(.system(size: 32)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3))
                    Text(tile.title).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(tile.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture { form.select(tile) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(tile.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 页顶的醒目横幅（G6）：权限被拒 / SDK 没编进来 / 驱动没装，带"打开系统设置…"或"看说明"。
private struct AddInputBannerView: View {
    let banner: AddInputBanner
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.white).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.headline).foregroundStyle(.white)
                Text(banner.message).font(.callout).foregroundStyle(.white.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(banner.actionTitle) { onAction() }
                .accessibilityLabel(banner.actionTitle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Theme.recording).opacity(0.9))
    }
}

/// Sheet 内容。
struct AddInputView: View {
    @ObservedObject var form: AddInputFormModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 类型分组 + 图标（G3）
                List(selection: kindSelection) {
                    ForEach(AddInputKindGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(group.kinds) { kind in
                                Label(kind.title, systemImage: kind.symbolName).tag(kind)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                .accessibilityLabel(L("addInput.kindList"))
                Divider()
                VStack(spacing: 0) {
                    if let banner = form.banner {
                        AddInputBannerView(banner: banner) { form.perform(banner.action) }
                    }
                    Form { InputSourceFormView(form: form) }
                        .formStyle(.grouped)
                }
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
                if form.isFull || !form.errorMessage.isEmpty {
                    Text(form.isFull ? form.fullMessage : form.errorMessage).foregroundStyle(.red).lineLimit(1)
                } else if let note = form.addNote {
                    Text(note).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer()
                Button(L("common.cancel")) { form.onCancel?() }.keyboardShortcut(.cancelAction)
                Button(L("addInput.add")) { form.onConfirm?() }.keyboardShortcut(.defaultAction)
                    .disabled(!form.canAdd)
            }
            .padding(12)
        }
        .frame(minWidth: AddInputSheetController.minimumSize.width, maxWidth: .infinity, minHeight: AddInputSheetController.minimumSize.height, maxHeight: .infinity)
    }

    private var kindSelection: Binding<AddInputModel.Kind?> {
        Binding(get: { form.model.kind }, set: { if let k = $0 { form.model.kind = k } })
    }
}

/// Sheet 本体：可以缩放，关掉时记下尺寸，下次照这个尺寸开（G4；还是 sheet，列入"有意保留"）。
@MainActor
final class AddInputSheetController: NSWindowController, NSWindowDelegate {
    static let defaultSize = NSSize(width: 820, height: 560)
    static let minimumSize = NSSize(width: 700, height: 460)
    let form: AddInputFormModel
    private let onConfirm: (InputConfig) -> Void
    private let history: AddInputHistory?

    /// 当前表单值（测试看）。
    var model: AddInputModel { form.model }

    /// kind = 打开时停在哪一页（底栏主体给上次添加用的类型，▴ / 菜单栏"按类型添加"给点的那一种；W5-F）；history = 本机记忆（预填上次的设备 / 路径、最近文件、面板尺寸）。
    init(state: MixerState, maxInputs: Int, kind: AddInputModel.Kind = AddInputHistory.defaultKind, history: AddInputHistory? = nil,
         environment: AddInputEnvironment = .live, onConfirm: @escaping (InputConfig) -> Void) {
        self.onConfirm = onConfirm
        self.history = history
        form = AddInputFormModel(state: state, maxInputs: maxInputs, history: history, environment: environment)
        form.model.kind = kind
        let size = history?.sheetSize.map { NSSize(width: max($0.width, Self.minimumSize.width), height: max($0.height, Self.minimumSize.height)) } ?? Self.defaultSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = L("addInput.title")
        super.init(window: panel)
        let host = NSHostingView(rootView: AddInputView(form: form))
        host.sizingOptions = []
        panel.contentView = host
        panel.contentMinSize = Self.minimumSize
        panel.delegate = self   // 挂成 sheet 之后 AppKit 把 contentMinSize 清成 0（探针实测），最小尺寸由 windowWillResize 兜住
        form.onConfirm = { [weak self] in self?.confirm() }
        form.onCancel = { [weak self] in self?.cancel() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 不小于最小尺寸（给缩略图网格和最近列表留地方）。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

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
        history?.sheetSize = window.contentRect(forFrameRect: window.frame).size
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            window.close()
        }
    }
}
