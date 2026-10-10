import Foundation
import SwitcherContracts
import SwitcherAudio

// 每路输入的效果链（W1-D3，prompt 102）：`InputSettings.effects`（契约 EffectSlot 链）→ 混音器该路的两格（EQ → 动态；顺序固定）。
//
// 1. 方案（InputEffectPlan，纯函数）：所有 parametricEQ 格（不论链里是否连续）按顺序合成一个 AUNBandEQ 的各段（≤ 16 段，多的不装）；
//    第一个动态格（compressor 自写 / dynamicsProcessor 苹果 AU，二选一）进动态格，第二个不装；peakLimiter / 认不出的 id 不装；都记日志。
//    处理顺序永远是 EQ → 动态（C 的格顺序），与链里的先后无关。
// 2. 现场：两格的 AU 在引擎创建时按最大输入数预建并挂好（`AudioMixer.installInputEffects`），运行期只开关 / 设参数 / 切动态格的种类
//    （SW_CMD_FX_KIND 只改指向），不改拓扑；再打开之前若关格已被实时线程确认，先复位（AudioUnitReset / 压缩器包络清零）。
//    槽位摘除后（detach 已确认）AudioEngine 调 `reset(slot:)` 清记录；C 侧状态由 attach 前的 sw_mix_ctx_prepare_slot 复位——都不在回调里做。
// 3. 延迟：已打开的格的延迟之和（NBandEQ 0、DynamicsProcessor 256、压缩器 = 冲激法实测，按设计 0）交给 AudioEngine，从这一路的对齐延迟线里扣
//    （效果在延迟线之前）；进不了总线时间线（总线 PTS 不变），所以不经 EffectLatencyTimeline。

/// 一路输入效果链的方案（纯函数）。
struct InputEffectPlan: Equatable {
    var bands: [BusEffectPlan.EQBand]
    /// 动态格：`.compressor` / `.dynamics`；nil = 链里没有。
    var dynamics: BusEffectPlan.Group?
    var notes: [BusEffectPlan.Note]
    var ignored: Int

    static func parse(_ slots: [EffectSlot], maxBands: Int = EffectParameterRanges.nBandEQMaxBands) -> InputEffectPlan {
        var bands: [BusEffectPlan.EQBand] = []
        var dynamics: BusEffectPlan.Group?
        var dynamicsID: String?
        var notes: [BusEffectPlan.Note] = []
        var ignored = 0
        for (index, slot) in slots.enumerated() {
            guard let parsed = BusEffectPlan.parseSlot(slot, index: index, host: "输入", notes: &notes) else { ignored += 1; continue }
            switch parsed {
            case .band(let b):
                if bands.count < maxBands { bands.append(b) }
                else {
                    notes.append(BusEffectPlan.Note(index: index, id: slot.id, key: nil, message: "每路的 EQ 格最多 \(maxBands) 段，第 \(index) 格没装"))
                    ignored += 1
                }
            case .dynamics(let p, let on):
                if let taken = dynamicsID {
                    notes.append(BusEffectPlan.Note(index: index, id: slot.id, key: nil, message: "与 \(taken) 二选一占同一格（动态格），第 \(index) 格没装"))
                    ignored += 1
                } else { dynamicsID = slot.id; dynamics = .dynamics(p, enabled: on) }
            case .compressor(let p, let on):
                if let taken = dynamicsID {
                    notes.append(BusEffectPlan.Note(index: index, id: slot.id, key: nil, message: "与 \(taken) 二选一占同一格（动态格），第 \(index) 格没装"))
                    ignored += 1
                } else { dynamicsID = slot.id; dynamics = .compressor(p, enabled: on) }
            case .limiter:
                notes.append(BusEffectPlan.Note(index: index, id: slot.id, key: nil, message: "每路只有 EQ 与动态两格，没有限幅格（限幅放总线），第 \(index) 格没装"))
                ignored += 1
            }
        }
        return InputEffectPlan(bands: bands, dynamics: dynamics, notes: notes, ignored: ignored)
    }
}

/// 全部输入槽位的效果格现场。`apply` / `reset` 只在 AudioEngine 的控制线程（或组装方线程，AudioEngine 的 lock 外）上调；`status` 任意线程读。
final class InputEffectsController: @unchecked Sendable {
    struct Rack {
        /// 上次处理过的链（相同就不再解析）。
        var effects: [EffectSlot]?
        var eqEnabled = false
        var eqBands = 0
        var eqRendered = false
        var eqDisableSequence: UInt64 = 0
        /// 链里的动态格种类（nil = 没有）。
        var dynamicsKind: EffectKind?
        var dynamicsEnabled = false
        var dynamicsRendered = false
        var dynamicsDisableSequence: UInt64 = 0
        /// C 格现在指向谁（AU 还是压缩器）。
        var activeKind: EffectSlotKind = .audioUnit
        var compressor: CompressorParameters?
        var measured: Int?
        var latencyFrames = 0
        var ignored = 0
    }

    private let mixer: AudioMixer
    private let noteLog: EffectNoteLog
    private let lock = NSLock()
    private var racks: [Rack]
    /// 预建了几个 AU、用了多久（报告用）。
    let prebuild: (units: Int, seconds: Double)

