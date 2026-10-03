// ISO 分路的纯逻辑（W3-C 交付 3；W3-E2 把 ISO 入口收成一个：输出设置 › ISO 页，底栏"ISO…"只是打开它）：
// 每路输入一个开关 = 节目里有没有这路的视频 ISO 录制输出（kind = .record、source = .input(n)），开 / 关就是 addOutput / removeOutput 命令（W5-I 起 ISO 页是表，K9）；
// 起 / 停由底栏的录制按钮一起做（同一拍起多条 startRecord）。录制目录、剩余空间和"还能录多久"（按 PGM + 所选 ISO 路的码率之和）给 ISO 页显示。
import Foundation
import SwitcherContracts
import SwitcherISO

/// 从快照里找 ISO 路、生成 addOutput 的配置（测试对着它写）。
@MainActor
enum ISORoutes {
    /// PGM 的录制输出（第一个 source = .program 的 record）。
    static func programRecord(in state: MixerState) -> OutputState? {
        state.outputs.first { $0.kind == .record && $0.settings.source == .program }
    }

    /// 输入 n 的 ISO 录制输出。
    static func isoRecord(in state: MixerState, input number: Int) -> OutputState? {
        state.outputs.first { $0.kind == .record && $0.settings.source == .input(number: number) }
    }

    /// 全部录制输出（PGM + ISO），按编号。
    static func allRecords(in state: MixerState) -> [OutputState] { state.outputs.filter { $0.kind == .record } }

    /// 给输入 n 建一个 ISO 录制输出：编码 / 文件一节同 PGM 录制输出（录制 1；没有就按节目格式的默认值），文件名模板带 {output} 免得同一秒同名，名字 "ISO n"。
    /// 之后录制 1 改了，没在录的 ISO 路跟着改、在录的停了再跟（W5-I，K10：OutputLinkage / OutputLinkageSync）——不再是"创建时抄一次"。
    static func makeISOOutput(for input: InputConfig, in state: MixerState, defaultDirectory: String) -> OutputState {
        let number = (state.outputs.map(\.number).max() ?? 0) + 1
        let pgm = programRecord(in: state)
        var record = pgm.flatMap(OutputLinkage.sharedRecordFile(from:)) ?? RecordSettings(directory: defaultDirectory)
        if !record.fileNamePattern.contains("{output}") { record.fileNamePattern += "-{output}" }
        let settings = OutputSettings(source: .input(number: input.number), video: pgm?.settings.video ?? RecordDefaults.video(for: state.format),
                                      audio: pgm?.settings.audio ?? RecordDefaults.audio(), record: record)
        return OutputState(number: number, kind: .record, name: L("outputSettings.iso.name", input.number), enabled: false, settings: settings)
    }

    /// 录制目录 + 剩余空间 + 按所有录制输出码率估的时长。
    static func estimateText(state: MixerState, defaultDirectory: String, reserveBytes: UInt64) -> String {
        let records = allRecords(in: state)
        let directory = programRecord(in: state)?.settings.record?.directory ?? records.first?.settings.record?.directory ?? defaultDirectory
        let (free, seconds) = OutputRuntime.estimate(directory: directory, outputs: records, reserveBytes: reserveBytes)
        let freeGB = Double(free) / 1_073_741_824
        let bps = records.reduce(0.0) { $0 + DiskEstimate.bytesPerSecond(video: $1.settings.video ?? VideoEncodeSettings(), audio: $1.settings.audio ?? AudioEncodeSettings()) }
        return L("outputSettings.iso.estimate", directory, freeGB, records.count, bps * 8 / 1_000_000, remainingText(seconds: seconds))
    }

    /// "还能录多久"（SwitcherISO 的 `DiskEstimate.describe` 返回中文，包不管语言，这里按同样的分档查表）。
    static func remainingText(seconds: Double) -> String {
        guard seconds.isFinite else { return L("disk.remaining.unlimited") }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L("disk.remaining.underMinute") }
        if minutes < 60 { return L("disk.remaining.minutes", minutes) }
        return L("disk.remaining.hours", minutes / 60, minutes % 60)
    }
}
