// 输入条末尾的虚线"＋ 添加输入"占位格（W5-H，01a D10 / 03 V-09）：和格子一样大，单击开添加面板（同底栏"添加输入"主体：停在上次的类型）；
// 空节目时它是输入条里唯一一格，框里多一行小字"也可以把视频 / 图片文件拖到这里"（G13 的拖放提示）。它自己也接拖放（同输入条）。
// 另：拖进来的文件怎么认（MediaFileDrop）——视频进"文件"输入、图片进"图片"输入，别的跳过。
// W6-A：紧凑小格那一档（宽 72）写短的"＋ 添加"、不写拖放的小字（放不下）。
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AddInputPlaceholderView: NSView {
    /// 单击（开添加面板）。
    var onClick: (() -> Void)?
    /// 拖放进来的视频 / 图片文件（只含认得的；可能为空 = 一个都不认得）与跳过的文件。
    var onDropFiles: ((MediaFileDrop.Result) -> Void)?
    /// 拖进来 / 拖走（输入条整条高亮）。
    var onDropHighlight: ((Bool) -> Void)?
    private let titleLabel = Theme.label(L("strip.add.title"), size: 13, weight: .semibold, color: Theme.dimText)
    private let hintLabel = Theme.label(L("strip.add.dropHint"), size: 10, color: Theme.dimText)
    private let border = CAShapeLayer()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var pressed = false
    /// 紧凑小格那一档（W6-A）。
    private var compact = false
    /// 空节目时要写拖放的小字（紧凑时也不写）。
    private var hintWanted = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        border.fillColor = nil
        border.strokeColor = Theme.dimText.cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        layer?.addSublayer(border)
        titleLabel.alignment = .center
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        addSubview(titleLabel)
        addSubview(hintLabel)
        widthConstraint = widthAnchor.constraint(equalToConstant: Theme.thumbnailWidth)
        heightConstraint = heightAnchor.constraint(equalToConstant: 150)
        NSLayoutConstraint.activate([
            widthConstraint, heightConstraint,
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -12),
            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
        toolTip = L("strip.add.tip")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("strip.add.a11y"))
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var titleText: String { titleLabel.stringValue }
    var hintText: String { hintLabel.stringValue }
    var isHintHidden: Bool { hintLabel.isHidden }
    var hasDashedBorder: Bool { border.superlayer != nil && !(border.lineDashPattern ?? []).isEmpty && border.path != nil }

    /// 空节目时写拖放的小字，有输入时收起（紧凑小格那一档放不下，也收起）。
    func setHintVisible(_ visible: Bool) {
        hintWanted = visible
        let shown = visible && !compact
        if hintLabel.isHidden == shown { hintLabel.isHidden = !shown }
    }

    /// 紧凑小格那一档（W6-A）：标题写短、不写拖放的小字。
    func setCompact(_ compact: Bool) {
        guard compact != self.compact else { return }
        self.compact = compact
        titleLabel.stringValue = compact ? L("strip.add.compactTitle") : L("strip.add.title")
        setHintVisible(hintWanted)
    }

    /// 和格子一样大（缩略图三档 / 裁切比例变了时由输入条设）。
    func setSize(width: CGFloat, height: CGFloat) {
        if widthConstraint.constant != width { widthConstraint.constant = width }
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 6, cornerHeight: 6, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        border.strokeColor = Theme.dimText.cgColor
    }

    // MARK: 点击

    func performClick() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        layer?.backgroundColor = Theme.cellBackground.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    // MARK: 拖放（与输入条同一口径）

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = MediaFileDrop.accepts(sender.draggingPasteboard)
        onDropHighlight?(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onDropHighlight?(false) }

    override func draggingEnded(_ sender: any NSDraggingInfo) { onDropHighlight?(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDropHighlight?(false)
        let result = MediaFileDrop.read(sender.draggingPasteboard)
        guard !result.accepted.isEmpty else { return false }
        onDropFiles?(result)
        return true
    }
}

/// 拖进输入条的文件怎么认（G13）：视频（movie / video）→ 文件输入，图片 → 图片输入；别的（文本、音频文件、文件夹）跳过。
enum MediaFileDrop {
    enum Kind: Equatable { case video, image }

    struct Result: Equatable {
        /// 认得的文件，按拖进来的顺序。
        var accepted: [(url: URL, kind: Kind)]
        /// 跳过的文件。
        var skipped: [URL]

        static func == (a: Result, b: Result) -> Bool {
            a.accepted.map(\.url) == b.accepted.map(\.url) && a.accepted.map(\.kind) == b.accepted.map(\.kind) && a.skipped == b.skipped
        }
    }

    static func kind(of url: URL) -> Kind? {
        guard url.isFileURL else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func read(_ pasteboard: NSPasteboard) -> Result {
        var result = Result(accepted: [], skipped: [])
        for url in fileURLs(in: pasteboard) {
            if let kind = kind(of: url) { result.accepted.append((url, kind)) } else { result.skipped.append(url) }
        }
        return result
    }

    /// 至少有一个认得的文件才接（光标变成"+"）。
    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        fileURLs(in: pasteboard).contains { kind(of: $0) != nil }
    }
}
