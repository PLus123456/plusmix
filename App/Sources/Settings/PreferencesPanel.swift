// 偏好设置（W3-E 交付第 7 条）：节目分辨率 / 帧率（在 Show 里，改了要换 session）、API 端口 / token、音频输出设备、PVW 预览全部叠加（W3-E2）、
// 外部输出在主屏上不盖住主界面（W3-E3）、第三方 API 兼容层（VMixCompat）开关（带法律提示）、语言、更新（W4-B 接 Sparkle，这里只留位置）、
// 操作确认（W5-B：底栏停录制 / 推流前先确认，默认开）。
// W5-B（02 X04 / 01a F5）：节目格式"应用"、节目音频"应用"、"应用并重起引擎"在录制 / 推流在跑时先确认（sheet 挂在本窗口上）；换完引擎这个窗口不关，
// 只把格式 / 节目音频几项重新读一遍新 session（rebind）。
// API / 音频 / 兼容层用 W2-B2 的同一组 UserDefaults 键（AppSettings.Keys），下次起 session 生效；"应用并重启引擎"立刻生效。
// 外部输出的主屏层级是包内选项、运行时可改：点"应用"就落到跑着的 session（AppController.updateSettings）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherControl
import SwitcherAudio

@MainActor
final class PreferencesModel: ObservableObject {
    struct AudioDeviceChoice: Identifiable, Hashable {
        let id: String
        let title: String
        let device: AppSettings.AudioDevice
    }
    struct LanguageChoice: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static let systemLanguage = "system"
    static let formatPresets: [ProgramFormat] = [.hd1080p60, .hd1080p5994, .hd1080p30, .hd720p60, .uhd2160p30]
    static let frameRates: [FrameRate] = [.fps24, .fps25, .fps2997, .fps30, .fps50, .fps5994, .fps60]
    static let resolutions: [(Int, Int)] = [(1920, 1080), (1280, 720), (3840, 2160)]

    @Published var formatWidth: Int
    @Published var formatHeight: Int
    @Published var frameRate: FrameRate
    @Published var apiEnabled: Bool
    @Published var apiHost: String
    @Published var apiPort: Int
    @Published var apiToken: String
    @Published var audioDevice: AppSettings.AudioDevice
    @Published var compatLayerEnabled: Bool
    @Published var compatLayerPort: Int
    /// PVW 预览全部叠加（渲染器总开关，换 session 生效）。
    @Published var overlaysInPreview: Bool
    /// 外部输出在主屏上不盖住主界面（ExternalDisplayManager.mainScreenLayering，应用即生效）。
    @Published var externalBehindInterface: Bool
    /// 节目音频的对齐延迟（48 kHz 帧）与监听点（提案 007）：存在节目文件里，不是全局偏好；改了要重建音频引擎（换 session）。
    @Published var alignmentFrames: Int
    @Published var monitorPoint: SwitcherContracts.MonitorPoint
    @Published var language: String
    /// 底栏停录制 / 停推流前先确认（W5-B，默认开）。
    @Published var confirmBeforeStop: Bool
    @Published private(set) var status = ""
    let audioDeviceChoices: [AudioDeviceChoice]
    let languageChoices: [LanguageChoice]
    /// 更新一节（W4-B，Sparkle）：是否配置了更新源、上次检查时间、自动检查开关（apply 时写回 Sparkle）。
    let updatesConfigured: Bool
    let updateStatus: String
    @Published var automaticUpdates: Bool
    private unowned let controller: AppController
    /// 确认 sheet 挂在哪个窗口上（PreferencesWindowController 设）。
    weak var presentingWindow: NSWindow?

    /// 兼容层的法律提示（设计方案 §0、§9.3：独立模块、默认关、发布前问律师）。
    static var compatLegalNotice: String { L("prefs.compat.legal") }

