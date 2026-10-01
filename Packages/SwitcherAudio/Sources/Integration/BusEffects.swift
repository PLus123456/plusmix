import Foundation
import SwitcherContracts
import SwitcherAudio

// 总线效果链（W5-C，prompt 88）：`BusState.effects`（契约 EffectSlot 链，docs/CONTRACTS.md §2.4）→ 混音器每条总线的三个 AU 格。
//
// 1. 方案（BusEffectPlan，纯函数）：
//    - 连续的 parametricEQ 格合成一组 = 一个 AUNBandEQ（最多 16 段，各段可单独旁路）；dynamicsProcessor / peakLimiter 各自一组；
//      链的顺序 = 处理顺序，所以被别的效果隔开的 EQ 是另一组。组数超过 3（C 混音器每条总线三格）的、认不出的 id 不装，记日志；
//    - 参数先钳到 EffectParameterRanges（AU 不钳），钳了的记日志；缺键用编辑器的默认值；
//    - 组 → 格号：保持顺序（格按 0 → 1 → 2 处理），尽量沿用已经装着的同种 AU（不换就不用旁路），平手时放默认格（EQ 0 / 压缩 1 / 限幅 2，
//      给以后往前插的效果留位置）。
// 2. 现场（BusEffectRack，只在控制线程上动）：
//    - 格里已经是同种 AU：只改参数 / 开关（enabled = false = C 的格开关关掉，实时线程在块边界自己应用，跳过 render，逐样本旁路）；
//      再打开之前，若关格命令已被实时线程确认，先 AudioUnitReset（清掉关之前的滤波器记忆 / 前瞻缓冲，探针：不清会把旧数据放出来）；
//    - 要换 AU 种类或新装：在控制线程上先把新 AU 建好、initialize、设好参数（探针：0.01 ms 级），然后关掉那一格，
//      等实时线程确认（commandsApplied ≥ 关格时的 commandsPushed）之后才挂进去、销毁旧的、再打开——那一格只在"确认 + 下一个控制周期 + 下一块"
//      这段时间里旁路（状态里的 lastBypassBlocks；空设备实测见报告 §2），别的格照常；原来就空着的格不用等，立刻装；
//    - 拆格同样：先关、确认后再摘下销毁。拓扑（装 / 换 / 拆）只在快照里 effects 的格数或 id 变了时发生；改参数、增减 EQ 段（16 以内）不换 AU。
// 3. 延迟（EffectLatencyTimeline）：每条总线已打开的 AU 的 kAudioUnitProperty_Latency 之和（NBandEQ 0、压缩 256、限幅 = 起音），
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
    }
    /// 一组 = 一格里的一个 AU。
    public enum Group: Equatable, Sendable {
        case eq([EQBand])
        case dynamics(Dynamics, enabled: Bool)
        case limiter(Limiter, enabled: Bool)

        public var kind: EffectKind {
            switch self {
            case .eq: .nBandEQ
            case .dynamics: .dynamicsProcessor
            case .limiter: .peakLimiter
            }
        }
        /// 这一格开不开：EQ 有任何一段开着就开（关着的段在 AU 里旁路），全关 = 格关（精确旁路）。
        public var enabled: Bool {
            switch self {
            case .eq(let bands): bands.contains { $0.enabled }
            case .dynamics(_, let on), .limiter(_, let on): on
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
    /// 契约链里没装上的格数（认不出的 id、超出三格的组里的格）。
    public var ignored: Int

    public static let effectIDs = (eq: "parametricEQ", dynamics: "dynamicsProcessor", limiter: "peakLimiter")
    /// 缺键时的默认值 = App 效果编辑器新加一格的默认值（App/Sources/Settings/AudioEffectParams.swift 的 EffectChainEditor）。
    public static let defaultBand = EQBand(centerHz: 1000, q: 1, gainDb: 0, enabled: true)
    public static let defaultDynamics = Dynamics(thresholdDb: -20, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.001, releaseSeconds: 0.05, overallGainDb: 0)
    public static let defaultLimiter = Limiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0)

    /// 契约链 → 组（≤ maxGroups）+ 日志。
    public static func parse(_ slots: [EffectSlot], maxGroups: Int = BusEffect.allCases.count,
                             maxBands: Int = EffectParameterRanges.nBandEQMaxBands) -> BusEffectPlan {
        var groups: [(group: Group, indices: [Int])] = []
        var notes: [Note] = []
        var ignored = 0
        for (index, slot) in slots.enumerated() {
            func number(_ key: String, _ fallback: Double) -> Double {
                guard let v = slot.params[key] else { return fallback }
                guard case .number(let x) = v, x.isFinite else {
                    notes.append(Note(index: index, id: slot.id, key: key, message: "不是有限数值（\(v)），用默认 \(fallback)"))
                    return fallback
                }
                let (c, clamped) = EffectParameterRanges.clamp(x, effect: slot.id, key: key)
                if clamped, let r = EffectParameterRanges.range(effect: slot.id, key: key) {
                    notes.append(Note(index: index, id: slot.id, key: key, message: "\(x) 超出 AU 范围 \(r.lowerBound)…\(r.upperBound)，钳到 \(c)"))
                }
                return c
            }
            switch slot.id {
            case effectIDs.eq:
                let d = defaultBand
                let band = EQBand(centerHz: number("centerHz", d.centerHz), q: number("q", d.q), gainDb: number("gainDb", d.gainDb), enabled: slot.enabled)
                if case .eq(var bands)? = groups.last?.group, bands.count < maxBands {
                    bands.append(band)
                    groups[groups.count - 1] = (.eq(bands), groups[groups.count - 1].indices + [index])
                } else {
                    groups.append((.eq([band]), [index]))
                }
            case effectIDs.dynamics:
                let d = defaultDynamics
                let p = Dynamics(thresholdDb: number("thresholdDb", d.thresholdDb), headroomDb: number("headroomDb", d.headroomDb),
                                 expansionRatio: number("expansionRatio", d.expansionRatio), attackSeconds: number("attackSeconds", d.attackSeconds),
                                 releaseSeconds: number("releaseSeconds", d.releaseSeconds), overallGainDb: number("overallGainDb", d.overallGainDb))
                groups.append((.dynamics(p, enabled: slot.enabled), [index]))
            case effectIDs.limiter:
                let d = defaultLimiter
                let p = Limiter(attackSeconds: number("attackSeconds", d.attackSeconds), decaySeconds: number("decaySeconds", d.decaySeconds),
                                preGainDb: number("preGainDb", d.preGainDb))
                groups.append((.limiter(p, enabled: slot.enabled), [index]))
            default:
                notes.append(Note(index: index, id: slot.id, key: nil, message: "不认识的效果 id，总线上不装"))
                ignored += 1
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
        case .dynamicsProcessor: 1
        case .peakLimiter: 2
        }
    }

    /// 组 → 格号（严格递增 = 保持处理顺序）。在所有递增的放法里挑"沿用已装同种 AU 的格数"最多的，其次"落在默认格"的最多，再平手取字典序最前。
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

/// 一条总线三格的现场状态。只在控制线程上改（AudioEngine 的 fxLock 下）。
final class BusEffectRack {
    struct Slot {
        /// 挂在混音器上的 AU。
        var unit: EffectUnit?
        /// 已推给混音器的开关。
        var enabled = false
        /// 挂上之后开过（实时线程 render 过它；再开之前要等关格确认后 Reset，换 / 拆之前要等关格确认）。
        var rendered = false
        /// 最近一次关格命令入队之后的 commandsPushed：commandsApplied ≥ 它 = 实时线程已经应用了关格。
        var disableSequence: UInt64 = 0
        /// 准备好、等确认后换进来的 AU。
        var pending: EffectUnit?
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
    private let lock = NSLock()
    private var racks: [BusEffectRack]
    private var logged: Set<String> = []
    private var noteList: [String] = []
    /// 测试 / 诊断：记日志的同时回调一下（nil = 只 NSLog）。
    var log: ((String) -> Void)?

    init(mixer: AudioMixer, timeline: EffectLatencyTimeline) {
        self.mixer = mixer
        self.timeline = timeline
        racks = Bus.allCases.map { BusEffectRack(bus: $0) }
    }

    /// 已记过的日志（钳位、没装上的格、建不起来的 AU），每条只记一次；最多留最近 200 条。
    var notes: [String] { lock.lock(); defer { lock.unlock() }; return noteList }

    func status(_ bus: Bus) -> AudioEngineStatus.BusEffects {
        lock.lock(); defer { lock.unlock() }
        let r = racks[bus.rawValue]
        return AudioEngineStatus.BusEffects(latencyFrames: r.latencyFrames, slots: r.slots.map { $0.unit?.kind }, enabled: r.slots.map(\.enabled),
                                            ignored: r.ignored, pendingSwaps: r.slots.filter { $0.pending != nil || $0.removeWhenSafe }.count,
                                            installs: r.installs, swaps: r.swaps, removals: r.removals, lastBypassBlocks: r.lastBypassBlocks)
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

    private func reconcile(_ rack: BusEffectRack, _ effects: [EffectSlot]) {
        let plan = BusEffectPlan.parse(effects)
        record(plan.notes, bus: rack.bus)
        rack.ignored = plan.ignored
        let installed = rack.slots.map { ($0.pending ?? $0.unit)?.kind }
        let positions = BusEffectPlan.assignSlots(plan.groups.map(\.kind), installed: installed)
        var desired = [BusEffectPlan.Group?](repeating: nil, count: rack.slots.count)
        for (g, p) in zip(plan.groups, positions) { desired[p] = g }
        for s in rack.slots.indices {
            var slot = rack.slots[s]
            defer { rack.slots[s] = slot }
            guard let g = desired[s] else {
                slot.group = nil
                slot.pending = nil
                if slot.unit != nil {
                    if slot.enabled { disable(rack, s, &slot, forSwap: false) }
                    slot.removeWhenSafe = true
                }
                continue
            }
            slot.group = g
            slot.removeWhenSafe = false
            if let p = slot.pending, p.kind != g.kind { slot.pending = nil }   // 准备好的那个又不要了
            if let p = slot.pending {
                Self.apply(g, to: p)                                            // 换进来时再开
            } else if let u = slot.unit, u.kind == g.kind {
                Self.apply(g, to: u)
                setEnabled(rack, s, &slot, g.enabled)
            } else {
                // 新装或换种类：先在这里把 AU 建好、设好参数，确认安全后（step）再挂进去
                do {
                    let eu = try mixer.makeEffectUnit(g.kind, bus: rack.bus, slot: BusEffect(slot: s))
                    Self.apply(g, to: eu)
                    slot.pending = eu
                    if slot.enabled { disable(rack, s, &slot, forSwap: true) }
                } catch {
                    record([BusEffectPlan.Note(index: s, id: g.kind.rawValue, key: nil, message: "第 \(s) 格建不起来：\(error)，这一格不装")], bus: rack.bus)
                    slot.group = nil
                    if slot.unit != nil {
                        if slot.enabled { disable(rack, s, &slot, forSwap: false) }
                        slot.removeWhenSafe = true
                    }
                }
            }
        }
        step(rack)
    }

    private func step(_ rack: BusEffectRack) {
        for s in rack.slots.indices {
            var slot = rack.slots[s]
            defer { rack.slots[s] = slot }
            guard slot.pending != nil || slot.removeWhenSafe else { continue }
            // 安全 = 格关着，且挂上之后没 render 过、或者关格命令已被实时线程应用
            guard !slot.enabled, !slot.rendered || acked(slot.disableSequence) else { continue }
            if let p = slot.pending {
                let replacing = slot.unit != nil
                do {
                    try mixer.attachEffectUnit(p)
                } catch {
                    record([BusEffectPlan.Note(index: s, id: p.kind.rawValue, key: nil, message: "第 \(s) 格挂不上：\(error)")], bus: rack.bus)
                    slot.pending = nil
                    continue
                }
                slot.unit = p
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
                mixer.removeEffectUnit(rack.bus, BusEffect(slot: s))
                slot.unit = nil
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
            // 关之前 render 过、关格已确认：清掉旧状态（前瞻缓冲里是关之前的信号）再开
            if slot.rendered && acked(slot.disableSequence) { slot.unit?.reset() }
            enable(rack, s, &slot)
        } else if !on && slot.enabled {
            disable(rack, s, &slot, forSwap: false)
        }
        publishLatency(rack)
    }

    private func enable(_ rack: BusEffectRack, _ s: Int, _ slot: inout BusEffectRack.Slot) {
        mixer.setEffectEnabled(rack.bus, BusEffect(slot: s), true)
        slot.enabled = true
        slot.rendered = true
        slot.swapDisabledAtBlock = nil   // 换格中途又改回原样（准备好的 AU 不要了）：这次关格不算换格旁路
    }

    private func disable(_ rack: BusEffectRack, _ s: Int, _ slot: inout BusEffectRack.Slot, forSwap: Bool) {
        mixer.setEffectEnabled(rack.bus, BusEffect(slot: s), false)
        slot.enabled = false
        slot.disableSequence = mixer.commandsPushed
        slot.swapDisabledAtBlock = forSwap ? mixer.stats.blocksRendered : nil
    }

    /// 已打开的 AU 的延迟之和；变了就记"从下一块起"（刚推的开 / 关格命令在下一块开头应用；实时线程正在一块中间时会晚一块，见 EffectLatencyTimeline）。
    private func publishLatency(_ rack: BusEffectRack) {
        var total = 0
        for slot in rack.slots where slot.enabled { total += slot.unit?.latencyFrames ?? 0 }
        guard total != rack.latencyFrames else { return }
        rack.latencyFrames = total
        timeline.set(rack.bus, frames: total, fromBlock: mixer.stats.blocksRendered)
    }

    private func record(_ notes: [BusEffectPlan.Note], bus: Bus) {
        for n in notes {
            let line = "\(bus.name) 第 \(n.index) 格 \(n.id)\(n.key.map { "." + $0 } ?? "")：\(n.message)"
            guard logged.insert(line).inserted else { continue }
            noteList.append(line)
            if noteList.count > 200 { noteList.removeFirst(noteList.count - 200) }
            NSLog("音频效果：%@", line)
            log?(line)
        }
    }

    /// 组的参数落到 AU（EffectUnit 的 setter 再钳一次；同值不重设）。
    static func apply(_ g: BusEffectPlan.Group, to eu: EffectUnit) {
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
        }
    }
}
