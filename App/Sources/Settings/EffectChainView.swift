// 效果链编辑器（EQ / 压缩 / 限幅参数），输入设置窗和总线效果共用。值模型是 EffectChainEditor，每次改动回调整条链。
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
                    Slider(value: $band.centerHz, in: 20...20000) { Text(L("effects.eq.centerHz", Int(band.centerHz))) }
                    Slider(value: $band.q, in: 0.1...10) { Text(L("effects.eq.q", band.q)) }
                    Slider(value: $band.gainDb, in: -24...24) { Text(L("effects.eq.gainDb", band.gainDb)) }
                }
            }
            if editor.eq.count < EffectChainEditor.maxEQBands {
                Button(L("effects.eq.add")) { editor.eq.append(EffectChainEditor.EQBand()) }
            }
        }
        Section(L("effects.dynamics.title")) {
            Toggle(L("effects.dynamics.present"), isOn: $editor.dynamics.present)
            if editor.dynamics.present {
                Toggle(L("effects.enabled"), isOn: $editor.dynamics.enabled)
                Slider(value: $editor.dynamics.thresholdDb, in: -60...0) { Text(L("effects.dynamics.thresholdDb", editor.dynamics.thresholdDb)) }
                Slider(value: $editor.dynamics.headroomDb, in: 0.1...40) { Text(L("effects.dynamics.headroomDb", editor.dynamics.headroomDb)) }
                Slider(value: $editor.dynamics.expansionRatio, in: 1...50) { Text(L("effects.dynamics.expansionRatio", editor.dynamics.expansionRatio)) }
                Slider(value: $editor.dynamics.attackSeconds, in: 0.0001...0.2) { Text(L("effects.dynamics.attackMs", editor.dynamics.attackSeconds * 1000)) }
                Slider(value: $editor.dynamics.releaseSeconds, in: 0.01...3) { Text(L("effects.dynamics.releaseMs", editor.dynamics.releaseSeconds * 1000)) }
                Slider(value: $editor.dynamics.overallGainDb, in: -40...40) { Text(L("effects.dynamics.overallGainDb", editor.dynamics.overallGainDb)) }
            }
        }
        Section(L("effects.limiter.title")) {
            Toggle(L("effects.limiter.present"), isOn: $editor.limiter.present)
            if editor.limiter.present {
                Toggle(L("effects.enabled"), isOn: $editor.limiter.enabled)
                Slider(value: $editor.limiter.attackSeconds, in: 0.001...0.03) { Text(L("effects.limiter.attackMs", editor.limiter.attackSeconds * 1000)) }
                Slider(value: $editor.limiter.decaySeconds, in: 0.001...0.06) { Text(L("effects.limiter.decayMs", editor.limiter.decaySeconds * 1000)) }
                Slider(value: $editor.limiter.preGainDb, in: -40...40) { Text(L("effects.limiter.preGainDb", editor.limiter.preGainDb)) }
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
