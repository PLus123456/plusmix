// 音频设备与总线出口（W5-K，prompt 97 交付 5，01a J8 / 02 X08 X09 / V07）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherAudio

/// 每条总线送到设备的哪一对声道（存第一个声道的下标，从 0 起；nil = 不输出）。
struct BusOutputMap: Codable, Equatable, Sendable {
    var master: Int?
    var busA: Int?
    var busB: Int?
    var headphones: Int?

    static func standard(outputChannels: Int) -> BusOutputMap { BusOutputMap(master: 0) }
    var busChannelMap: BusChannelMap { BusChannelMap() }
}

@MainActor
final class AudioOutputSettingsModel: ObservableObject {
    struct DeviceInfo: Hashable {
        var name: String
        var outputChannels: Int
    }
    struct PairChoice: Hashable, Identifiable {
        var first: Int?
        var title: String
        var id: String { first.map(String.init) ?? "none" }
    }
    @Published var device: AppSettings.AudioDevice
    @Published var map: BusOutputMap
    @Published var borrowMasterForMonitor = false
    var devicesProvider: () -> [DeviceInfo] = { [] }

    init(device: AppSettings.AudioDevice, map: BusOutputMap?) {
        self.device = device
        self.map = map ?? BusOutputMap(master: 0)
    }

    func reloadDevices() {}
    func selectDevice(_ device: AppSettings.AudioDevice) { self.device = device }
    var outputChannels: Int? { nil }
    var pairChoices: [PairChoice] { [] }
    func setPair(_ bus: Bus, first: Int?) {}
    var headphonesHint: String? { nil }
    var offersBorrowMasterForMonitor: Bool { false }
}
