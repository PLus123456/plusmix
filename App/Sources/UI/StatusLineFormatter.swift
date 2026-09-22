// 状态行的文字全部来自 Stats（铁律 4：UI、API、测试读同一个结构）。这是纯函数：同一 (上一行, 这一行, 节目格式) 永远得到同样的字段，
// 测试拿 stats.jsonl 里同一秒的两行重新算一遍，和屏幕上显示的逐字比。
// P2 落地后 Stats.encoder[i] 有 frames / dropped / disk_free_mb / reconnects / state：编码跳帧 / 码率取第一个真在跑的输出
// （state 不是 idle / stopped），磁盘取第一个报了 disk_free_mb 的输出（录制输出没在录也报所在卷的剩余）。
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

    /// 真在跑的编码器（录制 recording / stopping，推流 publishing / connecting / backoff …）：不是 idle / stopped 的第一项。
    static func activeEncoder(in stats: Stats) -> Stats.EncoderEntry? {
        stats.encoder.first { $0.state != "idle" && $0.state != "stopped" }
    }

    static func fields(current: Stats, previous: Stats?, format: ProgramFormat) -> [Field] {
        var out: [Field] = []
        out.append(Field(label: L("status.program"), value: "\(format.width)×\(format.height) \(format.frameRate)"))
        out.append(Field(label: "fps", value: outputFPS(current: current, previous: previous).map { String(format: "%.1f", $0) } ?? "—"))
        out.append(Field(label: "render", value: String(format: "%.2f ms", current.renderMs)))
        out.append(Field(label: "GPU", value: String(format: "%.0f%%", current.gpuPct)))
        out.append(Field(label: "CPU", value: String(format: "%.0f%%", current.cpuPct)))
        out.append(Field(label: L("status.missed"), value: "\(current.missedRender)"))
        if let e = activeEncoder(in: current) {
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
    static func line(current: Stats, previous: Stats?, format: ProgramFormat) -> String {
        fields(current: current, previous: previous, format: format).map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }
}
