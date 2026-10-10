// 状态模型（设计方案 §4、§9.1）：不可变快照，每拍读一次；只通过 Command → reduce 改。

// MARK: - 转场

/// §1.1 Transition：Cut、Fade、Wipe、Zoom、Stinger。
public enum TransitionType: String, Codable, Sendable, CaseIterable {
    case cut, fade, wipe, zoom, stinger
}

/// 进度由谁推：auto = 状态机按 durationTicks 每拍推进；tbar = 手动 `tbar(progress:)`。
public enum TransitionSource: String, Codable, Sendable {
    case auto, tbar
}

/// Wipe 的方向。
public enum WipeDirection: String, Codable, Sendable {
    case leftToRight, rightToLeft, topToBottom, bottomToTop, diagonal
}

/// Wipe 参数（W3-B 用）。
public struct WipeParams: Hashable, Codable, Sendable {
    /// 擦除方向。
    public var direction: WipeDirection
    /// 软边宽度，占画面的比例 0–1。
    public var softness: Double
    public init(direction: WipeDirection = .leftToRight, softness: Double = 0) {
        self.direction = direction
        self.softness = softness
    }
}

/// Stinger 参数（W3-B 用）：带 alpha 的输入叠上去，在它的第 cutAtTick 拍换底。
public struct StingerParams: Hashable, Codable, Sendable {
    /// 作 stinger 的输入（带 alpha 的文件 / 图片）；nil = 未设置。删掉这一路（removeInput）时置 nil，与叠加引用同口径（P4）；
    /// `MixerState.validate()` 不查它指不指向存在的输入（引用一律不查），P4 之前存下的悬空编号由 `Show.migratingLegacyKeys()` 清掉。
    public var input: Int?
    /// 在 stinger 的第几拍换底。按状态机口径，第 s 拍应用命令时 progress = 0（渲染器什么都不叠），
    /// 第 s + 1 拍才是 stinger 的第一帧，所以 cutAtTick 0 与 1 等价；cutAtTick ≥ durationTicks 等于"完成时换"。
    /// `TransitionRenderer.stingerShowsNewUnder` 是定义。
    public var cutAtTick: Int
    public init(input: Int? = nil, cutAtTick: Int = 0) {
        self.input = input
        self.cutAtTick = cutAtTick
    }
}

/// 转场槽（提案 020，用户 2026-10-11 批）：一个槽 = 一套完整的"效果 + 时长 + Wipe 参数 + Stinger 参数"，字段与 `TransitionState` 的当前那组一一对应。
/// `TransitionState.slots` 恰好 4 个（下标 0–3 = 槽 1–4），随节目文件存（槽里有 Stinger 用的输入编号，换节目必须跟着换）。
/// 快捷键 / MIDI / API / 兼容层 / Stream Deck 按槽触发（`useTransitionSlot`）、按槽改配置（`setTransitionSlot`）。
public struct TransitionSlot: Hashable, Codable, Sendable {
    /// 转场类型（cut 也允许，但出厂槽与搬迁不用它）。
    public var type: TransitionType
    /// 时长（拍）。
    public var durationTicks: Int
    /// Wipe 参数。
    public var wipe: WipeParams
    /// Stinger 参数。
    public var stinger: StingerParams
    public init(type: TransitionType, durationTicks: Int, wipe: WipeParams = WipeParams(), stinger: StingerParams = StingerParams()) {
        self.type = type
        self.durationTicks = durationTicks
        self.wipe = wipe
        self.stinger = stinger
    }

    /// 槽数。
    public static let count = 4
    /// 槽的编号范围（命令里的 slot）。
    public static let indexRange = 1...4
    /// 出厂四槽的秒数：1 = Fade 0.5 s、2 = Wipe 1 s、3 = Zoom 1 s、4 = Stinger 1 s。
    public static let factoryDefaultSeconds: [Double] = [0.5, 1, 1, 1]

    /// 出厂四槽：1 = Fade 0.5 s、2 = Wipe 1 s（leftToRight、软边 0）、3 = Zoom 1 s、4 = Stinger 1 s（输入 nil、换底拍 0）；
    /// 秒按节目帧率换拍（round，与叠加默认淡入同一算法：60 / 59.94 → 30 / 60 / 60 / 60，30 → 15 / 30 / 30 / 30，25 → 13 / 25 / 25 / 25）。
    /// 与 020 之前的四个按钮等价，老用户察觉不到变化。
    public static func factoryDefaults(for format: ProgramFormat) -> [TransitionSlot] {
        let fps = format.frameRate.approximateFramesPerSecond
        func ticks(_ i: Int) -> Int { Int((factoryDefaultSeconds[i] * fps).rounded()) }
        return [
            TransitionSlot(type: .fade, durationTicks: ticks(0)),
            TransitionSlot(type: .wipe, durationTicks: ticks(1), wipe: WipeParams(direction: .leftToRight, softness: 0)),
            TransitionSlot(type: .zoom, durationTicks: ticks(2)),
            TransitionSlot(type: .stinger, durationTicks: ticks(3), stinger: StingerParams(input: nil, cutAtTick: 0)),
        ]
    }

    /// JSON 键名。
    public static let jsonKeys = ["type", "durationTicks", "wipe", "stinger"]
}

