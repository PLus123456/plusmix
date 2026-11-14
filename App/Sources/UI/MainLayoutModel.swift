// 主窗口新排布的算法（W6-A，docs/spec/大屏与时间线方案.md §2.1 规则 1–10、§2.3）。可执行版本是方案示意页脚本里"第一层"那段的 layout() / pickTier()，
// 这里照它写，只是把示意页写死的尺寸换成从布局里量来的（中间那一列四档的 fittingSize、格子大小、调音台宽、头一行高……，见 MainLayoutMetrics）。
// 规则自己的几个数是方案定的：24 的容许值、三成的门槛、叠放时下边一行至少两行、竖屏右边一栏最窄 346、竖屏调音台 240–380（MainLayoutRules）。
// 纯计算：不碰视图，主窗口（MainWindowController+Arrangement）量好尺寸交给它、按它摆。
import CoreGraphics

/// 方案定的规则数（拿不准的不在这里改，写进报告等用户定）。
enum MainLayoutRules {
    /// 规则 9：中间那一列这一档最多比监看高出 24（监看下面最多空 24，不到一行按钮的高度）。
    static let tolerance: CGFloat = 24
    /// 规则 10：叠放的画面比并排大三成以上才换（不让窗口拉一拉就来回跳）。
    static let stackGain: CGFloat = 1.3
    /// 规则 10：叠放时下边一行至少留两行输入（并排时本来只有一行的留一行）。
    static let stackedKeepRows = 2
    /// §2.3：竖屏右边一栏宽不够 346 时监看让一点。
    static let portraitSideMinWidth: CGFloat = 346
    /// 示意页：竖屏让宽时监看最窄 120。
    static let portraitMonitorMinWidth: CGFloat = 120
    /// §2.3：竖屏调音台高 240–380（先保证输入区至少两行）。
    static let portraitMixerHeight: ClosedRange<CGFloat> = 240...380
    static let portraitKeepRows = 2
}

/// 量出来交给算法的尺寸（pt）。
struct MainLayoutMetrics: Equatable {
    /// 排布区（工具条以下、底栏以上）的宽 × 高。
    var size: CGSize
    /// 节目画布（节目格式）的宽 × 高（像素，只用比例）。
    var canvas: CGSize
    var mixerVisible: Bool
    /// 横屏调音台的宽（默认 340；拖过分隔条按拖的）。
    var mixerWidth: CGFloat
    /// 中间那一列四档的高（TransitionPanelView.fittingHeight，从"全"到"最小"）。
    var tierHeights: [CGFloat]
    /// 按时钟偏好允许用的档（下标，从全到最小）："一直显示" = [0]，"不显示" = [1, 2, 3]。
    var allowedTiers: [Int]
    var monitorTitleHeight: CGFloat
    var columnWidth: CGFloat
    /// 监看与中间那一列之间的空隙。
    var gap: CGFloat
    /// 分隔线的粗细。
    var divider: CGFloat
    /// 输入区：头一行的高、格子外的留白、格子间距。
    var stripHeader: CGFloat
    var stripInset: CGFloat
    var cellSpacing: CGFloat
    /// 横屏格子（按缩略图那一档）与竖屏小格的大小。
    var cell: CGSize
    var compactCell: CGSize
    /// 用户拖过上下之间的分隔条：横屏下边一行想要的高（nil = 按规则）。
    var preferredBottomHeight: CGFloat?
}

/// 算出来的排布：各块在排布区里的位置（翻转坐标：原点在左上，y 朝下），和用例 / 报告要看的几项。
struct MainLayoutResult: Equatable {
    enum Mode: Equatable { case sideBySide, stacked, portrait }

