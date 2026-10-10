// 输入层契约（设计方案 §4、§6）。

/// 输入类型（§1.1 Input）。
public enum InputKind: String, Codable, Sendable, CaseIterable {
    case camera, decklink, screen, file, image, ndi, audio, synthetic
}

/// 输入的运行时状态（设计方案 §6 无信号 / 热插拔 / 权限）。由输入自己的线程写，UI / 引擎读；实现要保证读写原子。
/// 未 `start()` 或已 `stop()` 时是 `noSignal`。
///
/// `noSignal` 与 `error` 的分界（W3-A 口径，用户 2026-09-22 定）：**会不会自己好**。
/// - 会自己好 → `noSignal`，另给 `lastError` 文案说明：驱动没装、设备不在 / 被拔了、NDI 源还没出现、外接显示器拔了。
///   装上驱动、插回设备、源上线之后输入自己恢复，不用用户在界面上重来。
/// - 不会自己好 → `error(message:)`：SDK 没编进来（可选 target 没开）、起流失败、权限被拒。
///   要么重新编译、要么去系统设置改权限、要么换配置，输入自己等不回来。
public enum InputState: Hashable, Sendable, Codable {
    case live
    case noSignal
    /// 带给用户看的文案（例如"摄像头权限被拒，去系统设置 › 隐私与安全性打开"）。
    case error(message: String)
}

// MARK: - 来源

/// 屏幕采集的目标。
public enum ScreenTarget: Hashable, Codable, Sendable {
    case display(id: UInt32)
    case window(id: UInt32)
    case application(bundleID: String)
}

/// 文件播到结尾怎么办。
public enum FileEndAction: String, Codable, Sendable {
    case holdLastFrame, loop, black
}

/// 合成测试源（引擎内置输入，测试标准 §2.1）的配置。TestKit 的 SyntheticVideoInput / SyntheticAudioInput 读它。
public struct SyntheticSourceSettings: Hashable, Codable, Sendable {
    /// 合成源帧率（30 / 59.94 / 60）。
    public var frameRate: FrameRate
    /// 画面宽（像素）。
    public var width: Int
    /// 画面高（像素）。
    public var height: Int
    /// 图案底色：纯灰（V7 用 64 / 192）、渐变，或灰底叠零均值噪声（`.noise`，提案 006，E2 在长跑里才有可判对象）。
    public var background: TestPattern.Background
    /// 烧进画面的输入 ID（调色板索引 0–15）；nil = (输入编号 − 1) mod 16。
    public var patternID: Int?
    /// 人为抖动：每帧到达时刻 ± 均匀分布（ms）。
    public var jitterMs: Double
    /// 人为丢帧：每 N 帧丢 1 帧；0 = 不丢。
    public var dropEveryN: Int
    /// 人为时钟漂移（ppm，±100 量级）。
    public var clockDriftPpm: Double
    /// 是否同时产生合成音频（click 与闪光共用 t0）。
    public var audio: Bool
    /// 合成音频的采样率漂移（ppm）。
    public var audioDriftPpm: Double

    public init(frameRate: FrameRate = .fps60, width: Int = 1920, height: Int = 1080,
                background: TestPattern.Background = .gray(level: 128), patternID: Int? = nil,
                jitterMs: Double = 0, dropEveryN: Int = 0, clockDriftPpm: Double = 0,
                audio: Bool = true, audioDriftPpm: Double = 0) {
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.background = background
        self.patternID = patternID
        self.jitterMs = jitterMs
        self.dropEveryN = dropEveryN
        self.clockDriftPpm = clockDriftPpm
        self.audio = audio
        self.audioDriftPpm = audioDriftPpm
    }
}

/// DeckLink 输入接口（BMDVideoConnection 的单个位；提案 008）。
public enum DeckLinkConnection: String, Codable, Sendable, CaseIterable {
    case sdi, hdmi, opticalSDI, component, composite, sVideo
}

/// NDI 接收带宽（NDIlib_recv_bandwidth；提案 008）。多画面缩略图用 `lowest` 省一半以上带宽 / 解码。
public enum NDIBandwidth: String, Codable, Sendable, CaseIterable {
    case highest, lowest, audioOnly
}

