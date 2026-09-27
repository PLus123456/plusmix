// W3-C3 交付 1：SwitcherOutputs 的 External / VirtualCamera / ISO 三个 target 与 CameraExtension/ 的源码里没有中文字面量——
// 包只给枚举 / 数字，给人看的文字由组装方（App）查表（OutputStatusText / ISORoutes.remainingText）；包里非有不可的文字
// （外部输出窗口标题、Aux 占位的默认文案、CMIO 设备 / 流名）用 ASCII，组装方可以换成本地化后的。
// 与 App 的 LocalizationTests.testL10n_noHardcodedChineseInUISources 同法（找字符串字面量里的 CJK），但更严：
// 不豁免日志 / 断言行；多行字符串（"""）、原始字符串（#"…"#）、插值里套的字面量和 \u{…} 转义都算；块注释（含嵌套）与字符串里的 // 分得清。
// 扫描器先对一段样例自检（testL10n_scannerFindsChineseInLiteralsNotInComments），免得规则写错了空跑通过。
// 放在 VirtualCameraTests：这个 target 不开窗口、不录制，最快；扫的是四个目录，不只是本 target。
import Foundation
import XCTest

final class SourceLanguageTests: XCTestCase {
    /// 扫的目录（相对仓库根）。
    static let roots = [
        "Packages/SwitcherOutputs/Sources/External",
        "Packages/SwitcherOutputs/Sources/VirtualCamera",
        "Packages/SwitcherOutputs/Sources/ISO",
        "CameraExtension",
    ]

