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

public enum WipeDirection: String, Codable, Sendable {
    case leftToRight, rightToLeft, topToBottom, bottomToTop, diagonal
}

/// Wipe 参数（W3-B 用）。
public struct WipeParams: Hashable, Codable, Sendable {
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
    public var input: Int?
    public var cutAtTick: Int
    public init(input: Int? = nil, cutAtTick: Int = 0) {
        self.input = input
        self.cutAtTick = cutAtTick
    }
}

/// 转场状态。空闲时 `type` / `durationTicks` 就是"下一次转场"的选择（UI 的转场按钮和时长预设改的是它）。
///
/// `progress` 的意义：新画面（= preview 输入）盖在旧画面（= program 输入）上的比例，0 … 1。
/// - 空闲：progress = 0，startTick = nil。
/// - auto 转场：第 s 拍应用命令，之后第 s + k 拍 progress = k / durationTicks（W1-B），到 1 时状态机把 program 与 preview 对调并回到空闲。
/// - tbar：progress 直接等于推杆位置；推到 1 提交（对调 + 回到 0）。
/// 渲染器只看 `progress` 和 `type`；Cut 没有中间态（durationTicks 对它无意义）。
public struct TransitionState: Hashable, Codable, Sendable {
    public var type: TransitionType
    public var durationTicks: Int
    public var progress: Double
    public var source: TransitionSource
    /// auto 转场开始的那一拍（应用命令的拍）；空闲或 tbar 为 nil。
    public var startTick: Tick?
    public var wipe: WipeParams
    public var stinger: StingerParams

    public init(type: TransitionType = .fade, durationTicks: Int = 30, progress: Double = 0, source: TransitionSource = .auto,
                startTick: Tick? = nil, wipe: WipeParams = WipeParams(), stinger: StingerParams = StingerParams()) {
        self.type = type
        self.durationTicks = durationTicks
        self.progress = progress
        self.source = source
        self.startTick = startTick
        self.wipe = wipe
        self.stinger = stinger
    }

    /// 正在转场（画面上有两路混合）。
    public var isActive: Bool { progress > 0 || startTick != nil }
}

/// FTB（§1.1）。`on` 是目标，`level` 是当前黑的比例（渲染器乘 1 − level）；状态机每拍把 level 向目标推 1 / durationTicks。
public struct FadeToBlack: Hashable, Codable, Sendable {
    public var on: Bool
    public var durationTicks: Int
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
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    /// 画中画默认位置：右下 1/4（V8 的固定状态用它）。
    public static let bottomRightQuarter = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
}

public enum OverlayAnimationKind: String, Codable, Sendable {
    case cut, fade, slide, zoom
}

/// 叠加通道的进出动画（W3-B 细化）。durationTicks = 0 等于 cut。
public struct OverlayAnimation: Hashable, Codable, Sendable {
    public var kind: OverlayAnimationKind
    public var durationTicks: Int
    public init(kind: OverlayAnimationKind = .cut, durationTicks: Int = 0) {
        self.kind = kind
        self.durationTicks = durationTicks
    }
}

/// Overlay 1–4 之一（§1.1）。`on` 是目标，`animProgress` 是当前显示比例 0（全隐）… 1（全显）；
/// 状态机每拍向目标推进，渲染器按 `animation.kind` 解释 animProgress。
public struct OverlayState: Hashable, Codable, Sendable {
    /// 叠在上面的输入；nil = 该通道没有指定输入。
    public var input: Int?
    public var on: Bool
    public var rect: NormalizedRect
    public var animProgress: Double
    public var animation: OverlayAnimation
    /// 最近一次 on 变化的拍；空闲为 nil。
    public var startTick: Tick?

    public init(input: Int? = nil, on: Bool = false, rect: NormalizedRect = .full, animProgress: Double = 0,
                animation: OverlayAnimation = OverlayAnimation(), startTick: Tick? = nil) {
        self.input = input
        self.on = on
        self.rect = rect
        self.animProgress = animProgress
        self.animation = animation
        self.startTick = startTick
    }

    /// 画面上能看见（含进出动画中）。
    public var isVisible: Bool { input != nil && (on || animProgress > 0) }
}

// MARK: - 音频

