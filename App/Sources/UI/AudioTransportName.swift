// 音频设备的连接方式（W5-A，03-目视检查.md V-14 / V-16）：包里给的是 CoreAudio 的传输类型四字码（kAudioDeviceTransportType*，"bltn"、"usb " 之类），
// 原来原样进了添加输入的说明行；这里翻成人话。码表按 macOS SDK 的 AudioHardwareBase.h（探针核对过）；不认识的和 0（包里显示成 "????"）不写。
import Foundation

enum AudioTransportName {
    /// 四字码 → 文案键的后缀。
    static let keys: [String: String] = [
        "bltn": "builtIn", "usb ": "usb", "blue": "bluetooth", "blea": "bluetoothLE", "thun": "thunderbolt", "pci ": "pci",
        "1394": "firewire", "hdmi": "hdmi", "dprt": "displayPort", "airp": "airPlay", "eavb": "avb", "grup": "aggregate",
        "virt": "virtual", "ccwd": "continuityWired", "ccwl": "continuityWireless", "rscr": "remoteScreen", "rstr": "remoteStreaming",
    ]

    /// 显示名；没有 / 不认识返回 nil。
    static func title(fourCC: String) -> String? {
        keys[fourCC].map { L("audio.transport.\($0)") }
    }
}
