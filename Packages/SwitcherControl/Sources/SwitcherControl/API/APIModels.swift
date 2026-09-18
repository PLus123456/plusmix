import Foundation
import SwitcherContracts

// HTTP / WS 的报文结构（docs/api.md 由这些类型和 CommandCatalog 生成）。
// 键名与 Codable 一致：MixerState / Stats / Tally / Command 都原样嵌入，不另造一套字段。

/// mach 时基（客户端把 host tick 换算成纳秒：ns = ticks × numer / denom）。
public struct TimebaseInfo: Codable, Hashable, Sendable {
    public var numer: UInt32
    public var denom: UInt32
    public init(_ tb: MachTimebase = HostClock.timebase) {
        numer = tb.numer
        denom = tb.denom
    }
}

/// GET /api/v1/state。
public struct StateResponse: Encodable, Sendable {
    public var version = SwitcherVersion.current
    /// 服务端此刻的 host time。
    public var now: HostTime
    public var timebase = TimebaseInfo()
    /// 节目时钟（引擎没起时钟为 nil）。
    public var clock: TickClockSpec?
    /// 产生这个快照的最后一条命令的 sequence（0 = 初始）。
    public var sequence: UInt64
    /// 快照生效的拍。
    public var tick: Tick
    /// 该拍的理想时刻（有时钟时）。
    public var tickTime: HostTime?
    /// 状态机发布这个快照的时刻。
    public var publishedAt: HostTime
    public var state: MixerState
    /// 每路已配置输入的 tally。
    public var tally: [Int: Tally]
    /// stats.jsonl 的最近一行（还没采到为 nil）。
    public var stats: Stats?

    enum CodingKeys: String, CodingKey { case version, now, timebase, clock, sequence, tick, tickTime, publishedAt, state, tally, stats }
    /// 可选字段缺省时写 null（合成的 Codable 会整个省略键，客户端不好区分"没有"和"没这个字段"）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(now, forKey: .now)
        try c.encode(timebase, forKey: .timebase)
        try c.encode(clock, forKey: .clock)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(tick, forKey: .tick)
        try c.encode(tickTime, forKey: .tickTime)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(state, forKey: .state)
        try c.encode(tally, forKey: .tally)
        try c.encode(stats, forKey: .stats)
    }
}

/// POST /api/v1/command 的请求体：`{"command": <Command>}`；也接受直接放 `<Command>`（见 `CommandEnvelope.decode`）。
public struct CommandRequest: Decodable, Sendable {
    public var command: Command
}

/// 命令回执（HTTP 应答体）。
public struct CommandResponse: Encodable, Sendable {
    public var sequence: UInt64
    public var appliedTick: Tick
    /// 状态是否真的变了（false = reducer 按规则忽略）。
    public var applied: Bool
    public var issuedAt: HostTime
    public var appliedTickTime: HostTime?
    public init(receipt: CommandReceipt, issuedAt: HostTime, clock: TickClockSpec?) {
        sequence = receipt.sequence
        appliedTick = receipt.appliedTick
        applied = receipt.applied
        self.issuedAt = issuedAt
        appliedTickTime = clock?.time(of: receipt.appliedTick)
    }

    enum CodingKeys: String, CodingKey { case sequence, appliedTick, applied, issuedAt, appliedTickTime }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(appliedTick, forKey: .appliedTick)
        try c.encode(applied, forKey: .applied)
        try c.encode(issuedAt, forKey: .issuedAt)
        try c.encode(appliedTickTime, forKey: .appliedTickTime)
    }
}

/// 出错应答体。
public struct ErrorResponse: Encodable, Sendable {
    public var error: String
    public init(_ error: String) { self.error = error }
}

/// 批量请求体：`{"commands": [<Command>, …]}`，按顺序执行，sequence 连续。
public struct BatchCommandRequest: Decodable, Sendable {
    public var commands: [Command]
}

/// 批量回执：全部成功 200；第 index 条被拒时 400，带前面已生效的回执。
public struct BatchCommandResponse: Encodable, Sendable {
    public var receipts: [CommandResponse]
    public var error: String?
    public var index: Int?

    enum CodingKeys: String, CodingKey { case receipts, error, index }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(receipts, forKey: .receipts)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(index, forKey: .index)
    }
}

/// GET /api/v1/log：最近走过总线的命令（诊断用）。
public struct CommandLogResponse: Encodable, Sendable {
    public var entries: [CommandLogEntry]
}

/// GET /api/v1/tally：给外部 tally / 面板轮询用的小应答。
public struct TallyResponse: Encodable, Sendable {
    public var sequence: UInt64
    public var tick: Tick
    public var program: Int
    public var preview: Int
    public var tally: [Int: Tally]
}

/// GET /api/v1/commands 的一项。
public struct CommandCatalogEntry: Encodable, Sendable {
    public var kind: CommandKind
    public var group: String
    public var summary: String
    public var parameters: [String: String]
    public var example: Command
    public init(_ doc: CommandDoc) {
        kind = doc.kind
        group = doc.group
        summary = doc.summary
        parameters = Dictionary(uniqueKeysWithValues: doc.parameters.map { ($0.name, $0.note) })
        example = doc.example
    }
}