/// 四条总线（§1.1 Bus）。rawValue 也是 `AudioState.buses` 的下标。
public enum Bus: Int, Codable, Sendable, CaseIterable {
    case master = 0, busA, busB, headphones
}

public struct BusState: Hashable, Codable, Sendable {
    public var bus: Bus
    public var gainDb: Double
    public var muted: Bool
    /// 总线效果链占位（ParametricEQ / DynamicsProcessor / PeakLimiter）。
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

/// 音频总体状态。每路输入的路由 / 增益 / 静音 / 独听 / 声像 / 延迟在 `MixerState.inputs[i].settings.audio`，只存一份。
public struct AudioState: Hashable, Codable, Sendable {
    /// 恰好 4 条，顺序 = Bus.allCases。
    public var buses: [BusState]
    /// 音频跟随视频：转场时相关输入交叉淡变，长度 = 转场时长，起点同一拍（§7）。
    public var afv: Bool
    public var monitorMode: MonitorMode

    public init(buses: [BusState] = Bus.allCases.map { BusState(bus: $0) }, afv: Bool = false, monitorMode: MonitorMode = .afl) {
        self.buses = buses
        self.afv = afv
        self.monitorMode = monitorMode
    }
}

// MARK: - 输出

/// §1.1 Output：录制、推流、NDI 发送、外部显示、虚拟摄像头、多画面。
public enum OutputKind: String, Codable, Sendable, CaseIterable {
    case record, stream, ndi, externalDisplay, virtualCamera, multiview
}

/// 输出送什么画面（外部显示 / NDI / 虚拟摄像头相当于 Aux）。
public enum OutputSource: Hashable, Codable, Sendable {
    case program
    case preview
    case multiview
    case input(number: Int)
}

public enum VideoCodec: String, Codable, Sendable {
    case h264, hevc, prores422, prores422HQ, prores4444
}

public enum AudioCodec: String, Codable, Sendable {
    case aac, pcm
}

/// 视频编码参数（设计方案 §8 编码行）。width / height nil = 节目分辨率。
public struct VideoEncodeSettings: Hashable, Codable, Sendable {
    public var codec: VideoCodec
    public var bitrateBps: Int
    public var keyframeIntervalFrames: Int
    public var width: Int?
    public var height: Int?
    public init(codec: VideoCodec = .h264, bitrateBps: Int = 6_000_000, keyframeIntervalFrames: Int = 120, width: Int? = nil, height: Int? = nil) {
        self.codec = codec
        self.bitrateBps = bitrateBps
        self.keyframeIntervalFrames = keyframeIntervalFrames
        self.width = width
        self.height = height
    }
}

public struct AudioEncodeSettings: Hashable, Codable, Sendable {
    public var codec: AudioCodec
    public var bitrateBps: Int
    public init(codec: AudioCodec = .aac, bitrateBps: Int = 160_000) {
        self.codec = codec
        self.bitrateBps = bitrateBps
    }
}

public enum RecordContainer: String, Codable, Sendable {
    case mov, mp4
}

/// 录制参数（设计方案 §8 录制行）。
public struct RecordSettings: Hashable, Codable, Sendable {
    public var directory: String
    /// 文件名模板，支持 {show} {date} {time} {output}。
    public var fileNamePattern: String
    public var container: RecordContainer
    /// movieFragmentInterval，秒；崩溃可恢复到最后一个片段。
    public var fragmentIntervalSeconds: Double
    /// 停止后转封装成 MP4（失败保留 .mov）。
    public var remuxToMP4: Bool
    public init(directory: String, fileNamePattern: String = "{show}-{date}-{time}", container: RecordContainer = .mov,
                fragmentIntervalSeconds: Double = 1, remuxToMP4: Bool = false) {
        self.directory = directory
        self.fileNamePattern = fileNamePattern
        self.container = container
        self.fragmentIntervalSeconds = fragmentIntervalSeconds
        self.remuxToMP4 = remuxToMP4
    }
}

/// 推流目的地（RTMP / RTMPS / SRT 由 url 的 scheme 决定）。
public struct StreamSettings: Hashable, Codable, Sendable {
    public var url: String
    public var streamKey: String
    /// 指数退避重连的上限（秒）。
    public var reconnectMaxSeconds: Double
    public init(url: String, streamKey: String = "", reconnectMaxSeconds: Double = 30) {
        self.url = url
        self.streamKey = streamKey
        self.reconnectMaxSeconds = reconnectMaxSeconds
    }
}

/// 一个输出的设置。按 kind 取用相关的子结构，其他留 nil；`extra` 给各输出会话放自己的附加项（占位）。
public struct OutputSettings: Hashable, Codable, Sendable {
    public var source: OutputSource
    public var video: VideoEncodeSettings?
    public var audio: AudioEncodeSettings?
    public var record: RecordSettings?
    public var stream: StreamSettings?
    public var extra: [String: JSONValue]
    public init(source: OutputSource = .program, video: VideoEncodeSettings? = nil, audio: AudioEncodeSettings? = nil,
                record: RecordSettings? = nil, stream: StreamSettings? = nil, extra: [String: JSONValue] = [:]) {
        self.source = source
        self.video = video
        self.audio = audio
        self.record = record
        self.stream = stream
        self.extra = extra
    }
}

/// 一个输出的状态：配置 + 目标开关。运行时的帧数 / 丢帧 / 码率在 Stats.encoder 里，不在这里（铁律 4）。
public struct OutputState: Hashable, Codable, Sendable, Identifiable {
    /// 输出编号，从 1 起。
    public var number: Int
    public var kind: OutputKind
    public var name: String
    /// 目标状态：true = 应该在跑（startRecord / startStream 置它）。
    public var enabled: Bool
    public var settings: OutputSettings