/// 一路输入"接的是什么"。`kind` 由它决定，不另外存。
///
/// **声道映射**（`audio` / `decklink` 的 `channels`，提案 014）：取源的哪几路写进这一路的音频环，值是源的声道下标（从 0 起）。
/// 环的声道数由组装方定（App / headless 现在都是 2），目标声道 d 取 `channels[d]`：
/// - 空数组 = 取前几路（目标 d 取源第 d 路；源是单声道就复制到所有声道，源声道比环少时缺的复制最后一路）；
/// - 比环的声道数短时，缺的复制最后一项（单声道话筒插在第 5 路：`[4]` 就是两个声道都取第 5 路）；多出来的项忽略；
/// - 越界的下标钳到源的声道范围里（`[0, 源声道数 − 1]`）。
/// 它是**采集侧**的参数：决定输入往环里写什么，改它等于重建这一路输入（和换设备同一类操作），所以放在这里，
/// 不放混音侧的 `InputAudioSettings`（提案 014"为什么不放 InputAudioSettings"）。
public enum InputSource: Hashable, Codable, Sendable {
    /// AVCaptureDevice.uniqueID。UVC 采集卡也走这里。
    case camera(uniqueID: String)
    /// DeckLink 设备的持久标识 + 输入接口（提案 008）。
    ///
    /// `deviceID` 的格式（W3-A 定，用户 2026-09-22 确认）：
    /// - 卡有 `BMDDeckLinkPersistentID` 属性时 `peid:<十进制 int64>`（`DeckLinkDeviceInfo.persistentID` 就是它）；
    /// - 没有该属性的老卡 `model:<型号>#<同型号内序号>`；
    /// - 空串 = 第一台有输入的卡。
    ///
    /// `connection` nil = 不改卡上的当前设置（Desktop Video Setup 里选的那个）。
    /// `channels` = SDI / HDMI 内嵌音频取哪几路（提案 014，口径见上面"声道映射"；内嵌音频最多 16 路）。
    case decklink(deviceID: String, connection: DeckLinkConnection? = nil, channels: [Int] = [])
    /// 屏幕 / 窗口 / 应用；frameRate nil = 跟节目帧率。
    case screen(target: ScreenTarget, frameRate: FrameRate?, captureAudio: Bool)
    /// 视频文件；rate = 播放速率（1 = 正常）。
    case file(path: String, endAction: FileEndAction, rate: Double)
    case image(path: String)
    /// NDI 源名（"机器名 (源名)"）+ 带宽模式 + 抖动缓冲深度（帧，0–2；提案 008）。
    /// 抖动缓冲直接决定这路的延迟，也决定 `Frame.pts` 的口径（见 `Frame.pts`）。
    case ndi(sourceName: String, bandwidth: NDIBandwidth = .highest, jitterBufferFrames: Int = 1)
    /// Core Audio 设备 UID（纯音频输入，`kAudioDevicePropertyDeviceUID`；空串 = 跟随系统默认输入）+ 取设备的哪几路
    /// （提案 014，口径见上面"声道映射"）。这种输入没有画面，`Input.videoSlot` 为 nil（能不能切进 Program 见那里的注释）。
    case audio(deviceUID: String, channels: [Int] = [])
    case synthetic(settings: SyntheticSourceSettings)

    /// 对应的输入类型。
    public var kind: InputKind {
        switch self {
        case .camera: .camera
        case .decklink: .decklink
        case .screen: .screen
        case .file: .file
        case .image: .image
        case .ndi: .ndi
        case .audio: .audio
        case .synthetic: .synthetic
        }
    }

    /// 抖动缓冲深度的合法范围（帧）。
    public static let ndiJitterBufferRange = 0...2
    /// 抖动缓冲深度的默认值（帧）。
    public static let defaultNDIJitterBufferFrames = 1

    // MARK: Codable（提案 008 / 014）

    /// JSON 形态的镜像。带默认值的参数在这里都是 Optional：合成的 Codable 对 Optional 用 decodeIfPresent / encodeIfPresent，
    /// 所以老文件缺键能按默认值解、默认值可以不写键。
    /// - 解码：缺 `connection` → nil，缺 `bandwidth` → highest，缺 `jitterBufferFrames` → 1，缺 `channels` → []。
    /// - 编码：`connection` nil 不写键；`channels` 为空不写键（014 之前能表达的值编出来与之前逐字节相同）；
    ///   ndi 的 `bandwidth` / `jitterBufferFrames` 照旧总是写（提案 008 落地时的形态）。
    ///   键名快照在 `ContractsP3Tests.testP3_008_*` 与 `Contracts014Tests` 里钉住。
    private enum Form: Codable {
        case camera(uniqueID: String)
        case decklink(deviceID: String, connection: DeckLinkConnection?, channels: [Int]?)
        case screen(target: ScreenTarget, frameRate: FrameRate?, captureAudio: Bool)
        case file(path: String, endAction: FileEndAction, rate: Double)
        case image(path: String)
        case ndi(sourceName: String, bandwidth: NDIBandwidth?, jitterBufferFrames: Int?)
        case audio(deviceUID: String, channels: [Int]?)
        case synthetic(settings: SyntheticSourceSettings)
    }

