import Foundation
import SwitcherContracts
import SwitcherAudio

// 总线效果链（W5-C，prompt 88）：`BusState.effects`（契约 EffectSlot 链，docs/CONTRACTS.md §2.4）→ 混音器每条总线的三个格。
//
// 1. 方案（BusEffectPlan，纯函数）：
//    - 连续的 parametricEQ 格合成一组 = 一个 AUNBandEQ（最多 16 段，各段可单独旁路）；dynamicsProcessor / compressor / peakLimiter 各自一组；
//      链的顺序 = 处理顺序，所以被别的效果隔开的 EQ 是另一组。组数超过 3（C 混音器每条总线三格）的、认不出的 id 不装，记日志；
//    - W1-D3：`compressor`（自写 C 压缩器，提案 024 (b)）与 `dynamicsProcessor` 二选一占同一格——链里两个都有时第二个不装、记日志；
//      `peakLimiter.ceilingDb` = 同一格内限幅之后的输出增益（C 的 post gain）；
//    - 参数先钳到 EffectParameterRanges（AU 不钳），钳了的记日志；缺键用编辑器的默认值；
//    - 组 → 格号：保持顺序（格按 0 → 1 → 2 处理），尽量沿用已经装着的同种效果（不换就不用旁路），平手时放默认格（EQ 0 / 压缩 1 / 限幅 2，
//      给以后往前插的效果留位置）。
// 2. 现场（BusEffectRack，只在控制线程上动）：
//    - 格里已经是同种效果：只改参数 / 开关（enabled = false = C 的格开关关掉，实时线程在块边界自己应用，跳过 render，逐样本旁路）；
//      再打开之前，若关格命令已被实时线程确认，先复位（AU：AudioUnitReset，清掉关之前的滤波器记忆 / 前瞻缓冲；压缩器：包络清零）；
//    - 要换种类或新装：AU 在控制线程上先建好、initialize、设好参数（探针：0.01 ms 级），压缩器先把参数与实测延迟准备好，然后关掉那一格，
//      等实时线程确认（commandsApplied ≥ 关格时的 commandsPushed）之后才挂进去 / 切种类、销毁旧的、再打开——那一格只在"确认 + 下一个控制周期 + 下一块"
//      这段时间里旁路（状态里的 lastBypassBlocks；空设备实测见报告 §2），别的格照常；原来就空着的格不用等，立刻装；
//    - 拆格同样：先关、确认后再摘下销毁。拓扑（装 / 换 / 拆）只在快照里 effects 的格数或 id 变了时发生；改参数、增减 EQ 段（16 以内）不换效果。
// 3. 延迟（EffectLatencyTimeline）：每条总线已打开的格的延迟之和（NBandEQ 0、DynamicsProcessor 256、PeakLimiter = 起音、压缩器 = 冲激法实测，按设计 0），
//    变化时记"从第几块起"给泵；泵把这条总线块的 PTS 再减去它，变化那一块按差值丢 / 补样本（ConsumerPump），A/V 对齐不因开效果漂。

/// 一条总线效果链的方案（纯函数，好测）。
public struct BusEffectPlan: Equatable, Sendable {
    /// EQ 的一段（契约 parametricEQ 一格）。q 是经典口径（EffectParameterRanges.eqBandwidthOctaves）。
    public struct EQBand: Equatable, Sendable {
        public var centerHz: Double
        public var q: Double
        public var gainDb: Double
        public var enabled: Bool
    }
    public struct Dynamics: Equatable, Sendable {
        public var thresholdDb: Double
        public var headroomDb: Double
        public var expansionRatio: Double
        public var attackSeconds: Double
        public var releaseSeconds: Double
        public var overallGainDb: Double
    }
    public struct Limiter: Equatable, Sendable {
        public var attackSeconds: Double
        public var decaySeconds: Double
        public var preGainDb: Double
        /// 024 顺带 (2)：限幅之后同一格内的输出增益（dB，−20…0；默认 0 = 不动）。
        public var ceilingDb: Double
    }
    /// 一组 = 一格里的一个效果。
    public enum Group: Equatable, Sendable {
        case eq([EQBand])
        case dynamics(Dynamics, enabled: Bool)
        case limiter(Limiter, enabled: Bool)
        /// 自写 C 压缩器（提案 024 (b)，W1-D3）。
        case compressor(CompressorParameters, enabled: Bool)

