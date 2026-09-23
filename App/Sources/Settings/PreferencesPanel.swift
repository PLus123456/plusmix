// 偏好设置（W3-E 交付第 7 条）：节目分辨率 / 帧率（在 Show 里，改了要换 session）、API 端口 / token、音频输出设备、PVW 预览全部叠加（W3-E2）、
// 第三方 API 兼容层（VMixCompat）开关（带法律提示）、语言、更新（W4-B 接 Sparkle，这里只留位置）。
// API / 音频 / 兼容层用 W2-B2 的同一组 UserDefaults 键（AppSettings.Keys），下次起 session 生效；"应用并重启引擎"立刻生效。
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
    @Published var language: String
    @Published private(set) var status = ""
    let audioDeviceChoices: [AudioDeviceChoice]
    let languageChoices: [LanguageChoice]
    /// 更新一节的说明（W4-B 接 Sparkle 前只有文案）。
    let updateStatus = L("prefs.update.pending")
    private unowned let controller: AppController

    /// 兼容层的法律提示（设计方案 §0、§9.3：独立模块、默认关、发布前问律师）。
    static var compatLegalNotice: String { L("prefs.compat.legal") }

    init(controller: AppController) {
        self.controller = controller
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
    func apply() {
        var s = controller.settings
        s.apiEnabled = apiEnabled
        s.apiHost = apiHost.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : apiHost.trimmingCharacters(in: .whitespaces)
        s.apiPort = max(0, min(65535, apiPort))
        s.apiToken = apiToken.isEmpty ? nil : apiToken
        s.audioDevice = audioDevice
        s.compatLayerEnabled = compatLayerEnabled
        s.compatLayerPort = max(1, min(65535, compatLayerPort))
        s.overlaysInPreview = overlaysInPreview
        controller.updateSettings(s)
        if language == Self.systemLanguage {
            controller.defaults.removeObject(forKey: "AppleLanguages")
        } else {
            controller.defaults.set([language], forKey: "AppleLanguages")
        }
        status = L("prefs.status.saved")
    }

    /// 节目格式变了就换 session（输入 / 输出原样带过去）；没变返回 false。
    @discardableResult
    func applyProgramFormat() -> Bool {
        guard let session = controller.session, session.format != programFormat else { return false }
        let format = programFormat
        status = L("prefs.status.restarting")
        Task { await controller.changeProgramFormat(format) }
        return true
    }

    /// 应用设置并立刻重起引擎（API / 音频设备 / 兼容层的改动才生效）。
    func applyAndRestart() {
        apply()
        status = L("prefs.status.restarting")
        Task { await controller.restartSession() }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
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
            Section(L("prefs.preview.title")) {
                Toggle(L("prefs.preview.overlaysAll"), isOn: $model.overlaysInPreview)
                Text(L("prefs.preview.hint")).font(.caption).foregroundStyle(.secondary)
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
                Button(L("prefs.update.check")) {}.disabled(true)
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
    }
}