    public init(from decoder: any Decoder) throws {
        switch try Form(from: decoder) {
        case .camera(let id): self = .camera(uniqueID: id)
        case .decklink(let id, let connection, let channels):
            self = .decklink(deviceID: id, connection: connection, channels: channels ?? [])
        case .screen(let target, let rate, let audio): self = .screen(target: target, frameRate: rate, captureAudio: audio)
        case .file(let path, let end, let rate): self = .file(path: path, endAction: end, rate: rate)
        case .image(let path): self = .image(path: path)
        case .ndi(let name, let bandwidth, let jitter):
            self = .ndi(sourceName: name, bandwidth: bandwidth ?? .highest,
                        jitterBufferFrames: jitter ?? InputSource.defaultNDIJitterBufferFrames)
        case .audio(let uid, let channels): self = .audio(deviceUID: uid, channels: channels ?? [])
        case .synthetic(let settings): self = .synthetic(settings: settings)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let form: Form
        switch self {
        case .camera(let id): form = .camera(uniqueID: id)
        case .decklink(let id, let connection, let channels):
            form = .decklink(deviceID: id, connection: connection, channels: channels.isEmpty ? nil : channels)
        case .screen(let target, let rate, let audio): form = .screen(target: target, frameRate: rate, captureAudio: audio)
        case .file(let path, let end, let rate): form = .file(path: path, endAction: end, rate: rate)
        case .image(let path): form = .image(path: path)
        case .ndi(let name, let bandwidth, let jitter): form = .ndi(sourceName: name, bandwidth: bandwidth, jitterBufferFrames: jitter)
        case .audio(let uid, let channels): form = .audio(deviceUID: uid, channels: channels.isEmpty ? nil : channels)
        case .synthetic(let settings): form = .synthetic(settings: settings)
        }
        try form.encode(to: encoder)
    }
}

// MARK: - 设置

/// 四边裁切，各边是占宽 / 高的比例（0–1）。
public struct CropInsets: Hashable, Codable, Sendable {
    /// 左边裁掉的比例。
    public var left: Double
    /// 上边裁掉的比例。
    public var top: Double
    /// 右边裁掉的比例。
    public var right: Double
    /// 下边裁掉的比例。
    public var bottom: Double
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
    /// 不裁。
    public static let none = CropInsets()
}

/// 放进节目画面时的变换：缩放、平移（占节目宽 / 高的比例）、旋转、翻转。
public struct Transform2D: Hashable, Codable, Sendable {
    /// 缩放倍数，1 = 原样。
    public var scale: Double
    /// 水平平移，占节目宽的比例。
    public var offsetX: Double
    /// 垂直平移，占节目高的比例。
    public var offsetY: Double
    /// 旋转角度（度，顺时针）。
    public var rotationDegrees: Double
    /// 水平翻转。
    public var flipHorizontal: Bool
    /// 垂直翻转。
    public var flipVertical: Bool
    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, rotationDegrees: Double = 0,
                flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
    /// 不变换。
    public static let identity = Transform2D()
}

/// 送哪些总线（§1.1 Bus：Master、Bus A、Bus B、Headphones）。
public struct BusRouting: Hashable, Codable, Sendable {
    /// 送 Master。
    public var master: Bool
    /// 送 Bus A。
    public var busA: Bool
    /// 送 Bus B。
    public var busB: Bool
    /// 送 Headphones。
    public var headphones: Bool
    public init(master: Bool = true, busA: Bool = false, busB: Bool = false, headphones: Bool = false) {
        self.master = master
        self.busA = busA
        self.busB = busB
        self.headphones = headphones
    }
    /// 只送 Master（默认）。
    public static let masterOnly = BusRouting()