        public var kind: EffectKind {
            switch self {
            case .eq: .nBandEQ
            case .dynamics: .dynamicsProcessor
            case .limiter: .peakLimiter
            case .compressor: .compressor
            }
        }
        /// 这一格开不开：EQ 有任何一段开着就开（关着的段在 AU 里旁路），全关 = 格关（精确旁路）。
        public var enabled: Bool {
            switch self {
            case .eq(let bands): bands.contains { $0.enabled }
            case .dynamics(_, let on), .limiter(_, let on), .compressor(_, let on): on
            }
        }
        /// 动态类（压缩）：dynamicsProcessor 与 compressor 二选一占同一格。
        public var isDynamics: Bool {
            switch self {
            case .dynamics, .compressor: true
            case .eq, .limiter: false
            }
        }
    }
    /// 一条日志：钳了的参数、不认识的 id、超出三格的组、建不起来的 AU。同一条（总线 + 内容）只记一次。
    public struct Note: Hashable, Sendable {
        /// 契约链里的下标。
        public var index: Int
        public var id: String
        public var key: String?
        public var message: String
    }

    public var groups: [Group]
    public var notes: [Note]
    /// 契约链里没装上的格数（认不出的 id、超出三格的组里的格、二选一里没装的那个）。
    public var ignored: Int