/// 转场状态。空闲时 `type` / `durationTicks` 就是"下一次转场"的选择（UI 的转场按钮和时长预设改的是它）。
///
/// `progress` 的意义：新画面（= preview 输入）盖在旧画面（= program 输入）上的比例，0 … 1。
/// - 空闲：progress = 0，startTick = nil。
/// - auto 转场：第 s 拍应用命令，之后第 s + k 拍 progress = k / durationTicks（W1-B），到 1 时状态机把 program 与 preview 对调并回到空闲。
/// - tbar：progress 直接等于推杆位置；推到 1 提交（对调 + 回到 0）。
/// 渲染器只看 `progress` 和 `type`；Cut 没有中间态（durationTicks 对它无意义）。
///
/// 转场槽（提案 020）：`slots` 恰好 4 个；`currentSlot` = 当前那组（type / durationTicks / wipe / stinger）对应哪个槽（1–4），
/// nil = 当前那组是 `setTransition` / `fade` / `setTransitionParams` / API 直接给的、不对应任何槽。T-bar / 回车 / `autoTransition` 用的永远是当前那组，
/// 所以"跟当前槽"不需要别的字段。渲染器只看当前那组，一个字节不动。
public struct TransitionState: Hashable, Codable, Sendable {
    /// 转场类型。
    public var type: TransitionType
    /// 转场时长（拍）。
    public var durationTicks: Int
    /// 进度 0–1，含义见类型说明。
    public var progress: Double
    /// 进度由谁推。
    public var source: TransitionSource
    /// auto 转场开始的那一拍（应用命令的拍）；空闲或 tbar 为 nil。
    public var startTick: Tick?
    /// Wipe 参数。
    public var wipe: WipeParams
    /// Stinger 参数。
    public var stinger: StingerParams
    /// 转场槽 1–4（提案 020）：恰好 4 个（`MixerState.validate()` 查）。写出总是写全；020 之前的文件缺键 → 裸解码为空数组，由 `Show.migratingLegacyKeys()` 补出厂槽。
    public var slots: [TransitionSlot]
    /// 当前那组对应的槽（1–4）；nil = 不对应任何槽。缺键 = nil；nil 不写键。
    public var currentSlot: Int?

    /// 不给 `slots` = 按 60 fps 的出厂四槽（这里不知道帧率；`MixerState.newShow(format:)` 按节目帧率重算）；
    /// 不给 `currentSlot` = 自动对号：当前那组与某个槽相同就是那个槽（`TransitionState()` 的 fade 30 = 槽 1），否则 nil（`TransitionState(type: .cut, durationTicks: 0)` 这种裸状态）。
    public init(type: TransitionType = .fade, durationTicks: Int = 30, progress: Double = 0, source: TransitionSource = .auto,
                startTick: Tick? = nil, wipe: WipeParams = WipeParams(), stinger: StingerParams = StingerParams(),
                slots: [TransitionSlot] = TransitionSlot.factoryDefaults(for: .hd1080p60), currentSlot: Int? = nil) {
        self.type = type
        self.durationTicks = durationTicks
        self.progress = progress
        self.source = source
        self.startTick = startTick
        self.wipe = wipe
        self.stinger = stinger
        self.slots = slots
        self.currentSlot = currentSlot ?? Self.slotIndex(matching: TransitionSlot(type: type, durationTicks: durationTicks, wipe: wipe, stinger: stinger), in: slots, preferring: nil)
    }

    enum CodingKeys: String, CodingKey { case type, durationTicks, progress, source, startTick, wipe, stinger, slots, currentSlot }

    /// 020 之前的 JSON 没有 slots / currentSlot：解成 [] / nil，`Show.migratingLegacyKeys()` 补齐（`validate()` 要求恰好 4 个，没经搬迁的进不了状态机）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(TransitionType.self, forKey: .type)
        durationTicks = try c.decode(Int.self, forKey: .durationTicks)
        progress = try c.decode(Double.self, forKey: .progress)
        source = try c.decode(TransitionSource.self, forKey: .source)
        startTick = try c.decodeIfPresent(Tick.self, forKey: .startTick)
        wipe = try c.decode(WipeParams.self, forKey: .wipe)
        stinger = try c.decode(StingerParams.self, forKey: .stinger)
        slots = try c.decodeIfPresent([TransitionSlot].self, forKey: .slots) ?? []
        currentSlot = try c.decodeIfPresent(Int.self, forKey: .currentSlot)
    }

    /// JSON 键名（startTick / currentSlot 可缺）。
    public static let jsonKeys = ["type", "durationTicks", "progress", "source", "startTick", "wipe", "stinger", "slots", "currentSlot"]

    /// 正在转场（画面上有两路混合）。
    public var isActive: Bool { progress > 0 || startTick != nil }

    /// 当前那组（type / durationTicks / wipe / stinger）看成一个槽的配置；设置 = 四个字段整体替换（不动 currentSlot / 进度）。
    public var currentGroup: TransitionSlot {
        get { TransitionSlot(type: type, durationTicks: durationTicks, wipe: wipe, stinger: stinger) }
        set {
            type = newValue.type
            durationTicks = newValue.durationTicks
            wipe = newValue.wipe
            stinger = newValue.stinger
        }
    }

    /// 把槽 index（1–4）拷进当前那组并记 `currentSlot = index`；越界不动。进度 / startTick 不碰（调用方自己决定要不要开始）。
    public mutating func select(slot index: Int) {
        guard TransitionSlot.indexRange.contains(index), index - 1 < slots.count else { return }
        currentGroup = slots[index - 1]
        currentSlot = index
    }

    /// 当前那组与哪个槽相同：先看 `preferring`（对得上就是它），否则按顺序找第一个相同的；都不同 → nil。
    public func slotIndexMatchingCurrentGroup(preferring index: Int? = nil) -> Int? {
        Self.slotIndex(matching: currentGroup, in: slots, preferring: index)
    }

    static func slotIndex(matching group: TransitionSlot, in slots: [TransitionSlot], preferring index: Int?) -> Int? {
        if let i = index, TransitionSlot.indexRange.contains(i), i - 1 < slots.count, slots[i - 1] == group { return i }
        return slots.firstIndex(of: group).map { $0 + 1 }
    }
}

/// FTB（§1.1）。`on` 是目标，`level` 是当前黑的比例（渲染器乘 1 − level）；状态机每拍把 level 向目标推 1 / durationTicks。
public struct FadeToBlack: Hashable, Codable, Sendable {
    /// 目标：是否黑。
    public var on: Bool
    /// 淡入 / 淡出黑的时长（拍）。
    public var durationTicks: Int
    /// 当前黑的比例 0–1。
    public var level: Double
    /// 最近一次 on 变化的拍；空闲为 nil。
    public var startTick: Tick?
    public init(on: Bool = false, durationTicks: Int = 30, level: Double = 0, startTick: Tick? = nil) {
        self.on = on
        self.durationTicks = durationTicks
        self.level = level
        self.startTick = startTick
    }
}

// MARK: - 叠加

