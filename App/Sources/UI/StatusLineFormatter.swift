// 状态行的文字全部来自 Stats（铁律 4：UI、API、测试读同一个结构）。这是纯函数：同一 (上一行, 这一行, 节目格式) 永远得到同样的字段，
// 测试拿 stats.jsonl 里同一秒的两行重新算一遍，和屏幕上显示的逐字比。
// P2 落地后 Stats.encoder[i] 有 frames / dropped / disk_free_mb / reconnects / state：编码跳帧 / 码率取第一个真在跑的输出
// （state 不是 idle / stopped / unavailable），磁盘取第一个报了 disk_free_mb 的输出（录制输出没在录也报所在卷的剩余）。
// W3-E3 接上 NDI 发送后 encoder[] 里也有 NDI 的项（码率是 UYVY 原始码率，约 2 Gb/s）：给了输出类型时先找录制 / 推流，都没在跑才看 NDI；
// Stats 的项不带类型，类型由调用方从快照给。W3-E5 起按每项的 `output`（提案 019 的输出编号）查快照里的 kind 对号，不再按"与 outputs 同序"
// （两次采样之间输出表变了、或一行顺序颠倒的 Stats 也对得准）。
// W5-F（01a E9 / 03 V-22）：节目格式写短"1080p60 / 1080p59.94"（非 16:9 写全宽高"1080×1920p30"）；字段名一律走本地化表、统一语言
// （原来"fps / render"是英文、其余是中文；GPU / CPU 是通用缩写，两种语言都写它）。
// W5-N（02 X28）：码率分开写"录制 x · 推流 y"——原来只取第一个在跑的，录制和推流同时开时推流码率看不到；多路时各给最差（码率最低）的那一路，
// 退避中（码率 0）的推流也算在跑、就是最差的。跳帧给录制 / 推流里最多的那一路，标签按实际含义写"编码滞后跳帧"（E1：编码跟不上、编码之前跳过的帧，
// 累计；设计方案 §10 写的"编码器占用"这里没有，不冒充）。NDI 的原始码率（约 2 Gb/s）不进这两项；只有 NDI 在发时跳帧才看它。
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

    /// 在跑的录制 / 推流项（X28）：kinds 给了按输出类型分；没给（老调用 / 测试）按 state 认——recording / stopping 算录制，
    /// publishing / connecting / backoff 算推流（这时分不出 NDI）。
    static func runningEncoders(in stats: Stats, kinds: [Int: OutputKind]?) -> (record: [Stats.EncoderEntry], stream: [Stats.EncoderEntry], other: [Stats.EncoderEntry]) {
        func running(_ e: Stats.EncoderEntry) -> Bool { !["idle", "stopped", "unavailable"].contains(e.state) }
        var record: [Stats.EncoderEntry] = [], stream: [Stats.EncoderEntry] = [], other: [Stats.EncoderEntry] = []
        for e in stats.encoder where running(e) {
            let kind: OutputKind?
            if let kinds { kind = kinds[e.output] } else { kind = ["recording", "stopping"].contains(e.state) ? .record : .stream }
            switch kind {
            case .record?: record.append(e)
            case .stream?: stream.append(e)
            default: other.append(e)
            }
        }
        return (record, stream, other)
    }

    static func fields(current: Stats, previous: Stats?, format: ProgramFormat, kinds: [Int: OutputKind]? = nil) -> [Field] {
        var out: [Field] = []
        out.append(Field(label: L("status.program"), value: formatText(format)))
        out.append(Field(label: L("status.fps"), value: outputFPS(current: current, previous: previous).map { String(format: "%.1f", $0) } ?? "—"))
        out.append(Field(label: L("status.render"), value: String(format: "%.2f ms", current.renderMs)))
        out.append(Field(label: L("status.gpu"), value: String(format: "%.0f%%", current.gpuPct)))
        out.append(Field(label: L("status.cpu"), value: String(format: "%.0f%%", current.cpuPct)))
        out.append(Field(label: L("status.missed"), value: "\(current.missedRender)"))
        let running = runningEncoders(in: current, kinds: kinds)
        let encoders = running.record + running.stream
        let skipped = (encoders.isEmpty ? running.other : encoders).map(\.skipped).max()
        out.append(Field(label: L("status.encoderLagSkipped"), value: skipped.map { "\($0)" } ?? "—"))
        out.append(Field(label: L("status.recordBitrate"), value: running.record.map(\.bitrate).min().map(bitrateText) ?? "—"))
        out.append(Field(label: L("status.streamBitrate"), value: running.stream.map(\.bitrate).min().map(bitrateText) ?? "—"))
        if let e = current.encoder.first(where: { $0.diskFreeMb > 0 }) {
            out.append(Field(label: L("status.disk"), value: diskText(megabytes: e.diskFreeMb)))
        } else {
            out.append(Field(label: L("status.disk"), value: "—"))
        }
        return out
    }

    /// 节目格式的短写法（E9）：16:9 写"高 p 帧率"（1080p60、1080p59.94、2160p30），别的比例写全宽高（1080×1920p30）。
    static func formatText(_ format: ProgramFormat) -> String {
        format.width * 9 == format.height * 16 ? "\(format.height)p\(format.frameRate)" : "\(format.width)×\(format.height)p\(format.frameRate)"
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

    /// 一行文字："节目 1080p60  ·  帧率 60.0  ·  渲染 1.93 ms  ·  …"。
    static func line(current: Stats, previous: Stats?, format: ProgramFormat, kinds: [Int: OutputKind]? = nil) -> String {
        fields(current: current, previous: previous, format: format, kinds: kinds).map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }
}