    public static let effectIDs = (eq: "parametricEQ", dynamics: "dynamicsProcessor", limiter: "peakLimiter", compressor: "compressor")
    /// 缺键时的默认值 = App 效果编辑器新加一格的默认值（App/Sources/Settings/AudioEffectParams.swift 的 EffectChainEditor）。
    public static let defaultBand = EQBand(centerHz: 1000, q: 1, gainDb: 0, enabled: true)
    public static let defaultDynamics = Dynamics(thresholdDb: -20, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.001, releaseSeconds: 0.05, overallGainDb: 0)
    public static let defaultLimiter = Limiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0, ceilingDb: 0)
    /// 契约 §2.4 定的 compressor 默认值（−20 dB、4:1、拐点 6、5 ms、100 ms、补偿 0）。
    public static let defaultCompressor = CompressorParameters()

    /// 一格解析出来的东西（总线与每路共用；W1-D3）。
    enum ParsedSlot {
        case band(EQBand)
        case dynamics(Dynamics, enabled: Bool)
        case limiter(Limiter, enabled: Bool)
        case compressor(CompressorParameters, enabled: Bool)
    }

    /// 解析一格：认不出的 id 给 nil（并记日志）；数值先钳到 EffectParameterRanges，钳了的记日志；缺键用默认值。
    static func parseSlot(_ slot: EffectSlot, index: Int, host: String, notes: inout [Note]) -> ParsedSlot? {
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let v = slot.params[key] else { return fallback }
            guard case .number(let x) = v, x.isFinite else {
                notes.append(Note(index: index, id: slot.id, key: key, message: "不是有限数值（\(v)），用默认 \(fallback)"))
                return fallback
            }
            let (c, clamped) = EffectParameterRanges.clamp(x, effect: slot.id, key: key)
            if clamped, let r = EffectParameterRanges.range(effect: slot.id, key: key) {
                notes.append(Note(index: index, id: slot.id, key: key, message: "\(x) 超出范围 \(r.lowerBound)…\(r.upperBound)，钳到 \(c)"))
            }
            return c
        }
        switch slot.id {
        case effectIDs.eq:
            let d = defaultBand
            return .band(EQBand(centerHz: number("centerHz", d.centerHz), q: number("q", d.q), gainDb: number("gainDb", d.gainDb), enabled: slot.enabled))
        case effectIDs.dynamics:
            let d = defaultDynamics
            let p = Dynamics(thresholdDb: number("thresholdDb", d.thresholdDb), headroomDb: number("headroomDb", d.headroomDb),
                             expansionRatio: number("expansionRatio", d.expansionRatio), attackSeconds: number("attackSeconds", d.attackSeconds),
                             releaseSeconds: number("releaseSeconds", d.releaseSeconds), overallGainDb: number("overallGainDb", d.overallGainDb))
            return .dynamics(p, enabled: slot.enabled)
        case effectIDs.limiter:
            let d = defaultLimiter
            let p = Limiter(attackSeconds: number("attackSeconds", d.attackSeconds), decaySeconds: number("decaySeconds", d.decaySeconds),
                            preGainDb: number("preGainDb", d.preGainDb), ceilingDb: number("ceilingDb", d.ceilingDb))
            return .limiter(p, enabled: slot.enabled)
        case effectIDs.compressor:
            let d = defaultCompressor
            let p = CompressorParameters(thresholdDb: number("thresholdDb", d.thresholdDb), ratio: number("ratio", d.ratio), kneeDb: number("kneeDb", d.kneeDb),
                                         attackSeconds: number("attackSeconds", d.attackSeconds), releaseSeconds: number("releaseSeconds", d.releaseSeconds),
                                         makeupGainDb: number("makeupGainDb", d.makeupGainDb))
            return .compressor(p, enabled: slot.enabled)
        default:
            notes.append(Note(index: index, id: slot.id, key: nil, message: "不认识的效果 id，\(host)上不装"))
            return nil
        }
    }

    /// 契约链 → 组（≤ maxGroups）+ 日志。
    public static func parse(_ slots: [EffectSlot], maxGroups: Int = BusEffect.allCases.count,
                             maxBands: Int = EffectParameterRanges.nBandEQMaxBands) -> BusEffectPlan {
        var groups: [(group: Group, indices: [Int])] = []
        var notes: [Note] = []
        var ignored = 0
        var dynamicsTaken: String?
        for (index, slot) in slots.enumerated() {
            guard let parsed = parseSlot(slot, index: index, host: "总线", notes: &notes) else { ignored += 1; continue }
            switch parsed {
            case .band(let band):
                if case .eq(var bands)? = groups.last?.group, bands.count < maxBands {
                    bands.append(band)
                    groups[groups.count - 1] = (.eq(bands), groups[groups.count - 1].indices + [index])
                } else {
                    groups.append((.eq([band]), [index]))
                }
            case .dynamics(let p, let on):
                if let taken = dynamicsTaken {
                    notes.append(Note(index: index, id: slot.id, key: nil, message: "与 \(taken) 二选一占同一格（动态格），第 \(index) 格没装"))
                    ignored += 1
                } else { dynamicsTaken = slot.id; groups.append((.dynamics(p, enabled: on), [index])) }
            case .compressor(let p, let on):
                if let taken = dynamicsTaken {
                    notes.append(Note(index: index, id: slot.id, key: nil, message: "与 \(taken) 二选一占同一格（动态格），第 \(index) 格没装"))
                    ignored += 1
                } else { dynamicsTaken = slot.id; groups.append((.compressor(p, enabled: on), [index])) }
            case .limiter(let p, let on):
                groups.append((.limiter(p, enabled: on), [index]))
            }
        }
        if groups.count > maxGroups {
            for g in groups[maxGroups...] {
                let first = g.indices[0]
                notes.append(Note(index: first, id: slots[first].id, key: nil,
                                  message: "超出总线的 \(maxGroups) 格（C 混音器每条总线 \(maxGroups) 格；连续的 EQ 算一格），第 \(g.indices.map(String.init).joined(separator: "、")) 格没装"))
                ignored += g.indices.count
            }
            groups.removeLast(groups.count - maxGroups)
        }
        return BusEffectPlan(groups: groups.map(\.group), notes: notes, ignored: ignored)
    }

    /// 默认格：EQ 0、压缩 1、限幅 2（W1-D 的布局）。
    public static func homeSlot(_ kind: EffectKind) -> Int {
        switch kind {
        case .nBandEQ, .parametricEQ: 0
        case .dynamicsProcessor, .compressor: 1
        case .peakLimiter: 2
        }
    }

    /// 组 → 格号（严格递增 = 保持处理顺序）。在所有递增的放法里挑"沿用已装同种效果的格数"最多的，其次"落在默认格"的最多，再平手取字典序最前。
    public static func assignSlots(_ kinds: [EffectKind], installed: [EffectKind?]) -> [Int] {
        let n = installed.count, k = kinds.count
        precondition(k <= n, "组数不能超过格数")
        var best = Array(0..<k), bestScore = Int.min
        var chosen: [Int] = []
        func visit(_ next: Int) {
            if chosen.count == k {
                var score = 0
                for (i, pos) in chosen.enumerated() {
                    if installed[pos] == kinds[i] { score += 10 }
                    if homeSlot(kinds[i]) == pos { score += 1 }
                }
                if score > bestScore { bestScore = score; best = chosen }
                return
            }
            guard next < n, n - next >= k - chosen.count else { return }
            for p in next..<n {
                chosen.append(p)
                visit(p + 1)
                chosen.removeLast()
            }
        }
        visit(0)
        return best
    }
}

