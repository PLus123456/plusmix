@preconcurrency import AVFoundation
import SwitcherContracts

/// 摄像头 / UVC 设备清单（探针、UI 用）。
public struct CameraDeviceInfo: Hashable, Sendable {
    public var uniqueID: String
    public var name: String
    public var modelID: String
    public var deviceType: String
    public var isConnected: Bool
    /// 有关联的音频设备（USB 摄像头自带麦克风）。
    public var linkedAudioDeviceName: String?
    public var formats: [CameraFormatNegotiation.Candidate]
}

public enum CameraDevices {
    /// 视频采集设备的发现会话：内置、外接（UVC / 连续互通）、桌上视角。
    static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified)
    }

    /// 当前所有视频设备。
    public static func list() -> [CameraDeviceInfo] {
        discovery().devices.map { info(of: $0) }
    }

    static func info(of d: AVCaptureDevice) -> CameraDeviceInfo {
        CameraDeviceInfo(uniqueID: d.uniqueID, name: d.localizedName, modelID: d.modelID, deviceType: d.deviceType.rawValue,
                         isConnected: d.isConnected,
                         linkedAudioDeviceName: d.linkedDevices.first { $0.hasMediaType(.audio) }?.localizedName,
                         formats: candidates(of: d))
    }

    /// 按 uniqueID 找设备；"0"、"1" 这样的下标也认（探针 / 命令行方便）。
    public static func device(uniqueID: String) -> AVCaptureDevice? {
        if let d = AVCaptureDevice(uniqueID: uniqueID) { return d }
        if let index = Int(uniqueID) {
            let list = discovery().devices
            return index >= 0 && index < list.count ? list[index] : nil
        }
        return nil
    }

    static func candidates(of d: AVCaptureDevice) -> [CameraFormatNegotiation.Candidate] {
        d.formats.enumerated().map { i, f in
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return CameraFormatNegotiation.Candidate(index: i, mediaSubType: CMFormatDescriptionGetMediaSubType(f.formatDescription),
                                                     width: Int(dims.width), height: Int(dims.height),
                                                     frameRateRanges: f.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate })
        }
    }

    /// 四字码。
    public static func fourCC(_ v: OSType) -> String {
        String(format: "%c%c%c%c", (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }
}
