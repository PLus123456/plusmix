// 音频设备与总线出口（W5-K，prompt 97 交付 5，01a J8 / 02 X08 X09 / V07）：设置 › 音频设备 选输出设备，并给每条总线（Master / Bus A / Bus B / 耳机）
// 选一个声道对或"不输出"。原来声道写死（Master 1/2、设备 ≥ 4 声道时耳机 3/4），Bus A / B 哪儿都不出、2 声道设备上耳机（独听 / PFL / AFL）没声。
// 存本机（AppSettings.busOutputMap，UserDefaults；nil = 跟设备默认），App 建音频引擎时换成 SwitcherAudio.BusChannelMap 传进 AudioEngineConfiguration
// （同一台设备上的映射包里已经支持，不改包）；改了要换 session 才生效（偏好设置的"应用并重起引擎"，录制 / 推流在跑先问）。
// 两条总线不共用一对声道：选了别人正在用的那一对，原来那条自动改成"不输出"（设备回调里后写的会盖掉先写的，C 侧散射顺序 Master → A → B → 耳机）。
// 设备只有 2 个声道时明确写"当前设备没有耳机声道"（调音台头部同一句），并给"监听时临时占用 Master 声道"的选项——
// 这一版的音频引擎还不会在独听时临时换声道（要 W1-D 系在设备回调里按"有独听"切换，问题单 W5K-w1-audio-monitor-selected-bus），选项先存下、页上写明尚未生效。
// 这一节放在偏好设置里；96（W5-J）合成"设置"窗时整节搬进"本机 › 音频设备"页（视图与模型自成一体）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherAudio

/// 每条总线送到设备的哪一对声道（存这一对第一个声道的下标，从 0 起：0 = 1/2、2 = 3/4；nil = 不输出）。
struct BusOutputMap: Codable, Equatable, Sendable {
    var master: Int?
    var busA: Int?
    var busB: Int?
    var headphones: Int?

    init(master: Int? = 0, busA: Int? = nil, busB: Int? = nil, headphones: Int? = nil) {
        self.master = master
        self.busA = busA
        self.busB = busB
        self.headphones = headphones
    }

    subscript(bus: Bus) -> Int? {
        get {
            switch bus {
            case .master: master
            case .busA: busA
            case .busB: busB
            case .headphones: headphones
            }
        }
        set {
            switch bus {
            case .master: master = newValue
            case .busA: busA = newValue
            case .busB: busB = newValue
            case .headphones: headphones = newValue
            }
        }
    }

    /// 设备默认（与包里 BusChannelMap.standard 同一口径）：Master 1/2；设备 ≥ 4 声道时耳机 3/4；Bus A / B 不输出。
    static func standard(outputChannels: Int) -> BusOutputMap {
        BusOutputMap(master: outputChannels >= 1 ? 0 : nil, headphones: outputChannels >= 4 ? 2 : nil)
    }

    /// 只留这台设备有的声道对，别的改成不输出（单声道设备上 1/2 照留：设备回调只写它有的那个声道）。
    func fitting(outputChannels: Int) -> BusOutputMap {
        var m = self
        for bus in Bus.allCases {
            guard let first = m[bus] else { continue }
            let fits = first + 1 < outputChannels || (first == 0 && outputChannels >= 1)
            if !fits { m[bus] = nil }
        }
        return m
    }

    /// 给音频引擎的映射（AudioEngineConfiguration.outputChannelMap）。
    var busChannelMap: BusChannelMap {
        func pair(_ first: Int?) -> (Int, Int)? { first.map { ($0, $0 + 1) } }
        return BusChannelMap(master: pair(master), busA: pair(busA), busB: pair(busB), headphones: pair(headphones))
    }
}

@MainActor
final class AudioOutputSettingsModel: ObservableObject {
    /// 一台输出设备（测试注入假的）。
    struct DeviceInfo: Hashable {
        var name: String
        var outputChannels: Int
    }
    struct DeviceChoice: Identifiable, Hashable {
        let id: String
        let title: String
        let device: AppSettings.AudioDevice
        /// 输出声道数（空设备 / 不知道为 nil）。
        let outputChannels: Int?
    }
    struct PairChoice: Identifiable, Hashable {
        /// 这一对第一个声道的下标；nil = 不输出。
        var first: Int?
        var title: String
        var id: Int { first ?? -1 }
    }

    @Published private(set) var device: AppSettings.AudioDevice
    @Published private(set) var map: BusOutputMap
    /// 用户改过声道（没改过 = 跟设备默认，存 nil）。
    @Published private(set) var isCustomized: Bool
    @Published var borrowMasterForMonitor: Bool
    @Published private(set) var devices: [DeviceChoice] = []
    /// 刚才自动改成"不输出"的总线（选了别人正在用的那一对）：页上说一句。
    @Published private(set) var lastDisplaced: Bus?
    /// 列设备（测试注入假的）；默认读 CoreAudio。
    var devicesProvider: () -> [DeviceInfo] = {
        AudioHAL.devices().filter { $0.outputChannels > 0 }.map { DeviceInfo(name: $0.name, outputChannels: $0.outputChannels) }
    }
    /// 系统默认输出设备的声道数。
    var systemDefaultChannels: () -> Int? = { AudioHAL.defaultOutputDevice().map { AudioHAL.info($0).outputChannels } }