/// 每条总线效果链延迟的时间线（控制线程写、泵线程读）："从第 fromBlock 块（混音器块序号）起延迟 = frames 帧"。
/// 块序号与消费者队列里每块带的 sequence 是同一个计数（sw_mix.c 的 block_sequence），离线驱动下精确；实时线程上命令可能晚一块应用，
/// 拼接点会差一块，只影响那一刻的过渡，之后的对齐是准的（报告 §3）。
final class EffectLatencyTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[(from: UInt64, frames: Int)]]

    init() { entries = Array(repeating: [(0, 0)], count: Bus.allCases.count) }

    func set(_ bus: Bus, frames: Int, fromBlock: UInt64) {
        lock.lock(); defer { lock.unlock() }
        var list = entries[bus.rawValue]
        list.removeAll { $0.from >= fromBlock }   // 同一块里改了几次：以最后一次为准
        list.append((fromBlock, frames))
        if list.count > 256 { list.removeFirst(list.count - 256) }
        entries[bus.rawValue] = list
    }

    /// 第 block 块的延迟。
    func frames(_ bus: Bus, atBlock block: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        let list = entries[bus.rawValue]
        for e in list.reversed() where e.from <= block { return e.frames }
        return list.first?.frames ?? 0
    }

    /// 当前（最新一条）的延迟。
    func current(_ bus: Bus) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries[bus.rawValue].last?.frames ?? 0
    }
}

/// 效果链的日志（钳了的参数、没装上的格、建不起来的 AU、压缩器实测延迟 ≠ 自报），总线与每路共用一份；同一条只记一次，最多留最近 200 条。W1-D3。
final class EffectNoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var logged: Set<String> = []
    private var list: [String] = []

    /// 记一条；返回是不是第一次见。
    @discardableResult
    func record(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard logged.insert(line).inserted else { return false }
        list.append(line)
        if list.count > 200 { list.removeFirst(list.count - 200) }
        NSLog("音频效果：%@", line)
        return true
    }
    var notes: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

/// 自写压缩器的延迟探针（提案 024 批后附加要求 ②）：默认 = 冲激法（`AudioMixer.probeCompressorLatency`）；测试可以换掉，模拟"量到 ≠ 自报"。
enum CompressorLatencyProbe {
    static let defaultMeasure: @Sendable (CompressorParameters) -> Int = { AudioMixer.probeCompressorLatency($0) }
    nonisolated(unsafe) static var measure: @Sendable (CompressorParameters) -> Int = defaultMeasure

