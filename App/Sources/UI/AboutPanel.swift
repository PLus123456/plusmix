// 关于面板（W5-A，01a P4 / X59）：系统标准面板 + credits——版本、Apache-2.0、NDI® 商标声明（THIRD_PARTY/NDI/NOTICE.md 第 2 条要求写在关于窗口）、
// "查看开源许可"链接。原来是不带 options 的 orderFrontStandardAboutPanel，没有任何声明。版本只在 credits 第一行写一次，系统那一行版本留空（不重复）。
// 开源许可的位置：发布包 Contents/Resources/Licenses/（scripts/release/archive.sh 放进去）；开发构建没有这个目录，链接退到仓库里的 THIRD_PARTY/README.md
// （从 App 所在位置往上找，开发构建在仓库的 .build 下）；都找不到就不给链接、写一句说明。
import AppKit
import SwitcherContracts

@MainActor
enum AboutPanel {
    /// NDI 商标声明的原句（NDI SDK 的品牌规范要求英文原样，两种语言都用它）。
    static let ndiTrademark = "NDI® is a registered trademark of Vizrt NDI AB."

    /// "查看开源许可"指向哪里：包内 Licenses/ → 仓库的 THIRD_PARTY/README.md → nil。
    static func licensesURL(bundleURL: URL = Bundle.main.bundleURL, resourceURL: URL? = Bundle.main.resourceURL) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if let licenses = resourceURL?.appendingPathComponent("Licenses", isDirectory: true),
           fm.fileExists(atPath: licenses.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return licenses
        }
        var dir = bundleURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let readme = dir.appendingPathComponent("THIRD_PARTY/README.md")
            if fm.fileExists(atPath: readme.path) { return readme }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// credits：每段一行、居中、小字。
    static func credits() -> NSAttributedString {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]
        let text = NSMutableAttributedString()
        func line(_ s: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: base)) }
            text.append(NSAttributedString(string: s, attributes: base.merging(extra) { $1 }))
        }
        line(L("about.version", SwitcherVersion.current, build))
        line(L("about.license"))
        line(ndiTrademark)
        if let url = licensesURL() {
            line(L("about.licenses"), [.link: url])
        } else {
            line(L("about.licensesUnavailable"))
        }
        return text
    }

    /// 给 orderFrontStandardAboutPanel(options:) 的参数。
    static func options() -> [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationName: ProductName.display, .applicationVersion: "", .version: "", .credits: credits()]
    }

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options())
        NSApp.activate()
    }
}
