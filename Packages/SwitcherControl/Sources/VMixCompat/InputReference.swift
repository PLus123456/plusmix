import Foundation
import SwitcherContracts

/// `Input=` 参数的四种写法（上游 HTTP API 的约定）：编号（1 起）；0 = 当前 PVW；-1 = 当前 PGM；GUID（XML 的 key）；名字（区分大小写，整个标题）。
public enum InputReference {
    /// 输入编号 → XML `key`（稳定的 GUID：末段就是编号）。
    public static func key(forInput number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", max(0, number))
    }

    /// 解析；找不到抛 inputNotFound。
    public static func resolve(_ text: String, in state: MixerState) throws(CompatError) -> Int {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) {
            if n == 0 { return state.preview }
            if n == -1 { return state.program }
            guard n > 0, state.input(n) != nil else { throw CompatError(code: .inputNotFound, message: "input \(n) does not exist") }
            return n
        }
        let lower = s.lowercased()
        if let byKey = state.inputs.first(where: { key(forInput: $0.number) == lower }) { return byKey.number }
        if let byName = state.inputs.first(where: { $0.name == s }) { return byName.number }
        throw CompatError(code: .inputNotFound, message: "no input numbered, keyed or named \"\(s)\"")
    }
}
