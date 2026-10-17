import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherControl
#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
#endif

/// W2-C4（prompt 116，reports/issues/W4C3-w5-app-gaps-found-by-docs.md 第 7 条，S2）：默认表的 ⇧1–⇧0（直切 PGM）实体键盘按不出来。
/// `KeyCombo(event:)` 拿 charactersIgnoringModifiers 当键名，它只忽略 ⇧ **以外**的修饰键：⇧1 得到 ⇧ 打出来的字符（美式 "!"，拼音输入法全角 "！"），
/// 组合成 "shift+!"，对不上表里的 "shift+1"。App 用例都用合成事件、直接给 charactersIgnoringModifiers = "1"，没覆盖到。
/// 修后：带 ⇧ 的数字 / 符号键按键码取不加 ⇧ 的字符；JSON 里 / 录键录下的旧写法（"shift+!"、"shift+！"）读进来规范成同一个键。
final class ShiftKeyComboTests: XCTestCase {
    #if canImport(AppKit)
    /// 数字行十个键（Carbon kVK_ANSI_1…kVK_ANSI_0）与美式符号键，配上不加 ⇧ 的名字。
    static let digitKeys: [(UInt16, String)] = [
        (UInt16(kVK_ANSI_1), "1"), (UInt16(kVK_ANSI_2), "2"), (UInt16(kVK_ANSI_3), "3"), (UInt16(kVK_ANSI_4), "4"), (UInt16(kVK_ANSI_5), "5"),
        (UInt16(kVK_ANSI_6), "6"), (UInt16(kVK_ANSI_7), "7"), (UInt16(kVK_ANSI_8), "8"), (UInt16(kVK_ANSI_9), "9"), (UInt16(kVK_ANSI_0), "0"),
    ]
    static let symbolKeys: [(UInt16, String)] = [
        (UInt16(kVK_ANSI_Minus), "-"), (UInt16(kVK_ANSI_Equal), "="), (UInt16(kVK_ANSI_LeftBracket), "["), (UInt16(kVK_ANSI_RightBracket), "]"),
        (UInt16(kVK_ANSI_Backslash), "\\"), (UInt16(kVK_ANSI_Semicolon), ";"), (UInt16(kVK_ANSI_Quote), "'"), (UInt16(kVK_ANSI_Comma), ","),
        (UInt16(kVK_ANSI_Period), "."), (UInt16(kVK_ANSI_Slash), "/"), (UInt16(kVK_ANSI_Grave), "`"),
    ]

