import Foundation

/// stats.jsonl 的一行（测试标准 §7）。字段名逐字等于那一行：
/// ts、tick、render_ms、missed_render、jitter_ms、per_input{fps, dup, drop}、encoder[{skipped, bitrate}]、audio{dropouts, underruns}、rss_mb、cpu_pct、gpu_pct。
/// UI 状态行、API、测试三方读同一个结构，不许各自另算（铁律 4）。
///
/// 口径（每秒一行，"窗口" = 上一行到这一行之间）：
/// - `ts`：Unix 时间（秒，含小数），采样那一刻的墙钟。
/// - `tick`：采样那一刻的节目拍。
/// - `render_ms`：V1，窗口内每拍"拍点时刻 → 该拍命令缓冲区 GPU 完成"的平均毫秒数。
/// - `missed_render`：V2，渲染滞后丢帧，自启动以来的累计数。
/// - `jitter_ms`：V3，窗口内 |PGM 帧派发时刻 − 理想拍点| 的最大值（ms）。
/// - `per_input[n]`：键是输入编号。fps = 窗口内该输入 push 的帧数 / 窗口秒数；dup = FrameSlotStats.reused 累计；drop = FrameSlotStats.dropped 累计。
/// - `encoder[i]`：与 MixerState.outputs 里带编码器的输出同序。skipped = E1 编码滞后跳帧累计；bitrate = 窗口内平均输出码率（bit/s）。
/// - `audio`：A1，dropouts = 输出回调超时累计，underruns = 缓冲欠载累计。
/// - `rss_mb`：进程 RSS（MB）；`cpu_pct`：进程 CPU（100 = 一个核）；`gpu_pct`：GPU 占用。
/// 累计值单调不减，任意两行相减就是窗口内的增量。
public struct Stats: Hashable, Codable, Sendable {
    /// JSON 键 ts：Unix 时间（秒）。
    public var ts: Double
    /// JSON 键 tick。
    public var tick: Tick
    /// JSON 键 render_ms。
    public var renderMs: Double
    /// JSON 键 missed_render。
    public var missedRender: UInt64
    /// JSON 键 jitter_ms。
    public var jitterMs: Double
    /// JSON 键 per_input，键是输入编号。
    public var perInput: [Int: PerInput]
    /// JSON 键 encoder。
    public var encoder: [EncoderEntry]
    /// JSON 键 audio。
    public var audio: AudioCounters
    /// JSON 键 rss_mb。
    public var rssMb: Double
    /// JSON 键 cpu_pct。
    public var cpuPct: Double
    /// JSON 键 gpu_pct。
    public var gpuPct: Double

    /// per_input 的元素。
    public struct PerInput: Hashable, Codable, Sendable {
        /// 窗口内该输入 push 的帧数 / 秒。
        public var fps: Double
        /// FrameSlotStats.reused 累计。
        public var dup: UInt64
        /// FrameSlotStats.dropped 累计。
        public var drop: UInt64
        public init(fps: Double, dup: UInt64, drop: UInt64) {
            self.fps = fps
            self.dup = dup
            self.drop = drop
        }
        /// JSON 键名。
        public static let jsonKeys = ["fps", "dup", "drop"]
    }

    /// encoder 的元素，与带编码器的输出同序。
    public struct EncoderEntry: Hashable, Codable, Sendable {
        /// E1 编码滞后跳帧累计。
        public var skipped: UInt64
        /// 窗口平均输出码率（bit/s）。
        public var bitrate: Double
        public init(skipped: UInt64, bitrate: Double) {
            self.skipped = skipped
            self.bitrate = bitrate
        }
        /// JSON 键名。
        public static let jsonKeys = ["skipped", "bitrate"]
    }

    /// audio 一节。
    public struct AudioCounters: Hashable, Codable, Sendable {
        /// 输出回调超时累计。
        public var dropouts: UInt64
        /// 缓冲欠载累计。
        public var underruns: UInt64
        public init(dropouts: UInt64, underruns: UInt64) {
            self.dropouts = dropouts
            self.underruns = underruns
        }
        /// JSON 键名。
        public static let jsonKeys = ["dropouts", "underruns"]
    }

    public init(ts: Double, tick: Tick, renderMs: Double, missedRender: UInt64, jitterMs: Double, perInput: [Int: PerInput],
                encoder: [EncoderEntry], audio: AudioCounters, rssMb: Double, cpuPct: Double, gpuPct: Double) {
        self.ts = ts
        self.tick = tick
        self.renderMs = renderMs
        self.missedRender = missedRender
        self.jitterMs = jitterMs
        self.perInput = perInput
        self.encoder = encoder
        self.audio = audio
        self.rssMb = rssMb
        self.cpuPct = cpuPct
        self.gpuPct = gpuPct
    }

    enum CodingKeys: String, CodingKey {
        case ts, tick
        case renderMs = "render_ms"
        case missedRender = "missed_render"
        case jitterMs = "jitter_ms"
        case perInput = "per_input"
        case encoder, audio
        case rssMb = "rss_mb"
        case cpuPct = "cpu_pct"
        case gpuPct = "gpu_pct"
    }

    /// 顶层键名，按测试标准 §7 的顺序。
    public static let jsonKeys = ["ts", "tick", "render_ms", "missed_render", "jitter_ms", "per_input", "encoder", "audio", "rss_mb", "cpu_pct", "gpu_pct"]

    /// 写 jsonl 用的编码器：键排序、不转义斜杠、不换行。非有限的浮点值会抛错，写入方要先处理。
    public static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    /// 读 jsonl 用的解码器。
    public static let lineDecoder = JSONDecoder()

    /// 一行 JSON（不带换行）。
    public func jsonLine() throws -> String {
        String(decoding: try Stats.lineEncoder.encode(self), as: UTF8.self)
    }
    /// 解析一行。
    public static func parse(line: String) throws -> Stats {
        try lineDecoder.decode(Stats.self, from: Data(line.utf8))
    }
    /// 解析整份 jsonl（空行跳过）。
    public static func parse(lines text: String) throws -> [Stats] {
        try text.split(separator: "\n", omittingEmptySubsequences: true).map { try parse(line: String($0)) }
    }
}