/// 节目画面里的位置尺寸，全部是 0–1 的比例（原点左上）。
public struct NormalizedRect: Hashable, Codable, Sendable {
    /// 左上 x（占宽比例）。
    public var x: Double
    /// 左上 y（占高比例）。
    public var y: Double
    /// 宽（占宽比例）。
    public var width: Double
    /// 高（占高比例）。
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    /// 整个画面。
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    /// 画中画默认位置：右下 1/4（V8 的固定状态用它）。
    public static let bottomRightQuarter = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
}

/// 叠加进出动画的方式。
public enum OverlayAnimationKind: String, Codable, Sendable {
    case cut, fade, slide, zoom
}

/// 画面的一条边（slide 从哪进出；提案 010）。
public enum OverlayEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// 叠加通道的进出动画（W3-B 细化）。durationTicks = 0 等于 cut。
public struct OverlayAnimation: Hashable, Codable, Sendable {
    /// 动画方式。
    public var kind: OverlayAnimationKind
    /// 动画时长（拍）；0 = cut。
    public var durationTicks: Int
    /// slide 从哪条边进出（提案 010）；nil = 离 rect 最近的边（并列时底 > 顶 > 左 > 右，
    /// 所以整幅 rect 一律从底边、下三分之一自然向上滑入）。只对 kind = slide 有意义。
    public var slideFrom: OverlayEdge?

    public init(kind: OverlayAnimationKind = .cut, durationTicks: Int = 0, slideFrom: OverlayEdge? = nil) {
        self.kind = kind
        self.durationTicks = durationTicks
        self.slideFrom = slideFrom
    }

    enum CodingKeys: String, CodingKey { case kind, durationTicks, slideFrom }

    /// 老 Show 没有 slideFrom：缺键 = nil（提案 010）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(OverlayAnimationKind.self, forKey: .kind)
        durationTicks = try c.decode(Int.self, forKey: .durationTicks)
        slideFrom = try c.decodeIfPresent(OverlayEdge.self, forKey: .slideFrom)
    }

    /// JSON 键名。
    public static let jsonKeys = ["kind", "durationTicks", "slideFrom"]

    /// 新节目四路叠加的默认进出动画时长（秒，提案 027，用户 2026-10-10 批）；按节目帧率换成拍存，见 `defaultFade(for:)`。
    public static let defaultFadeSeconds = 0.5
    /// 新节目的默认叠加动画（提案 027）：fade，round(0.5 s × 帧率) 拍（60 / 59.94 → 30、30 / 29.97 → 15、25 → 13、50 → 25、24 → 12）。
    /// `OverlayAnimation()` 无参默认仍是 cut 0 拍（它不知道帧率；API / 脚本直接构造的不受影响）；已存文件里的 animation 照读不变。
    /// App 新建节目（emptyShow）、`MixerState.newShow(format:outputs:)` 都用它，三方一致。
    public static func defaultFade(for format: ProgramFormat) -> OverlayAnimation {
        OverlayAnimation(kind: .fade, durationTicks: Int((defaultFadeSeconds * format.frameRate.approximateFramesPerSecond).rounded()))
    }
}

/// 画中画边框（提案 010）。
public struct OverlayBorder: Hashable, Codable, Sendable {
    /// 边框宽，占节目高的比例（1080p 下 0.006 ≈ 6 px）；渲染器钳到 0–0.1。界面（叠加面板）只给到 0.05（1080p 下 54 px，再宽就不像边框了），
    /// 0.05–0.1 只能从 API / 节目文件给（W3-E2 报告 §4 第 3 条）。
    public var width: Double
    /// 边框颜色。
    public var color: RGB8
    public init(width: Double = 0.006, color: RGB8 = RGB8(red: 255, green: 255, blue: 255)) {
        self.width = width
        self.color = color
    }
    /// 默认边框宽（占节目高的比例）。
    public static let defaultWidth = 0.006
}

/// 叠加的锚点（提案 010）：rect 改尺寸时哪个点不动，缩放动画绕它缩。
public enum OverlayAnchor: String, Codable, Sendable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    /// 锚点在 rect 内的归一化位置 (u, v)，原点左上：center = (0.5, 0.5)、topLeft = (0, 0)。
    public var unitPoint: (u: Double, v: Double) {
        let u: Double
        switch self {
        case .topLeft, .left, .bottomLeft: u = 0
        case .top, .center, .bottom: u = 0.5
        case .topRight, .right, .bottomRight: u = 1
        }
        let v: Double
        switch self {
        case .topLeft, .top, .topRight: v = 0
        case .left, .center, .right: v = 0.5
        case .bottomLeft, .bottom, .bottomRight: v = 1
        }
        return (u, v)
    }
}

/// Overlay 1–4 之一（§1.1）。`on` 是目标，`animProgress` 是当前显示比例 0（全隐）… 1（全显）；
/// 状态机每拍向目标推进，渲染器按 `animation.kind` 解释 animProgress。
public struct OverlayState: Hashable, Codable, Sendable {
    /// 叠在上面的输入；nil = 该通道没有指定输入。
    public var input: Int?
    /// 目标：是否显示。
    public var on: Bool
    /// 位置尺寸。
    public var rect: NormalizedRect
    /// 当前显示比例 0–1。
    public var animProgress: Double
    /// 进出动画。
    public var animation: OverlayAnimation
    /// 最近一次 on 变化的拍；空闲为 nil。
    public var startTick: Tick?
    /// 画中画边框（提案 010）；nil = 不画。
    public var border: OverlayBorder?
    /// 位置尺寸的锚点（提案 010）：缩放动画绕它缩。
    public var anchor: OverlayAnchor
    /// 在 PVW 里也预览这一路叠加（提案 010）；不影响它上不上 PGM。
    /// 渲染器把它与 `MetalRendererOptions.overlaysInPreview`（"全部预览"总开关）取或。
    public var previewOn: Bool

    public init(input: Int? = nil, on: Bool = false, rect: NormalizedRect = .full, animProgress: Double = 0,
                animation: OverlayAnimation = OverlayAnimation(), startTick: Tick? = nil,
                border: OverlayBorder? = nil, anchor: OverlayAnchor = .center, previewOn: Bool = false) {
        self.input = input
        self.on = on
        self.rect = rect
        self.animProgress = animProgress
        self.animation = animation
        self.startTick = startTick
        self.border = border
        self.anchor = anchor
        self.previewOn = previewOn
    }

