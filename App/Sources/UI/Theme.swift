// 主界面的颜色 / 字体 / 尺寸。Tally 颜色按广播惯例：PGM 红、PVW 绿（落地方案 §7 第 3 条），不用稿子里的绿 / 橙。
import AppKit

@MainActor
enum Theme {
    static let windowBackground = NSColor(white: 0.11, alpha: 1)
    static let panelBackground = NSColor(white: 0.15, alpha: 1)
    static let cellBackground = NSColor(white: 0.19, alpha: 1)
    static let divider = NSColor(white: 0.25, alpha: 1)
    /// 自绘滑块的轨道（声像滑块）。
    static let sliderTrack = NSColor(white: 0.36, alpha: 1)
    static let text = NSColor(white: 0.9, alpha: 1)
    static let dimText = NSColor(white: 0.6, alpha: 1)

    /// Tally：PGM 红。
    static let tallyProgram = NSColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1)
    /// Tally：PVW 绿。标题条上压白字，调暗到对比度 ≥ 4.5:1（原来 0.12 / 0.62 / 0.22 只有 3.5:1，03-目视检查.md V-06）。
    static let tallyPreview = NSColor(red: 0.10, green: 0.52, blue: 0.18, alpha: 1)
    /// 电平表的绿段（不压字，保持原来的亮度）。
    static let meterGreen = NSColor(red: 0.12, green: 0.62, blue: 0.22, alpha: 1)
    /// 都不在。
    static let tallyOff = NSColor(white: 0.28, alpha: 1)
    /// 按钮按下 / 开着的高亮。
    static let accent = NSColor(red: 0.24, green: 0.52, blue: 0.95, alpha: 1)
    static let ftbActive = NSColor(red: 0.6, green: 0.1, blue: 0.1, alpha: 1)
    static let recording = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
    /// 提醒条（W5-L）：琥珀底黑字（对比 ≥ 4.5:1）。
    static let reminderBackground = NSColor(red: 0.96, green: 0.70, blue: 0.16, alpha: 1)
    static let reminderText = NSColor(white: 0.08, alpha: 1)
    /// 界面锁着时锁按钮的底色（金色，W5-L / E8）。
    static let lockActive = NSColor(red: 0.85, green: 0.62, blue: 0.10, alpha: 1)

    static let monitorTitleHeight: CGFloat = 26
    static let thumbnailWidth: CGFloat = 200
    static let thumbnailHeight: CGFloat = 112.5   // 16:9
    static let transitionColumnWidth: CGFloat = 150
    static let mixerPanelWidth: CGFloat = 340
    /// 输入条最矮多高（格子按钮点得到，W5-A / X61）与开始时多高（W5-A 原型实测）。
    static let inputStripMinimumHeight: CGFloat = 190
    static let inputStripInitialHeight: CGFloat = 197
    /// 底栏总高 = 按钮行 + 状态行（W5-F 起状态行独立成窗口最底一行，总高不变）。
    static let bottomBarHeight: CGFloat = 58
    /// 状态行高（窗口最底一行）。
    static let statusBarHeight: CGFloat = 20

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

    /// 开着 / 按下的高亮：底色换成 color，标题一律白字（FTB / 录制 / 静音的红底原来是黑字，对比 3.0:1，V-05）。
    /// 每个快照都会调：状态没变就不重设（不每帧新建标题串）。改了 title 的按钮（录制 / 推流）要在改完 title 之后再调。
    static func setHighlighted(_ button: NSButton, _ on: Bool, color: NSColor = Theme.accent) {
        let bezel: NSColor? = on ? color : nil
        if button.bezelColor == bezel, hasWhiteTitle(button) == on { return }
        button.bezelColor = bezel
        button.contentTintColor = on ? .white : nil
        setTitleColor(button, on ? .white : nil)
    }

    /// 推按钮的标题色：contentTintColor 管不到推按钮的标题，有颜色时换成带色的 attributedTitle；nil = 回到系统配色（重设 title 就回到默认属性）。
    static func setTitleColor(_ button: NSButton, _ color: NSColor?) {
        let title = button.title
        guard let color else {
            button.title = title
            return
        }
        let style = NSMutableParagraphStyle()
        style.alignment = button.alignment
        style.lineBreakMode = .byTruncatingTail
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color, .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: style,
        ])
    }

    private static func hasWhiteTitle(_ button: NSButton) -> Bool {
        guard button.attributedTitle.length > 0 else { return false }
        return (button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .white
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
