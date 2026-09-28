// 状态行的文字全部来自 Stats（铁律 4：UI、API、测试读同一个结构）。这是纯函数：同一 (上一行, 这一行, 节目格式) 永远得到同样的字段，
// 测试拿 stats.jsonl 里同一秒的两行重新算一遍，和屏幕上显示的逐字比。
// P2 落地后 Stats.encoder[i] 有 frames / dropped / disk_free_mb / reconnects / state：编码跳帧 / 码率取第一个真在跑的输出
// （state 不是 idle / stopped / unavailable），磁盘取第一个报了 disk_free_mb 的输出（录制输出没在录也报所在卷的剩余）。
// W3-E3 接上 NDI 发送后 encoder[] 里也有 NDI 的项（码率是 UYVY 原始码率，约 2 Gb/s）：给了输出类型时先找录制 / 推流，都没在跑才看 NDI；
// Stats 的项不带类型，类型由调用方从快照给。W3-E5 起按每项的 `output`（提案 019 的输出编号）查快照里的 kind 对号，不再按"与 outputs 同序"
// （两次采样之间输出表变了、或一行顺序颠倒的 Stats 也对得准）。
import Foundation
import SwitcherContracts

enum StatusLineFormatter {
    struct Field: Equatable {
        let label: String
        let value: String
    }

    /// 输出 fps 按相邻两行的 tick 差 / ts 差算（Stats 没有直接的输出 fps 字段；tick 是采样那一刻的节目拍）。
    static func outputFPS(current: Stats, previous: Stats?) -> Double? {
        guard let previous, current.ts > previous.ts else { return nil }
        return Double(current.tick.rawValue - previous.tick.rawValue) / (current.ts - previous.ts)
    }

    /// 真在跑的编码器（录制 recording / stopping，推流 publishing / connecting / backoff，NDI publishing）：不是 idle / stopped / unavailable 的项。
    /// kinds = 输出编号 → 类型（快照里的 outputs）：给了就按每项的 `output` 查类型，先找录制 / 推流；都没在跑才退到第一个在跑的
    /// （NDI，或表里没有的编号——输出刚删、这行 Stats 还是上一秒的）；nil = 不分类型，第一个在跑的。
    static func activeEncoder(in stats: Stats, kinds: [Int: OutputKind]? = nil) -> Stats.EncoderEntry? {
        func running(_ e: Stats.EncoderEntry) -> Bool { !["idle", "stopped", "unavailable"].contains(e.state) }
        let runningEntries = stats.encoder.filter(running)
        if let kinds, let e = runningEntries.first(where: { kinds[$0.output].map { $0 != .ndi } ?? false }) {
            return e
        }
        return runningEntries.first
    }

    static func fields(current: Stats, previous: Stats?, format: ProgramFormat, kinds: [Int: OutputKind]? = nil) -> [Field] {
        var out: [Field] = []
        out.append(Field(label: L("status.program"), value: "\(format.width)×\(format.height) \(format.frameRate)"))
        out.append(Field(label: "fps", value: outputFPS(current: current, previous: previous).map { String(format: "%.1f", $0) } ?? "—"))
        out.append(Field(label: "render", value: String(format: "%.2f ms", current.renderMs)))
        out.append(Field(label: "GPU", value: String(format: "%.0f%%", current.gpuPct)))
        out.append(Field(label: "CPU", value: String(format: "%.0f%%", current.cpuPct)))
        out.append(Field(label: L("status.missed"), value: "\(current.missedRender)"))
        if let e = activeEncoder(in: current, kinds: kinds) {
            out.append(Field(label: L("status.encoderSkipped"), value: "\(e.skipped)"))
            out.append(Field(label: L("status.bitrate"), value: bitrateText(e.bitrate)))
        } else {
            out.append(Field(label: L("status.encoderSkipped"), value: "—"))
            out.append(Field(label: L("status.bitrate"), value: "—"))
        }
        if let e = current.encoder.first(where: { $0.diskFreeMb > 0 }) {
            out.append(Field(label: L("status.disk"), value: diskText(megabytes: e.diskFreeMb)))
        } else {
            out.append(Field(label: L("status.disk"), value: "—"))
        }
        return out
    }

    static func bitrateText(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.2f Mb/s", bitsPerSecond / 1_000_000) }
        if bitsPerSecond >= 1_000 { return String(format: "%.0f kb/s", bitsPerSecond / 1_000) }
        return String(format: "%.0f b/s", bitsPerSecond)
    }

    /// 磁盘剩余：≥ 1 GB 显示 GB（1 位小数），否则 MB（整数）；1 GB = 1024 MB（与 disk_free_mb 的 2^20 口径一致）。
    static func diskText(megabytes: Double) -> String {
        if megabytes >= 1024 { return String(format: "%.1f GB", megabytes / 1024) }
        return String(format: "%.0f MB", megabytes)
    }

    /// 一行文字："节目 1920×1080 60 · fps 60.0 · render 1.93 ms · …"。
    static func line(current: Stats, previous: Stats?, format: ProgramFormat, kinds: [Int: OutputKind]? = nil) -> String {
        fields(current: current, previous: previous, format: format, kinds: kinds).map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }
}
