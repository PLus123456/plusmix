// 状态行的文字全部来自 Stats（铁律 4：UI、API、测试读同一个结构）。这是纯函数：同一 (上一行, 这一行, 节目格式) 永远得到同样的字段，
// 测试拿 stats.jsonl 里同一秒的两行重新算一遍，和屏幕上显示的逐字比。
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

    static func fields(current: Stats, previous: Stats?, format: ProgramFormat) -> [Field] {
        var out: [Field] = []
        out.append(Field(label: "节目", value: "\(format.width)×\(format.height) \(format.frameRate)"))
        out.append(Field(label: "fps", value: outputFPS(current: current, previous: previous).map { String(format: "%.1f", $0) } ?? "—"))
        out.append(Field(label: "render", value: String(format: "%.2f ms", current.renderMs)))
        out.append(Field(label: "GPU", value: String(format: "%.0f%%", current.gpuPct)))
        out.append(Field(label: "CPU", value: String(format: "%.0f%%", current.cpuPct)))
        out.append(Field(label: "丢帧", value: "\(current.missedRender)"))
        // 编码：Stats.encoder 只有 skipped / bitrate（"编码占用"没有字段，提案 001 待批）；没有编码器在跑时显示 —
        if let e = current.encoder.first {
            out.append(Field(label: "编码跳帧", value: "\(e.skipped)"))
            out.append(Field(label: "码率", value: bitrateText(e.bitrate)))
        } else {
            out.append(Field(label: "编码跳帧", value: "—"))
            out.append(Field(label: "码率", value: "—"))
        }
        // 磁盘剩余：Stats 里没有（提案 001 的 disk_free_mb 待批），先显示 —，不在 UI 里另算（铁律 4）
        out.append(Field(label: "磁盘", value: "—"))
        return out
    }

    static func bitrateText(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.2f Mb/s", bitsPerSecond / 1_000_000) }
        if bitsPerSecond >= 1_000 { return String(format: "%.0f kb/s", bitsPerSecond / 1_000) }
        return String(format: "%.0f b/s", bitsPerSecond)
    }

    /// 一行文字："节目 1920×1080 60 · fps 60.0 · render 1.93 ms · …"。
    static func line(current: Stats, previous: Stats?, format: ProgramFormat) -> String {
        fields(current: current, previous: previous, format: format).map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }
}
