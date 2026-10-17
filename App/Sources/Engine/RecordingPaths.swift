// 录制文件落点的避让（K01，Codex 2026-10-13 审查；用户 2026-10-17 定：开录遇到同名文件自动加后缀、永不删旧文件）。
// Recorder 的库接口约定"输出路径已存在则覆盖"（start 里先 removeItem，转封装同名 .mp4 也先删），所以避让只能在组装方的路径分配这一层做：
// 模板展开出来的名字被占了——磁盘上已有同名 .mov（转封装成 MP4 的路连同名 .mp4 一起看），或这一批 / 正在录的别的路要用同一个名字——
// 就依次试 name-2、name-3……（与切备用目录的 RecordingFallback 同一种后缀）。固定模板（例如 fixed）、同一秒再录、快速起停都落在这里。
import Foundation

enum RecordingPaths {
    /// 一个路径去掉扩展名之后的"名字"，比较时不分大小写（APFS 默认不分大小写：Fixed.mov 与 fixed.mov 是同一个文件）。
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.deletingPathExtension().path.lowercased()
    }

    /// 从 url 起找第一个没被占的落点（扩展名照原样，一期永远 .mov）。
    /// - Parameters:
    ///   - remuxToMP4: 这一路停了之后转封装成同名 .mp4：同名 .mp4 已在磁盘上也算被占（Remux 会先删它）。
    ///   - taken: 正在录 / 这一批已分出去的落点（`key(_:)`）：它们的文件可能还没建出来（writer 在第一帧才建），磁盘上看不到。
    ///   - exists: 磁盘上有没有这个文件（测试替身用；默认 FileManager）。
    static func unique(_ url: URL, remuxToMP4: Bool, taken: Set<String>,
                       exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        func occupied(_ candidate: URL) -> Bool {
            if taken.contains(key(candidate)) || exists(candidate) { return true }
            return remuxToMP4 && exists(candidate.deletingPathExtension().appendingPathExtension("mp4"))
        }
        if !occupied(url) { return url }
        var n = 2
        while n < 100_000 {
            let candidate = directory.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !occupied(candidate) { return candidate }
            n += 1
        }
        // 十万个都占了（不会发生）：带一段随机串，仍然不删任何旧文件
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString)").appendingPathExtension(ext)
    }
}