    init(mixer: AudioMixer, notes: EffectNoteLog) throws {
        self.mixer = mixer
        noteLog = notes
        racks = Array(repeating: Rack(), count: mixer.inputCapacity)
        prebuild = try mixer.installInputEffects()
    }

    func status(slot: Int) -> AudioEngineStatus.InputEffects {
        lock.lock(); defer { lock.unlock() }
        guard slot >= 0, slot < racks.count else { return .none }
        let r = racks[slot]
        return AudioEngineStatus.InputEffects(eqEnabled: r.eqEnabled, eqBands: r.eqBands, dynamicsKind: r.dynamicsKind, dynamicsEnabled: r.dynamicsEnabled,
                                              latencyFrames: r.latencyFrames, compressorMeasuredLatencyFrames: r.measured, ignored: r.ignored)
    }

    /// 槽位摘除且 detach 已确认：清记录（C 侧的格由下次 attach 前的 prepare_slot 复位）。
    func reset(slot: Int) {
        lock.lock(); defer { lock.unlock() }
        guard slot >= 0, slot < racks.count else { return }
        racks[slot] = Rack()
    }

    /// 把一路的 effects 落到它的两格；返回已打开的格的延迟之和（帧）。链没变就什么都不做。
    @discardableResult
    func apply(slot: Int, inputNumber: Int, effects: [EffectSlot]) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard slot >= 0, slot < racks.count else { return 0 }
        var rack = racks[slot]
        defer { racks[slot] = rack }
        guard rack.effects != effects else { return rack.latencyFrames }
        rack.effects = effects
        let plan = InputEffectPlan.parse(effects)
        for n in plan.notes { noteLog.record("输入 \(inputNumber) 第 \(n.index) 格 \(n.id)\(n.key.map { "." + $0 } ?? "")：\(n.message)") }
        rack.ignored = plan.ignored
        let eqLoc = EffectLocation.input(slot: slot, .parametricEQ), dynLoc = EffectLocation.input(slot: slot, .dynamics)
        // EQ
        var eqLatency = 0
        if let eq = mixer.effectUnit(eqLoc) {
            for (i, b) in plan.bands.enumerated() { eq.setEQBand(i, centerHz: Float(b.centerHz), q: Float(b.q), gainDb: Float(b.gainDb), enabled: b.enabled) }
            eq.bypassEQBands(from: plan.bands.count)
            let on = plan.bands.contains { $0.enabled }
            setEnabled(eqLoc, on, enabled: &rack.eqEnabled, rendered: &rack.eqRendered, disableSequence: &rack.eqDisableSequence)
            eqLatency = on ? eq.latencyFrames : 0
        }
        rack.eqBands = plan.bands.count
        // 动态格：压缩器 / 苹果 AU 二选一
        var dynLatency = 0
        switch plan.dynamics {
        case .compressor(let p, let on)?:
            if rack.activeKind != .compressor { mixer.setEffectKind(dynLoc, .compressor); rack.activeKind = .compressor }
            if rack.compressor != p {
                mixer.setCompressor(dynLoc, p)
                rack.compressor = p
                rack.measured = CompressorLatencyProbe.measured(for: p, at: "输入 \(inputNumber) 动态格", notes: noteLog)
            }
            rack.dynamicsKind = .compressor
            setEnabled(dynLoc, on, enabled: &rack.dynamicsEnabled, rendered: &rack.dynamicsRendered, disableSequence: &rack.dynamicsDisableSequence)
            dynLatency = on ? (rack.measured ?? CompressorParameters.reportedLatencyFrames) : 0
        case .dynamics(let d, let on)?:
            if let au = mixer.effectUnit(dynLoc) {
                au.setDynamics(thresholdDb: Float(d.thresholdDb), headroomDb: Float(d.headroomDb), expansionRatio: Float(d.expansionRatio),
                               attack: Float(d.attackSeconds), release: Float(d.releaseSeconds), overallGainDb: Float(d.overallGainDb))
                if rack.activeKind != .audioUnit { mixer.setEffectKind(dynLoc, .audioUnit); rack.activeKind = .audioUnit }
                rack.dynamicsKind = .dynamicsProcessor
                setEnabled(dynLoc, on, enabled: &rack.dynamicsEnabled, rendered: &rack.dynamicsRendered, disableSequence: &rack.dynamicsDisableSequence)
                dynLatency = on ? au.latencyFrames : 0
            }
        case nil, .eq?, .limiter?:
            rack.dynamicsKind = nil
            setEnabled(dynLoc, false, enabled: &rack.dynamicsEnabled, rendered: &rack.dynamicsRendered, disableSequence: &rack.dynamicsDisableSequence)
        }
        rack.latencyFrames = eqLatency + dynLatency
        return rack.latencyFrames
    }

    /// 开 / 关一格：再打开之前，若关之前 render 过且关格已被实时线程确认，先复位（关着时实时线程不碰它）。
    private func setEnabled(_ loc: EffectLocation, _ on: Bool, enabled: inout Bool, rendered: inout Bool, disableSequence: inout UInt64) {
        if on && !enabled {
            if rendered && mixer.commandsApplied >= disableSequence { mixer.resetEffectState(loc) }
            mixer.setEffectEnabled(loc, true)
            enabled = true
            rendered = true
        } else if !on && enabled {
            mixer.setEffectEnabled(loc, false)
            enabled = false
            disableSequence = mixer.commandsPushed
        }
    }
}
