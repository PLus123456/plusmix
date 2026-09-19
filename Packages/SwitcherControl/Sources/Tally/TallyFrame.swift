import Foundation
import SwitcherContracts

/// 一帧 tally：外部设备（多画面边框、面板按钮、tally 灯、TSL）要的全部信息。由快照推导，只在内容变化时发。
public struct TallyFrame: Hashable, Sendable, Encodable {
    /// 一路输入的 tally。
    public struct InputTally: Hashable, Sendable, Encodable {
        public var number: Int
        public var name: String
        public var program: Bool
        public var preview: Bool
        public init(number: Int, name: String, program: Bool, preview: Bool) {
            self.number = number
            self.name = name
            self.program = program
            self.preview = preview
        }
    }

    /// 一个输出的开关状态（录制 / 推流灯）。
    public struct OutputTally: Hashable, Sendable, Encodable {
        public var number: Int
        public var kind: OutputKind
        public var name: String
        public var enabled: Bool
        public init(number: Int, kind: OutputKind, name: String, enabled: Bool) {
            self.number = number
            self.kind = kind
            self.name = name
            self.enabled = enabled
        }
    }

    /// 固定 "tally"。
    public let type = "tally"
    /// 产生这个快照的最后一条命令的 sequence。
    public var sequence: UInt64
    /// 快照生效的拍。
    public var tick: Tick
    /// 该拍的理想时刻（有时钟时）。
    public var tickTime: HostTime?
    /// 状态机发布这个快照的时刻。
    public var publishedAt: HostTime
    /// PGM 输入编号（0 = 黑场）。
    public var program: Int
    /// PVW 输入编号。
    public var preview: Int
    /// 转场进行中（此时 PVW 输入也在 PGM 上）。
    public var transitionActive: Bool
    /// FTB 目标。
    public var ftb: Bool
    /// 任一录制输出在跑。
    public var recording: Bool
    /// 任一推流输出在跑。
    public var streaming: Bool
    /// 按编号升序。
    public var inputs: [InputTally]
    /// 录制 / 推流输出（其他种类不在这里）。
    public var outputs: [OutputTally]

    /// 由快照推导。tally 规则只在 `MixerState.tally(ofInput:)` 一处。
    public init(snapshot: MixerSnapshot, clock: TickClockSpec?) {
        let state = snapshot.state
        let tallies = state.tallies
        sequence = snapshot.sequence
        tick = snapshot.tick
        tickTime = clock?.time(of: snapshot.tick)
        publishedAt = snapshot.publishedAt
        program = state.program
        preview = state.preview
        transitionActive = state.transition.isActive
        ftb = state.ftb.on
        inputs = state.inputs.sorted { $0.number < $1.number }.map {
            let t = tallies[$0.number] ?? .off
            return InputTally(number: $0.number, name: $0.name, program: t.program, preview: t.preview)
        }
        let relevant = state.outputs.filter { $0.kind == .record || $0.kind == .stream }.sorted { $0.number < $1.number }
        outputs = relevant.map { OutputTally(number: $0.number, kind: $0.kind, name: $0.name, enabled: $0.enabled) }
        recording = relevant.contains { $0.kind == .record && $0.enabled }
        streaming = relevant.contains { $0.kind == .stream && $0.enabled }
    }

    /// 只比 tally 内容（不比 sequence / tick / 时刻）：发布器用它判断要不要出新帧。
    public func sameTally(as other: TallyFrame) -> Bool {
        program == other.program && preview == other.preview && transitionActive == other.transitionActive && ftb == other.ftb
            && recording == other.recording && streaming == other.streaming && inputs == other.inputs && outputs == other.outputs
    }

    enum CodingKeys: String, CodingKey {
        case type, sequence, tick, tickTime, publishedAt, program, preview, transitionActive, ftb, recording, streaming, inputs, outputs
    }

    /// 可选字段缺省时写 null（客户端好区分"没有"和"没这个字段"）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(tick, forKey: .tick)
        try c.encode(tickTime, forKey: .tickTime)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(program, forKey: .program)
        try c.encode(preview, forKey: .preview)
        try c.encode(transitionActive, forKey: .transitionActive)
        try c.encode(ftb, forKey: .ftb)
        try c.encode(recording, forKey: .recording)
        try c.encode(streaming, forKey: .streaming)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(outputs, forKey: .outputs)
    }
}

/// mach 时基（客户端把 host tick 换算成纳秒：ns = ticks × numer / denom）。
public struct TallyTimebase: Codable, Hashable, Sendable {
    public var numer: UInt32
    public var denom: UInt32
    public init(_ tb: MachTimebase = HostClock.timebase) {
        numer = tb.numer
        denom = tb.denom
    }
}

/// 连接建立后的第一条。
public struct TallyHelloMessage: Encodable, Sendable {
    public var type = "hello"
    public var version = SwitcherVersion.current
    public var now: HostTime
    public var timebase = TallyTimebase()
    public var clock: TickClockSpec?

    enum CodingKeys: String, CodingKey { case type, version, now, timebase, clock }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(version, forKey: .version)
        try c.encode(now, forKey: .now)
        try c.encode(timebase, forKey: .timebase)
        try c.encode(clock, forKey: .clock)
    }
}

/// 心跳：没有变化时每隔几秒一条，设备靠它判断链路还活着。
public struct TallyHeartbeatMessage: Encodable, Sendable {
    public var type = "heartbeat"
    public var now: HostTime
    /// 最近一帧的 sequence（客户端可对一下有没有漏）。
    public var sequence: UInt64
}

/// tally 流的 JSON 编码器：键排序、不转义斜杠（与 API / stats.jsonl 同一种写法）。
public enum TallyJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
