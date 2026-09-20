import SwitcherContracts

/// TALLY 串：每个输入位置一位，0 = 关、1 = PGM、2 = PVW；位置 = 编号，缺的编号写 0。
/// 取值只看 `MixerState.tally(ofInput:)`（转场中 PVW 也是 PGM，叠加通道可见的输入也是 PGM，PGM 优先于 PVW）。
public enum TallyDigits {
    public static func string(for state: MixerState) -> String {
        let maxNumber = state.inputs.map(\.number).max() ?? 0
        guard maxNumber >= 1 else { return "" }
        let tallies = state.tallies
        var s = ""
        s.reserveCapacity(maxNumber)
        for number in 1...maxNumber {
            let t = tallies[number] ?? .off
            s.append(t.program ? "1" : (t.preview ? "2" : "0"))
        }
        return s
    }
}