    /// 按总线读写。
    public subscript(bus: Bus) -> Bool {
        get {
            switch bus {
            case .master: master
            case .busA: busA
            case .busB: busB
            case .headphones: headphones
            }
        }
        set {
            switch bus {
            case .master: master = newValue
            case .busA: busA = newValue
            case .busB: busB = newValue
            case .headphones: headphones = newValue
            }
        }
    }
}

/// 一路输入的音频参数（设计方案 §7"每路输入"那一行）。
public struct InputAudioSettings: Hashable, Codable, Sendable {
    /// 送哪些总线。
    public var routing: BusRouting
    /// 增益，dB。
    public var gainDb: Double
    /// 静音。
    public var muted: Bool
    /// 独听（送耳机）。
    public var solo: Bool
    /// 声像 −1（左）… +1（右）。
    public var pan: Double
    /// 延迟补偿（§3.6）：把这路音频相对视频推迟 0–500 ms，修采集卡自身的 A/V 偏差。由混音器的延迟线实现。
    public var delayMs: Int
    /// 这一路参不参与 AFV 门控（用户 2026-09-22 批，012"顺带的疑问"1）：
    /// - true（默认）= 跟随视频：`AudioState.afv` 开时按 PGM 门控，转场时进交叉淡变；
    /// - false = 不跟随视频：门控增益恒 1，一直按自己的推子 / 静音 / 路由出声，也不进转场的 from / to
    ///   （主持人话筒的用法）。`AudioState.afv` 关时所有路都恒 1，这一位不起作用。
    public var afv: Bool

    /// 延迟补偿的合法范围（ms）。
    public static let delayRangeMs = 0...500
    /// 增益的合法范围（dB）。
    public static let gainRangeDb = -96.0...24.0

    public init(routing: BusRouting = .masterOnly, gainDb: Double = 0, muted: Bool = false, solo: Bool = false,
                pan: Double = 0, delayMs: Int = 0, afv: Bool = true) {
        self.routing = routing
        self.gainDb = gainDb
        self.muted = muted
        self.solo = solo
        self.pan = pan
        self.delayMs = delayMs
        self.afv = afv
    }

    enum CodingKeys: String, CodingKey { case routing, gainDb, muted, solo, pan, delayMs, afv }

    /// 老 Show 没有 afv 键：缺键 = true（参与门控，与加这一位之前的行为相同）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routing = try c.decodeIfPresent(BusRouting.self, forKey: .routing) ?? .masterOnly
        gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
        afv = try c.decodeIfPresent(Bool.self, forKey: .afv) ?? true
    }

    /// JSON 键名。
    public static let jsonKeys = ["routing", "gainDb", "muted", "solo", "pan", "delayMs", "afv"]
}

/// 效果链里的一格。`id` 是效果标识，`params` 是该 id 的键表（全部 number；缺键 = 默认值、越界钳住，由实现做）。
/// 链的顺序 = 处理顺序；`enabled = false` 的格旁路。`InputSettings.effects`（每路）与 `BusState.effects`（每总线）同一套键表；
/// 总线那一半 W5-C（prompt 88）起生效，每路的归 W1-D3（prompt 102）。认不出的 id / 键实现跳过，不报错。
///
/// 音频效果的 id 与键（提案 012 C 三个苹果单元 + 提案 024 (b) 的自写压缩器，用户 2026-10-03 批；CONTRACTS.md §2.4 是同一张表）。
/// 三个苹果单元的键范围 = 引擎钳位 `SwitcherAudio.EffectParameterRanges`（头文件范围 ∩ 本机 AU 的 ParameterInfo，表在 reports/w5-audio-bus-effects.md §1.5），契约不重复；
/// 024 新加的键范围与默认值在这里定：
///
/// | id | 键 |
/// |---|---|
/// | `parametricEQ` | `centerHz`、`q`、`gainDb`。一条链里连续多格 = 多段（≤ 16，见下） |
/// | `dynamicsProcessor` | `thresholdDb`、`headroomDb`、`expansionRatio`、`attackSeconds`、`releaseSeconds`、`overallGainDb`。苹果 AUDynamicsProcessor，没有固定比例（高级项） |
/// | `compressor` | `thresholdDb`（−60…0 dBFS，默认 −20）、`ratio`（1…20，默认 4，n:1）、`kneeDb`（0…24，默认 6；0 = 硬拐点）、`attackSeconds`（0.0001…0.2，默认 0.005）、`releaseSeconds`（0.01…3，默认 0.1）、`makeupGainDb`（0…24，默认 0）。自写 C 压缩器（024 (b)，W1-D3 实现）：不用前瞻、组延迟按设计 0 帧，实测延迟进 A/V 对齐；与 `dynamicsProcessor` 二选一占同一格 |
/// | `peakLimiter` | `attackSeconds`、`decaySeconds`、`preGainDb`，另加可选 `ceilingDb`（−20…0 dBFS，默认 0；024 顺带 (2)：AUPeakLimiter 的天花板固定 0 dBFS，实现为同一格内限幅之后的输出增益，不多占格） |
///
/// `parametricEQ.q` 的口径（024 顺带 (1)）：经典 Q——带宽 = 增益为峰值一半（dB）处的上下边频之比，BW = 2/ln2 · asinh(1/(2q)) 倍频程
/// （q = √2 → 1 oct）；AUNBandEQ 的带宽参数就是这个定义（设计方案 §7 原来对的 AUParametricEQ 的 Q 随增益变，不是这个口径）。
/// 一个 EQ 格（AUNBandEQ）最多 16 段：连续的 `parametricEQ` 格合成一格；每条总线最多 3 格（被别的效果隔开的 EQ 另占一格），超出的不装。
///
/// 视频效果格目前没有：`border`（画中画边框）是提案 010 落地前的过渡做法，正式字段是 `OverlayState.border`，搬迁与 reducer 一律清掉（P4 / 019 D）。
public struct EffectSlot: Hashable, Codable, Sendable {
    /// 效果标识，例如 "parametricEQ"（键表见类型说明）。
    public var id: String
    /// 是否启用。
    public var enabled: Bool
    /// 效果参数（按 id 的键表；全部 number）。
    public var params: [String: JSONValue]
    public init(id: String, enabled: Bool = true, params: [String: JSONValue] = [:]) {
        self.id = id
        self.enabled = enabled
        self.params = params
    }
}

