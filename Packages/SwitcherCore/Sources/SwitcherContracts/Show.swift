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
    /// 叠加通道，恰好 4 个（`Show.validateStructure()` 在构造 MixerState 之前查，提案 034 ③）。
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

    /// 生成运行时状态：瞬态（转场进度等）清零，目标值直接到位。叠加不是 4 个会在 `MixerState.init` 里断言——那是写错代码；
    /// 文件 / API 进来的节目走 `makeValidatedState()`。
    public func makeState() -> MixerState {
        var s = MixerState(format: mixer.format, inputs: inputs, program: mixer.program, preview: mixer.preview,
                           transition: mixer.transition, ftb: mixer.ftb, overlays: mixer.overlays, audio: audio, outputs: outputs)
        s.resetTransientState()
        return s
    }

    /// 构造 MixerState 之前的结构检查（提案 034 ③，用户 2026-10-25 批；Codex N02）：叠加恰好 4 个（`MixerStateError.overlayCount`）、
    /// 转场槽恰好 4 个或空（空的由 `migratingLegacyKeys()` 补出厂槽；否则 `.transitionSlotCount`）。原来 `makeState()` 的 precondition 跑在 `validate()` 之前，
    /// overlayCount 这个错误永远到不了、一份 `"overlays": []` 的文件就让进程 SIGTRAP。搬迁前后调都对（搬迁不改叠加个数、只把空槽补成 4 个）。
    public func validateStructure() throws {
        guard mixer.overlays.count == MixerState.overlayCount else { throw MixerStateError.overlayCount(mixer.overlays.count) }
        let slots = mixer.transition.slots.count
        guard slots == TransitionSlot.count || slots == 0 else { throw MixerStateError.transitionSlotCount(slots) }
    }

    /// 不可信的节目（文件、API 的 loadShow）生成运行时状态：`validateStructure()` → `makeState()` → `validate()`，哪一步不过就抛、进程在（提案 034 ③）。
    /// Show.load / migrate、CommandValidator 与 reducer 的 loadShow 四处都是先 `migratingLegacyKeys()` 再调它，判得一致。
    public func makeValidatedState() throws -> MixerState {
        try validateStructure()
        let state = makeState()
        try state.validate()
        return state
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
            _ = try show.makeValidatedState()
            return show
        }
        return try migrate(from: try fileDecoder.decode(JSONValue.self, from: data), schemaVersion: version)
    }

    /// 过渡键 → 正式字段的一次性搬迁（提案 010 / 013；`schemaVersion` 不升，全部字段带默认值），顺带清掉老版本留下的死数据（P4）；020 的转场槽补齐也在这里。
    /// 幂等：正式字段已经有值的不动；搬完清掉旧键，写出只写正式字段。放在这里是为了 App / headless / 测试读同一份；
    /// 状态机对 loadShow（整份）与 addOutput / setOutputSettings（`OutputSettings.migratingLegacyKeys()`）进来的数据也先搬（P4），
    /// 所以状态机里的状态不会再有输出的过渡键；setInputSettings / addInput 带进来的 border 格不搬（没有叠加通道的上下文），存盘再读时清掉。
    ///
    /// - `OutputSettings.extra["layout"]` → `OutputSettings.multiview`（010）；
    /// - `OutputSettings.extra["displayID"]` / `["fallbackToMain"]` → `OutputSettings.display`（013）；
    /// - 某路输入效果链里第一个启用的 `EffectSlot(id: "border")` → 用到这路输入、还没有边框的叠加通道的 `OverlayState.border`（010）。
    ///   搬完之后所有 "border" 格一律清掉：没有叠加通道用到的、停用的、通道已有正式边框而没搬的都算——读它的后备路径 W3-B2 删了，留着没人读（P4）；
    /// - `transition.stinger.input` 指向不存在的输入 → nil：P4 之前 removeInput 不清这个引用，删掉 Stinger 用的那一路之后存下的文件里留着悬空编号，
    ///   清成与 removeInput 现在的规则同一结果（`validate()` 不查引用）。
    public func migratingLegacyKeys() -> Show {
        var show = self
        for i in show.outputs.indices { show.outputs[i].settings = show.outputs[i].settings.migratingLegacyKeys() }
        // 边框：叠加通道 → 它用的输入 → 那路效果链里第一个启用的 "border" 格
        for k in show.mixer.overlays.indices {
            guard show.mixer.overlays[k].border == nil, let n = show.mixer.overlays[k].input,
                  let input = show.inputs.first(where: { $0.number == n }),
                  let slot = input.settings.effects.first(where: { $0.enabled && $0.id == OverlayBorder.legacyEffectID })
            else { continue }
            show.mixer.overlays[k].border = OverlayBorder(legacyParams: slot.params)
        }
        for i in show.inputs.indices {
            show.inputs[i].settings.effects.removeAll { $0.id == OverlayBorder.legacyEffectID }
        }
        if let n = show.mixer.transition.stinger.input, !show.inputs.contains(where: { $0.number == n }) {
            show.mixer.transition.stinger.input = nil
        }
        // 转场槽（提案 020）：020 之前的文件没有 slots → 按节目帧率补出厂四槽，槽 1 换成文件里原来那组（原来是 cut 的槽 1 用 Fade 0.5 s）；
        // currentSlot = 当前那组对得上的槽（原来那组进了槽 1 就是 1；cut 对不上任何槽 → nil，当前那组仍是 cut，行为不变）。
        // 有 slots 没 currentSlot 的照 nil。四个槽里指向不存在输入的 stinger.input 置 nil（P4 清当前那组悬空引用的规则扩到槽）。幂等。
        if show.mixer.transition.slots.isEmpty {
            var slots = TransitionSlot.factoryDefaults(for: show.mixer.format)
            let group = show.mixer.transition.currentGroup
            if group.type != .cut { slots[0] = group }
            show.mixer.transition.slots = slots
            show.mixer.transition.currentSlot = show.mixer.transition.slotIndexMatchingCurrentGroup()
        }
        for k in show.mixer.transition.slots.indices {
            if let n = show.mixer.transition.slots[k].stinger.input, !show.inputs.contains(where: { $0.number == n }) {
                show.mixer.transition.slots[k].stinger.input = nil
            }
        }
        return show
    }

    /// 提案 023 第四节：W5-H 存在 `layout["inputCategories"]`（`{"<输入编号>": "<颜色>"}`）里的分类 → 各路 `InputConfig.color`。
    /// 有键按原值搬（认不出的颜色 / 不存在的编号跳过；正式字段已有值的不动），搬完删键；名字键 `inputCategoryNames` 留在 layout（(a)，契约不解释）；幂等。
    /// **不在 `migratingLegacyKeys()` 里自动调**（与 025 同一做法）：现在的 App 还在读写 layout 键，并进去会在 App 切换之前把分类清掉；
    /// App 切换时在 Show.load 后调一次、读写切到字段（归 100 之后的 App 会话或 G8 胶水），之后可以并进 `migratingLegacyKeys()`。
    public func migratingLegacyInputCategories() -> Show {
        var show = self
        guard let raw = show.layout.values[InputConfig.legacyCategoriesLayoutKey] else { return show }
        show.layout.values.removeValue(forKey: InputConfig.legacyCategoriesLayoutKey)
        guard case .object(let entries) = raw else { return show }
        for (key, value) in entries {
            guard let number = Int(key), case .string(let name) = value, let color = InputColor(rawValue: name),
                  let i = show.inputs.firstIndex(where: { $0.number == number }), show.inputs[i].color == nil else { continue }
            show.inputs[i].color = color
        }
        return show
    }

    /// 迁移占位：目前只有 v1，没有旧版本可迁。将来出 v2 时在这里逐级升级（v1 → v2 → …），旧版本文件要能读（设计方案 §4）。
    public static func migrate(from document: JSONValue, schemaVersion: Int) throws -> Show {
        switch schemaVersion {
        case currentSchemaVersion:
            let data = try JSONEncoder().encode(document)
            let show = try fileDecoder.decode(Show.self, from: data).migratingLegacyKeys()
            _ = try show.makeValidatedState()
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
            // 过渡键的默认与正式字段的默认都是"不退回"（提案 015 起一致，都是 false）；只有出现过旧键的才搬，搬的时候按旧键的原值走，不改语义。
            if found { s.display = DisplayOutputSettings(displayID: displayID, fallbackToMain: fallback) }
        }
        s.extra.removeValue(forKey: DisplayOutputSettings.legacyDisplayIDKey)
        s.extra.removeValue(forKey: DisplayOutputSettings.legacyFallbackKey)
        return s
    }
}