    public init(number: Int, kind: OutputKind, name: String, enabled: Bool = false, settings: OutputSettings = OutputSettings()) {
        self.number = number
        self.kind = kind
        self.name = name
        self.enabled = enabled
        self.settings = settings
    }
    public var id: Int { number }
}

// MARK: - Tally

/// §1.1 Tally：每个输入"在 PGM / 在 PVW / 都不在"。由 `MixerState.tally(ofInput:)` 推导，全系统只算这一次。
public struct Tally: Hashable, Codable, Sendable {
    public var program: Bool
    public var preview: Bool
    public init(program: Bool, preview: Bool) {
        self.program = program
        self.preview = preview
    }
    public static let off = Tally(program: false, preview: false)
}

// MARK: - MixerState

public enum MixerStateError: Error, Equatable {
    case overlayCount(Int)
    case busOrder
    case reservedInputNumber(Int)
    case duplicateInput(Int)
    case duplicateOutput(Int)
}

/// 不可变快照（设计方案 §4）。相比 §4 多了 `format` 和 `inputs`：addInput / removeInput / setInputSettings 要在 reduce 里落地，
/// 输入表必须在状态里；渲染器每拍要读裁切 / 变换，也得从快照拿。
public struct MixerState: Hashable, Codable, Sendable {
    public var format: ProgramFormat
    /// 按编号升序；编号从 1 起。
    public var inputs: [InputConfig]
    /// PGM 输入编号；0 = 黑场。
    public var program: Int
    /// PVW 输入编号；0 = 黑场。
    public var preview: Int
    public var transition: TransitionState
    public var ftb: FadeToBlack
    /// 恰好 4 个。
    public var overlays: [OverlayState]
    public var audio: AudioState
    public var outputs: [OutputState]

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

    /// 不变量检查（解码 / 载入节目文件后调）。
    public func validate() throws {
        guard overlays.count == MixerState.overlayCount else { throw MixerStateError.overlayCount(overlays.count) }
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

    public func input(_ number: Int) -> InputConfig? { inputs.first { $0.number == number } }
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

    /// 清掉瞬态（转场 / FTB / 叠加动画的进度和起始拍），载入节目文件时用；目标值（on）保留并直接到位。
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
    }
}

/// 状态机发布出来的快照：不可变对象，渲染线程 / 音频线程通过原子指针交换拿到最新的一个（§4、§9.1）。
/// 读的一方只 retain 这个对象，不进 actor、不加锁。
public final class MixerSnapshot: Sendable {
    public let state: MixerState
    /// 产生这个快照的最后一条命令的 sequence（0 = 初始状态）。
    public let sequence: UInt64
    /// 这个快照生效的拍。
    public let tick: Tick

    public init(state: MixerState, sequence: UInt64, tick: Tick) {
        self.state = state
        self.sequence = sequence
        self.tick = tick
    }
}