    /// 量一次并与自报比；不一致按量到的记并记日志（每种参数一条）。返回要用的延迟（帧）。
    static func measured(for p: CompressorParameters, at place: String, notes: EffectNoteLog) -> Int {
        let m = measure(p)
        let reported = CompressorParameters.reportedLatencyFrames
        guard m >= 0 else {
            notes.record("\(place) 压缩器：冲激法量不到延迟（输出全零），按自报 \(reported) 帧")
            return reported
        }
        if m != reported {
            notes.record("\(place) 压缩器：自报延迟 \(reported) 帧，冲激法量到 \(m) 帧，按量到的 \(m) 帧记（阈值 \(p.thresholdDb) 比例 \(p.ratio) 拐点 \(p.kneeDb) 起音 \(p.attackSeconds) 释放 \(p.releaseSeconds)）")
        }
        return m
    }
}

/// 一格里挂着的效果（AU 或自写压缩器）。
enum InstalledEffect {
    case au(EffectUnit)
    /// 压缩器：参数 + 冲激法实测的延迟（帧）。
    case compressor(CompressorParameters, measured: Int)

    var kind: EffectKind {
        switch self {
        case .au(let u): u.kind
        case .compressor: .compressor
        }
    }
    var latencyFrames: Int {
        switch self {
        case .au(let u): u.latencyFrames
        case .compressor(_, let m): m
        }
    }
    var unit: EffectUnit? { if case .au(let u) = self { return u } else { return nil } }
    var measured: Int? { if case .compressor(_, let m) = self { return m } else { return nil } }
}

/// 一条总线三格的现场状态。只在控制线程上改（AudioEngine 的 fxLock 下）。
final class BusEffectRack {
    struct Slot {
        /// 挂在混音器上的效果。
        var installed: InstalledEffect?
        /// 已推给混音器的开关。
        var enabled = false
        /// 挂上之后开过（实时线程 render 过它；再开之前要等关格确认后复位，换 / 拆之前要等关格确认）。
        var rendered = false
        /// 最近一次关格命令入队之后的 commandsPushed：commandsApplied ≥ 它 = 实时线程已经应用了关格。
        var disableSequence: UInt64 = 0
        /// 准备好、等确认后换进来的效果。
        var pending: InstalledEffect?
        /// 这一格该装的组。
        var group: BusEffectPlan.Group?
        /// 确认后拆掉。
        var removeWhenSafe = false
        /// 为换格而关格时的块号（算旁路块数）。
        var swapDisabledAtBlock: UInt64?
    }

    let bus: Bus
    var slots = [Slot](repeating: Slot(), count: BusEffect.allCases.count)
    /// 上次处理过的链（相同就不再解析）。
    var effects: [EffectSlot]?
    var ignored = 0
    /// 已发布给泵的延迟（帧）。
    var latencyFrames = 0
    var installs = 0, swaps = 0, removals = 0
    var lastBypassBlocks: Int?

    init(bus: Bus) { self.bus = bus }

    var hasPendingWork: Bool { slots.contains { $0.pending != nil || $0.removeWhenSafe } }
}

/// 四条总线的效果链现场 + 换格的步骤（W5-C）。`apply` / `step` 只在 AudioEngine 的控制线程（手动模式 = 调 runControlCycle 的线程）上调；
/// `status` / `notes` 任意线程读。混音命令走 AudioMixer 的命令队列，AU 的建 / 挂 / 拆 / Reset 只在实时线程确认不碰它之后做。
final class BusEffectsController: @unchecked Sendable {
    private let mixer: AudioMixer
    let timeline: EffectLatencyTimeline
    let noteLog: EffectNoteLog
    private let lock = NSLock()
    private var racks: [BusEffectRack]

    init(mixer: AudioMixer, timeline: EffectLatencyTimeline, notes: EffectNoteLog = EffectNoteLog()) {
        self.mixer = mixer
        self.timeline = timeline
        noteLog = notes
        racks = Bus.allCases.map { BusEffectRack(bus: $0) }
    }

    /// 已记过的日志（钳位、没装上的格、建不起来的 AU），每条只记一次；最多留最近 200 条。
    var notes: [String] { noteLog.notes }

