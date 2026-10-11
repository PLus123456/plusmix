// 设置"性能与电源"页（W5-L，01a P1 / 04 Q47）：两个开关——引擎运行时阻止系统睡眠与 App Nap、阻止显示器休眠（默认都开，即时生效，存本机设置）；
// 一行现状（现在拿着哪几条，EngineActivity）；下面只读显示机型 / 芯片 / 内存 / GPU / 系统（本机信息，启动时取一次，不进 Stats，同 Q45 的口径）。
import AppKit
import IOKit
import Metal
import SwiftUI

@MainActor
final class PowerSettingsModel: ObservableObject {
    /// 只读的一行"名称：值"。
    struct MachineRow: Identifiable, Equatable {
        var label: String
        var value: String
        var id: String { label }
    }

    @Published var preventSleep: Bool {
        didSet { if preventSleep != oldValue { commit() } }
    }
    @Published var preventDisplaySleep: Bool {
        didSet { if preventDisplaySleep != oldValue { commit() } }
    }
    let machineRows: [MachineRow]
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        preventSleep = controller.settings.preventSleepWhileRunning
        preventDisplaySleep = controller.settings.preventDisplaySleepWhileRunning
        machineRows = PowerMachineInfo.rows
    }

    /// 即时生效：只写这两个键，AppController 按引擎在不在跑拿 / 放。
    private func commit() {
        let (sleep, display) = (preventSleep, preventDisplaySleep)
        controller.updateSettings({ $0.preventSleepWhileRunning = sleep; $0.preventDisplaySleepWhileRunning = display }, saving: { $0.savePower(to: $1) })
        objectWillChange.send()   // 现状那一行跟着变
    }

    /// 现状："引擎运行中：已阻止系统睡眠与 App Nap、已阻止显示器休眠" / "引擎没在跑：不阻止"。
    var statusText: String {
        let activity = controller.engineActivity
        guard controller.session?.isRunning == true else { return L("prefs.power.status.idle") }
        var held: [String] = []
        if activity.holdsSystemActivity { held.append(L("prefs.power.status.system")) }
        if activity.holdsDisplayActivity { held.append(L("prefs.power.status.display")) }
        return held.isEmpty ? L("prefs.power.status.none") : L("prefs.power.status.running", held.joined(separator: L("prefs.remote.listSeparator")))
    }
}

/// 本机信息（只读，启动时取一次）。G7 合并时改名（96 的 PreferencesPanel 里原来也有一个 MachineInfo，两边同名；那份没人用，W5-N 删了）。
enum PowerMachineInfo {
    @MainActor
    static let rows: [PowerSettingsModel.MachineRow] = {
        var model = sysctlString("hw.model") ?? "Mac"
        if let product = productName { model = L("prefs.power.machine.modelNamed", product, model) }
        let memory = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "—"
        let gpu = gpuCoreCount.map { L("prefs.power.machine.gpuCores", gpuName, $0) } ?? gpuName
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            .init(label: L("prefs.power.machine.model"), value: model),
            .init(label: L("prefs.power.machine.chip"), value: sysctlString("machdep.cpu.brand_string") ?? "—"),
            .init(label: L("prefs.power.machine.memory"), value: L("prefs.power.machine.memoryGB", memory)),
            .init(label: L("prefs.power.machine.gpu"), value: gpu),
            .init(label: L("prefs.power.machine.os"), value: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        ]
    }()

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 市场名（"MacBook Pro (16-inch, M5 Max)"）：IODeviceTree:/product 的 product-name；没有为 nil。
    static var productName: String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return nil }
        let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// GPU 核数（AGXAccelerator 的 gpu-core-count）；查不到为 nil。
    static var gpuCoreCount: Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
}

struct PowerSettingsSection: View {
    @ObservedObject var model: PowerSettingsModel

    var body: some View {
        Section(L("prefs.power.title")) {
            Toggle(L("prefs.power.preventSleep"), isOn: $model.preventSleep)
            Toggle(L("prefs.power.preventDisplaySleep"), isOn: $model.preventDisplaySleep)
            Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            Text(L("prefs.power.hint")).font(.caption).foregroundStyle(.secondary)
            ForEach(model.machineRows) { row in
                LabeledContent(row.label) { Text(verbatim: row.value).textSelection(.enabled) }
            }
        }
    }
}