    /// 真键盘事件：CGEvent(keyboardEventSource:virtualKey:keyDown:) 造、NSEvent(cgEvent:) 转（**不投递**），字符由系统按当前输入源算——
    /// 本机是拼音输入法（⇧1 → "！"），美式键盘是 "!"。
    func realKeyEvent(_ keyCode: UInt16, _ flags: CGEventFlags) throws -> NSEvent {
        let source = CGEventSource(stateID: .privateState)
        let cg = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true))
        cg.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// 合成事件：指定 characters / charactersIgnoringModifiers，模拟不同输入法下同一个键（键码相同、字符不同）。
    func syntheticKeyEvent(_ keyCode: UInt16, _ chars: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode))
    }

    /// 当前输入源（只读，写进失败信息方便对照）。
    var inputSourceID: String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    /// 实体键盘 ⇧1–⇧0 → "shift+1"…"shift+0"，默认表直切 PGM 1–10；⌥⇧ / ⌃⇧ 一样；⇧ + 符号键得美式不加 ⇧ 的名字；不带 ⇧ 的、⇧ + 字母照旧。
    func testW2C4_shiftDigitFromRealKeyboardEventMatchesDefaultTable() throws {
        let source = inputSourceID
        for (index, (code, digit)) in Self.digitKeys.enumerated() {
            let event = try realKeyEvent(code, .maskShift)
            let raw = event.charactersIgnoringModifiers ?? "nil"
            let combo = KeyCombo(event: event)
            XCTAssertEqual(combo, KeyCombo("shift+\(digit)"), "输入源 \(source)：⇧\(digit) 的 charactersIgnoringModifiers = \(raw)，组合成 \(combo?.description ?? "nil")")
            XCTAssertEqual(combo.flatMap { HotkeyTable.default.action(for: $0) }, .command(.setProgram(input: index + 1)), "默认表 ⇧\(digit) = 直切 PGM \(index + 1)")
            XCTAssertEqual(KeyCombo(event: try realKeyEvent(code, [.maskShift, .maskAlternate])), KeyCombo("alt+shift+\(digit)"), "⌥⇧\(digit)")
            XCTAssertEqual(KeyCombo(event: try realKeyEvent(code, [.maskShift, .maskControl])), KeyCombo("ctrl+shift+\(digit)"), "⌃⇧\(digit)")
            XCTAssertEqual(KeyCombo(event: try realKeyEvent(code, [])), KeyCombo(digit), "不带 ⇧：照旧")
            XCTAssertEqual(KeyCombo(event: try realKeyEvent(code, .maskAlternate)), KeyCombo("alt+\(digit)"), "⌥\(digit)：照旧")
            XCTAssertEqual(KeyCombo(event: try realKeyEvent(code, .maskControl)), KeyCombo("ctrl+\(digit)"), "⌃\(digit)：照旧")
        }
        for (code, name) in Self.symbolKeys {
            let event = try realKeyEvent(code, .maskShift)
            XCTAssertEqual(KeyCombo(event: event), KeyCombo(key: name, modifiers: [.shift]),
                           "输入源 \(source)：⇧\(name) 的 charactersIgnoringModifiers = \(event.charactersIgnoringModifiers ?? "nil")")
        }
        XCTAssertEqual(KeyCombo(event: try realKeyEvent(UInt16(kVK_ANSI_A), .maskShift)), KeyCombo("shift+a"), "⇧ + 字母照旧")
        XCTAssertEqual(KeyCombo(event: try realKeyEvent(UInt16(kVK_ANSI_Keypad1), .maskShift)), KeyCombo("shift+1"), "小键盘 ⇧1 本来就是 1")
    }

    /// 同一个键在美式与拼音输入法下 charactersIgnoringModifiers 不同（"!" / "！"、"$" / "¥"、"^" / "……"、"_" / "——"、"{" / "「"……，后者是本机探针实测），
    /// 组合键一样；手写 / 录下的 hotkeys.json 只要是同一个键就对得上。
    func testW2C4_shiftKeysSameUnderUSAndPinyinInput() throws {
        let us = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
        let pinyin = ["！", "@", "#", "¥", "%", "……", "&", "*", "（", "）"]
        for (i, (code, digit)) in Self.digitKeys.enumerated() {
            for chars in [us[i], pinyin[i], digit] {   // 第三种 = 法语这类数字要按 ⇧ 才出来的布局
                XCTAssertEqual(KeyCombo(event: try syntheticKeyEvent(code, chars, flags: .shift)), KeyCombo("shift+\(digit)"), "⇧\(digit) 打出 \(chars)")
            }
        }
        let usSymbols = ["_", "+", "{", "}", "|", ":", "\"", "<", ">", "?", "~"]
        let pinyinSymbols = ["——", "+", "「", "」", "｜", "：", "\"", "《", "》", "？", "～"]
        for (i, (code, name)) in Self.symbolKeys.enumerated() {
            for chars in [usSymbols[i], pinyinSymbols[i]] {
                XCTAssertEqual(KeyCombo(event: try syntheticKeyEvent(code, chars, flags: .shift)), KeyCombo(key: name, modifiers: [.shift]), "⇧\(name) 打出 \(chars)")
            }
        }
    }
    #endif

    /// 设置 › 快捷键 里录键录下的旧行（"shift+!"、拼音下 "shift+！"）读进来规范成同一个键，照样能用；写回 JSON 是新写法。
    /// 不带 ⇧ 的符号不动（法语键盘上 "!" 不用 ⇧ 就打得出来）。
    func testW2C4_legacyShiftedSymbolSpellingsNormalize() throws {
        let cases: [(String, String)] = [
            ("shift+!", "shift+1"), ("shift+！", "shift+1"), ("⇧!", "shift+1"), ("Shift+@", "shift+2"), ("shift+#", "shift+3"),
            ("shift+$", "shift+4"), ("shift+¥", "shift+4"), ("shift+%", "shift+5"), ("shift+^", "shift+6"), ("shift+…", "shift+6"),
            ("shift+&", "shift+7"), ("shift+*", "shift+8"), ("shift+(", "shift+9"), ("shift+（", "shift+9"), ("shift+)", "shift+0"), ("shift+）", "shift+0"),
            ("shift+_", "shift+-"), ("shift+—", "shift+-"), ("shift++", "shift+="), ("shift+{", "shift+["), ("shift+「", "shift+["),
            ("shift+}", "shift+]"), ("shift+」", "shift+]"), ("shift+|", "shift+\\"), ("shift+｜", "shift+\\"), ("shift+:", "shift+;"), ("shift+：", "shift+;"),
            ("shift+\"", "shift+'"), ("shift+<", "shift+,"), ("shift+《", "shift+,"), ("shift+>", "shift+."), ("shift+》", "shift+."),
            ("shift+?", "shift+/"), ("shift+？", "shift+/"), ("shift+~", "shift+`"), ("shift+～", "shift+`"),
            ("alt+shift+#", "alt+shift+3"), ("ctrl+shift+！", "ctrl+shift+1"),
        ]
        for (legacy, expected) in cases {
            let combo = try XCTUnwrap(KeyCombo(legacy), legacy)
            XCTAssertEqual(combo, KeyCombo(expected), "\(legacy) → \(combo.description)")
            XCTAssertEqual(combo.description, expected, legacy)
        }
        // 程序里拼的 KeyCombo(key:modifiers:) 同一口径
        XCTAssertEqual(KeyCombo(key: "!", modifiers: [.shift]), KeyCombo("shift+1"))
        XCTAssertEqual(KeyCombo(key: "！", modifiers: [.shift, .option]), KeyCombo("alt+shift+1"))
        XCTAssertEqual(KeyCombo(key: "+", modifiers: [.shift]).description, "shift+=")
        XCTAssertEqual(KeyCombo(key: "!", modifiers: []).description, "!", "不带 ⇧ 不动")
        XCTAssertEqual(KeyCombo("!")?.description, "!", "不带 ⇧ 不动")
        XCTAssertEqual(KeyCombo("alt+(")?.description, "alt+(", "不带 ⇧ 不动")
        XCTAssertEqual(KeyCombo("shift+a")?.description, "shift+a")
        XCTAssertEqual(KeyCombo("shift+f5")?.description, "shift+f5")
        // 旧表：录下的那一行规范成 shift+1、写回是新写法，⇧1 派发到它
        let json = #"{"version":1,"bindings":[{"key":"shift+！","action":{"command":{"setProgram":{"input":3}}},"note":"拼音下重录的"}]}"#
        let table = try HotkeyTable.load(from: Data(json.utf8))
        XCTAssertEqual(table.bindings[0].key, KeyCombo("shift+1"))
        XCTAssertEqual(table.action(for: try XCTUnwrap(KeyCombo("shift+1"))), .command(.setProgram(input: 3)))
        XCTAssertTrue(String(decoding: try table.jsonData(), as: UTF8.self).contains(#""key" : "shift+1""#), "写回新写法")
        #if canImport(AppKit)
        XCTAssertEqual(KeyCombo(event: try realKeyEvent(UInt16(kVK_ANSI_1), .maskShift)).flatMap { table.action(for: $0) }, .command(.setProgram(input: 3)),
                       "实体键盘 ⇧1 派发到旧行")
        #endif
    }

    /// 原来能这样存：默认行 "shift+1"（按不出来）+ 自己在 ⇧1 上录的另一行 "shift+!"（按得出来，录键时冲突检查也没拦）。规范化之后两行同键——
    /// 不处理的话整张表因冲突读不进来、App 退回默认表。读的时候留录下的那一行、停用撞上的别的行（表里还在，可以再勾回来）；
    /// 两行都是旧写法（美式录一次、拼音录一次）不替用户选，照旧报冲突。
    func testW2C4_legacyShiftRowCollidingWithDefaultRowKeepsRecordedRow() throws {
        let json = """
        {"version":1,"bindings":[
          {"key":"shift+1","action":{"command":{"setProgram":{"input":1}}},"note":"直切 PGM 1 号"},
          {"key":"shift+!","action":{"fadeMs":{"durationMs":800}},"note":"自己录的"},
          {"key":"2","action":{"command":{"setPreview":{"input":2}}}}
        ]}
        """
        let table = try HotkeyTable.load(from: Data(json.utf8))
        XCTAssertEqual(table.action(for: try XCTUnwrap(KeyCombo("shift+1"))), .fadeMs(durationMs: 800), "⇧1 = 原来按得出来的那一行")
        XCTAssertFalse(table.bindings[0].enabled, "撞上的默认行停用")
        XCTAssertTrue(table.bindings[1].enabled)
        XCTAssertTrue(table.bindings[2].enabled, "别的行不动")
        XCTAssertTrue(table.conflicts().isEmpty)
        // 设置导出包（App 的 SettingsTransfer）先把整个包解码、再编码回来交给 load 查——原样的写法到 load 那一步已经没了，所以解码时就要处理掉
        struct SettingsPackage: Codable { var hotkeys: HotkeyTable }
        let package = try JSONDecoder().decode(SettingsPackage.self, from: Data("{\"hotkeys\": \(json)}".utf8))
        XCTAssertEqual(package.hotkeys, table, "包里解码同一个结果")
        XCTAssertNoThrow(try HotkeyTable.load(from: try package.hotkeys.jsonData()), "编码回来再查：不报冲突")
        let both = #"{"version":1,"bindings":[{"key":"shift+!","action":{"toggleFTB":{}}},{"key":"shift+！","action":{"toggleAFV":{}}}]}"#
        XCTAssertThrowsError(try HotkeyTable.load(from: Data(both.utf8)), "两行都是旧写法：照旧报冲突") { e in
            guard case HotkeyTableError.conflicts(let c) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(c.first?.key, KeyCombo("shift+1"))
        }
        XCTAssertNoThrow(try HotkeyTable.load(from: Data(both.utf8), allowConflicts: true))
    }
}
