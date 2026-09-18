// 输入层契约（设计方案 §4、§6）。

/// 输入类型（§1.1 Input）。
public enum InputKind: String, Codable, Sendable, CaseIterable {
    case camera, decklink, screen, file, image, ndi, audio, synthetic
}

/// 输入的运行时状态（设计方案 §6 无信号 / 热插拔 / 权限）。由输入自己的线程写，UI / 引擎读；实现要保证读写原子。
/// 未 `start()` 或已 `stop()` 时是 `noSignal`。
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

/// 一路输入"接的是什么"。`kind` 由它决定，不另外存。
public enum InputSource: Hashable, Codable, Sendable {
    /// AVCaptureDevice.uniqueID。UVC 采集卡也走这里。
    case camera(uniqueID: String)
    /// DeckLink 设备的持久标识（W3-A 定具体格式，先用字符串）。
    case decklink(deviceID: String)
    /// 屏幕 / 窗口 / 应用；frameRate nil = 跟节目帧率。
    case screen(target: ScreenTarget, frameRate: FrameRate?, captureAudio: Bool)
    /// 视频文件；rate = 播放速率（1 = 正常）。
    case file(path: String, endAction: FileEndAction, rate: Double)
    case image(path: String)
    /// NDI 源名（"机器名 (源名)"）。
    case ndi(sourceName: String)
    /// Core Audio 设备 UID（纯音频输入）。
    case audio(deviceUID: String)
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

    /// 延迟补偿的合法范围（ms）。
    public static let delayRangeMs = 0...500
    /// 增益的合法范围（dB）。
    public static let gainRangeDb = -96.0...24.0

    public init(routing: BusRouting = .masterOnly, gainDb: Double = 0, muted: Bool = false, solo: Bool = false,
                pan: Double = 0, delayMs: Int = 0) {
        self.routing = routing
        self.gainDb = gainDb
        self.muted = muted
        self.solo = solo
        self.pan = pan
        self.delayMs = delayMs
    }
}

/// 效果链里的一格（占位）。`id` 是效果标识（例如 "parametricEQ"），参数是自由 JSON；具体定义由音频 / 合成会话给。
public struct EffectSlot: Hashable, Codable, Sendable {
    /// 效果标识，例如 "parametricEQ"。
    public var id: String
    /// 是否启用。
    public var enabled: Bool
    /// 效果参数（自由 JSON，占位）。
    public var params: [String: JSONValue]
    public init(id: String, enabled: Bool = true, params: [String: JSONValue] = [:]) {
        self.id = id
        self.enabled = enabled
        self.params = params
    }
}

/// 抠像参数（占位，W3-B 细化时走契约提案）。YCbCr 颜色距离 + 溢色抑制（设计方案 §5）。
public struct KeyerSettings: Hashable, Codable, Sendable {
    /// 是否抠像。
    public var enabled: Bool
    /// 键色。
    public var keyColor: RGB8
    /// 颜色距离容差 0–1。
    public var tolerance: Double
    /// 边缘柔化 0–1。
    public var softness: Double
    /// 溢色抑制强度 0–1。
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
    /// 效果链占位。
    public var effects: [EffectSlot]
    /// 抠像占位。
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
    /// 纯音频输入为 nil。
    var videoSlot: (any FrameSlot)? { get }
    /// 没有音频的输入（图片等）为 nil。
    var audioRing: (any AudioRing)? { get }
    func start() throws
    func stop()
}
