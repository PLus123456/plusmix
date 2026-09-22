import CSwitcherDeckLink
import Foundation
import SwitcherContracts

/// 输入接口（BMDVideoConnection 位集）：一台卡支持哪几个口。
/// 契约里的同名类型 `SwitcherContracts.DeckLinkConnection`（提案 008）是**单个**口（选哪个），两者用下面的 init 互转。
public struct DeckLinkConnection: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let sdi = DeckLinkConnection(rawValue: 1 << 0)
    public static let hdmi = DeckLinkConnection(rawValue: 1 << 1)
    public static let opticalSDI = DeckLinkConnection(rawValue: 1 << 2)
    public static let component = DeckLinkConnection(rawValue: 1 << 3)
    public static let composite = DeckLinkConnection(rawValue: 1 << 4)
    public static let sVideo = DeckLinkConnection(rawValue: 1 << 5)

    /// 契约里的单个口 → 位集里的那一位（提案 008）。
    public init(_ single: SwitcherContracts.DeckLinkConnection) {
        switch single {
        case .sdi: self = .sdi
        case .hdmi: self = .hdmi
        case .opticalSDI: self = .opticalSDI
        case .component: self = .component
        case .composite: self = .composite
        case .sVideo: self = .sVideo
        }
    }

    /// 位集里包含的口，按契约的单个口列出（UI 的下拉用）。
    public var supported: [SwitcherContracts.DeckLinkConnection] {
        SwitcherContracts.DeckLinkConnection.allCases.filter { contains(DeckLinkConnection($0)) }
    }

    /// 名字列表（UI 用）。
    public var names: [String] {
        var out: [String] = []
        if contains(.sdi) { out.append("SDI") }
        if contains(.hdmi) { out.append("HDMI") }
        if contains(.opticalSDI) { out.append("Optical SDI") }
        if contains(.component) { out.append("Component") }
        if contains(.composite) { out.append("Composite") }
        if contains(.sVideo) { out.append("S-Video") }
        return out
    }
}

/// 一台 DeckLink 设备（枚举结果）。`persistentID` 就是 `InputSource.decklink(deviceID:)` 该存的字符串：
/// "peid:<int64>"（卡有持久 ID 属性时）或 "model:<型号>#<序号>"。
public struct DeckLinkDeviceInfo: Hashable, Sendable {
    public var persistentID: String
    public var modelName: String
    public var displayName: String
    public var inputConnections: DeckLinkConnection
    public var supportsFormatDetection: Bool
    public var hasInput: Bool
    public var index: Int

    public init(persistentID: String, modelName: String, displayName: String, inputConnections: DeckLinkConnection,
                supportsFormatDetection: Bool, hasInput: Bool, index: Int) {
        self.persistentID = persistentID
        self.modelName = modelName
        self.displayName = displayName
        self.inputConnections = inputConnections
        self.supportsFormatDetection = supportsFormatDetection
        self.hasInput = hasInput
        self.index = index
    }

    init(_ c: sw_decklink_device_info) {
        var c = c
        persistentID = withUnsafePointer(to: &c.persistent_id) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        modelName = withUnsafePointer(to: &c.model_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        displayName = withUnsafePointer(to: &c.display_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        inputConnections = DeckLinkConnection(rawValue: c.input_connections)
        supportsFormatDetection = c.supports_input_format_detection != 0
        hasInput = c.has_input != 0
        index = Int(c.index)
    }
}

/// 设备枚举。没有 SDK / 驱动时空列表，不崩。
public enum DeckLinkDevices {
    /// 当前连着的设备。
    public static func list() -> [DeckLinkDeviceInfo] {
        var buf = [sw_decklink_device_info](repeating: sw_decklink_device_info(), count: 16)
        let n = Int(sw_decklink_enumerate(&buf, Int32(buf.count)))
        if n > buf.count {
            buf = [sw_decklink_device_info](repeating: sw_decklink_device_info(), count: n)
            _ = sw_decklink_enumerate(&buf, Int32(buf.count))
        }
        return (0..<min(n, buf.count)).map { DeckLinkDeviceInfo(buf[$0]) }
    }

    /// 按持久标识找；id 为空 = 第一台有输入的。
    public static func device(persistentID id: String) -> DeckLinkDeviceInfo? {
        let all = list()
        return id.isEmpty ? all.first { $0.hasInput } : all.first { $0.persistentID == id }
    }
}

/// 检测到的视频格式。
public struct DeckLinkVideoFormat: Hashable, Sendable, CustomStringConvertible {
    /// BMDDisplayMode 四字码。
    public var displayMode: UInt32
    public var width: Int
    public var height: Int
    public var frameDuration: Int64
    public var timeScale: Int64
    /// UYVY（'2vuy'）或 BGRA。
    public var pixelFormat: PixelFormat?
    public var interlaced: Bool
    public var name: String

    init(_ c: sw_decklink_video_format) {
        var c = c
        displayMode = c.display_mode
        width = Int(c.width)
        height = Int(c.height)
        frameDuration = c.frame_duration
        timeScale = c.time_scale
        pixelFormat = PixelFormat(cvPixelFormatType: OSType(c.pixel_format))
        interlaced = c.interlaced != 0
        name = withUnsafePointer(to: &c.name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
    }

    /// 帧率（fps）。
    public var framesPerSecond: Double { frameDuration > 0 ? Double(timeScale) / Double(frameDuration) : 0 }
    /// 帧间隔（host 时长）；帧率未知时 nil。
    public var frameInterval: HostDuration? {
        guard frameDuration > 0, timeScale > 0 else { return nil }
        return HostDuration(nanoseconds: Int64(Int128(1_000_000_000) * Int128(frameDuration) / Int128(timeScale)))
    }
    public var description: String {
        "\(width)x\(height) \(pixelFormat.map { $0.rawValue.uppercased() } ?? "?") \(timeScale)/\(frameDuration)\(interlaced ? " i" : " p")\(name.isEmpty ? "" : " " + name)"
    }
}
