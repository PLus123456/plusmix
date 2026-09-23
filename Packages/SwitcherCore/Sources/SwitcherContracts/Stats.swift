import Foundation

/// stats.jsonl 的一行（测试标准 §7；P2 按已批提案 001 / 002 / 004 / 005 扩了 per_input、encoder、audio 三节）。字段名逐字：
/// ts、tick、render_ms、missed_render、jitter_ms、per_input{fps, dup, drop, latency_ms, latency_max_ms}、
/// encoder[{skipped, bitrate, frames, dropped, disk_free_mb, reconnects, state}]、display[{output, kind, frames, dropped, undelivered, state}]、
/// audio{dropouts, underruns, discontinuities, meters}、rss_mb、cpu_pct、gpu_pct。
/// UI 状态行、API、测试三方读同一个结构，不许各自另算（铁律 4）。
///
/// 口径（每秒一行，"窗口" = 上一行到这一行之间）：
/// - `ts`：Unix 时间（秒，含小数），采样那一刻的墙钟。
/// - `tick`：采样那一刻的节目拍。
/// - `render_ms`：V1，窗口内每拍"拍点时刻 → 该拍命令缓冲区 GPU 完成"的平均毫秒数。
/// - `missed_render`：V2，渲染滞后丢帧，自启动以来的累计数。
/// - `jitter_ms`：V3，窗口内 |PGM 帧派发时刻 − 理想拍点| 的最大值（ms）。
/// - `per_input[n]`：键是输入编号。fps = 窗口内该输入 push 的帧数 / 窗口秒数；dup = FrameSlotStats.reused 累计；drop = FrameSlotStats.dropped 累计；
///   latency_ms / latency_max_ms = 提案 005 的 L1（见 `PerInput`）。
/// - `encoder[i]`：与 MixerState.outputs 里带编码器的输出同序。skipped = E1 编码滞后跳帧累计；bitrate = 窗口内平均输出码率（bit/s）；
///   frames / dropped / disk_free_mb / reconnects / state = 提案 001 / 002（见 `EncoderEntry`）。
/// - `display[i]`：提案 013，显示类输出（外部显示窗口、虚拟摄像头、多画面窗口、主界面监视器）各一项，无固定顺序，按 `output` / `kind` 认。
///   frames = 已呈现 / 已送出帧数累计；dropped = 在呈现 / 发布时没赶上刷新 / 被扩展丢弃的帧数累计；
///   undelivered = 不在呈现 / 发布时没送出去的帧数累计（提案 018，与 dropped 不重叠）；state 见 `DisplayEntry.states`。
/// - `audio`：A1，dropouts = 输出回调超时累计，underruns = 缓冲欠载累计，discontinuities = 波形不连续累计；meters = 表读数（提案 004，见 `AudioCounters`）。
/// - `rss_mb`：进程 RSS（MB）；`cpu_pct`：进程 CPU（100 = 一个核）；`gpu_pct`：GPU 占用。
/// 累计值单调不减，任意两行相减就是窗口内的增量。
///
/// 兼容：P2 / P3 之前写的 stats.jsonl 没有新字段，解码时缺键给默认值（0 / "idle" / 空数组 / 空）；写出时总是写全。
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
    /// JSON 键 display（提案 013）：显示类输出（外部显示窗口、虚拟摄像头、多画面窗口、主界面监视器）各一项。
    public var display: [DisplayEntry]
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
        /// JSON 键 latency_ms（提案 005）：窗口内该输入的 L1 平均值（ms）= 帧交给第一个 FrameConsumer 的那一刻 − 该帧的 `Frame.ingressTime`，
        /// 只算"这一拍第一次用到的帧"（帧率转换的重复拍不算）。窗口内没有样本写 0；引擎侧算法归 W1-B2，之前引擎写 0。
        public var latencyMs: Double
        /// JSON 键 latency_max_ms（提案 005）：同口径的窗口最大值（ms）。
        public var latencyMaxMs: Double
        public init(fps: Double, dup: UInt64, drop: UInt64, latencyMs: Double = 0, latencyMaxMs: Double = 0) {
            self.fps = fps
            self.dup = dup
            self.drop = drop
            self.latencyMs = latencyMs
            self.latencyMaxMs = latencyMaxMs
        }
        enum CodingKeys: String, CodingKey {
            case fps, dup, drop
            case latencyMs = "latency_ms"
            case latencyMaxMs = "latency_max_ms"
        }
        /// 老文件没有 latency_*：缺键给 0。
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fps = try c.decode(Double.self, forKey: .fps)
            dup = try c.decode(UInt64.self, forKey: .dup)
            drop = try c.decode(UInt64.self, forKey: .drop)
            latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
            latencyMaxMs = try c.decodeIfPresent(Double.self, forKey: .latencyMaxMs) ?? 0
        }
        /// JSON 键名。
        public static let jsonKeys = ["fps", "dup", "drop", "latency_ms", "latency_max_ms"]
    }

    /// encoder 的元素，与带编码器的输出同序。
    public struct EncoderEntry: Hashable, Codable, Sendable {
        /// E1 编码滞后跳帧累计。
        public var skipped: UInt64
        /// 窗口平均输出码率（bit/s）。
        public var bitrate: Double
        /// JSON 键 frames（提案 001）：写进文件 / 交给传输层的视频帧数，累计（录制 = RecorderCounters.videoFrames；推流 = StreamCounters.framesSent；NDI = framesSent）。
        public var frames: UInt64
        /// JSON 键 dropped（提案 001）：编码之后、落地之前丢的帧，累计（录制 = writer 不接的 videoFramesRejected；推流 = E9 网络丢帧 networkDropped；
        /// NDI = 队列满丢的帧）。与 E1 的 skipped 是两回事：skipped 在编码之前。
        public var dropped: UInt64
        /// JSON 键 disk_free_mb（提案 001）：录制目录所在卷的剩余 MB（1 MB = 2^20 字节，与 rss_mb 同口径）；非录制输出写 0。
        public var diskFreeMb: Double
        /// JSON 键 reconnects（提案 002）：推流重连成功次数，累计；录制 / NDI 写 0。
        public var reconnects: UInt64
        /// JSON 键 state（提案 002）：输出的运行状态。推流：idle / connecting / publishing / backoff / stopping / stopped / failed；
        /// NDI：publishing / idle / unavailable（SDK 不在）；录制：idle / recording / stopping / stopped / failed。
        public var state: String
        public init(skipped: UInt64, bitrate: Double, frames: UInt64 = 0, dropped: UInt64 = 0, diskFreeMb: Double = 0,
                    reconnects: UInt64 = 0, state: String = "idle") {
            self.skipped = skipped
            self.bitrate = bitrate
            self.frames = frames
            self.dropped = dropped
            self.diskFreeMb = diskFreeMb
            self.reconnects = reconnects
            self.state = state
        }
        enum CodingKeys: String, CodingKey {
            case skipped, bitrate, frames, dropped
            case diskFreeMb = "disk_free_mb"
            case reconnects, state
        }
        /// 老文件只有 skipped / bitrate：其余缺键给 0 / "idle"。
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            skipped = try c.decode(UInt64.self, forKey: .skipped)
            bitrate = try c.decode(Double.self, forKey: .bitrate)
            frames = try c.decodeIfPresent(UInt64.self, forKey: .frames) ?? 0
            dropped = try c.decodeIfPresent(UInt64.self, forKey: .dropped) ?? 0
            diskFreeMb = try c.decodeIfPresent(Double.self, forKey: .diskFreeMb) ?? 0
            reconnects = try c.decodeIfPresent(UInt64.self, forKey: .reconnects) ?? 0
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        }
        /// JSON 键名。
        public static let jsonKeys = ["skipped", "bitrate", "frames", "dropped", "disk_free_mb", "reconnects", "state"]
    }

    /// display 的元素（提案 013）：显示类输出没有编码器，帧数 / 丢帧 / 状态进这里。
    public struct DisplayEntry: Hashable, Codable, Sendable {
        /// 输出编号（`MixerState.outputs` 里的 number）；主界面的监视器视图不是输出，用 0。
        public var output: Int
        /// "externalDisplay" / "virtualCamera" / "multiviewWindow" / "monitor"。
        public var kind: String
        /// 已呈现（显示）/ 已送出（虚拟摄像头扩展收到）的帧数，累计。
        public var frames: UInt64
        /// 在呈现 / 发布的时候没送出去的帧数，累计：显示类 = 引擎给了新帧、两次显示刷新之间就被覆盖的；
        /// 虚拟摄像头 = 连上之后本端队列满 + 排不进 sink（扩展没及时取）+ 扩展收了没输出的。不在呈现 / 发布时的进 `undelivered`。
        public var dropped: UInt64
        /// 输出拿到（或该拿到）、但因为当时不在呈现 / 发布而没送出去的帧数，累计（提案 018）。与 `dropped` 不重叠。
        /// - virtualCamera：扩展没装 / 没激活 / 没连上期间收到就丢掉的 PGM 帧（含那段时间本端队列满挤掉的）；
        /// - externalDisplay：窗口收起（目标显示器不在）或被遮住期间，当前这个源出了、窗口没画的帧（换源不算：换之前的源不是这个输出的）；
        /// - multiviewWindow / monitor：同 externalDisplay 的口径（组装方用记账源记；不记就是 0）。
        /// 显示类在一段时间里 frames + dropped + undelivered ≈ 这段时间里当前源出的新帧（差的是首尾还在路上的一两帧）。
        public var undelivered: UInt64
        /// "idle" / "presenting" / "noDisplay"（显示器不在：退回主屏或黑着等）/ "waitingExtension"（扩展未激活）/
        /// "publishing" / "stopped" / "failed"。
        public var state: String
        public init(output: Int, kind: String, frames: UInt64 = 0, dropped: UInt64 = 0, undelivered: UInt64 = 0, state: String = "idle") {
            self.output = output
            self.kind = kind
            self.frames = frames
            self.dropped = dropped
            self.undelivered = undelivered
            self.state = state
        }
        enum CodingKeys: String, CodingKey { case output, kind, frames, dropped, undelivered, state }
        /// 缺键给 0 / "idle"（013 的老条目没有 undelivered）。
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            output = try c.decode(Int.self, forKey: .output)
            kind = try c.decode(String.self, forKey: .kind)
            frames = try c.decodeIfPresent(UInt64.self, forKey: .frames) ?? 0
            dropped = try c.decodeIfPresent(UInt64.self, forKey: .dropped) ?? 0
            undelivered = try c.decodeIfPresent(UInt64.self, forKey: .undelivered) ?? 0
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        }
        /// JSON 键名。
        public static let jsonKeys = ["output", "kind", "frames", "dropped", "undelivered", "state"]
        /// kind 的合法值。
        public static let kinds = ["externalDisplay", "virtualCamera", "multiviewWindow", "monitor"]
        /// state 的合法值。
        public static let states = ["idle", "presenting", "noDisplay", "waitingExtension", "publishing", "stopped", "failed"]
    }

    /// audio 一节。
    public struct AudioCounters: Hashable, Codable, Sendable {
        /// 输出回调超时累计。
        public var dropouts: UInt64
        /// 缓冲欠载累计。
        public var underruns: UInt64
        /// JSON 键 discontinuities（提案 004）：A1 的第三个加数，Master 消费者流上相邻样本跳变 > 0.5 满幅的次数，累计
        /// （集成层泵线程上的流式检测，合成信号的 click 按平台启发式排除；正式判定用已知 click 位置排除的离线口径）。
        public var discontinuities: UInt64
        /// JSON 键 meters（提案 004）：采样那一刻的表读数。来源只有一处（AudioMixer.meters）；1 Hz 的 Stats 留档 / API / 测试用，UI 高刷新率的表另读。
        public var meters: Meters
        public init(dropouts: UInt64, underruns: UInt64, discontinuities: UInt64 = 0, meters: Meters = Meters()) {
            self.dropouts = dropouts
            self.underruns = underruns
            self.discontinuities = discontinuities
            self.meters = meters
        }
        enum CodingKeys: String, CodingKey { case dropouts, underruns, discontinuities, meters }
        /// 老文件只有 dropouts / underruns：缺键给 0 / 空表。
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dropouts = try c.decode(UInt64.self, forKey: .dropouts)
            underruns = try c.decode(UInt64.self, forKey: .underruns)
            discontinuities = try c.decodeIfPresent(UInt64.self, forKey: .discontinuities) ?? 0
            meters = try c.decodeIfPresent(Meters.self, forKey: .meters) ?? Meters()
        }
        /// JSON 键名。
        public static let jsonKeys = ["dropouts", "underruns", "discontinuities", "meters"]

        /// 表读数（提案 004）：`buses` 顺序 = Bus.allCases（4 条），`inputs` 键 = 输入编号。
        /// 峰值 / 真峰值 dBFS / dBTP（20·log10，下限 `floorDb`），响度 LUFS（静音也钳到下限，JSON 写不了 −inf），LRA 单位 LU。
        public struct Meters: Hashable, Codable, Sendable {
            public var buses: [BusMeter]
            public var inputs: [Int: InputMeter]
            public init(buses: [BusMeter] = [], inputs: [Int: InputMeter] = [:]) {
                self.buses = buses
                self.inputs = inputs
            }
            /// JSON 键名。
            public static let jsonKeys = ["buses", "inputs"]
            /// dB / LUFS 的下限。
            public static let floorDb: Double = -120
            /// 线性幅度 → dB（20·log10），≤ 0、非有限或低于下限都给下限。
            public static func decibels(fromLinear v: Double) -> Double {
                guard v.isFinite, v > 0 else { return floorDb }
                return max(floorDb, 20 * log10(v))
            }
            /// LUFS / LU 的钳位：非有限（libebur128 对静音给 −inf）或低于下限都给下限。
            public static func loudness(_ lufs: Double) -> Double {
                lufs.isFinite ? max(floorDb, lufs) : floorDb
            }
        }

        /// 一条总线的表读数。
        public struct BusMeter: Hashable, Codable, Sendable {
            /// JSON 键 bus：总线名（`Bus.name`）：master / busA / busB / headphones。
            public var bus: String
            /// JSON 键 peak_db：本块采样峰值 dBFS，[L, R]。
            public var peakDb: [Double]
            /// JSON 键 rms_db（提案 017）：推子后（与 peak_db 同一取样点）的均方根电平 dBFS，[L, R]；300 ms 一阶指数平均（IEC 60268-17 的 VU 积分时间），
            /// 每个混音块更新一次，采样那一刻的值；空数组 = 这份数没有 RMS（017 之前的文件），读表的照只有峰值画。
            public var rmsDb: [Double]
            /// JSON 键 true_peak_db：真峰值 dBTP，[L, R]。
            public var truePeakDb: [Double]
            /// JSON 键 lufs_m：瞬时响度（400 ms）。
            public var lufsM: Double
            /// JSON 键 lufs_s：短期响度（3 s）。
            public var lufsS: Double
            /// JSON 键 lufs_i：积分响度。
            public var lufsI: Double
            /// JSON 键 lra：响度范围（LU）。
            public var lra: Double
            public init(bus: String, peakDb: [Double], rmsDb: [Double] = [], truePeakDb: [Double], lufsM: Double, lufsS: Double, lufsI: Double, lra: Double) {
                self.bus = bus
                self.peakDb = peakDb
                self.rmsDb = rmsDb
                self.truePeakDb = truePeakDb
                self.lufsM = lufsM
                self.lufsS = lufsS
                self.lufsI = lufsI
                self.lra = lra
            }
            enum CodingKeys: String, CodingKey {
                case bus
                case peakDb = "peak_db"
                case rmsDb = "rms_db"
                case truePeakDb = "true_peak_db"
                case lufsM = "lufs_m"
                case lufsS = "lufs_s"
                case lufsI = "lufs_i"
                case lra
            }
            /// rms_db 缺键 = 空数组（017 之前的 stats.jsonl）；其余键照常。
            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                bus = try c.decode(String.self, forKey: .bus)
                peakDb = try c.decode([Double].self, forKey: .peakDb)
                rmsDb = try c.decodeIfPresent([Double].self, forKey: .rmsDb) ?? []
                truePeakDb = try c.decode([Double].self, forKey: .truePeakDb)
                lufsM = try c.decode(Double.self, forKey: .lufsM)
                lufsS = try c.decode(Double.self, forKey: .lufsS)
                lufsI = try c.decode(Double.self, forKey: .lufsI)
                lra = try c.decode(Double.self, forKey: .lra)
            }
            /// JSON 键名。
            public static let jsonKeys = ["bus", "peak_db", "rms_db", "true_peak_db", "lufs_m", "lufs_s", "lufs_i", "lra"]
        }

        /// 一路输入的表读数（推子后）。
        public struct InputMeter: Hashable, Codable, Sendable {
            /// JSON 键 peak_db：采样峰值 dBFS，[L, R]。
            public var peakDb: [Double]
            /// JSON 键 rms_db（提案 017）：均方根电平 dBFS，[L, R]，口径同 BusMeter.rmsDb；空数组 = 没有 RMS。
            public var rmsDb: [Double]
            public init(peakDb: [Double], rmsDb: [Double] = []) { self.peakDb = peakDb; self.rmsDb = rmsDb }
            enum CodingKeys: String, CodingKey { case peakDb = "peak_db", rmsDb = "rms_db" }
            /// rms_db 缺键 = 空数组。
            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                peakDb = try c.decode([Double].self, forKey: .peakDb)
                rmsDb = try c.decodeIfPresent([Double].self, forKey: .rmsDb) ?? []
            }
            /// JSON 键名。
            public static let jsonKeys = ["peak_db", "rms_db"]
        }
    }

    public init(ts: Double, tick: Tick, renderMs: Double, missedRender: UInt64, jitterMs: Double, perInput: [Int: PerInput],
                encoder: [EncoderEntry], audio: AudioCounters, rssMb: Double, cpuPct: Double, gpuPct: Double,
                display: [DisplayEntry] = []) {
        self.ts = ts
        self.tick = tick
        self.renderMs = renderMs
        self.missedRender = missedRender
        self.jitterMs = jitterMs
        self.perInput = perInput
        self.encoder = encoder
        self.display = display
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
        case encoder, display, audio
        case rssMb = "rss_mb"
        case cpuPct = "cpu_pct"
        case gpuPct = "gpu_pct"
    }

    /// 老 stats.jsonl 没有 display（提案 013）：缺键 = 空数组。写出总是写全。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Double.self, forKey: .ts)
        tick = try c.decode(Tick.self, forKey: .tick)
        renderMs = try c.decode(Double.self, forKey: .renderMs)
        missedRender = try c.decode(UInt64.self, forKey: .missedRender)
        jitterMs = try c.decode(Double.self, forKey: .jitterMs)
        perInput = try c.decode([Int: PerInput].self, forKey: .perInput)
        encoder = try c.decode([EncoderEntry].self, forKey: .encoder)
        display = try c.decodeIfPresent([DisplayEntry].self, forKey: .display) ?? []
        audio = try c.decode(AudioCounters.self, forKey: .audio)
        rssMb = try c.decode(Double.self, forKey: .rssMb)
        cpuPct = try c.decode(Double.self, forKey: .cpuPct)
        gpuPct = try c.decode(Double.self, forKey: .gpuPct)
    }

    /// 顶层键名，按测试标准 §7 的顺序。
    public static let jsonKeys = ["ts", "tick", "render_ms", "missed_render", "jitter_ms", "per_input", "encoder", "display", "audio", "rss_mb", "cpu_pct", "gpu_pct"]

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
