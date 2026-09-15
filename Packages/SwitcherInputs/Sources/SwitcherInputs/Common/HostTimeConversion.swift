import CoreMedia
import SwitcherContracts

extension HostTime {
    /// host clock（`CMClockGetHostTimeClock`）上的 CMTime → host tick。
    /// `CMClockConvertHostTimeToSystemUnits` 直接给 mach_absolute_time 单位，不经过秒的浮点。
    @inline(__always)
    public init(hostClockTime: CMTime) {
        self.init(ticks: CMClockConvertHostTimeToSystemUnits(hostClockTime))
    }

    /// 某个时钟上的 CMTime → host tick：先 CMSyncConvertTime 到 host clock（设计方案 §3.6：AVCapture 的时间戳这么转），再换单位。
    /// `clock` 为 nil（会话还没跑起来时 synchronizationClock 可能是 nil）时按已经是 host clock 处理。
    @inline(__always)
    public init(time: CMTime, from clock: CMClock?) {
        let host = CMClockGetHostTimeClock()
        if let clock, !CFEqual(clock, host) {
            self.init(hostClockTime: CMSyncConvertTime(time, from: clock, to: host))
        } else {
            self.init(hostClockTime: time)
        }
    }

    /// 反向：host tick → host clock 的 CMTime（纳秒刻度）。
    public var cmTime: CMTime { CMTime(value: Int64(nanoseconds), timescale: 1_000_000_000) }
}

extension HostDuration {
    /// CMTime 时长 → host tick（无效 / 不定的 CMTime 给 0）。
    public init(cmDuration: CMTime) {
        guard cmDuration.isValid, !cmDuration.isIndefinite, cmDuration.timescale != 0 else {
            self.init(ticks: 0)
            return
        }
        self.init(nanoseconds: Int64((Double(cmDuration.value) * 1e9 / Double(cmDuration.timescale)).rounded()))
    }
}