    enum CodingKeys: String, CodingKey {
        case input, on, rect, animProgress, animation, startTick, border, anchor, previewOn
    }

    /// 老 Show 没有 border / anchor / previewOn：缺键给 nil / center / false（提案 010）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input)
        on = try c.decode(Bool.self, forKey: .on)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        animProgress = try c.decode(Double.self, forKey: .animProgress)
        animation = try c.decode(OverlayAnimation.self, forKey: .animation)
        startTick = try c.decodeIfPresent(Tick.self, forKey: .startTick)
        border = try c.decodeIfPresent(OverlayBorder.self, forKey: .border)
        anchor = try c.decodeIfPresent(OverlayAnchor.self, forKey: .anchor) ?? .center
        previewOn = try c.decodeIfPresent(Bool.self, forKey: .previewOn) ?? false
    }

    /// 画面上能看见（含进出动画中）。
    public var isVisible: Bool { input != nil && (on || animProgress > 0) }

    /// JSON 键名。
    public static let jsonKeys = ["input", "on", "rect", "animProgress", "animation", "startTick", "border", "anchor", "previewOn"]
}

// MARK: - 音频

/// 四条总线（§1.1 Bus）。rawValue 也是 `AudioState.buses` 的下标。
public enum Bus: Int, Codable, Sendable, CaseIterable {
    case master = 0, busA, busB, headphones

    /// 名字（Stats.audio.meters.buses[i].bus 用，提案 004）：master / busA / busB / headphones，与 `BusRouting` 的 JSON 键一致。
    public var name: String {
        switch self {
        case .master: "master"
        case .busA: "busA"
        case .busB: "busB"
        case .headphones: "headphones"
        }
    }
    /// 按名字找；不认识给 nil。
    public init?(name: String) {
        guard let b = Bus.allCases.first(where: { $0.name == name }) else { return nil }
        self = b
    }
}

/// 一条总线的状态。
public struct BusState: Hashable, Codable, Sendable {
    /// 哪条总线。
    public var bus: Bus
    /// 总线增益（dB）。
    public var gainDb: Double
    /// 总线静音。
    public var muted: Bool
    /// 总线效果链（W5-C 起生效）——只放音频效果（提案 023 第三节）：id 与键表见 `EffectSlot`（parametricEQ / dynamicsProcessor / compressor / peakLimiter）；
    /// 每条总线最多 3 格，连续的 parametricEQ 格合成一格（≤ 16 段），超出的不装；链顺序 = 处理顺序，enabled = false 的格旁路。
    public var effects: [EffectSlot]
    public init(bus: Bus, gainDb: Double = 0, muted: Bool = false, effects: [EffectSlot] = []) {
        self.bus = bus
        self.gainDb = gainDb
        self.muted = muted
        self.effects = effects
    }
}

/// 耳机监听方式：AFL（推子后）/ PFL（推子前）。
public enum MonitorMode: String, Codable, Sendable {
    case afl, pfl
}

/// 耳机 / 监听总线从对齐延迟线的哪一侧取信号（提案 007；对应混音器的 sw_monitor_point，W1-D2）。
public enum MonitorPoint: String, Codable, Sendable, CaseIterable {
    /// 延迟线之前：不带对齐延迟与每路延迟补偿的低延迟监听（默认）。
    case preDelayLine
    /// 延迟线之后：与节目画面对齐。
    case postDelayLine
}

/// 音频总体状态。每路输入的路由 / 增益 / 静音 / 独听 / 声像 / 延迟在 `MixerState.inputs[i].settings.audio`，只存一份。
public struct AudioState: Hashable, Codable, Sendable {
    /// 恰好 4 条，顺序 = Bus.allCases。
    public var buses: [BusState]
    /// 音频跟随视频（全局总开关）：转场时相关输入交叉淡变，长度 = 转场时长，起点同一拍（§7）。
    /// false = 所有路的门控增益恒 1；true 时哪几路参与由每路的 `InputAudioSettings.afv` 决定。
    public var afv: Bool
    /// 耳机监听方式。
    public var monitorMode: MonitorMode
    /// 节目音频相对采集的对齐延迟（48 kHz 帧；提案 007）：每路输入"环年龄 + 对齐延迟线"= 它，
    /// Master / 总线 / ISO 块的 PTS = 块首样本 host time − 它。2048 帧 = 42.67 ms，与视频内部延迟（≈ 3 帧）同量级。
    /// 低延迟监听调小、大块生产者调大；运行期改要重建延迟线，所以只走 Show / 设置面板，没有对应命令。
    public var alignmentFrames: Int
    /// 耳机 / 监听总线取对齐延迟线之前（低延迟监听，默认）还是之后（与节目画面对齐）。提案 007；同上，没有对应命令。
    public var monitorPoint: MonitorPoint
    /// 耳机 / 监听总线上听的是哪条总线（提案 026，用户 2026-10-10 批）：master（默认，老文件缺键也是）/ busA / busB；走 `setMonitorSource`。
    /// `headphones` 自己无效：命令在校验器 / reducer 被拒，文件 / API 全量状态里出现的按 master 读。独听（PFL / AFL，`monitorMode` + 每路 solo）仍优先于它。
    /// 设备客户端按它取总线送耳机（引擎侧归 W1-D3 / prompt 102；之前耳机固定听 Master）。
    public var monitorSource: Bus

    /// 对齐延迟的默认值（帧）。
    public static let defaultAlignmentFrames = 2048

    public init(buses: [BusState] = Bus.allCases.map { BusState(bus: $0) }, afv: Bool = false, monitorMode: MonitorMode = .afl,
                alignmentFrames: Int = AudioState.defaultAlignmentFrames, monitorPoint: MonitorPoint = .preDelayLine, monitorSource: Bus = .master) {
        self.buses = buses
        self.afv = afv
        self.monitorMode = monitorMode
        self.alignmentFrames = alignmentFrames
        self.monitorPoint = monitorPoint
        self.monitorSource = monitorSource
    }

    enum CodingKeys: String, CodingKey { case buses, afv, monitorMode, alignmentFrames, monitorPoint, monitorSource }