    var mode: Mode
    /// 中间那一列用哪一档（下标，0 全 … 3 最小）。
    var tier: Int
    /// 每幅监看的画面区（不含标题条，精确值）。
    var picture: CGSize
    /// 并排会是多大（叠放时给报告 / 用例看）。
    var sideBySidePicture: CGSize
    /// 监看本身占的高（并排一幅 / 叠放两幅加空隙 / 竖屏一幅，含标题条）。
    var contentHeight: CGFloat
    /// 横屏：上半区高（= 中间那一列的高）；竖屏：排布区高。
    var topHeight: CGFloat
    /// 横屏：按规则的上半区高（分隔条往下拖的上限 = 贴合高）。
    var fitTopHeight: CGFloat
    /// 横屏：分隔条往上拖的下限（最矮那一档放得下）。
    var minTopHeight: CGFloat
    /// 横屏：下边一行高；竖屏：输入区高。
    var bottomHeight: CGFloat
    /// 调音台高（横屏 = 下边一行高；竖屏另算；收起 = 0）。
    var mixerHeight: CGFloat
    var preview: CGRect
    var program: CGRect
    var column: CGRect
    var inputs: CGRect
    var mixer: CGRect
    /// 横屏：上 / 下之间（可拖）；竖屏：左 / 右之间（不拖）。
    var mainDivider: CGRect
    /// 横屏：输入 ｜ 调音台（可拖）；竖屏：输入 / 调音台（不拖）；调音台收起为 nil。
    var mixerDivider: CGRect?

    var slack: CGFloat { max(0, topHeight - contentHeight) }
}

enum MainLayoutModel {
    /// 输入区放得下几行（示意页 rowsFor：头一行 + 上留白，每行 = 格子 + 间距，至少一行）。
    static func rows(for height: CGFloat, _ m: MainLayoutMetrics, cellHeight: CGFloat? = nil) -> Int {
        let h = cellHeight ?? m.cell.height
        return max(1, Int(((height - m.stripHeader - m.stripInset) / (h + m.cellSpacing)).rounded(.down)))
    }

    /// 一行放几格（示意页 perRow：左留白 + 每格 = 格子 + 间距）。
    static func columns(for width: CGFloat, cellWidth: CGFloat, _ m: MainLayoutMetrics) -> Int {
        max(1, Int(((width - m.stripInset) / (cellWidth + m.cellSpacing)).rounded(.down)))
    }

    /// 输入区一行格子最矮多高（头一行 + 上留白 + 格子 + 下留白）。
    static func stripMinimum(_ m: MainLayoutMetrics) -> CGFloat { m.stripHeader + m.stripInset + m.cell.height + m.cellSpacing }

    /// 选"放得下的最大一档"（示意页 pickTier）：这一档不比监看高出 24 以上、不超过上半区的上限、不因此少露一行输入。都不行用允许的最矮那一档。
    static func pickTier(contentHeight: CGFloat, topMax: CGFloat, availableHeight: CGFloat, _ m: MainLayoutMetrics) -> Int {
        let best = rows(for: availableHeight - min(contentHeight, topMax) - m.divider, m)
        for i in m.allowedTiers {
            let h = m.tierHeights[i]
            let top = max(contentHeight, h)
            if h <= contentHeight + MainLayoutRules.tolerance, top <= topMax, rows(for: availableHeight - top - m.divider, m) >= best { return i }
        }
        return m.allowedTiers.last ?? (m.tierHeights.count - 1)
    }

    static func compute(_ m: MainLayoutMetrics) -> MainLayoutResult {
        m.canvas.width >= m.canvas.height ? landscape(m) : portrait(m)
    }

    // MARK: 横屏（规则 2、3、7、9、10）