    func status(_ bus: Bus) -> AudioEngineStatus.BusEffects {
        lock.lock(); defer { lock.unlock() }
        let r = racks[bus.rawValue]
        return AudioEngineStatus.BusEffects(latencyFrames: r.latencyFrames, slots: r.slots.map { $0.installed?.kind }, enabled: r.slots.map(\.enabled),
                                            ignored: r.ignored, pendingSwaps: r.slots.filter { $0.pending != nil || $0.removeWhenSafe }.count,
                                            installs: r.installs, swaps: r.swaps, removals: r.removals, lastBypassBlocks: r.lastBypassBlocks,
                                            compressorMeasuredLatencyFrames: r.slots.compactMap { $0.installed?.measured }.first)
    }

    /// 某条总线现在的效果链延迟（帧）。
    func latencyFrames(_ bus: Bus) -> Int { lock.lock(); defer { lock.unlock() }; return racks[bus.rawValue].latencyFrames }

    /// 总线状态来了：effects 变了的总线重新对一遍（推子 / 静音变化也会带来 .buses 事件，effects 没变就什么都不做）。
    func apply(_ buses: [BusState]) {
        lock.lock(); defer { lock.unlock() }
        for bs in buses {
            let rack = racks[bs.bus.rawValue]
            guard rack.effects != bs.effects else { continue }
            rack.effects = bs.effects
            reconcile(rack, bs.effects)
        }
    }

    /// 每个控制周期：等实时线程确认的换格 / 拆格，确认了就做。
    func step() {
        lock.lock(); defer { lock.unlock() }
        for rack in racks where rack.hasPendingWork { step(rack) }
    }

    // MARK: 内部（持锁）

    private func acked(_ sequence: UInt64) -> Bool { mixer.commandsApplied >= sequence }

    private func location(_ rack: BusEffectRack, _ s: Int) -> EffectLocation { .bus(rack.bus, BusEffect(slot: s)) }

    private func reconcile(_ rack: BusEffectRack, _ effects: [EffectSlot]) {
        let plan = BusEffectPlan.parse(effects)
        record(plan.notes, bus: rack.bus)
        rack.ignored = plan.ignored
        let installed = rack.slots.map { ($0.pending ?? $0.installed)?.kind }
        let positions = BusEffectPlan.assignSlots(plan.groups.map(\.kind), installed: installed)
        var desired = [BusEffectPlan.Group?](repeating: nil, count: rack.slots.count)
        for (g, p) in zip(plan.groups, positions) { desired[p] = g }
        for s in rack.slots.indices {
            var slot = rack.slots[s]
            defer { rack.slots[s] = slot }
            guard let g = desired[s] else {
                slot.group = nil
                slot.pending = nil
                if slot.installed != nil {
                    if slot.enabled { disable(rack, s, &slot, forSwap: false) }
                    slot.removeWhenSafe = true
                }
                continue
            }
            slot.group = g
            slot.removeWhenSafe = false
            if let p = slot.pending, p.kind != g.kind { slot.pending = nil }   // 准备好的那个又不要了
            if let p = slot.pending {
                slot.pending = prepare(g, from: p, rack: rack, s: s)                // 换进来时再开
            } else if let u = slot.installed, u.kind == g.kind {
                applyParameters(g, to: &slot, rack: rack, s: s)
                setEnabled(rack, s, &slot, g.enabled)
            } else {
                // 新装或换种类：先在这里把效果准备好（AU 建好、设好参数；压缩器量好延迟），确认安全后（step）再挂进去 / 切种类
                if let prepared = prepare(g, from: nil, rack: rack, s: s) {
                    slot.pending = prepared
                    if slot.enabled { disable(rack, s, &slot, forSwap: true) }
                } else {
                    slot.group = nil
                    if slot.installed != nil {
                        if slot.enabled { disable(rack, s, &slot, forSwap: false) }
                        slot.removeWhenSafe = true
                    }
                }
            }
        }
        step(rack)
    }

