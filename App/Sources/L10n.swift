// 本地化入口（W3-E 交付第 8 条）：用户可见文案全部经 L(键) 取，表在 App/Resources/{zh-Hans,en}.lproj/Localizable.strings。
// 键是稳定的英文标识（"menu.show"），不是中文原文，两种语言平等；缺键返回键本身（LocalizationTests 会抓）。
// 测试宿主固定 zh-Hans（`languageOverride`，AppController 设），测试里的中文断言在任何机器上都成立；正式 App 跟系统语言，
// 偏好设置里的"语言"写 AppleLanguages（重启生效，与 macOS 的每 App 语言设置同一套机制）。
import Foundation
import Synchronization

enum L10n {
    /// 支持的语言（lproj 名）。
    static let supportedLanguages = ["zh-Hans", "en"]

    private static let overrideBox = Mutex<String?>(nil)
    private static let bundles = Mutex<[String: Bundle]>([:])

    /// 固定用某种语言（测试宿主）；nil = 跟系统。
    static var languageOverride: String? {
        get { overrideBox.withLock { $0 } }
        set { overrideBox.withLock { $0 = newValue } }
    }

    /// 界面语言对应的 Locale（日期 / 时间的格式跟界面语言走，W5-A 时钟）：覆盖语言 → 主 bundle 实际选中的本地化。
    static var locale: Locale {
        Locale(identifier: languageOverride ?? Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// 某种语言的 lproj bundle；没有就 nil。
    static func bundle(language: String) -> Bundle? {
        bundles.withLock { cache in
            if let b = cache[language] { return b }
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let b = Bundle(path: path) else { return nil }
            cache[language] = b
            return b
        }
    }

    /// 取文案：覆盖语言 → 主 bundle 按系统语言；缺键返回键本身。
    static func string(_ key: String) -> String {
        if let lang = languageOverride, let b = bundle(language: lang) {
            return b.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// 指定语言取文案（偏好设置预览 / 测试）。
    static func string(_ key: String, language: String, _ args: CVarArg...) -> String {
        let raw = bundle(language: language)?.localizedString(forKey: key, value: key, table: nil) ?? key
        return args.isEmpty ? raw : String(format: raw, arguments: args)
    }

    /// 某种语言的整张表（测试比对两种语言的键）。
    static func table(language: String) -> [String: String]? {
        guard let path = bundle(language: language)?.path(forResource: "Localizable", ofType: "strings") else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }
}

/// 取文案。
func L(_ key: String) -> String { L10n.string(key) }

/// 取格式文案并填参数（%d / %@ / %.1f）。
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L10n.string(key), arguments: args) }
