import AppKit
import Metal
import SwitcherContracts
import SwitcherRender

/// 多个外部显示窗口，跟着快照的输出表增删（一个 `kind = .externalDisplay` 且 enabled 的输出 = 一个窗口，键 = 输出编号）。
/// 显示器插拔：观察 `NSApplication.didChangeScreenParametersNotification`，让每个窗口重新找目标屏。
/// Aux（源 = 输入 n）的全分辨率画面要组装方给 `auxFrames`（每路开一个帧槽分支）；运行状态、"无信号"文案、主屏层级都是包内选项，
/// 设在管理器上就下发到每个窗口（现有的和以后开的）。
@MainActor
public final class ExternalDisplayManager {
    public private(set) var windows: [Int: ExternalDisplayWindow] = [:]
    /// 纹理来源（换 session 时换）。
    public var source: (any DisplayFrameSource)? {
        didSet { for w in windows.values { w.source = source } }
    }
    /// Aux 的帧来源（App：InputRuntime.openBranch / releaseBranch）。nil = Aux 窗口画占位。
    public var auxFrames: AuxFrameTap? {
        didSet { for w in windows.values { w.auxFrames = auxFrames } }
    }
    /// Aux 那路输入的运行状态（App：InputRuntime.runtimeState，与多画面缩略格子的"无信号"同一个来源）。
    public var inputStateProvider: (@MainActor (Int) -> InputState?)? {
        didSet { for w in windows.values { w.inputStateProvider = inputStateProvider } }
    }
    /// Aux 占位的"无信号"文案（App 按本地化表给 input.noSignal）。
    public var noSignalText = AuxInputPresenter.defaultNoSignalText {
        didSet { for w in windows.values { w.noSignalText = noSignalText } }
    }
    /// 窗口开在主屏上时是否盖住主界面（默认盖住 = W3-C 起的行为）。
    public var mainScreenLayering: ExternalDisplayWindow.MainScreenLayering = .front {
        didSet { for w in windows.values { w.mainScreenLayering = mainScreenLayering } }
    }
    /// 某个窗口的状态变了（编号、状态）。
    public var onStatusChange: ((Int, ExternalDisplayWindow.Status) -> Void)?
    /// 用户在某个窗口按了 Esc（编号）；组装方删那个输出。
    public var onCloseRequested: ((Int) -> Void)?
    /// 显示器参数变化的次数（测试看）。
    public private(set) var screenChanges = 0
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?
    private var lastInputs: [InputConfig] = []
    private var textureSize = (width: 1920, height: 1080)

    public init(source: (any DisplayFrameSource)?) {
        self.source = source
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
        // Aux 的着色器在后台先编好（约 80 ms），开 Aux 窗口时不在主线程等
        if let device = MTLCreateSystemDefaultDevice() { AuxPipeline.prepare(for: device) }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 让窗口表跟上快照：enabled 的外部显示输出各一个窗口，设置变了就更新，消失 / 关掉的关窗口（关窗口会还掉 Aux 的帧槽分支）。
    /// 输入表变了也要调（Aux 那路被删 / 换来源 / 改名）。
    public func reconcile(outputs: [OutputState], inputs: [InputConfig], format: ProgramFormat) {
        lastInputs = inputs
        textureSize = (format.width, format.height)
        let wanted = outputs.filter { $0.kind == .externalDisplay && $0.enabled }
        let wantedNumbers = Set(wanted.map(\.number))
        for (n, w) in windows where !wantedNumbers.contains(n) {
            w.closeOutput()
            windows.removeValue(forKey: n)
        }
        for output in wanted {
            let spec = ExternalDisplaySpec(settings: output.settings)
            if let w = windows[output.number] {
                w.apply(inputs: inputs, textureWidth: format.width, textureHeight: format.height)
                w.update(spec: spec)
            } else {
                let w = ExternalDisplayWindow(spec: spec, source: source, inputs: inputs, textureWidth: format.width, textureHeight: format.height,
                                              auxFrames: auxFrames, mainScreenLayering: mainScreenLayering)
                w.inputStateProvider = inputStateProvider
                w.noSignalText = noSignalText
                let number = output.number
                w.onStatusChange = { [weak self] status in self?.onStatusChange?(number, status) }
                w.onCloseRequested = { [weak self] in self?.onCloseRequested?(number) }
                windows[number] = w
                onStatusChange?(number, w.status)
            }
        }
    }

    /// 关掉全部（换节目 / 退出）。
    public func closeAll() {
        for w in windows.values { w.closeOutput() }
        windows.removeAll()
    }

    /// 显示器变了：每个窗口重新找目标屏。
    public func screensDidChange() {
        screenChanges += 1
        for w in windows.values { w.screensDidChange() }
    }

    /// 每个外部显示窗口在 Stats 里的一项（提案 013，铁律 4；W3-C2 复核）：
    /// - frames = 这个窗口累计呈现的帧（PGM / PVW / 多画面的 blit + Aux 画出去的输入帧；换源不清零，占位不算）；
    /// - dropped = 没赶上显示刷新的帧 = 引擎给了新帧、两次刷新之间就被覆盖的：PGM / PVW / 多画面按渲染器版本号跳过的个数
    ///   （DisplayFrameLedger），Aux 按该路帧槽分支两次刷新之间挤掉 / 跳过的帧（AuxInputPresenter）；窗口收起 / 被遮住 / 换源期间不记；
    /// - state：showing → "presenting"；waitingForDisplay（黑着等）/ fallbackToMain（暂用主屏）→ "noDisplay"（目标显示器不在）。
    public var statsEntries: [Stats.DisplayEntry] {
        windows.map { (number, w) in
            let name: String
            switch w.status {
            case .showing: name = "presenting"
            case .waitingForDisplay, .fallbackToMain: name = "noDisplay"
            }
            return Stats.DisplayEntry(output: number, kind: "externalDisplay", frames: w.presentedFrames, dropped: w.droppedFrames, state: name)
        }
        .sorted { $0.output < $1.output }
    }

    /// 某个窗口的状态文案（状态行 / 菜单用）。
    public static func describe(_ status: ExternalDisplayWindow.Status) -> String {
        switch status {
        case .showing(let id): "显示中（显示器 \(id)）"
        case .waitingForDisplay(let id): "等待显示器 \(id) 接上"
        case .fallbackToMain(let id): "显示器 \(id) 不在，暂用主显示器"
        }
    }
}