    private static func landscape(_ m: MainLayoutMetrics) -> MainLayoutResult {
        let a = m.canvas.width / max(m.canvas.height, 1)
        let W = m.size.width, availH = m.size.height
        let stripMin = stripMinimum(m)
        let topMax = availH - stripMin - m.divider
        // 并排：每幅监看半个窗口宽，贴合高 = 宽 × 画布高 / 画布宽 + 标题条
        let slotW = (W - m.columnWidth - 2 * m.gap) / 2
        var iw = slotW, ih = slotW / a
        if ih + m.monitorTitleHeight > topMax { ih = max(0, topMax - m.monitorTitleHeight); iw = ih * a }
        let hug = ih + m.monitorTitleHeight
        let sideTier = pickTier(contentHeight: hug, topMax: topMax, availableHeight: availH, m)
        let sideTop = min(topMax, max(hug, m.tierHeights[sideTier]))
        // 叠放：PVW 在上、PGM 在下，中间那一列挪到右边；下边一行至少留两行输入
        let keep = min(MainLayoutRules.stackedKeepRows, rows(for: availH - sideTop - m.divider, m))
        let topMax2 = availH - max(stripMin, m.stripHeader + m.stripInset + CGFloat(keep) * (m.cell.height + m.cellSpacing)) - m.divider
        let stackW = W - m.columnWidth - 2 * m.gap
        let h2 = min(stackW / a, (topMax2 - m.gap) / 2 - m.monitorTitleHeight), w2 = h2 * a
        let stacked = h2 > 0 && (w2 * h2 >= MainLayoutRules.stackGain * iw * ih
                                 || (sideTop - hug > MainLayoutRules.tolerance && w2 * h2 > iw * ih))
        var mode: MainLayoutResult.Mode = .sideBySide
        var picture = CGSize(width: iw, height: ih)
        var content = hug, tier = sideTier, fitTop = sideTop
        if stacked {
            mode = .stacked
            picture = CGSize(width: w2, height: h2)
            content = 2 * (m.monitorTitleHeight + h2) + m.gap
            tier = pickTier(contentHeight: content, topMax: topMax2, availableHeight: availH, m)
            fitTop = min(topMax2, max(content, m.tierHeights[tier]))
        }
        // 分隔条（规则 7）：往上拖让下边一行更高（监看等比变小），往下最多拖到贴合高；最矮那一档要放得下
        let lowest = m.allowedTiers.map { m.tierHeights[$0] }.min() ?? m.tierHeights.last ?? 0
        let minTop = min(fitTop, lowest)
        var top = fitTop
        if let preferred = m.preferredBottomHeight {
            top = min(fitTop, max(minTop, availH - m.divider - preferred))
        }
        if top < fitTop - 0.01 {
            // 拖小了：监看在剩下的高度里等比变小；这一档挑放得进这一截的最大那一档
            if mode == .stacked {
                let h = min(picture.height, max(0, (top - m.gap) / 2 - m.monitorTitleHeight))
                picture = CGSize(width: h * a, height: h)
                content = 2 * (m.monitorTitleHeight + h) + m.gap
            } else {
                let h = min(picture.height, max(0, top - m.monitorTitleHeight))
                picture = CGSize(width: h * a, height: h)
                content = h + m.monitorTitleHeight
            }
            tier = m.allowedTiers.first { m.tierHeights[$0] <= top + 0.01 } ?? (m.allowedTiers.last ?? tier)
        }
        let topH = top.rounded()
        let bottomY = topH + m.divider
        let bottomH = max(0, availH - bottomY)
        let mixerW = m.mixerVisible ? m.mixerWidth : 0
        let inputW = m.mixerVisible ? W - mixerW - m.divider : W
        let pw = widthRounded(picture.width), ph = picture.height.rounded()
        let title = m.monitorTitleHeight
        var preview: CGRect, program: CGRect, column: CGRect
        if mode == .stacked {
            let x = ((stackW - pw) / 2).rounded()
            preview = CGRect(x: x, y: 0, width: pw, height: title + ph)
            program = CGRect(x: x, y: title + ph + m.gap, width: pw, height: title + ph)
            column = CGRect(x: (stackW + m.gap).rounded(), y: 0, width: m.columnWidth, height: topH)
        } else {
            let columnX = (slotW + m.gap).rounded()
            column = CGRect(x: columnX, y: 0, width: m.columnWidth, height: topH)
            let rightSlotX = columnX + m.columnWidth + m.gap
            let rightSlotW = W - rightSlotX
            preview = CGRect(x: ((columnX - m.gap - pw) / 2).rounded(), y: 0, width: pw, height: title + ph)
            program = CGRect(x: (rightSlotX + (rightSlotW - pw) / 2).rounded(), y: 0, width: pw, height: title + ph)
        }
        let inputs = CGRect(x: 0, y: bottomY, width: inputW, height: bottomH)
        let mixer = m.mixerVisible ? CGRect(x: inputW + m.divider, y: bottomY, width: mixerW, height: bottomH) : .zero
        return MainLayoutResult(mode: mode, tier: tier, picture: picture, sideBySidePicture: CGSize(width: iw, height: ih),
                                contentHeight: content, topHeight: topH, fitTopHeight: fitTop.rounded(), minTopHeight: minTop.rounded(),
                                bottomHeight: bottomH, mixerHeight: m.mixerVisible ? bottomH : 0,
                                preview: preview, program: program, column: column, inputs: inputs, mixer: mixer,
                                mainDivider: CGRect(x: 0, y: topH, width: W, height: m.divider),
                                mixerDivider: m.mixerVisible ? CGRect(x: inputW, y: bottomY, width: m.divider, height: bottomH) : nil)
    }

