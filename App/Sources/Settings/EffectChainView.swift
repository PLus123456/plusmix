// 效果链编辑器（EQ / 压缩 / 限幅参数），输入设置窗和总线效果共用。值模型是 EffectChainEditor，每次改动回调整条链。
// 滑块范围 = EffectEditorRanges（W5-C：都在引擎送进 AU 之前的钳位范围里，界面值 = AU 值）。
import SwiftUI
import SwitcherContracts

struct EffectChainView: View {
    @Binding var editor: EffectChainEditor

    var body: some View {
        Section(L("effects.eq.title")) {
            ForEach($editor.eq) { $band in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L("effects.enabled"), isOn: $band.enabled)
                        Spacer()
                        Button(L("effects.eq.remove")) { editor.eq.removeAll { $0.id == band.id } }
                    }
                    Slider(value: $band.centerHz, in: EffectEditorRanges.eqCenterHz) { Text(L("effects.eq.centerHz", Int(band.centerHz))) }
                    Slider(value: $band.q, in: EffectEditorRanges.eqQ) { Text(L("effects.eq.q", band.q)) }
                    Slider(value: $band.gainDb, in: EffectEditorRanges.eqGainDb) { Text(L("effects.eq.gainDb", band.gainDb)) }
                }
            }
            if editor.eq.count < EffectChainEditor.maxEQBands {
                Button(L("effects.eq.add")) { editor.eq.append(EffectChainEditor.EQBand()) }
            }
        }
        Section(L("effects.dynamics.title")) {
            // 动态格：压缩器（compressor）/ 动态处理器（dynamicsProcessor）二选一占同一格（提案 024 (b)，W5-O；新开默认压缩器，同音频设置窗）
            Toggle(L("effects.dynamics.present"), isOn: Binding(get: { editor.dynamicsKind != nil }, set: { on in
                if on, editor.dynamicsKind == nil { editor.compressor.present = true }
                if !on { editor.compressor.present = false; editor.dynamics.present = false }
            }))
            if let kind = editor.dynamicsKind {
                Picker(L("audioSettings.compressor.kind"), selection: Binding(get: { kind }, set: { editor.setDynamicsKind($0) })) {
                    ForEach(EffectChainEditor.DynamicsKind.allCases) { k in Text(L("audioSettings.compressor.kind.\(k.rawValue)")).tag(k) }
                }
                if kind == .compressor {
                    Toggle(L("effects.enabled"), isOn: $editor.compressor.enabled)
                    Slider(value: $editor.compressor.thresholdDb, in: EffectEditorRanges.compThresholdDb) { Text(L("effects.dynamics.thresholdDb", editor.compressor.thresholdDb)) }
                    Slider(value: $editor.compressor.ratio, in: EffectEditorRanges.compRatio) { Text(L("audioSettings.compressor.ratio", editor.compressor.ratio)) }
                    Slider(value: $editor.compressor.kneeDb, in: EffectEditorRanges.compKneeDb) { Text(L("audioSettings.compressor.knee", editor.compressor.kneeDb)) }
                    Slider(value: $editor.compressor.attackSeconds, in: EffectEditorRanges.compAttackSeconds) { Text(L("effects.dynamics.attackMs", editor.compressor.attackSeconds * 1000)) }
                    Slider(value: $editor.compressor.releaseSeconds, in: EffectEditorRanges.compReleaseSeconds) { Text(L("effects.dynamics.releaseMs", editor.compressor.releaseSeconds * 1000)) }
                    Slider(value: $editor.compressor.makeupGainDb, in: EffectEditorRanges.compMakeupGainDb) { Text(L("audioSettings.compressor.makeupGain", editor.compressor.makeupGainDb)) }
                } else {
                    Toggle(L("effects.enabled"), isOn: $editor.dynamics.enabled)
                    Slider(value: $editor.dynamics.thresholdDb, in: EffectEditorRanges.dynThresholdDb) { Text(L("effects.dynamics.thresholdDb", editor.dynamics.thresholdDb)) }
                    Slider(value: $editor.dynamics.headroomDb, in: EffectEditorRanges.dynHeadroomDb) { Text(L("effects.dynamics.headroomDb", editor.dynamics.headroomDb)) }
                    Slider(value: $editor.dynamics.expansionRatio, in: EffectEditorRanges.dynExpansionRatio) { Text(L("effects.dynamics.expansionRatio", editor.dynamics.expansionRatio)) }
                    Slider(value: $editor.dynamics.attackSeconds, in: EffectEditorRanges.dynAttackSeconds) { Text(L("effects.dynamics.attackMs", editor.dynamics.attackSeconds * 1000)) }
                    Slider(value: $editor.dynamics.releaseSeconds, in: EffectEditorRanges.dynReleaseSeconds) { Text(L("effects.dynamics.releaseMs", editor.dynamics.releaseSeconds * 1000)) }
                    Slider(value: $editor.dynamics.overallGainDb, in: EffectEditorRanges.dynOverallGainDb) { Text(L("effects.dynamics.overallGainDb", editor.dynamics.overallGainDb)) }
                }
            }
        }
        Section(L("effects.limiter.title")) {
            Toggle(L("effects.limiter.present"), isOn: $editor.limiter.present)
            if editor.limiter.present {
                Toggle(L("effects.enabled"), isOn: $editor.limiter.enabled)
                Slider(value: $editor.limiter.attackSeconds, in: EffectEditorRanges.limAttackSeconds) { Text(L("effects.limiter.attackMs", editor.limiter.attackSeconds * 1000)) }
                Slider(value: $editor.limiter.decaySeconds, in: EffectEditorRanges.limDecaySeconds) { Text(L("effects.limiter.decayMs", editor.limiter.decaySeconds * 1000)) }
                Slider(value: $editor.limiter.preGainDb, in: EffectEditorRanges.limPreGainDb) { Text(L("effects.limiter.preGainDb", editor.limiter.preGainDb)) }
            }
        }
        if !editor.others.isEmpty {
            Section(L("effects.others.title")) {
                ForEach(Array(editor.others.enumerated()), id: \.offset) { _, slot in
                    Text(L("effects.others.slot", slot.id, slot.enabled ? L("common.on") : L("common.off")))
                }
            }
        }
    }
}