    /// 老 Show / 老快照没有 alignmentFrames / monitorPoint（提案 007）/ monitorSource（提案 026）：缺键给默认值；monitorSource = headphones 按 master 读。写出总是写全。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buses = try c.decode([BusState].self, forKey: .buses)
        afv = try c.decode(Bool.self, forKey: .afv)
        monitorMode = try c.decode(MonitorMode.self, forKey: .monitorMode)
        alignmentFrames = try c.decodeIfPresent(Int.self, forKey: .alignmentFrames) ?? AudioState.defaultAlignmentFrames
        monitorPoint = try c.decodeIfPresent(MonitorPoint.self, forKey: .monitorPoint) ?? .preDelayLine
        let source = try c.decodeIfPresent(Bus.self, forKey: .monitorSource) ?? .master
        monitorSource = source == .headphones ? .master : source
    }

    /// JSON 键名。
    public static let jsonKeys = ["buses", "afv", "monitorMode", "alignmentFrames", "monitorPoint", "monitorSource"]
}

// MARK: - 输出

/// §1.1 Output：录制、推流、NDI 发送、外部显示、虚拟摄像头、多画面。
public enum OutputKind: String, Codable, Sendable, CaseIterable {
    case record, stream, ndi, externalDisplay, virtualCamera, multiview
}

/// 输出送什么画面（外部显示 / NDI / 虚拟摄像头相当于 Aux）。
/// `multiview` 作 `MultiviewCell.source` 时被渲染器忽略（格子不能套自己，W3-B 口径）。
public enum OutputSource: Hashable, Codable, Sendable {
    case program
    case preview
    case multiview
    case input(number: Int)
}

/// 视频编码器。ProRes 走硬件。
public enum VideoCodec: String, Codable, Sendable {
    case h264, hevc, prores422, prores422HQ, prores4444
}

/// 音频编码器。
public enum AudioCodec: String, Codable, Sendable {
    case aac, pcm
}

/// 视频编码参数（设计方案 §8 编码行）。width / height nil = 节目分辨率。
public struct VideoEncodeSettings: Hashable, Codable, Sendable {
    /// 编码器。
    public var codec: VideoCodec
    /// 目标码率（bit/s）。
    public var bitrateBps: Int
    /// 关键帧间隔（帧）。
    public var keyframeIntervalFrames: Int
    /// 输出宽；nil = 节目宽。
    public var width: Int?
    /// 输出高；nil = 节目高。
    public var height: Int?
    public init(codec: VideoCodec = .h264, bitrateBps: Int = 6_000_000, keyframeIntervalFrames: Int = 120, width: Int? = nil, height: Int? = nil) {
        self.codec = codec
        self.bitrateBps = bitrateBps
        self.keyframeIntervalFrames = keyframeIntervalFrames
        self.width = width
        self.height = height
    }
}

/// 音频编码参数。
public struct AudioEncodeSettings: Hashable, Codable, Sendable {
    /// 编码器。
    public var codec: AudioCodec
    /// 码率（bit/s）。
    public var bitrateBps: Int
    public init(codec: AudioCodec = .aac, bitrateBps: Int = 160_000) {
        self.codec = codec
        self.bitrateBps = bitrateBps
    }
}

/// 录制容器。
public enum RecordContainer: String, Codable, Sendable {
    case mov, mp4
}

/// 录制参数（设计方案 §8 录制行）。
public struct RecordSettings: Hashable, Codable, Sendable {
    /// 录制目录。相对路径的口径（提案 007 B）：headless 相对进程工作目录；App 相对 `~/Movies/PlusMix`（W4-D 改名前是 `~/Movies/Switcher`）。
    public var directory: String
    /// 文件名模板，支持 {show} {date} {time} {output}。
    public var fileNamePattern: String
    /// 容器格式——**已废弃（提案 023 第二节，用户 2026-10-11 批）**：运行时从不读它，文件一律写 .mov；要 .mp4 用 `remuxToMP4`（停止后转封装，失败保留 .mov），
    /// 两者表达同一件事。字段与枚举留着（删了是破坏性 wire 变更）：缺键 = mov，写出仍写（老程序读新文件不缺键）；不加 `@available`（App 的 OutputSettingsPanel 还读它给提示）。
    public var container: RecordContainer
    /// movieFragmentInterval，秒；崩溃可恢复到最后一个片段。
    public var fragmentIntervalSeconds: Double
    /// 停止后转封装成 MP4（失败保留 .mov）。
    public var remuxToMP4: Bool
    /// 参与"全部录制"（提案 025，W5-I 的 `extra["app.record.armed"]` 升正式字段）：true（默认，老文件缺键也是 true）= 底栏 / API 的"全部开始"起这一路；
    /// false = 只能单路起（ISO 表里 PGM 那一行取消 = 只录 ISO）。headless / API 现在逐路 startRecord，不看它；"全部录制"要认它归控制会话。
    public var armed: Bool
    /// 自己的编码格式（提案 025，W5-I 的 `extra["app.record.ownFormat"]`）：只对来源是某路输入的录制（ISO 路）有意义——
    /// false（默认）= 编码参数跟主录制（第一个来源 = PGM 的录制输出）；true = 用自己的 video / audio。
    public var ownFormat: Bool
    public init(directory: String, fileNamePattern: String = "{show}-{date}-{time}", container: RecordContainer = .mov,
                fragmentIntervalSeconds: Double = 1, remuxToMP4: Bool = false, armed: Bool = true, ownFormat: Bool = false) {
        self.directory = directory
        self.fileNamePattern = fileNamePattern
        self.container = container
        self.fragmentIntervalSeconds = fragmentIntervalSeconds
        self.remuxToMP4 = remuxToMP4
        self.armed = armed
        self.ownFormat = ownFormat
    }

    enum CodingKeys: String, CodingKey { case directory, fileNamePattern, container, fragmentIntervalSeconds, remuxToMP4, armed, ownFormat }