/// GET /api/v1/commands。
public struct CommandCatalogResponse: Encodable, Sendable {
    public var commands: [CommandCatalogEntry] = CommandCatalog.entries.map(CommandCatalogEntry.init)
}

// MARK: WebSocket 报文

/// 连接建立后的第一条。
public struct HelloMessage: Encodable, Sendable {
    public var type = "hello"
    public var version = SwitcherVersion.current
    public var now: HostTime
    public var timebase = TimebaseInfo()
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

/// 状态快照（整快照 + 版本号）。
public struct SnapshotMessage: Encodable, Sendable {
    public var type = "snapshot"
    public var sequence: UInt64
    public var tick: Tick
    public var tickTime: HostTime?
    /// 状态机发布这个快照的时刻（C2 的"状态变化 → 客户端"从它算）。
    public var publishedAt: HostTime
    /// 服务端序列化这条消息的时刻。
    public var sentAt: HostTime
    public var state: MixerState
    public var tally: [Int: Tally]

    enum CodingKeys: String, CodingKey { case type, sequence, tick, tickTime, publishedAt, sentAt, state, tally }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(tick, forKey: .tick)
        try c.encode(tickTime, forKey: .tickTime)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(state, forKey: .state)
        try c.encode(tally, forKey: .tally)
    }
}

/// 每秒一行 Stats。
public struct StatsMessage: Encodable, Sendable {
    public var type = "stats"
    public var stats: Stats
}

/// 客户端在 WS 上发的命令：`{"id": <任意 JSON>, "command": <Command>}` 或 `{"id": …, "commands": [<Command>, …]}`。
public struct WSCommandRequest: Decodable, Sendable {
    public var id: JSONValue?
    public var command: Command?
    public var commands: [Command]?
}

/// WS 批量回执。
public struct WSReceiptsMessage: Encodable, Sendable {
    public var type = "receipts"
    public var id: JSONValue?
    public var receipts: [ReceiptMessage]
    public var error: String?
    public var index: Int?

    enum CodingKeys: String, CodingKey { case type, id, receipts, error, index }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(receipts, forKey: .receipts)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(index, forKey: .index)
    }
}

/// WS 命令的回执。
public struct ReceiptMessage: Encodable, Sendable {
    public var type = "receipt"
    public var id: JSONValue?
    public var sequence: UInt64
    public var appliedTick: Tick
    public var applied: Bool
    public var issuedAt: HostTime
    public var appliedTickTime: HostTime?

    enum CodingKeys: String, CodingKey { case type, id, sequence, appliedTick, applied, issuedAt, appliedTickTime }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(appliedTick, forKey: .appliedTick)
        try c.encode(applied, forKey: .applied)
        try c.encode(issuedAt, forKey: .issuedAt)
        try c.encode(appliedTickTime, forKey: .appliedTickTime)
    }
}

/// WS 命令出错。
public struct WSErrorMessage: Encodable, Sendable {
    public var type = "error"
    public var id: JSONValue?
    public var error: String
}

/// 请求体里的命令：一条或一批。
public enum CommandPayload: Sendable {
    case single(Command)
    case batch([Command])
}

/// 解析命令请求体：`{"commands": [...]}`、`{"command": ...}` 或裸 Command。
public enum CommandEnvelope {
    public static func decode(_ data: Data) throws -> Command {
        if let wrapped = try? APIJSON.decoder.decode(CommandRequest.self, from: data) { return wrapped.command }
        return try APIJSON.decoder.decode(Command.self, from: data)
    }

    /// 批量或单条。空的 commands 数组算错。
    public static func decodePayload(_ data: Data) throws -> CommandPayload {
        if let batch = try? APIJSON.decoder.decode(BatchCommandRequest.self, from: data) {
            guard !batch.commands.isEmpty else { throw EnvelopeError.emptyBatch }
            return .batch(batch.commands)
        }
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["commands"] != nil {
            // 有 commands 键但解不成命令数组：把解码错误报出去，别当成裸 Command
            _ = try APIJSON.decoder.decode(BatchCommandRequest.self, from: data)
        }
        return .single(try decode(data))
    }

    public enum EnvelopeError: Error, CustomStringConvertible {
        case emptyBatch
        public var description: String { "commands 不能是空数组" }
    }

    /// 给人看的解码错误。
    public static func describe(_ error: any Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .keyNotFound(let k, let ctx): return "命令 JSON 缺少键 \(k.stringValue)（\(ctx.debugDescription)）"
            case .typeMismatch(_, let ctx): return "命令 JSON 类型不对：\(ctx.debugDescription)"
            case .valueNotFound(_, let ctx): return "命令 JSON 缺值：\(ctx.debugDescription)"
            case .dataCorrupted(let ctx): return "命令 JSON 无法解析：\(ctx.debugDescription)"
            @unknown default: return "命令 JSON 无法解析：\(e)"
            }
        }
        if let e = error as? EnvelopeError { return e.description }
        return "命令 JSON 无法解析：\(error)"
    }
}
