// 主界面的颜色 / 字体 / 尺寸。Tally 颜色按广播惯例：PGM 红、PVW 绿（落地方案 §7 第 3 条），不用稿子里的绿 / 橙。
import AppKit

@MainActor
enum Theme {
    static let windowBackground = NSColor(white: 0.11, alpha: 1)
    static let panelBackground = NSColor(white: 0.15, alpha: 1)
    static let cellBackground = NSColor(white: 0.19, alpha: 1)
    static let divider = NSColor(white: 0.25, alpha: 1)
    static let text = NSColor(white: 0.9, alpha: 1)
    static let dimText = NSColor(white: 0.6, alpha: 1)

    /// Tally：PGM 红。
    static let tallyProgram = NSColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1)
    /// Tally：PVW 绿。
    static let tallyPreview = NSColor(red: 0.12, green: 0.62, blue: 0.22, alpha: 1)
    /// 都不在。
    static let tallyOff = NSColor(white: 0.28, alpha: 1)
    /// 按钮按下 / 开着的高亮。
    static let accent = NSColor(red: 0.24, green: 0.52, blue: 0.95, alpha: 1)
    static let ftbActive = NSColor(red: 0.6, green: 0.1, blue: 0.1, alpha: 1)
    static let recording = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)

    static let monitorTitleHeight: CGFloat = 26
    static let thumbnailWidth: CGFloat = 200
    static let thumbnailHeight: CGFloat = 112.5   // 16:9
    static let transitionColumnWidth: CGFloat = 150
    static let mixerPanelWidth: CGFloat = 340
    static let bottomBarHeight: CGFloat = 58

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func monoLabel(_ text: String, size: CGFloat = 12, color: NSColor = Theme.text) -> NSTextField {
        let l = label(text, size: size, color: color)
        l.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        return l
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// 能显示"开着"状态的按钮（bezelColor 变色）。
    static func toggleButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let b = button(title, target: target, action: action)
        b.setButtonType(.momentaryPushIn)
        return b
    }

    static func setHighlighted(_ button: NSButton, _ on: Bool, color: NSColor = Theme.accent) {
        button.bezelColor = on ? color : nil
        button.contentTintColor = on ? .white : nil
    }
}

/// 带背景色的容器视图（用图层背景色，不走 draw）。
final class PanelView: NSView {
    var backgroundColor: NSColor {
        didSet { layer?.backgroundColor = backgroundColor.cgColor }
    }
    init(color: NSColor = Theme.panelBackground) {
        backgroundColor = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = backgroundColor.cgColor
    }
}