    /// 为一个组准备好要挂的效果：AU 新建（或沿用准备好的同种 AU）并设参数；压缩器带上实测延迟。建不起来给 nil（已记日志）。
    private func prepare(_ g: BusEffectPlan.Group, from existing: InstalledEffect?, rack: BusEffectRack, s: Int) -> InstalledEffect? {
        switch g {
        case .compressor(let p, _):
            if case .compressor(let old, let m)? = existing, old == p { return .compressor(p, measured: m) }
            return .compressor(p, measured: CompressorLatencyProbe.measured(for: p, at: "\(rack.bus.name) 第 \(s) 格", notes: noteLog))
        case .eq, .dynamics, .limiter:
            if case .au(let eu)? = existing, eu.kind == g.kind {
                Self.applyAUParameters(g, to: eu)
                return existing
            }
            do {
                let eu = try mixer.makeEffectUnit(g.kind, bus: rack.bus, slot: BusEffect(slot: s))
                Self.applyAUParameters(g, to: eu)
                return .au(eu)
            } catch {
                record([BusEffectPlan.Note(index: s, id: g.kind.rawValue, key: nil, message: "第 \(s) 格建不起来：\(error)，这一格不装")], bus: rack.bus)
                return nil
            }
        }
    }

    /// 同种效果已在格里：只改参数（AU 的 setter 同值不重设；压缩器重发六条系数命令并重新量延迟；限幅的 ceilingDb 落到格的输出增益）。
    private func applyParameters(_ g: BusEffectPlan.Group, to slot: inout BusEffectRack.Slot, rack: BusEffectRack, s: Int) {
        let loc = location(rack, s)
        switch g {
        case .compressor(let p, _):
            guard case .compressor(let old, let m)? = slot.installed else { return }
            if old != p {
                mixer.setCompressor(loc, p)
                let measured = CompressorLatencyProbe.measured(for: p, at: "\(rack.bus.name) 第 \(s) 格", notes: noteLog)
                slot.installed = .compressor(p, measured: measured)
            } else {
                slot.installed = .compressor(p, measured: m)
            }
        case .eq, .dynamics, .limiter:
            guard case .au(let eu)? = slot.installed else { return }
            Self.applyAUParameters(g, to: eu)
            if case .limiter(let l, _) = g { mixer.setEffectOutputGain(loc, dB: l.ceilingDb) }
        }
    }

    private func step(_ rack: BusEffectRack) {
        for s in rack.slots.indices {
            var slot = rack.slots[s]
            defer { rack.slots[s] = slot }
            guard slot.pending != nil || slot.removeWhenSafe else { continue }
            // 安全 = 格关着，且挂上之后没 render 过、或者关格命令已被实时线程应用
            guard !slot.enabled, !slot.rendered || acked(slot.disableSequence) else { continue }
            let loc = location(rack, s)
            if let p = slot.pending {
                let replacing = slot.installed != nil
                switch p {
                case .au(let eu):
                    do {
                        try mixer.attachEffectUnit(eu)
                    } catch {
                        record([BusEffectPlan.Note(index: s, id: p.kind.rawValue, key: nil, message: "第 \(s) 格挂不上：\(error)")], bus: rack.bus)
                        slot.pending = nil
                        continue
                    }
                    if case .compressor? = slot.installed { mixer.setEffectKind(loc, .audioUnit) }
                    mixer.setEffectOutputGain(loc, dB: { if case .limiter(let l, _)? = slot.group { return l.ceilingDb } else { return 0 } }())
                case .compressor(let params, _):
                    if case .au? = slot.installed { mixer.removeEffectUnit(at: loc) }   // AU 卸下销毁；格改跑压缩器
                    mixer.setEffectKind(loc, .compressor)
                    mixer.setCompressor(loc, params)
                    mixer.resetEffectState(loc)                                      // 格关着且已确认 / 没 render 过：包络从零起
                    mixer.setEffectOutputGain(loc, dB: 0)
                }
                slot.installed = p
                slot.pending = nil
                slot.rendered = false
                if replacing { rack.swaps += 1 } else { rack.installs += 1 }
                if slot.group?.enabled == true {
                    let disabledAt = slot.swapDisabledAtBlock
                    enable(rack, s, &slot)
                    // 关 / 开两条命令各在入队后的下一块开头应用，入队那一刻实时线程若在一块中间就再晚一块：旁路块数 ≤ 入队间隔 + 1（取上界）
                    if let d = disabledAt { rack.lastBypassBlocks = Int(mixer.stats.blocksRendered &- d) + 1 }
                }
                slot.swapDisabledAtBlock = nil
            } else if slot.removeWhenSafe {
                switch slot.installed {
                case .au?: mixer.removeEffectUnit(at: loc)
                case .compressor?: mixer.setEffectKind(loc, .audioUnit)   // 格回到"没装 AU 的 AU 格" = 旁路
                case nil: break
                }
                mixer.setEffectOutputGain(loc, dB: 0)
                slot.installed = nil
                slot.rendered = false
                slot.removeWhenSafe = false
                slot.swapDisabledAtBlock = nil
                rack.removals += 1
            }
        }
        publishLatency(rack)
    }