    init(controller: AppController) {
        self.controller = controller
        updatesConfigured = controller.updateController.isConfigured
        updateStatus = controller.updateController.statusText
        automaticUpdates = controller.updateController.automaticallyChecksForUpdates
        let s = controller.settings
        let format = controller.session?.format ?? .hd1080p60
        formatWidth = format.width
        formatHeight = format.height
        frameRate = format.frameRate
        apiEnabled = s.apiEnabled
        apiHost = s.apiHost
        apiPort = s.apiPort
        apiToken = s.apiToken ?? ""
        audioDevice = s.audioDevice
        compatLayerEnabled = s.compatLayerEnabled
        compatLayerPort = s.compatLayerPort
        overlaysInPreview = s.overlaysInPreview
        externalBehindInterface = s.externalBehindInterface
        confirmBeforeStop = s.confirmBeforeStop
        let audio = controller.session?.state.audio ?? AudioState()
        alignmentFrames = audio.alignmentFrames
        monitorPoint = audio.monitorPoint
        let languages = controller.defaults.stringArray(forKey: "AppleLanguages")
        language = languages?.first.flatMap { code in L10n.supportedLanguages.contains(code) ? code : nil } ?? Self.systemLanguage
        var choices = [AudioDeviceChoice(id: "default", title: L("prefs.audio.systemDefault"), device: .systemDefault),
                       AudioDeviceChoice(id: "null", title: L("prefs.audio.null"), device: .null)]
        for d in AudioHAL.devices() where d.outputChannels > 0 {
            choices.append(AudioDeviceChoice(id: "name:" + d.name, title: d.name, device: .named(d.name)))
        }
        if case .named(let n) = s.audioDevice, !choices.contains(where: { $0.device == s.audioDevice }) {
            choices.append(AudioDeviceChoice(id: "name:" + n, title: L("prefs.audio.missing", n), device: .named(n)))
        }
        audioDeviceChoices = choices
        languageChoices = [LanguageChoice(id: Self.systemLanguage, title: L("prefs.language.system"))] + L10n.supportedLanguages.map { LanguageChoice(id: $0, title: L("prefs.language.\($0)")) }
    }

    var audioDeviceID: String {
        get { audioDeviceChoices.first { $0.device == audioDevice }?.id ?? "default" }
        set { if let c = audioDeviceChoices.first(where: { $0.id == newValue }) { audioDevice = c.device } }
    }

    var programFormat: ProgramFormat { ProgramFormat(width: formatWidth, height: formatHeight, frameRate: frameRate) }

    func selectFormatPreset(_ f: ProgramFormat) {
        formatWidth = f.width
        formatHeight = f.height
        frameRate = f.frameRate
    }

    /// 写 UserDefaults + AppController.settings（下次起 session 生效）+ 语言。
    /// 检查更新（Sparkle 自己的窗口）。
    func checkForUpdates() { controller.updateController.checkForUpdates() }
    /// 导出诊断包（与帮助菜单同一个流程）。
    func exportDiagnostics() { DiagnosticsExport.present(controller: controller) }

    func apply() {
        if updatesConfigured { controller.updateController.automaticallyChecksForUpdates = automaticUpdates }
        var s = controller.settings
        s.apiEnabled = apiEnabled
        s.apiHost = apiHost.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : apiHost.trimmingCharacters(in: .whitespaces)
        s.apiPort = max(0, min(65535, apiPort))
        s.apiToken = apiToken.isEmpty ? nil : apiToken
        s.audioDevice = audioDevice
        s.compatLayerEnabled = compatLayerEnabled
        s.compatLayerPort = max(1, min(65535, compatLayerPort))
        s.overlaysInPreview = overlaysInPreview
        s.externalBehindInterface = externalBehindInterface
        s.confirmBeforeStop = confirmBeforeStop
        controller.updateSettings(s)
        if language == Self.systemLanguage {
            controller.defaults.removeObject(forKey: "AppleLanguages")
        } else {
            controller.defaults.set([language], forKey: "AppleLanguages")
        }
        status = L("prefs.status.saved")
    }

    /// 节目格式变了就换 session（输入 / 输出原样带过去）；录制 / 推流在跑先确认（取消 = 不换）。没变返回 false。
    @discardableResult
    func applyProgramFormat() -> Bool {
        guard let session = controller.session, session.format != programFormat else { return false }
        let format = programFormat
        controller.confirmEngineRestart(.format, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.status = L("prefs.status.restarting")
            Task { await controller.changeProgramFormat(format) }
        }
        return true
    }

    /// 换了 session（换格式 / 节目音频 / 重起、新建 / 打开）：窗口不关，格式与节目音频几项按新 session 重新读一遍（W5-B，X04）。没有 session 时不动。
    func rebind() {
        guard let session = controller.session else { return }
        let restarting = status == L("prefs.status.restarting")
        formatWidth = session.format.width
        formatHeight = session.format.height
        frameRate = session.format.frameRate
        alignmentFrames = session.state.audio.alignmentFrames
        monitorPoint = session.state.audio.monitorPoint
        if restarting { status = L("prefs.status.restarted") }
    }

    /// 对齐延迟的范围（帧，48 kHz）：0 … 0.5 s。
    static let alignmentRange = 0...24_000
    static let alignmentStep = 256

    /// 对齐延迟 / 监听点变了就换 session 重建音频引擎（录制 / 推流会停）；没变返回 false。
    @discardableResult
    func applyShowAudio() -> Bool {
        guard let session = controller.session else { return false }
        let frames = min(max(alignmentFrames, Self.alignmentRange.lowerBound), Self.alignmentRange.upperBound)
        guard frames != session.state.audio.alignmentFrames || monitorPoint != session.state.audio.monitorPoint else { return false }
        let point = monitorPoint
        controller.confirmEngineRestart(.showAudio, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.status = L("prefs.status.restarting")
            Task { await controller.changeShowAudio(alignmentFrames: frames, monitorPoint: point) }
        }
        return true
    }

