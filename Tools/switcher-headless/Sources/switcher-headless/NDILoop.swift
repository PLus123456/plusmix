import Foundation
import SwitcherNDI

/// NDI 回环（G4 gate4-ndi：headless 自己的 NDISender(PGM) → NDIInput）：节目文件里 `ndi(sourceName:)` 不含 "(" 时视为"本机某个发送端的名字"，
/// 在发现列表里找名字以 " (名字)" 结尾的源（NDI 源名是 "机器名 (名字)"），等最多 timeout 秒；含 "(" 的名字原样交给 NDIInput（它自己等源出现）。
enum NDILoop {
    static func resolveSourceName(_ name: String, timeoutSeconds: Double = 10) throws -> String {
        if name.contains("(") { return name }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var seen: [String] = []
        repeat {
            let sources = try NDIFinder.discover(timeoutMs: 1500, showLocalSources: true)
            seen = sources.map(\.name)
            if let hit = sources.first(where: { $0.name.hasSuffix(" (\(name))") || $0.name == name }) { return hit.name }
        } while Date() < deadline
        throw CLIError("\(Int(timeoutSeconds)) s 内网络上没有名为「\(name)」的 NDI 源（要先起发送端：--ndi-send \(name)）。现在能看到：\(seen.isEmpty ? "无" : seen.joined(separator: " / "))")
    }
}
