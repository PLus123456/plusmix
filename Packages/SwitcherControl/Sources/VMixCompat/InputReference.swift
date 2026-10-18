import Foundation
import SwitcherContracts

/// `Input=` 参数的四种写法（上游 HTTP API 的约定）：编号（1 起）；0 = 当前 PVW；-1 = 当前 PGM；GUID（XML 的 key）；名字（区分大小写，整个标题）。
public enum InputReference {
    /// 输入编号 → XML `key`（稳定的 GUID：末段就是编号）。
    public static func key(forInput number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", max(0, number))
    }

    /// 解析成一路**存在的**输入；找不到抛 inputNotFound。
    /// 0 / -1 = 当前 PVW / PGM：它是黑场（noInput）、或指着一路已经不在的输入（`MixerState.validate` 不查引用）时同样抛 inputNotFound——
    /// 兼容层的 Input= 永远点名一路真输入（W2-C4，Codex 审查 D02：原来解成 0 / 悬空编号交给翻译器，音频四组强制解包，整个进程 SIGTRAP）。
    public static func resolve(_ text: String, in state: MixerState) throws(CompatError) -> Int {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) {
            if n == 0 { return try current(state.preview, reference: n, role: "preview", in: state) }
            if n == -1 { return try current(state.program, reference: n, role: "program", in: state) }
            guard n > 0, state.input(n) != nil else { throw CompatError(code: .inputNotFound, message: "input \(n) does not exist") }
            return n
        }
        let lower = s.lowercased()
        if let byKey = state.inputs.first(where: { key(forInput: $0.number) == lower }) { return byKey.number }
        if let byName = state.inputs.first(where: { $0.name == s }) { return byName.number }
        throw CompatError(code: .inputNotFound, message: "no input numbered, keyed or named \"\(s)\"")
    }

    /// 0 / -1 指向的那一路：黑场或已经不在都算找不到（文案说清是当前 PVW / PGM 落空，不是编号写错了）。
    private static func current(_ number: Int, reference: Int, role: String, in state: MixerState) throws(CompatError) -> Int {
        guard number != MixerState.noInput else {
            throw CompatError(code: .inputNotFound, message: "Input=\(reference) is the current \(role), which is empty (black)")
        }
        guard state.input(number) != nil else {
            throw CompatError(code: .inputNotFound, message: "Input=\(reference) is the current \(role), input \(number), which does not exist")
        }
        return number
    }
}
