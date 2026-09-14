import Foundation

/// 命令行错误：直接给人看的一句话。
struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// 极简参数表：`--key value`、`--flag`（下一个 token 以 -- 开头或没有时算开关）、位置参数。
struct ParsedArguments {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
    /// 同一个 key 出现多次时全部保留（--meta k=v 用）。
    var repeated: [String: [String]] = [:]

    init(_ args: [String], valueKeys: Set<String>) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                let hasValue = valueKeys.contains(key) && i + 1 < args.count
                if hasValue {
                    options[key] = args[i + 1]
                    repeated[key, default: []].append(args[i + 1])
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { options[key] }
    func url(_ key: String) -> URL? { options[key].map { URL(fileURLWithPath: $0) } }
    func double(_ key: String) throws -> Double? {
        guard let s = options[key] else { return nil }
        guard let v = Double(s) else { throw CLIError("--\(key) 要一个数字，收到 \(s)") }
        return v
    }
    func int(_ key: String) throws -> Int? {
        guard let s = options[key] else { return nil }
        guard let v = Int(s) else { throw CLIError("--\(key) 要一个整数，收到 \(s)") }
        return v
    }
    func has(_ key: String) -> Bool { flags.contains(key) || options[key] != nil }
}