    /// 025 之前的文件没有 armed / ownFormat：缺键 = true / false（与 W5-I 对 extra 缺键的语义相同）；container 可缺（023 二，= mov）。写出总是写全。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directory = try c.decode(String.self, forKey: .directory)
        fileNamePattern = try c.decode(String.self, forKey: .fileNamePattern)
        container = try c.decodeIfPresent(RecordContainer.self, forKey: .container) ?? .mov
        fragmentIntervalSeconds = try c.decode(Double.self, forKey: .fragmentIntervalSeconds)
        remuxToMP4 = try c.decode(Bool.self, forKey: .remuxToMP4)
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? true
        ownFormat = try c.decodeIfPresent(Bool.self, forKey: .ownFormat) ?? false
    }

    /// JSON 键名。
    public static let jsonKeys = ["directory", "fileNamePattern", "container", "fragmentIntervalSeconds", "remuxToMP4", "armed", "ownFormat"]

    /// 025 之前 App（W5-I）放在 `OutputSettings.extra` 里的键：`OutputSettings.migratingLegacyAppFlags()` 把它们搬进 `armed` / `ownFormat`。
    public static let legacyArmedExtraKey = "app.record.armed"
    public static let legacyOwnFormatExtraKey = "app.record.ownFormat"
}

/// 推流目的地（RTMP / RTMPS / SRT 由 url 的 scheme 决定）。
public struct StreamSettings: Hashable, Codable, Sendable {
    /// 推流地址（rtmp:// / rtmps:// / srt://）。
    public var url: String
    /// 推流密钥。
    public var streamKey: String
    /// 指数退避重连的上限（秒）。
    public var reconnectMaxSeconds: Double
    /// 编码参数跟第一个推流目的地（提案 025，W5-I 的 `extra["app.stream.followFirst"]` 升正式字段）：false（默认，老文件缺键也是 false）= 自己的 video / audio；
    /// true = 跟编号最小的 stream 输出的 video / audio（地址、密钥、重连上限不跟）。谁来跟是 App（OutputLinkage）的事，契约只存标记。
    public var followFirst: Bool
    public init(url: String, streamKey: String = "", reconnectMaxSeconds: Double = 30, followFirst: Bool = false) {
        self.url = url
        self.streamKey = streamKey
        self.reconnectMaxSeconds = reconnectMaxSeconds
        self.followFirst = followFirst
    }

    enum CodingKeys: String, CodingKey { case url, streamKey, reconnectMaxSeconds, followFirst }

    /// 025 之前的文件没有 followFirst：缺键 = false。写出总是写全。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        streamKey = try c.decode(String.self, forKey: .streamKey)
        reconnectMaxSeconds = try c.decode(Double.self, forKey: .reconnectMaxSeconds)
        followFirst = try c.decodeIfPresent(Bool.self, forKey: .followFirst) ?? false
    }

    /// JSON 键名。
    public static let jsonKeys = ["url", "streamKey", "reconnectMaxSeconds", "followFirst"]

    /// 025 之前 App（W5-I）放在 `OutputSettings.extra` 里的键：`OutputSettings.migratingLegacyAppFlags()` 把它搬进 `followFirst`。
    public static let legacyFollowFirstExtraKey = "app.stream.followFirst"
}

/// 多画面的一个自定义格子（提案 010）。
public struct MultiviewCell: Hashable, Codable, Sendable {
    /// 格子里放什么：program / preview / input(number:)；`multiview` 无效（渲染器忽略该格，格子不能套自己）。
    public var source: OutputSource
    /// 格子在多画面画面里的位置尺寸（归一化，渲染器钳到画面内）。
    public var rect: NormalizedRect
    public init(source: OutputSource, rect: NormalizedRect) {
        self.source = source
        self.rect = rect
    }
}

/// 多画面布局（提案 010；kind = multiview 的输出用）。
public struct MultiviewLayoutSettings: Hashable, Codable, Sendable {
    /// 预设名：`pgmPvw+grid`（默认，= W1-C 的布局：上 PVW / PGM，下半按路数 4×2 / 6×3 / 8×4）、
    /// `pgmPvw+4x2`、`pgmPvw+2x2`、`3x3`、`4x4`。`custom` 非空时忽略；认不出的名字退回默认。
    public var preset: String
    /// 自定义格子；非空时代替预设。
    public var custom: [MultiviewCell]
    /// PGM / PVW 格画安全框（EBU R95：动作安全 3.5%，字幕安全 5%）。
    public var safeArea: Bool
    /// 画电平表（真实读数：`Stats.audio.meters`，经渲染器的 `setMeters` 喂进来，数只有这一份）：输入格画该路的表（还没有读数时画空表），
    /// PGM 格 = Master 总线、PVW 格 = 当前 PVW 那一路（没有读数时这两格不画）。纯音频输入的格子总是画表（那是它唯一的内容），不看这个开关。
    public var meters: Bool

    /// 默认预设名。
    public static let defaultPreset = "pgmPvw+grid"

    public init(preset: String = MultiviewLayoutSettings.defaultPreset, custom: [MultiviewCell] = [],
                safeArea: Bool = false, meters: Bool = false) {
        self.preset = preset
        self.custom = custom
        self.safeArea = safeArea
        self.meters = meters
    }

    enum CodingKeys: String, CodingKey { case preset, custom, safeArea, meters }

    /// 各键都可缺（提案 010）：只给 `{"safeArea": true}` 也是合法布局。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? MultiviewLayoutSettings.defaultPreset
        custom = try c.decodeIfPresent([MultiviewCell].self, forKey: .custom) ?? []
        safeArea = try c.decodeIfPresent(Bool.self, forKey: .safeArea) ?? false
        meters = try c.decodeIfPresent(Bool.self, forKey: .meters) ?? false
    }

    /// JSON 键名。
    public static let jsonKeys = ["preset", "custom", "safeArea", "meters"]
}

/// 外部显示输出的设置（提案 013；kind = externalDisplay 用）。
public struct DisplayOutputSettings: Hashable, Codable, Sendable {
    /// CGDirectDisplayID；nil = 主显示器。显示器 ID 重启后可能变，App 侧另存型号 / 序列号做匹配是界面的事。
    public var displayID: UInt32?
    /// 显示器不在时：false（默认，提案 015）= 黑着等它回来、不动主显示器；true = 退回主显示器全屏（会盖住操作界面，只在明确要的时候开）。
    public var fallbackToMain: Bool
    public init(displayID: UInt32? = nil, fallbackToMain: Bool = false) {
        self.displayID = displayID
        self.fallbackToMain = fallbackToMain
    }

