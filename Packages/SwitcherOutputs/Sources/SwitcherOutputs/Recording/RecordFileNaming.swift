import Foundation
import SwitcherContracts

/// 契约 `RecordSettings.fileNamePattern`（{show} {date} {time} {output}）→ 实际文件路径。组装方（headless / App）用它给 Recorder 配 url。
extension RecordSettings {
    /// 展开模板：{show} = 节目名、{output} = 输出名、{date} = yyyy-MM-dd、{time} = HH-mm-ss（本地时区）；
    /// 文件名里不合法的字符（/ :）换成 -；扩展名一期永远 .mov（`container` 见报告契约疑问 4）。
    public func outputURL(showName: String, outputName: String, date: Date = Date(), calendar: Calendar = .current) -> URL {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.calendar = calendar
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH-mm-ss"
        func clean(_ s: String) -> String {
            let cleaned = s.map { c -> Character in (c == "/" || c == ":") ? "-" : c }
            let out = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? "untitled" : out
        }
        var name = fileNamePattern
        name = name.replacingOccurrences(of: "{show}", with: clean(showName))
        name = name.replacingOccurrences(of: "{output}", with: clean(outputName))
        name = name.replacingOccurrences(of: "{date}", with: df.string(from: date))
        name = name.replacingOccurrences(of: "{time}", with: tf.string(from: date))
        name = clean(name)
        if name.lowercased().hasSuffix(".mov") { name = String(name.dropLast(4)) }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).appendingPathExtension("mov")
    }
}