    init(device: AppSettings.AudioDevice, map: BusOutputMap?, borrowMasterForMonitor: Bool = false) {
        self.device = device
        self.map = map ?? BusOutputMap()
        isCustomized = map != nil
        self.borrowMasterForMonitor = borrowMasterForMonitor
        reloadDevices()
    }

    /// 重新列设备：系统默认 / 不出声（空设备）/ 每台有输出声道的设备；设置里那台不在了也列（标"不在"）。
    func reloadDevices() {
        let list = devicesProvider()
        var choices = [DeviceChoice(id: "default", title: L("prefs.audio.systemDefault"), device: .systemDefault, outputChannels: systemDefaultChannels()),
                       DeviceChoice(id: "null", title: L("prefs.audio.null"), device: .null, outputChannels: nil)]
        for d in list {
            choices.append(DeviceChoice(id: "name:" + d.name, title: L("audioDevice.deviceLine", d.name, d.outputChannels), device: .named(d.name), outputChannels: d.outputChannels))
        }
        if case .named(let n) = device, !choices.contains(where: { $0.device == device }) {
            choices.append(DeviceChoice(id: "name:" + n, title: L("prefs.audio.missing", n), device: device, outputChannels: nil))
        }
        devices = choices
        if !isCustomized, let channels = outputChannels { map = .standard(outputChannels: channels) }
    }

    var selectedID: String { devices.first { $0.device == device }?.id ?? "default" }

    /// 换设备：声道按新设备收（没改过的跟新设备的默认；改过的只去掉这台没有的声道对）。
    func selectDevice(_ newDevice: AppSettings.AudioDevice) {
        device = newDevice
        lastDisplaced = nil
        guard let channels = outputChannels else { return }
        map = isCustomized ? map.fitting(outputChannels: channels) : .standard(outputChannels: channels)
    }

    func selectDevice(id: String) {
        if let c = devices.first(where: { $0.id == id }) { selectDevice(c.device) }
    }

    /// 选中的设备有几个输出声道（空设备 / 不在了为 nil）。
    var outputChannels: Int? { devices.first { $0.device == device }?.outputChannels }

    /// 声道对的选项："不输出"、1/2、3/4……（按这台设备的声道数）。
    var pairChoices: [PairChoice] {
        var out = [PairChoice(first: nil, title: L("audioDevice.noOutput"))]
        if let channels = outputChannels {
            for first in stride(from: 0, to: max(channels, 1), by: 2) {
                out.append(PairChoice(first: first, title: first + 1 < channels ? "\(first + 1)/\(first + 2)" : "\(first + 1)"))
            }
        }
        return out
    }

    /// 给一条总线选声道对；别的总线正用着这一对就改成"不输出"（不共用，见文件头）。
    func setPair(_ bus: Bus, first: Int?) {
        guard map[bus] != first else { return }
        var m = map
        lastDisplaced = nil
        if let first {
            for other in Bus.allCases where other != bus && m[other] == first {
                m[other] = nil
                lastDisplaced = other
            }
        }
        m[bus] = first
        map = m
        isCustomized = true
    }

    /// 恢复设备默认（Master 1/2，≥ 4 声道时耳机 3/4）。
    func resetToDeviceDefault() {
        isCustomized = false
        lastDisplaced = nil
        map = .standard(outputChannels: outputChannels ?? 2)
    }

    /// 存哪一份（没改过存 nil = 跟设备默认）。
    var storedMap: BusOutputMap? { isCustomized ? map : nil }

    /// 设备只有 2 个（或更少）声道：耳机总线（独听 / PFL / AFL）没有声道可出（X09）。空设备不提示。
    var headphonesHint: String? {
        guard let channels = outputChannels, channels > 0, channels <= 2 else { return nil }
        return L("audioDevice.noHeadphoneChannels")
    }

    /// 给"监听时临时占用 Master 声道"的选项（只在 2 声道设备上有意义）。
    var offersBorrowMasterForMonitor: Bool { headphonesHint != nil }

    /// 这台设备的声道说明。
    var channelSummary: String? { outputChannels.map { L("audioDevice.channelCount", $0) } }
}

/// 设置 › 音频设备 一节（偏好设置里；96 合窗后整节搬进"本机 › 音频设备"）。
struct AudioOutputSettingsSection: View {
    @ObservedObject var model: AudioOutputSettingsModel

    var body: some View {
        Section(L("prefs.audio.title")) {
            Picker(L("prefs.audio.device"), selection: Binding(get: { model.selectedID }, set: { model.selectDevice(id: $0) })) {
                ForEach(model.devices) { Text($0.title).tag($0.id) }
            }
            if let summary = model.channelSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
            if let hint = model.headphonesHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ForEach(Bus.allCases, id: \.self) { bus in
                Picker(L("audioDevice.busOutput", L("bus.\(bus.name)")), selection: Binding(get: { model.map[bus] ?? -1 }, set: { model.setPair(bus, first: $0 < 0 ? nil : $0) })) {
                    ForEach(model.pairChoices) { Text($0.title).tag($0.id) }
                }
            }
            if let displaced = model.lastDisplaced {
                Text(L("audioDevice.displaced", L("bus.\(displaced.name)"))).font(.caption).foregroundStyle(.orange)
            }
            if model.offersBorrowMasterForMonitor {
                Toggle(L("audioDevice.borrowMaster"), isOn: $model.borrowMasterForMonitor)
            }
            HStack {
                Button(L("audioDevice.resetMap")) { model.resetToDeviceDefault() }.disabled(!model.isCustomized)
                Spacer()
            }
            Text(L("audioDevice.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