    func testL10n_scannerFindsChineseInLiteralsNotInComments() {
        let sample = #"""
        let a = "ok"                       // 注释里的中文不算
        let b = "中文"
        /* 块注释 "不算" /* 嵌套 "也不算" */ 仍在注释里 "不算" */
        let c = "a // 这不是注释"
        let d = #"原始 "字符串" 中文"#
        let e = """
            多行
            """
        let f = "\(x ? "内插里" : "no") \(g("x(y)"))"
        let g = "转义 \"引号\" 之后"
        /// 文档注释 "不算"
        let h = "\u{4E2D}"
        let i = "（全角括号）"
        let j = "ASCII only… \(y) × 2 → ok"
        #if DEBUG
        let k = ##"两个 # 的"原始串"##
        #endif
        """#
        let hits = ChineseLiteralScanner.scan(sample)
        XCTAssertEqual(hits.map(\.line), [2, 4, 5, 6, 9, 10, 12, 13, 16], "\(hits)")
        XCTAssertEqual(hits.first?.literal, "中文")
        XCTAssertEqual(hits.first { $0.line == 9 }?.literal, "内插里", "插值里套的字面量单独算")
        XCTAssertTrue(ChineseLiteralScanner.scan(#"let s = "\(a) and \(b)" // 中文"#).isEmpty)
        XCTAssertTrue(ChineseLiteralScanner.scan("/* 没闭合的块注释 \"中文\"").isEmpty)
    }

    func testL10n_packageSourcesHaveNoChineseLiterals() throws {
        let root = try Self.repoRoot()
        var violations: [String] = []
        for dir in Self.roots {
            let base = root.appendingPathComponent(dir)
            let files = Self.files(under: base, extension: "swift")
            XCTAssertFalse(files.isEmpty, "\(dir) 下应有 Swift 源文件（路径写错了会空跑通过）")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                let rel = String(file.path.dropFirst(root.path.count + 1))
                violations += ChineseLiteralScanner.scan(text).map { "\(rel):\($0.line) \($0.literal)" }
            }
            // 扩展的 Info.plist 等：系统设置里显示的名字也是给人看的文字
            for plist in Self.files(under: base, extension: "plist") {
                let data = try Data(contentsOf: plist)
                let object = try PropertyListSerialization.propertyList(from: data, format: nil)
                let rel = String(plist.path.dropFirst(root.path.count + 1))
                violations += ChineseLiteralScanner.plistStrings(object).filter { ChineseLiteralScanner.containsCJK($0.value) }.map { "\(rel) \($0.path) = \($0.value)" }
            }
        }
        XCTAssertEqual(violations, [], "包源码里的中文字面量（给人看的文字由组装方查表，包里非有不可的用 ASCII）：\n" + violations.joined(separator: "\n"))
    }

    static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) { return url }
        }
        throw XCTSkip("找不到仓库根（CLAUDE.md）")
    }

    static func files(under directory: URL, extension ext: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == ext { out.append(url) }
        return out.sorted { $0.path < $1.path }
    }
}

/// Swift 源码里含中文的字符串字面量。一个小词法器：代码 / 行注释 / 块注释（可嵌套）/ 字符串（# 个数、单行或多行、插值里又是代码）。
/// 不是完整的 Swift 词法（正则字面量之类不认），对本仓库的源码够用；规则由 testL10n_scannerFindsChineseInLiteralsNotInComments 自检。
enum ChineseLiteralScanner {
    struct Hit: Equatable, CustomStringConvertible {
        /// 字面量开始的行（从 1 数）。
        let line: Int
        /// 字面量的内容（不含引号；插值部分不在里面，插值里套的字面量单独一条）。
        let literal: String
        var description: String { "\(line): \(literal)" }
    }

    /// CJK：部首、符号与标点（、。「」）、假名、汉字（含扩展区 / 兼容区）、竖排标点、全角字符（（）：；！）。
    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    static func containsCJK(_ s: String) -> Bool { s.unicodeScalars.contains(where: isCJK) }

    private struct Frame {
        var isString: Bool
        /// 代码层：插值里的括号深度（回到 0 再遇到 ")" = 插值结束）。
        var parens = 0
        /// 字符串层。
        var hashes = 0
        var multiline = false
        var startLine = 0
        var content = String.UnicodeScalarView()
    }

    static func scan(_ text: String) -> [Hit] {
        let s = Array(text.unicodeScalars)
        func at(_ k: Int) -> Unicode.Scalar? { k < s.count ? s[k] : nil }
        var hits: [Hit] = []
        var stack = [Frame(isString: false)]
        var line = 1
        var i = 0
        while i < s.count {
            let c = s[i]
            let top = stack.count - 1
            if !stack[top].isString {
                if c == "/", at(i + 1) == "/" {                       // 行注释：到行尾（换行留给下一轮数行号）
                    while i < s.count, s[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/", at(i + 1) == "*" {                       // 块注释，可嵌套
                    var depth = 1
                    i += 2
                    while i < s.count, depth > 0 {
                        if s[i] == "/", at(i + 1) == "*" { depth += 1; i += 2; continue }
                        if s[i] == "*", at(i + 1) == "/" { depth -= 1; i += 2; continue }
                        if s[i] == "\n" { line += 1 }
                        i += 1
                    }
                    continue
                }
                if c == "#" || c == "\"" {                            // 字符串开头（前面可以有 # 个数）；# 后面不是引号就是 #if 之类
                    var k = i
                    var hashes = 0
                    while at(k) == "#" { hashes += 1; k += 1 }
                    if at(k) == "\"" {
                        let multiline = at(k + 1) == "\"" && at(k + 2) == "\""
                        stack.append(Frame(isString: true, hashes: hashes, multiline: multiline, startLine: line))
                        i = k + (multiline ? 3 : 1)
                    } else {
                        i = k
                    }
                    continue
                }
                if c == "(" { stack[top].parens += 1 }
                if c == ")" {
                    if stack[top].parens == 0, stack.count > 1 {     // 插值结束，回到字符串
                        stack.removeLast()
                        i += 1
                        continue
                    }
                    stack[top].parens -= 1
                }
                if c == "\n" { line += 1 }
                i += 1
                continue
            }
            // 字符串层
            let hashes = stack[top].hashes
            if c == "\\" {
                var k = i + 1
                var n = 0
                while n < hashes, at(k) == "#" { n += 1; k += 1 }
                if n == hashes, let e = at(k) {                      // 转义（原始字符串要 \ 后跟同样个数的 #）
                    if e == "(" {                                     // 插值：里面是代码
                        stack.append(Frame(isString: false))
                        i = k + 1
                        continue
                    }
                    if e == "u", at(k + 1) == "{" {                  // \u{…}：按解出来的字符算
                        var m = k + 2
                        var hex = ""
                        while let d = at(m), d != "}" { hex.unicodeScalars.append(d); m += 1 }
                        if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { stack[top].content.append(u) }
                        i = m + 1
                        continue
                    }
                    stack[top].content.append(e)
                    if e == "\n" { line += 1 }
                    i = k + 1
                    continue
                }
            }
            if c == "\"" {
                let quotes = stack[top].multiline ? 3 : 1
                let closes = (0..<quotes).allSatisfy { at(i + $0) == "\"" } && (0..<hashes).allSatisfy { at(i + quotes + $0) == "#" }
                if closes {
                    let literal = String(stack[top].content)
                    if containsCJK(literal) { hits.append(Hit(line: stack[top].startLine, literal: literal)) }
                    stack.removeLast()
                    i += quotes + hashes
                    continue
                }
            }
            stack[top].content.append(c)
            if c == "\n" { line += 1 }
            i += 1
        }
        return hits.sorted { $0.line < $1.line }
    }

    /// plist 里所有字符串值（键路径 + 值）。
    static func plistStrings(_ object: Any, path: String = "") -> [(path: String, value: String)] {
        switch object {
        case let s as String:
            return [(path, s)]
        case let d as [String: Any]:
            return d.keys.sorted().flatMap { plistStrings(d[$0]!, path: path + "/" + $0) }
        case let a as [Any]:
            return a.enumerated().flatMap { plistStrings($0.element, path: path + "[\($0.offset)]") }
        default:
            return []
        }
    }
}