/// 抠像参数（YCbCr 颜色距离 + 溢色抑制，设计方案 §5）。四个数的口径由提案 009 钉死，
/// 渲染器 `Shaders/Compositor.metal` 的 `applyKey`（uniforms 在 `Renderer/CompositorPasses.swift` 的 `Keyer.fill`）就是定义：
/// UI 的滑杆、`docs/api.md` 的 setInputSettings 说明、别的渲染实现都按同一口径。
/// 输出是预乘 alpha（`rgb × alpha`），进 source-over 混合管线；抠像对该输入出现的每一处
/// （PGM 底、转场新画面、叠加、PVW、多画面缩略图）都生效。
public struct KeyerSettings: Hashable, Codable, Sendable {
    /// 是否抠像。
    public var enabled: Bool
    /// 键色，full-range 8-bit RGB。渲染器把它按 BT.709 换成色度 (Cb, Cr)（归一化到 −0.5…+0.5），
    /// **只比色度不比亮度**：绿幕上的阴影（同色度、低亮度）也被抠掉——这是 §5"YCbCr 空间的颜色距离"的第一版取舍。
    public var keyColor: RGB8
    /// 颜色距离容差 0–1：完全抠掉的色度距离半径 = `tolerance × 0.5`。
    /// 像素色度到键色色度的欧氏距离 d ≤ 半径 → alpha 0。
    public var tolerance: Double
    /// 边缘柔化 0–1：柔化带宽度 = `softness × 0.25`（色度距离单位）。
    /// d 落在 [半径, 半径 + 带宽] 内时 alpha 用 smoothstep 从 0 升到 1；0 = 硬边。
    public var softness: Double
    /// 溢色抑制强度 0–1：留下来的像素把色度在键色方向上的正分量减掉这个比例
    /// （c′ = c − s·max(0, c·k̂)·k̂），亮度不变，所以溢色边缘变成同亮度的灰而不是变暗。
    /// 键色是灰（没有色度方向）时不做抑制。
    public var spillSuppression: Double
    public init(enabled: Bool = false, keyColor: RGB8 = RGB8(red: 0, green: 255, blue: 0),
                tolerance: Double = 0.3, softness: Double = 0.1, spillSuppression: Double = 0.5) {
        self.enabled = enabled
        self.keyColor = keyColor
        self.tolerance = tolerance
        self.softness = softness
        self.spillSuppression = spillSuppression
    }
}

/// 一路输入的全部可调设置（设计方案 §4 `Input.settings`）。存在 MixerState.inputs 里，只此一份。
public struct InputSettings: Hashable, Codable, Sendable {
    /// 四边裁切。
    public var crop: CropInsets
    /// 放进节目画面的变换。
    public var transform: Transform2D
    /// 音频参数（路由 / 增益 / 静音 / 独听 / 声像 / 延迟补偿）。
    public var audio: InputAudioSettings
    /// 这一路的效果链（id 与键表见 `EffectSlot`；每路的接线归 W1-D3 / prompt 102，装什么的口径见提案 023 第三节）。
    public var effects: [EffectSlot]
    /// 抠像（口径见提案 009）。
    public var keyer: KeyerSettings

