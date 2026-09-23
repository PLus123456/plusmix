import SwitcherContracts

/// 热插拔事件记录（S5 摄像头 / S4 音频设备的计时用）。输入自己在状态变化时填。
public struct InputHotplugEvents: Hashable, Sendable {
    /// 收到"设备断开"的次数。
    public var disconnects: UInt64 = 0
    /// 收到"设备接上"的次数。
    public var connects: UInt64 = 0
    /// 最近一次断开通知的时刻。
    public var lastDisconnectAt: HostTime?
    /// 最近一次连接通知的时刻。
    public var lastConnectAt: HostTime?
    /// 最近一次进 live 的时刻。
    public var lastLiveAt: HostTime?
    /// 最近一次状态变化的时刻。
    public var lastStateChangeAt: HostTime?
    public init() {}
}

/// 能被 `HotplugTimer` 计时的输入（摄像头、音频设备）。
public protocol HotplugMonitorable: AnyObject {
    /// 输入编号（拔插前后不该变）。
    var number: Int { get }
    /// 当前状态。
    var state: InputState { get }
    /// 最近一次错误 / 提示文案。
    var lastError: String? { get }
    /// 热插拔事件。
    var hotplugEvents: InputHotplugEvents { get }
    /// 提示语里的设备叫法（设备名，退回标识符）。
    var hotplugDeviceLabel: String { get }
}
