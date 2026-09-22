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
    /// 解出来之后做一次性的过渡键搬迁（`migratingLegacyKeys()`），所以 App / headless 都不用各写一份。
    public static func load(from data: Data) throws -> Show {
        struct Header: Decodable { let schemaVersion: Int? }
        let header: Header
        do { header = try fileDecoder.decode(Header.self, from: data) } catch { throw ShowError.malformed("不是 JSON 对象：\(error)") }
        guard let version = header.schemaVersion else { throw ShowError.malformed("缺少 schemaVersion") }
        if version == currentSchemaVersion {
            let show = try fileDecoder.decode(Show.self, from: data).migratingLegacyKeys()
            try show.makeState().validate()
            return show
        }
        return try migrate(from: try fileDecoder.decode(JSONValue.self, from: data), schemaVersion: version)
    }

    /// 过渡键 → 正式字段的一次性搬迁（提案 010 / 013；`schemaVersion` 不升，全部字段带默认值）。
    /// 幂等：正式字段已经有值的不动；搬完清掉旧键，写出只写正式字段。放在这里是为了 App / headless / 测试读同一份。
    ///
    /// - `OutputSettings.extra["layout"]` → `OutputSettings.multiview`（010）；
    /// - `OutputSettings.extra["displayID"]` / `["fallbackToMain"]` → `OutputSettings.display`（013）；
    /// - 某路输入效果链里的 `EffectSlot(id: "border")` → 用到它的叠加通道的 `OverlayState.border`（010）。
    ///   没有叠加通道用这路输入时不动（渲染器的后备路径还认它）。
    public func migratingLegacyKeys() -> Show {
        var show = self
        for i in show.outputs.indices { show.outputs[i].settings = show.outputs[i].settings.migratingLegacyKeys() }
        // 边框：叠加通道 → 它用的输入 → 那路效果链里第一个启用的 "border" 格
        var movedFrom = Set<Int>()
        for k in show.mixer.overlays.indices {
            guard show.mixer.overlays[k].border == nil, let n = show.mixer.overlays[k].input,
                  let input = show.inputs.first(where: { $0.number == n }),
                  let slot = input.settings.effects.first(where: { $0.enabled && $0.id == OverlayBorder.legacyEffectID })
            else { continue }
            show.mixer.overlays[k].border = OverlayBorder(legacyParams: slot.params)
            movedFrom.insert(n)
        }
        for i in show.inputs.indices where movedFrom.contains(show.inputs[i].number) {
            // 只清掉搬走的那种（启用的）；停用的边框格是"配过但关了"，留着
            show.inputs[i].settings.effects.removeAll { $0.enabled && $0.id == OverlayBorder.legacyEffectID }
        }
        return show
    }

    /// 迁移占位：目前只有 v1，没有旧版本可迁。将来出 v2 时在这里逐级升级（v1 → v2 → …），旧版本文件要能读（设计方案 §4）。
    public static func migrate(from document: JSONValue, schemaVersion: Int) throws -> Show {
        switch schemaVersion {
        case currentSchemaVersion:
            let data = try JSONEncoder().encode(document)
            let show = try fileDecoder.decode(Show.self, from: data).migratingLegacyKeys()
            try show.makeState().validate()
            return show
        default:
            throw ShowError.unsupportedSchemaVersion(schemaVersion)
        }
    }
}

extension OutputSettings {
    /// `extra` 里的过渡键 → 正式字段（提案 010 / 013）。正式字段已有值的不动；搬完清掉旧键。幂等。
    public func migratingLegacyKeys() -> OutputSettings {
        var s = self
        if s.multiview == nil, let v = s.extra[MultiviewLayoutSettings.legacyExtraKey] {
            s.multiview = MultiviewLayoutSettings(legacyValue: v)
        }
        s.extra.removeValue(forKey: MultiviewLayoutSettings.legacyExtraKey)
        if s.display == nil {
            var displayID: UInt32?
            var fallback = false
            var found = false
            if case .number(let n)? = s.extra[DisplayOutputSettings.legacyDisplayIDKey], n >= 0, n <= Double(UInt32.max) {
                displayID = UInt32(n)
                found = true
            }
            if case .bool(let b)? = s.extra[DisplayOutputSettings.legacyFallbackKey] {
                fallback = b
                found = true
            }
            // 过渡键的默认是"不退回"（`ExternalDisplaySpec` 的 false），正式字段的默认是"退回"；
            // 只有出现过旧键的才搬，搬的时候按旧键的原值走，不改语义。
            if found { s.display = DisplayOutputSettings(displayID: displayID, fallbackToMain: fallback) }
        }
        s.extra.removeValue(forKey: DisplayOutputSettings.legacyDisplayIDKey)
        s.extra.removeValue(forKey: DisplayOutputSettings.legacyFallbackKey)
        return s
    }
}

extension MultiviewLayoutSettings {
    /// 过渡键名（`OutputSettings.extra`）。
    public static let legacyExtraKey = "layout"

    /// 过渡键的值 → 正式字段：字符串 = 预设名；对象 = {preset / cells / safeArea / meters}；认不出的给默认布局。
    public init(legacyValue v: JSONValue) {
        self.init()
        switch v {
        case .string(let name):
            preset = name
        case .object(let o):
            if case .string(let name)? = o["preset"] { preset = name }
            if case .bool(let b)? = o["safeArea"] { safeArea = b }
            if case .bool(let b)? = o["meters"] { meters = b }
            if case .array(let arr)? = o["cells"] {
                for e in arr {
                    guard case .object(let c) = e, case .object(let r)? = c["rect"] else { continue }
                    let source: OutputSource
                    switch c["source"] {
                    case .string("program")?: source = .program
                    case .string("preview")?: source = .preview
                    case .number(let n)? where n >= 1 && n < 1_000_000: source = .input(number: Int(n))
                    default: continue
                    }
                    func num(_ k: String) -> Double { if case .number(let d)? = r[k] { return d } else { return 0 } }
                    custom.append(MultiviewCell(source: source,
                                                rect: NormalizedRect(x: num("x"), y: num("y"), width: num("width"), height: num("height"))))
                }
            }
        default:
            break
        }
    }
}

extension DisplayOutputSettings {
    /// 过渡键名（`OutputSettings.extra`；W3-C 的 `ExternalDisplaySpec.displayIDKey` / `fallbackKey`）。
    public static let legacyDisplayIDKey = "displayID"
    public static let legacyFallbackKey = "fallbackToMain"
}

extension OverlayBorder {
    /// 过渡做法里边框效果格的 id（`InputSettings.effects`）。
    public static let legacyEffectID = "border"

    /// 效果格参数 → 正式字段：width（占节目高比例）、color（[r, g, b] 0–255）。
    public init(legacyParams params: [String: JSONValue]) {
        self.init()
        if case .number(let w)? = params["width"], w.isFinite { width = min(max(w, 0), 0.1) }
        if case .array(let a)? = params["color"], a.count >= 3 {
            func comp(_ i: Int) -> UInt8 {
                guard case .number(let v) = a[i], v.isFinite else { return 0 }
                return UInt8(min(max(v, 0), 255))
            }
            color = RGB8(red: comp(0), green: comp(1), blue: comp(2))
        }
    }
}