    public init(crop: CropInsets = .none, transform: Transform2D = .identity, audio: InputAudioSettings = InputAudioSettings(),
                effects: [EffectSlot] = [], keyer: KeyerSettings = KeyerSettings()) {
        self.crop = crop
        self.transform = transform
        self.audio = audio
        self.effects = effects
        self.keyer = keyer
    }

    /// 把所有数值钳到合法范围（reducer 应用 setInputSettings 时调）：
    /// 延迟 0–500 ms、增益 −96…+24 dB、声像 −1…1、裁切各边 0–1 且对边之和 ≤ 1（右 / 下让位）、缩放 > 0。
    public func clamped() -> InputSettings {
        var s = self
        s.audio.delayMs = min(max(s.audio.delayMs, InputAudioSettings.delayRangeMs.lowerBound), InputAudioSettings.delayRangeMs.upperBound)
        s.audio.gainDb = min(max(s.audio.gainDb, InputAudioSettings.gainRangeDb.lowerBound), InputAudioSettings.gainRangeDb.upperBound)
        s.audio.pan = min(max(s.audio.pan, -1), 1)
        func unit(_ v: Double) -> Double { min(max(v, 0), 1) }
        s.crop.left = unit(s.crop.left)
        s.crop.top = unit(s.crop.top)
        s.crop.right = min(unit(s.crop.right), 1 - s.crop.left)
        s.crop.bottom = min(unit(s.crop.bottom), 1 - s.crop.top)
        s.transform.scale = max(s.transform.scale, 0.01)
        s.keyer.tolerance = unit(s.keyer.tolerance)
        s.keyer.softness = unit(s.keyer.softness)
        s.keyer.spillSuppression = unit(s.keyer.spillSuppression)
        return s
    }
}

// MARK: - 配置与协议

/// 一路输入的静态配置：编号、名字、来源、设置。节目文件和 MixerState.inputs 里存的就是它。
public struct InputConfig: Hashable, Codable, Sendable, Identifiable {
    /// 输入编号，从 1 起；0 保留给"无输入 / 黑场"。
    public var number: Int
    /// 显示名。
    public var name: String
    /// 来源。
    public var source: InputSource
    /// 可调设置。
    public var settings: InputSettings

    public init(number: Int, name: String, source: InputSource, settings: InputSettings = InputSettings()) {
        self.number = number
        self.name = name
        self.source = source
        self.settings = settings
    }

    /// 由 source 推出的类型。
    public var kind: InputKind { source.kind }
    /// Identifiable：就是编号。
    public var id: Int { number }
}

/// 一路正在运行的输入（设计方案 §4 `Input`、§6"统一接口"）。
///
/// 规则：
/// - 自带线程，只往自己的 `videoSlot` / `audioRing` 里写，从不碰渲染线程和音频线程。
/// - 帧槽和音频环由组装方在 init 时注入（实现分别在 SwitcherEngine 和 SwitcherAudio，Inputs 包看不到）。
/// - `number` / `kind` 创建后不变；`name` 和设置以 MixerState 为准，对象只是镜像。
/// - `state` 由输入线程写、任何线程读，实现要保证原子。
/// - `start()` / `stop()` 在非实时线程调，可以阻塞、可以分配；stop 后 state 回到 noSignal。
public protocol Input: AnyObject {
    var number: Int { get }
    var name: String { get }
    var kind: InputKind { get }
    var state: InputState { get }
    /// 纯音频输入（`InputSource.audio`）为 nil。口径（W2-A2 报告 §4 第 2 条，用户 2026-09-23 定）：
    /// - 引擎对这一路挑帧恒为 nil：组装方可以不登记帧槽，也可以登记一个没人往里推的空槽（App 的 InputRuntime 给每路都建槽，效果相同）；
    /// - 它照样能被选进 Program / Preview / 叠加：画面按"没帧"画黑场，音频照常按每路 AFV 走（切到它就出它的声）；
    /// - 多画面里它的格子画占位（名字 + 电平表），不是黑画面。
    var videoSlot: (any FrameSlot)? { get }
    /// 没有音频的输入（图片等）为 nil。
    var audioRing: (any AudioRing)? { get }
    func start() throws
    func stop()
}