    enum CodingKeys: String, CodingKey { case displayID, fallbackToMain }

    /// fallbackToMain 缺键 = false（提案 013 定 true，015 改成 false：与 `ExternalDisplaySpec` 从 G4 起的运行时默认一致，用户 2026-09-23 批）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        fallbackToMain = try c.decodeIfPresent(Bool.self, forKey: .fallbackToMain) ?? false
    }

    /// JSON 键名。
    public static let jsonKeys = ["displayID", "fallbackToMain"]
}

/// 一个输出的设置。按 kind 取用相关的子结构，其他留 nil；`extra` 给各输出会话放自己的附加项（占位）。
public struct OutputSettings: Hashable, Codable, Sendable {
    /// 送什么画面。录制输出的 source 只认 program / input(n)：从 API / 节目文件写进来的 preview / multiview **按 program 录**（录制器的来源选择只认这两种），
    /// 校验器不拒（提案 023 第二节 (a)，用户 2026-10-11 批）；界面上录制来源只给 PGM / 某路输入。
    public var source: OutputSource
    /// 视频编码参数；不编码的输出为 nil。
    public var video: VideoEncodeSettings?
    /// 音频编码参数；不编码的输出为 nil。
    public var audio: AudioEncodeSettings?
    /// 录制参数（kind = record）。
    public var record: RecordSettings?
    /// 推流参数（kind = stream）。
    public var stream: StreamSettings?
    /// 多画面布局（kind = multiview；提案 010）；nil = 默认布局。
    public var multiview: MultiviewLayoutSettings?
    /// 外部显示设置（kind = externalDisplay；提案 013）；nil = 主显示器、拔掉退回主屏。
    public var display: DisplayOutputSettings?
    /// 各输出会话的附加设置（占位）。
    public var extra: [String: JSONValue]
    public init(source: OutputSource = .program, video: VideoEncodeSettings? = nil, audio: AudioEncodeSettings? = nil,
                record: RecordSettings? = nil, stream: StreamSettings? = nil,
                multiview: MultiviewLayoutSettings? = nil, display: DisplayOutputSettings? = nil,
                extra: [String: JSONValue] = [:]) {
        self.source = source
        self.video = video
        self.audio = audio
        self.record = record
        self.stream = stream
        self.multiview = multiview
        self.display = display
        self.extra = extra
    }

    /// JSON 键名。
    public static let jsonKeys = ["source", "video", "audio", "record", "stream", "multiview", "display", "extra"]
}

/// 一个输出的状态：配置 + 目标开关。运行时的帧数 / 丢帧 / 码率在 Stats.encoder 里，不在这里（铁律 4）。
public struct OutputState: Hashable, Codable, Sendable, Identifiable {
    /// 输出编号，从 1 起。
    public var number: Int
    /// 输出类型。
    public var kind: OutputKind
    /// 显示名。
    public var name: String
    /// 目标状态：true = 应该在跑。record / stream 由 startRecord / startStream 置，其余 kind 由 `setOutputEnabled` 置（提案 012）。
    /// kind = multiview 的 enabled = 要不要把多画面 NV12 送给下游（enabled 且 `settings.source` = `.multiview` 时渲染器每拍多转一次 NV12 填 `RenderedFrame.multiview`）；
    /// 多画面布局取第一个 kind = multiview 的输出的 `settings.multiview`，与 enabled 无关，只承载布局的那一个可以一直关着（W3-E2 报告 §4 第 2 条）。
    /// 节目文件里的 enabled 只对 headless 的场景文件生效（t0 起录 / 起推）；App 打开任何节目文件（含退出时自动存的 LastSession）
    /// 时把 record / stream 的 enabled 清掉，这两类输出只由用户动作（按钮 / 快捷键 / API）起（提案 007 B 第 1 条，
    /// App 的 `ShowDocuments.stoppingOutputs` 实现）。
    public var enabled: Bool
    /// 设置。
    public var settings: OutputSettings

    public init(number: Int, kind: OutputKind, name: String, enabled: Bool = false, settings: OutputSettings = OutputSettings()) {
        self.number = number
        self.kind = kind
        self.name = name
        self.enabled = enabled
        self.settings = settings
    }
    /// Identifiable：就是编号。
    public var id: Int { number }
}

// MARK: - Tally

/// §1.1 Tally：每个输入"在 PGM / 在 PVW / 都不在"。由 `MixerState.tally(ofInput:)` 推导，全系统只算这一次。
public struct Tally: Hashable, Codable, Sendable {
    /// 在 PGM 上。
    public var program: Bool
    /// 在 PVW 上。
    public var preview: Bool
    public init(program: Bool, preview: Bool) {
        self.program = program
        self.preview = preview
    }
    /// 都不在。
    public static let off = Tally(program: false, preview: false)
}

// MARK: - MixerState

/// `validate()` 抛出的不变量错误。
public enum MixerStateError: Error, Equatable {
    case overlayCount(Int)
    case busOrder
    case reservedInputNumber(Int)
    case duplicateInput(Int)
    case duplicateOutput(Int)
    /// 转场槽不是恰好 4 个（提案 020）。
    case transitionSlotCount(Int)
    /// currentSlot 不在 1…4（提案 020）。
    case transitionSlotIndex(Int)
}

/// 不可变快照（设计方案 §4）。相比 §4 多了 `format` 和 `inputs`：addInput / removeInput / setInputSettings 要在 reduce 里落地，
/// 输入表必须在状态里；渲染器每拍要读裁切 / 变换，也得从快照拿。
public struct MixerState: Hashable, Codable, Sendable {
    /// 节目格式。
    public var format: ProgramFormat
    /// 按编号升序；编号从 1 起。
    public var inputs: [InputConfig]
    /// PGM 输入编号；0 = 黑场。
    public var program: Int
    /// PVW 输入编号；0 = 黑场。
    public var preview: Int
    /// 转场状态。
    public var transition: TransitionState
    /// FTB 状态。
    public var ftb: FadeToBlack
    /// 恰好 4 个。
    public var overlays: [OverlayState]
    /// 音频状态。
    public var audio: AudioState
    /// 输出表，按编号升序。
    public var outputs: [OutputState]

