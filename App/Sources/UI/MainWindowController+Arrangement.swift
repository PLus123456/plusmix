// 主窗口的两套排布（W6-A，prompt 144；docs/spec/大屏与时间线方案.md §2）。
// 新排布（默认）：五块视图（PVW、PGM、中间那一列、输入区、调音台）放进 MainLayoutView，按 MainLayoutModel 算出来的位置摆——
//   横屏：上边 PVW ｜ 中间那一列 ｜ PGM 横贯窗口（很宽的画布上下叠放、中间那一列挪到右边），下边一行"输入区 ｜ 调音台"同高，输入区折行；
//   竖屏：左边监看占满高度，右边一栏输入区（竖的小格）在上、调音台在下；
//   中间那一列按高度四档自动收放（时钟偏好"自动 / 一直显示 / 不显示"），收起时钟时时间挪到状态行；
//   上下之间、输入 ｜ 调音台之间的分隔条可拖（竖屏不拖），位置存本机。
// 旧排布（窗口 › 排布 › 旧排布）：今天的样子，NSSplitView 那一套（MainWindowController.swift），五块视图搬回去。
// 所有尺寸从布局里量（中间那一列四档的 fittingSize、格子大小……），规则数在 MainLayoutRules。不碰契约。
import AppKit

@MainActor
extension MainWindowController {
    // MARK: 偏好