    // MARK: 竖屏（规则 5、§2.3）

    private static func portrait(_ m: MainLayoutMetrics) -> MainLayoutResult {
        let a = m.canvas.width / max(m.canvas.height, 1)
        let W = m.size.width, availH = m.size.height
        let title = m.monitorTitleHeight
        // 监看占满整个高度；右边一栏宽不够 346 时监看让一点
        var ih = availH - title, iw = ih * a
        let maxIw = (W - MainLayoutRules.portraitSideMinWidth - m.divider - m.columnWidth - 2 * m.gap) / 2
        if iw > maxIw { iw = max(MainLayoutRules.portraitMonitorMinWidth, maxIw); ih = iw / a }
        let pw = widthRounded(iw), ph = ih.rounded()
        let columnX = pw + m.gap
        let programX = columnX + m.columnWidth + m.gap
        let sideX = programX + pw + m.divider
        let sideW = max(0, W - sideX)
        // 右边一栏：上面输入区（竖的小格），下面调音台，和输入区同宽，高 240–380（先保证输入区至少两行）
        let keep = CGFloat(MainLayoutRules.portraitKeepRows)
        let mixH: CGFloat = m.mixerVisible
            ? max(MainLayoutRules.portraitMixerHeight.lowerBound,
                  min(MainLayoutRules.portraitMixerHeight.upperBound,
                      availH - m.divider - (m.stripHeader + m.stripInset + keep * (m.compactCell.height + m.cellSpacing))))
            : 0
        let mixerH = mixH.rounded()
        let inputH = availH - (m.mixerVisible ? mixerH + m.divider : 0)
        let content = ph + title
        let tier = pickTier(contentHeight: content, topMax: availH, availableHeight: availH, m)
        let inputs = CGRect(x: sideX, y: 0, width: sideW, height: inputH)
        let mixer = m.mixerVisible ? CGRect(x: sideX, y: inputH + m.divider, width: sideW, height: mixerH) : .zero
        return MainLayoutResult(mode: .portrait, tier: tier, picture: CGSize(width: iw, height: ih), sideBySidePicture: CGSize(width: iw, height: ih),
                                contentHeight: content, topHeight: availH, fitTopHeight: availH, minTopHeight: availH,
                                bottomHeight: inputH, mixerHeight: m.mixerVisible ? mixerH : 0,
                                preview: CGRect(x: 0, y: 0, width: pw, height: content),
                                program: CGRect(x: programX, y: 0, width: pw, height: content),
                                column: CGRect(x: columnX, y: 0, width: m.columnWidth, height: availH),
                                inputs: inputs, mixer: mixer,
                                mainDivider: CGRect(x: programX + pw, y: 0, width: m.divider, height: availH),
                                mixerDivider: m.mixerVisible ? CGRect(x: sideX, y: inputH, width: sideW, height: m.divider) : nil)
    }

    /// 示意页的写法：宽遇 .5 往下取（472.5 → 472，和实拍一致）。
    static func widthRounded(_ w: CGFloat) -> CGFloat { (w - 0.01).rounded() }
}
