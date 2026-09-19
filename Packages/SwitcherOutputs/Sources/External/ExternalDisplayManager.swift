import AppKit
import SwitcherContracts
import SwitcherRender

/// 多个外部显示窗口，跟着快照的输出表增删（一个 `kind = .externalDisplay` 且 enabled 的输出 = 一个窗口，键 = 输出编号）。
/// 显示器插拔：观察 `NSApplication.didChangeScreenParametersNotification`，让每个窗口重新找目标屏。
@MainActor
public final class ExternalDisplayManager {
    public private(set) var windows: [Int: ExternalDisplayWindow] = [:]
    /// 纹理来源（换 session 时换）。
    public var source: (any DisplayFrameSource)? {
        didSet { for w in windows.values { w.source = source } }
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
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 让窗口表跟上快照：enabled 的外部显示输出各一个窗口，设置变了就更新，消失 / 关掉的关窗口。
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
                w.update(spec: spec)
                w.apply(inputs: inputs, textureWidth: format.width, textureHeight: format.height)
            } else {
                let w = ExternalDisplayWindow(spec: spec, source: source, inputs: inputs, textureWidth: format.width, textureHeight: format.height)
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

    /// 某个窗口的状态文案（状态行 / 菜单用）。
    public static func describe(_ status: ExternalDisplayWindow.Status) -> String {
        switch status {
        case .showing(let id): "显示中（显示器 \(id)）"
        case .waitingForDisplay(let id): "等待显示器 \(id) 接上"
        case .fallbackToMain(let id): "显示器 \(id) 不在，暂用主显示器"
        }
    }
}
