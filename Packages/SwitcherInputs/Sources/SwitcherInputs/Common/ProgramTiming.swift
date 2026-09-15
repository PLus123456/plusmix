import SwitcherContracts

/// 节目时钟的引用：格式（尺寸 / 帧率）+ 拍点时钟（t0 + 帧时长）。组装方在引擎 `start(t0:)` 之前定好 t0，把同一份交给所有输入。
///
/// 谁用：摄像头按 `format.frameRate` 协商设备格式；屏幕 `frameRate == nil` 时跟它；文件把播放位置锚到 `clock` 的拍点；
/// 图片每拍把 pts 刷新为拍点。
public struct ProgramTiming: Sendable, Hashable {
    /// 节目格式。
    public var format: ProgramFormat
    /// 拍点时钟。
    public var clock: TickClockSpec

    public init(format: ProgramFormat, clock: TickClockSpec) {
        precondition(clock.frameDuration == format.frameRate.frameDuration, "拍点时钟的帧时长必须等于节目帧率的倒数")
        self.format = format
        self.clock = clock
    }
    /// 用 t0 构造。
    public init(format: ProgramFormat, t0: HostTime) {
        self.init(format: format, clock: TickClockSpec(t0: t0, frameRate: format.frameRate))
    }

    /// 一拍的 host 时长。
    public var frameDuration: HostDuration { clock.duration(ofTicks: 1) }
    /// 第 n 拍的时刻。
    @inline(__always)
    public func time(of tick: Tick) -> HostTime { clock.time(of: tick) }
    /// 时刻属于哪一拍。
    @inline(__always)
    public func tick(at time: HostTime) -> Tick { clock.tick(at: time) }
    /// 第一个时刻 ≥ time 的拍（time 正好在拍点上就是那一拍）。
    public func nextTick(atOrAfter time: HostTime) -> Tick {
        let t = clock.tick(at: time)
        return clock.time(of: t) == time ? t : t + 1
    }
}