    /// 叠加通道数。
    public static let overlayCount = 4
    /// "无输入 / 黑场"的编号。
    public static let noInput = 0

    public init(format: ProgramFormat = .hd1080p60, inputs: [InputConfig] = [], program: Int = MixerState.noInput,
                preview: Int = MixerState.noInput, transition: TransitionState = TransitionState(), ftb: FadeToBlack = FadeToBlack(),
                overlays: [OverlayState] = Array(repeating: OverlayState(), count: MixerState.overlayCount),
                audio: AudioState = AudioState(), outputs: [OutputState] = []) {
        precondition(overlays.count == MixerState.overlayCount, "overlays 必须恰好 \(MixerState.overlayCount) 个")
        self.format = format
        self.inputs = inputs
        self.program = program
        self.preview = preview
        self.transition = transition
        self.ftb = ftb
        self.overlays = overlays
        self.audio = audio
        self.outputs = outputs
    }

    /// 新节目的默认状态（提案 027，用户 2026-10-10 批）：`MixerState(format:outputs:)` 再把四路叠加的进出动画设成 `OverlayAnimation.defaultFade(for: format)`
    /// （淡入淡出 0.5 s，按帧率换拍）；其余字段与 `init` 的默认相同。App 新建节目、API / headless 建新节目都从这里拿，叠加行为三方一致；
    /// `MixerState()` / `MixerState(format:)` 的默认（cut 0 拍）不变——它们是测试与脚本的"裸状态"。
    public static func newShow(format: ProgramFormat = .hd1080p60, outputs: [OutputState] = []) -> MixerState {
        var s = MixerState(format: format, outputs: outputs)
        let fade = OverlayAnimation.defaultFade(for: format)
        for i in s.overlays.indices { s.overlays[i].animation = fade }
        // 提案 020：出厂四槽按节目帧率算，当前那组 = 槽 1（Fade 0.5 s）
        s.transition.slots = TransitionSlot.factoryDefaults(for: format)
        s.transition.select(slot: 1)
        return s
    }

    /// 不变量检查（解码 / 载入节目文件后调）。只查结构：叠加恰好 4 个、总线顺序、输入编号 ≥ 1 且不重复、输出编号不重复、转场槽恰好 4 个且 currentSlot 为 nil 或 1…4（020）。
    /// 不查引用（PGM / PVW / 叠加 / Stinger 指向的输入在不在）：悬空引用由 reducer 的 removeInput 清，渲染器按"没有这路"画（用户 2026-09-27 定）。
    public func validate() throws {
        guard overlays.count == MixerState.overlayCount else { throw MixerStateError.overlayCount(overlays.count) }
        guard transition.slots.count == TransitionSlot.count else { throw MixerStateError.transitionSlotCount(transition.slots.count) }
        if let i = transition.currentSlot, !TransitionSlot.indexRange.contains(i) { throw MixerStateError.transitionSlotIndex(i) }
        guard audio.buses.map(\.bus) == Bus.allCases else { throw MixerStateError.busOrder }
        var seen = Set<Int>()
        for i in inputs {
            guard i.number != MixerState.noInput, i.number > 0 else { throw MixerStateError.reservedInputNumber(i.number) }
            guard seen.insert(i.number).inserted else { throw MixerStateError.duplicateInput(i.number) }
        }
        var seenOut = Set<Int>()
        for o in outputs {
            guard seenOut.insert(o.number).inserted else { throw MixerStateError.duplicateOutput(o.number) }
        }
    }

    /// 按编号找输入。
    public func input(_ number: Int) -> InputConfig? { inputs.first { $0.number == number } }
    /// 按编号找输出。
    public func output(_ number: Int) -> OutputState? { outputs.first { $0.number == number } }

    /// 一路输入的 tally。规则：
    /// - program：是 PGM 输入；或转场进行中且是 PVW 输入；或某个叠加通道可见（开着或退出动画未完）且用的是它。
    /// - preview：是 PVW 输入。
    /// - FTB 不改变 tally。编号 0 永远 off。
    public func tally(ofInput number: Int) -> Tally {
        guard number != MixerState.noInput else { return .off }
        var onProgram = number == program
        if !onProgram && transition.isActive && number == preview { onProgram = true }
        if !onProgram {
            for o in overlays where o.isVisible && o.input == number { onProgram = true; break }
        }
        return Tally(program: onProgram, preview: number == preview)
    }

    /// 所有已配置输入的 tally。
    public var tallies: [Int: Tally] {
        var result: [Int: Tally] = [:]
        for i in inputs { result[i.number] = tally(ofInput: i.number) }
        return result
    }

    /// 清掉瞬态（转场 / FTB / 叠加动画的进度和起始拍、文件输入的定位请求——021），载入节目文件时用；目标值（on / paused / restartOnProgram）保留并直接到位。
    public mutating func resetTransientState() {
        transition.progress = 0
        transition.startTick = nil
        transition.source = .auto
        ftb.level = ftb.on ? 1 : 0
        ftb.startTick = nil
        for i in overlays.indices {
            overlays[i].animProgress = overlays[i].on ? 1 : 0
            overlays[i].startTick = nil
        }
        for i in inputs.indices {
            inputs[i].settings.playback.seekSeconds = nil
            inputs[i].settings.playback.seekTick = nil
        }
    }
}

/// 状态机发布出来的快照：不可变对象，渲染线程 / 音频线程通过原子指针交换拿到最新的一个（§4、§9.1）。
/// 读的一方只 retain 这个对象，不进 actor、不加锁。
public final class MixerSnapshot: Sendable {
    /// 快照内容。
    public let state: MixerState
    /// 产生这个快照的最后一条命令的 sequence（0 = 初始状态）。
    public let sequence: UInt64
    /// 这个快照生效的拍。
    public let tick: Tick
    /// 状态机发布这个快照的时刻（host time；提案 003 §B）。C2 的"状态变化 → 客户端"从它算。
    public let publishedAt: HostTime

    public init(state: MixerState, sequence: UInt64, tick: Tick, publishedAt: HostTime = .now()) {
        self.state = state
        self.sequence = sequence
        self.tick = tick
        self.publishedAt = publishedAt
    }
}