    private func setEnabled(_ rack: BusEffectRack, _ s: Int, _ slot: inout BusEffectRack.Slot, _ on: Bool) {
        if on && !slot.enabled {
            // 关之前 render 过、关格已确认：清掉旧状态（前瞻缓冲里是关之前的信号 / 压缩器包络）再开
            if slot.rendered && acked(slot.disableSequence) { mixer.resetEffectState(location(rack, s)) }
            enable(rack, s, &slot)
        } else if !on && slot.enabled {
            disable(rack, s, &slot, forSwap: false)
        }
        publishLatency(rack)
    }

    private func enable(_ rack: BusEffectRack, _ s: Int, _ slot: inout BusEffectRack.Slot) {
        mixer.setEffectEnabled(location(rack, s), true)
        slot.enabled = true
        slot.rendered = true
        slot.swapDisabledAtBlock = nil   // 换格中途又改回原样（准备好的 AU 不要了）：这次关格不算换格旁路
    }

    private func disable(_ rack: BusEffectRack, _ s: Int, _ slot: inout BusEffectRack.Slot, forSwap: Bool) {
        mixer.setEffectEnabled(location(rack, s), false)
        slot.enabled = false
        slot.disableSequence = mixer.commandsPushed
        slot.swapDisabledAtBlock = forSwap ? mixer.stats.blocksRendered : nil
    }

    /// 已打开的格的延迟之和；变了就记"从下一块起"（刚推的开 / 关格命令在下一块开头应用；实时线程正在一块中间时会晚一块，见 EffectLatencyTimeline）。
    private func publishLatency(_ rack: BusEffectRack) {
        var total = 0
        for slot in rack.slots where slot.enabled { total += slot.installed?.latencyFrames ?? 0 }
        guard total != rack.latencyFrames else { return }
        rack.latencyFrames = total
        timeline.set(rack.bus, frames: total, fromBlock: mixer.stats.blocksRendered)
    }

    private func record(_ notes: [BusEffectPlan.Note], bus: Bus) {
        for n in notes { noteLog.record("\(bus.name) 第 \(n.index) 格 \(n.id)\(n.key.map { "." + $0 } ?? "")：\(n.message)") }
    }

    /// 组的参数落到 AU（EffectUnit 的 setter 再钳一次；同值不重设）。压缩器不走这里。
    static func applyAUParameters(_ g: BusEffectPlan.Group, to eu: EffectUnit) {
        switch g {
        case .eq(let bands):
            for (i, b) in bands.enumerated() {
                eu.setEQBand(i, centerHz: Float(b.centerHz), q: Float(b.q), gainDb: Float(b.gainDb), enabled: b.enabled)
            }
            eu.bypassEQBands(from: bands.count)
        case .dynamics(let d, _):
            eu.setDynamics(thresholdDb: Float(d.thresholdDb), headroomDb: Float(d.headroomDb), expansionRatio: Float(d.expansionRatio),
                           attack: Float(d.attackSeconds), release: Float(d.releaseSeconds), overallGainDb: Float(d.overallGainDb))
        case .limiter(let l, _):
            eu.setLimiter(attack: Float(l.attackSeconds), decay: Float(l.decaySeconds), preGainDb: Float(l.preGainDb))
        case .compressor:
            break
        }
    }
}