    /// 应用设置并立刻重起引擎（API / 音频设备 / 兼容层的改动才生效）；录制 / 推流在跑先确认，取消 = 既不应用也不重起。
    func applyAndRestart() {
        controller.confirmEngineRestart(.restart, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.apply()
            self?.status = L("prefs.status.restarting")
            Task { await controller.restartSession() }
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section(L("prefs.confirm.title")) {
                Toggle(L("prefs.confirm.stop"), isOn: $model.confirmBeforeStop)
                Text(L("prefs.confirm.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.format.title")) {
                Picker(L("prefs.format.resolution"), selection: Binding(get: { "\(model.formatWidth)x\(model.formatHeight)" }, set: { v in
                    let parts = v.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { model.formatWidth = parts[0]; model.formatHeight = parts[1] }
                })) {
                    ForEach(PreferencesModel.resolutions, id: \.0) { r in Text("\(r.0)×\(r.1)").tag("\(r.0)x\(r.1)") }
                }
                Picker(L("prefs.format.frameRate"), selection: $model.frameRate) {
                    ForEach(PreferencesModel.frameRates, id: \.self) { Text("\($0)").tag($0) }
                }
                Button(L("prefs.format.apply")) { model.applyProgramFormat() }
                Text(L("prefs.format.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.api.title")) {
                Toggle(L("prefs.api.enabled"), isOn: $model.apiEnabled)
                TextField(L("prefs.api.host"), text: $model.apiHost)
                TextField(L("prefs.api.port"), value: $model.apiPort, format: .number)
                SecureField(L("prefs.api.token"), text: $model.apiToken)
                Text(L("prefs.api.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.audio.title")) {
                Picker(L("prefs.audio.device"), selection: Binding(get: { model.audioDeviceID }, set: { model.audioDeviceID = $0 })) {
                    ForEach(model.audioDeviceChoices) { Text($0.title).tag($0.id) }
                }
                Text(L("prefs.audio.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.showAudio.title")) {
                Stepper(value: $model.alignmentFrames, in: PreferencesModel.alignmentRange, step: PreferencesModel.alignmentStep) {
                    Text(L("prefs.showAudio.alignment", model.alignmentFrames, Double(model.alignmentFrames) / 48))
                }
                Picker(L("prefs.showAudio.monitorPoint"), selection: $model.monitorPoint) {
                    ForEach(SwitcherContracts.MonitorPoint.allCases, id: \.self) { Text(L("prefs.showAudio.monitorPoint.\($0.rawValue)")).tag($0) }
                }
                Button(L("prefs.showAudio.apply")) { model.applyShowAudio() }
                Text(L("prefs.showAudio.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.preview.title")) {
                Toggle(L("prefs.preview.overlaysAll"), isOn: $model.overlaysInPreview)
                Text(L("prefs.preview.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.external.title")) {
                Toggle(L("prefs.external.behindInterface"), isOn: $model.externalBehindInterface)
                Text(L("prefs.external.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.compat.title")) {
                Toggle(L("prefs.compat.enabled"), isOn: $model.compatLayerEnabled)
                TextField(L("prefs.compat.port"), value: $model.compatLayerPort, format: .number)
                Text(PreferencesModel.compatLegalNotice).font(.caption).foregroundStyle(.secondary)
                Text(L("prefs.compat.pending")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.language.title")) {
                Picker(L("prefs.language.picker"), selection: $model.language) {
                    ForEach(model.languageChoices) { Text($0.title).tag($0.id) }
                }
                Text(L("prefs.language.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.update.title")) {
                Text(model.updateStatus).font(.caption).foregroundStyle(.secondary)
                if model.updatesConfigured {
                    Toggle(L("prefs.update.automatic"), isOn: $model.automaticUpdates)
                    Button(L("prefs.update.check")) { model.checkForUpdates() }
                    Text(L("prefs.update.pending")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(L("prefs.update.check")) {}.disabled(true)
                    Text(L("prefs.update.unconfiguredHint")).font(.caption).foregroundStyle(.secondary)
                }
                Button(L("prefs.update.exportDiagnostics")) { model.exportDiagnostics() }
                Text(L("prefs.update.diagnosticsHint")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(L("prefs.apply")) { model.apply() }.keyboardShortcut(.defaultAction)
                    Button(L("prefs.applyRestart")) { model.applyAndRestart() }
                    Spacer()
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class PreferencesWindowController: PanelWindowController {
    let model: PreferencesModel

    init(model: PreferencesModel) {
        self.model = model
        super.init(title: L("prefs.windowTitle"), size: NSSize(width: 560, height: 640), autosaveName: "Preferences", content: PreferencesView(model: model))
        model.presentingWindow = window
    }
}