extension OutputSettings {
    /// 提案 025：W5-I 放在 `extra` 里的三个 App 层标记（`app.record.armed` / `app.record.ownFormat` / `app.stream.followFirst`）→ 正式字段
    /// `RecordSettings.armed` / `.ownFormat` / `StreamSettings.followFirst`。只有出现过旧键的才搬、按旧键的原值走（bool）；搬完清掉旧键（值不是 bool、
    /// 或对应子结构不在的，只清键）；幂等。**不在 `migratingLegacyKeys()` 里自动调**：025 之前的 App 还在读写 extra 键，搬迁时机由 App 定
    /// （用户 2026-10-10 定：App 在 Show.load 后调一次、读写切到字段，归 101 / W5-N）；之后可以并进 `migratingLegacyKeys()`。
    public func migratingLegacyAppFlags() -> OutputSettings {
        var s = self
        func takeBool(_ key: String) -> Bool? {
            defer { s.extra.removeValue(forKey: key) }
            if case .bool(let b)? = s.extra[key] { return b }
            return nil
        }
        if let armed = takeBool(RecordSettings.legacyArmedExtraKey) { s.record?.armed = armed }
        if let own = takeBool(RecordSettings.legacyOwnFormatExtraKey) { s.record?.ownFormat = own }
        if let follow = takeBool(StreamSettings.legacyFollowFirstExtraKey) { s.stream?.followFirst = follow }
        return s
    }
}

extension Show {
    /// 提案 025：对每个输出做一次 `OutputSettings.migratingLegacyAppFlags()`（App 在 Show.load 后调一次，归 101）。
    public func migratingLegacyAppFlags() -> Show {
        var show = self
        for i in show.outputs.indices { show.outputs[i].settings = show.outputs[i].settings.migratingLegacyAppFlags() }
        return show
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
