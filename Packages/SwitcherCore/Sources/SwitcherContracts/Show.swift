import Foundation

/// 节目文件里"切换"那一块：MixerState 里除 inputs / audio / outputs 之外的字段（它们在 Show 顶层各自一节）。
public struct MixerSettings: Hashable, Codable, Sendable {
    /// 节目格式。
    public var format: ProgramFormat
    /// PGM 输入编号。
    public var program: Int
    /// PVW 输入编号。
    public var preview: Int
    /// 转场选择与状态。
    public var transition: TransitionState
    /// FTB。
    public var ftb: FadeToBlack
    /// 叠加通道，恰好 4 个。
    public var overlays: [OverlayState]

    public init(format: ProgramFormat, program: Int, preview: Int, transition: TransitionState, ftb: FadeToBlack, overlays: [OverlayState]) {
        self.format = format
        self.program = program
        self.preview = preview
        self.transition = transition
        self.ftb = ftb
        self.overlays = overlays
    }

    public init(state: MixerState) {
        self.init(format: state.format, program: state.program, preview: state.preview,
                  transition: state.transition, ftb: state.ftb, overlays: state.overlays)
    }
}

/// 界面布局（窗口位置、面板开关……）。契约不解释它的内容，原样存取；App 会话自己定义键。JSON 里就是一个对象。
public struct ShowLayout: Hashable, Sendable {
    /// 原样存取的键值。
    public var values: [String: JSONValue]
    public init(values: [String: JSONValue] = [:]) { self.values = values }
}

extension ShowLayout: Codable {
    public init(from decoder: Decoder) throws { values = try decoder.singleValueContainer().decode([String: JSONValue].self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(values) }
}

/// 读节目文件的错误。
public enum ShowError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case malformed(String)
}

/// 节目文件（§1.1 Show）：一个 JSON，保存输入、切换、音频、输出、布局。schemaVersion = 1。
/// 与 MixerState 的关系：Show 是持久化形态，MixerState 是运行时快照，字段一一对应（`init(name:state:layout:)` / `makeState()`）。
public struct Show: Hashable, Codable, Sendable {
    /// 当前文件格式版本。
    public static let currentSchemaVersion = 1

    /// 文件格式版本。
    public var schemaVersion: Int
    /// 节目名。
    public var name: String
    /// 输入表。
    public var inputs: [InputConfig]
    /// 切换部分。
    public var mixer: MixerSettings
    /// 音频状态。
    public var audio: AudioState
    /// 输出表。
    public var outputs: [OutputState]
    /// 界面布局。
    public var layout: ShowLayout

    public init(schemaVersion: Int = Show.currentSchemaVersion, name: String, inputs: [InputConfig], mixer: MixerSettings,
                audio: AudioState, outputs: [OutputState], layout: ShowLayout = ShowLayout()) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.inputs = inputs
        self.mixer = mixer
        self.audio = audio
        self.outputs = outputs
        self.layout = layout
    }

    /// 从运行时状态生成。
    public init(name: String, state: MixerState, layout: ShowLayout = ShowLayout()) {
        self.init(name: name, inputs: state.inputs, mixer: MixerSettings(state: state), audio: state.audio, outputs: state.outputs, layout: layout)
    }

    /// 生成运行时状态：瞬态（转场进度等）清零，目标值直接到位。
    public func makeState() -> MixerState {
        var s = MixerState(format: mixer.format, inputs: inputs, program: mixer.program, preview: mixer.preview,
                           transition: mixer.transition, ftb: mixer.ftb, overlays: mixer.overlays, audio: audio, outputs: outputs)
        s.resetTransientState()
        return s
    }

    /// 文件编码：缩进、键排序，方便 diff。
    public static let fileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    /// 文件解码器。
    public static let fileDecoder = JSONDecoder()

    /// 编码成文件内容。
    public func save() throws -> Data { try Show.fileEncoder.encode(self) }

    /// 读文件：先看 schemaVersion，当前版本直接解，旧版本走 `migrate`，缺字段或未知版本抛错。
    public static func load(from data: Data) throws -> Show {
        struct Header: Decodable { let schemaVersion: Int? }
        let header: Header
        do { header = try fileDecoder.decode(Header.self, from: data) } catch { throw ShowError.malformed("不是 JSON 对象：\(error)") }
        guard let version = header.schemaVersion else { throw ShowError.malformed("缺少 schemaVersion") }
        if version == currentSchemaVersion {
            let show = try fileDecoder.decode(Show.self, from: data)
            try show.makeState().validate()
            return show
        }
        return try migrate(from: try fileDecoder.decode(JSONValue.self, from: data), schemaVersion: version)
    }

    /// 迁移占位：目前只有 v1，没有旧版本可迁。将来出 v2 时在这里逐级升级（v1 → v2 → …），旧版本文件要能读（设计方案 §4）。
    public static func migrate(from document: JSONValue, schemaVersion: Int) throws -> Show {
        switch schemaVersion {
        case currentSchemaVersion:
            let data = try JSONEncoder().encode(document)
            let show = try fileDecoder.decode(Show.self, from: data)
            try show.makeState().validate()
            return show
        default:
            throw ShowError.unsupportedSchemaVersion(schemaVersion)
        }
    }
}