    /// 按本机偏好装排布、定时钟（AppController 挂上偏好时、用例开头调）。
    func applyLayoutPreferences() {
        guard window != nil else { return }
        let wanted = layoutPreferences?.arrangement ?? .adaptive
        if installedArrangement != wanted { install(wanted) }
        applyClockDisplay()
        if installedArrangement == .adaptive {
            layoutView.needsLayout = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// 窗口 › 排布：新排布 / 旧排布（存本机）。
    func setArrangement(_ arrangement: WindowArrangement) {
        layoutPreferences?.arrangement = arrangement
        guard arrangement != installedArrangement else { return }
        install(arrangement)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// 时钟：自动 / 一直显示 / 不显示（存本机）。
    var clockDisplay: ClockDisplay { layoutPreferences?.clockDisplay ?? .auto }

    func setClockDisplay(_ display: ClockDisplay) {
        layoutPreferences?.clockDisplay = display
        applyClockDisplay()
    }

    /// 按时钟偏好允许用的档：自动 = 四档；一直显示 = 只有全档（今天的样子，宁可空着也留时钟）；不显示 = 去掉全档。
    var allowedColumnTiers: [TransitionPanelView.ColumnTier] {
        switch clockDisplay {
        case .auto: TransitionPanelView.ColumnTier.allCases
        case .always: [.full]
        case .never: [.noClock, .compact, .minimal]
        }
    }

    private func applyClockDisplay() {
        if installedArrangement == .legacy {
            // 旧排布：今天的样子是全档带时钟；"不显示"照偏好收起时钟
            transitionPanel.setTier(clockDisplay == .never ? .noClock : .full)
            syncStatusClock()
        } else {
            layoutView.needsLayout = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// 时钟不在中间那一列时，时间挪到状态行右端（小字）。
    func syncStatusClock() {
        bottomBar.statusBar.setClockShown(!transitionPanel.isClockShown)
    }

    // MARK: 装 / 拆

    /// 换排布：五块视图从现在的容器拿下来、放进另一套；调音台开没开着带过去。
    func install(_ target: WindowArrangement) {
        guard let window, let content = window.contentView else { return }
        let mixerVisible = installedArrangement == nil ? true : isMixerPanelVisible
        switch installedArrangement {
        case .legacy?: tearDownLegacy()
        case .adaptive?: tearDownAdaptive()
        case nil: break
        }
        installedArrangement = target
        arrangement = target
        lastStackedDecision = nil   // 切新 / 旧排布：并排 / 叠放按无状态的规则重新定
        switch target {
        case .legacy: installLegacy(content: content, mixerVisible: mixerVisible)
        case .adaptive: installAdaptive(content: content, mixerVisible: mixerVisible)
        }
        applyClockDisplay()
        syncStatusClock()
        inputStrip.setMixerVisible(isMixerPanelVisible)
    }

    private func tearDownLegacy() {
        NSLayoutConstraint.deactivate(legacyConstraints + legacyContainerConstraints)
        for v in [previewMonitor, transitionPanel, programMonitor] as [NSView] {
            monitorsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for v in centerSplit.arrangedSubviews {
            centerSplit.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for v in outerSplit.arrangedSubviews {
            outerSplit.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        outerSplit.removeFromSuperview()
    }

    private func tearDownAdaptive() {
        NSLayoutConstraint.deactivate(adaptiveContainerConstraints)
        for v in [previewMonitor, transitionPanel, programMonitor, inputStrip, mixerPanel] as [NSView] { v.removeFromSuperview() }
        layoutView.removeFromSuperview()
    }

    /// 旧排布：中列 ｜ 调音台（右侧通高），中列 = 上监看（自由高度）/ 下输入条（一行，197 高）。原来 buildLayout 里的那一段。
    private func installLegacy(content: NSView, mixerVisible: Bool) {
        for v in [previewMonitor, transitionPanel, programMonitor, inputStrip, mixerPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        mixerPanel.isHidden = false
        for v in [previewMonitor, transitionPanel, programMonitor] as [NSView] { monitorsStack.addArrangedSubview(v) }
        centerSplit.addArrangedSubview(monitorsStack)
        centerSplit.addArrangedSubview(inputStrip)
        centerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        centerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        outerSplit.addArrangedSubview(centerSplit)
        outerSplit.addArrangedSubview(mixerPanel)
        outerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        outerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        content.addSubview(outerSplit)
        NSLayoutConstraint.activate(legacyContainerConstraints + legacyConstraints)
        previewMonitor.canvasAspect = nil
        programMonitor.canvasAspect = nil
        inputStrip.flow = .row
        inputStrip.forcesCompact = false
        mixerPanel.adaptiveHeight = false
        inputStripMinimumConstraint?.constant = inputStrip.minimumHeight
        window?.layoutIfNeeded()
        // 输入条开始时 197 高（W5-A 原型实测的值）。原来写成"窗口外框高 − 底栏 − 230"，230 里暗含了 32 pt 的标题栏；W5-G 加了工具条之后
        // 那一行是 52 pt，输入条就少了 20、被下面的最大坐标夹到 189（全量第一遍 MainWindowLayoutTests 红出来的）。改按内容区算，和标题栏多高无关。
        // W5-H：格子多了一行按钮、缩略图框按裁切比例变矮，"中"档贴着格子的高仍是 197（inputStrip.minimumHeight + 2）
        centerSplit.setPosition(content.bounds.height - Theme.bottomBarHeight - max(Theme.inputStripInitialHeight, inputStrip.minimumHeight + 2) - centerSplit.dividerThickness,
                                ofDividerAt: 0)
        // 分隔条 1 pt 不算在调音台里（W5-A 量出 339，G6 追加 ③）
        outerSplit.setPosition(outerSplit.frame.width - Theme.mixerPanelWidth - outerSplit.dividerThickness, ofDividerAt: 0)
        if !mixerVisible { outerSplit.setPosition(outerSplit.frame.width, ofDividerAt: 0) }
        updateInputStripMinimum()
    }

    /// 新排布：五块视图放进 MainLayoutView，按规则摆（layoutAdaptive）。
    private func installAdaptive(content: NSView, mixerVisible: Bool) {
        for v in [previewMonitor, transitionPanel, programMonitor, inputStrip, mixerPanel] as [NSView] {
            v.removeFromSuperview()
            // 改成按 frame 摆之前先给个像样的尺寸：刚建出来的视图是 0×0，内部的必需约束（标题条、搜索框最窄 120……）会和"宽 0"撞
            if v.frame.width < 400 || v.frame.height < 200 {
                v.frame = NSRect(x: 0, y: 0, width: max(v.frame.width, v === transitionPanel ? Theme.transitionColumnWidth : 800), height: max(v.frame.height, 420))
            }
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = []
            layoutView.addSubview(v)
        }
        layoutView.bringDividersToFront()
        content.addSubview(layoutView)
        NSLayoutConstraint.activate(adaptiveContainerConstraints)
        adaptiveMixerVisible = mixerVisible
        mixerPanel.isHidden = !mixerVisible
        inputStrip.flow = .wrap
        mixerPanel.adaptiveHeight = true
        applyCanvas(canvasSize)
        if let window, window.contentMinSize != Self.minimumContentSize { window.contentMinSize = Self.minimumContentSize }
        // 马上按现在的内容区摆一次（排布区 = 内容区去掉底栏），不等下一趟自动布局
        let area = NSSize(width: content.bounds.width, height: content.bounds.height - Theme.bottomBarHeight)
        layoutView.frame = NSRect(origin: NSPoint(x: 0, y: Theme.bottomBarHeight), size: area)
        layoutAdaptive(area)
        layoutView.needsLayout = true
    }

    // MARK: 画布 / 调音台 / 中间那一列变了

    /// 换节目画布（换 session）：监看的画面区比例、竖屏的紧凑小格、重排。
    func applyCanvas(_ size: CGSize) {
        canvasSize = size
        lastStackedDecision = nil   // 换节目格式：并排 / 叠放按无状态的规则重新定
        let adaptive = installedArrangement == .adaptive
        let aspect: CGFloat? = adaptive && size.height > 0 ? size.width / size.height : nil
        previewMonitor.canvasAspect = aspect
        programMonitor.canvasAspect = aspect
        inputStrip.forcesCompact = adaptive && size.width < size.height
        if adaptive { layoutView.needsLayout = true }
    }

    /// 新排布收起 / 展开调音台。
    func setAdaptiveMixerVisible(_ visible: Bool) {
        adaptiveMixerVisible = visible
        mixerPanel.isHidden = !visible
        inputStrip.setMixerVisible(visible)
        layoutView.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// 中间那一列各档的高变了（T-bar 下面那行提示出没）。
    func columnHeightsChanged() {
        if installedArrangement == .adaptive { layoutView.needsLayout = true }
    }

    // MARK: 摆（新排布）

    /// 量好尺寸交给 MainLayoutModel，按结果摆五块视图和两条分隔条。
    func layoutAdaptive(_ size: NSSize) {
        guard installedArrangement == .adaptive, size.width > 0, size.height > 0, !applyingAdaptiveLayout else { return }
        applyingAdaptiveLayout = true
        defer { applyingAdaptiveLayout = false }
        var metrics = adaptiveMetrics(size: size)
        metrics.previouslyStacked = lastStackedDecision
        let result = MainLayoutModel.compute(metrics)
        arrangementResult = result
        switch result.mode {
        case .stacked: lastStackedDecision = true
        case .sideBySide: lastStackedDecision = false
        case .portrait: lastStackedDecision = nil
        }
        if let tier = TransitionPanelView.ColumnTier(rawValue: result.tier) { transitionPanel.setTier(tier) }
        setFrame(previewMonitor, result.preview)
        setFrame(programMonitor, result.program)
        setFrame(transitionPanel, result.column)
        setFrame(inputStrip, result.inputs)
        if adaptiveMixerVisible { setFrame(mixerPanel, result.mixer) }
        let portrait = result.mode == .portrait
        layoutView.topDivider.place(result.mainDivider, axis: portrait ? .vertical : .horizontal, draggable: !portrait)
        layoutView.mixerDivider.place(result.mixerDivider, axis: portrait ? .horizontal : .vertical, draggable: !portrait)
    }

    private func setFrame(_ view: NSView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// 从布局里量出算法要的尺寸。
    func adaptiveMetrics(size: NSSize) -> MainLayoutMetrics {
        let cell = inputStrip.cellSize
        return MainLayoutMetrics(size: size, canvas: canvasSize, mixerVisible: adaptiveMixerVisible,
                                 mixerWidth: clampedMixerWidth(layoutPreferences?.mixerWidth ?? Theme.mixerPanelWidth, totalWidth: size.width),
                                 tierHeights: TransitionPanelView.ColumnTier.allCases.map { transitionPanel.fittingHeight(of: $0) },
                                 allowedTiers: allowedColumnTiers.map(\.rawValue),
                                 monitorTitleHeight: Theme.monitorTitleHeight, columnWidth: Theme.transitionColumnWidth,
                                 gap: MainLayoutView.monitorGap, divider: MainLayoutView.dividerThickness,
                                 stripHeader: InputStripView.headerHeight, stripInset: InputStripView.stackInset, cellSpacing: InputStripView.itemSpacing,
                                 cell: cell, compactCell: cell, preferredBottomHeight: layoutPreferences?.bottomRowHeight)
    }

    /// 调音台宽：不窄于 340；输入区至少留一列格子。
    private func clampedMixerWidth(_ width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let inputMinimum = InputStripView.stackInset + inputStrip.cellSize.width + InputStripView.itemSpacing
        let upper = max(Theme.mixerPanelWidth, totalWidth - MainLayoutView.dividerThickness - inputMinimum)
        return min(max(width, Theme.mixerPanelWidth), upper).rounded()
    }

    // MARK: 分隔条（规则 7）

    func configureDividers() {
        let top = layoutView.topDivider
        top.onDragBegan = { [weak self] in self?.dragStartTop = self?.arrangementResult?.topHeight }
        top.onDragged = { [weak self] delta in self?.dragTopDivider(by: delta) }
        top.onDragEnded = { [weak self] in self?.dragStartTop = nil }
        let mixer = layoutView.mixerDivider
        mixer.onDragBegan = { [weak self] in self?.dragStartMixerWidth = self?.mixerPanel.frame.width }
        mixer.onDragged = { [weak self] delta in self?.dragMixerDivider(by: delta) }
        mixer.onDragEnded = { [weak self] in self?.dragStartMixerWidth = nil }
    }

    /// 上下之间：往上拖（delta < 0）让下边一行更高、监看等比变小；往下最多拖到贴合高（拖到那里 = 按规则排，不存位置）；最矮那一档要放得下。
    private func dragTopDivider(by delta: CGFloat) {
        guard let start = dragStartTop, let result = arrangementResult, result.mode != .portrait else { return }
        let availH = layoutView.bounds.height
        let top = min(result.fitTopHeight, max(result.minTopHeight, (start + delta).rounded()))
        layoutPreferences?.bottomRowHeight = top >= result.fitTopHeight - 0.5 ? nil : availH - MainLayoutView.dividerThickness - top
        layoutView.needsLayout = true
        layoutView.layoutSubtreeIfNeeded()
    }

    /// 输入 ｜ 调音台之间：往左拖调音台变宽（宽度存本机），往右不窄于 340；拖过 340 的一半收起调音台（同旧排布 NSSplitView 拖到底收起）。
    private func dragMixerDivider(by delta: CGFloat) {
        guard let start = dragStartMixerWidth, arrangementResult?.mode != .portrait else { return }
        let proposed = start - delta
        if proposed < Theme.mixerPanelWidth / 2 {
            if adaptiveMixerVisible { setAdaptiveMixerVisible(false) }
            return
        }
        let width = clampedMixerWidth(proposed, totalWidth: layoutView.bounds.width)
        layoutPreferences?.mixerWidth = width <= Theme.mixerPanelWidth + 0.5 ? nil : width
        if !adaptiveMixerVisible { setAdaptiveMixerVisible(true) }
        layoutView.needsLayout = true
        layoutView.layoutSubtreeIfNeeded()
    }
}
