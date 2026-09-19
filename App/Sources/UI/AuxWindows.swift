// 多画面独立窗口与外部显示窗口（W3-E 交付第 5 条；设计方案 §8 外部显示 / 多画面、§10 各自独立窗口）。
// 两者都是 MetalDisplayView（display link 各自刷新，渲染线程不碰 drawable）。外部显示 = 全屏 NSWindow 在指定显示器，
// 源可选 PGM / PVW / 多画面 / 任一输入（Aux 语义；任一输入 = 多画面纹理里那一格）。W3-C 的 ExternalDisplayOutput 合入后可换成它。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class MultiviewWindowController: NSWindowController {
    let display = MetalDisplayView(frame: .zero)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("multiview.windowTitle")
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setFrameAutosaveName("MultiviewWindow")
        super.init(window: window)
        display.target = .multiview
        display.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(display)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                display.topAnchor.constraint(equalTo: content.topAnchor),
                display.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                display.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                display.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bind(source: (any DisplayFrameSource)?) { display.source = source }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ExternalDisplayWindowController: NSWindowController, NSWindowDelegate {
    let outputNumber: Int
    let display = MetalDisplayView(frame: .zero)
    /// 用户关掉窗口（不是跟着快照关的）→ 移除该输出。
    var onUserClose: (() -> Void)?
    private var closingFromState = false
    private let fullScreen: Bool
    private var screenNumber: UInt32?

    init(outputNumber: Int, fullScreen: Bool) {
        self.outputNumber = outputNumber
        self.fullScreen = fullScreen
        let style: NSWindow.StyleMask = fullScreen ? [.borderless] : [.titled, .closable, .resizable]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.title = L("external.windowTitle", outputNumber)
        if fullScreen {
            window.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hidesOnDeactivate = false
        }
        super.init(window: window)
        window.delegate = self
        display.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(display)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                display.topAnchor.constraint(equalTo: content.topAnchor),
                display.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                display.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                display.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 跟快照：屏幕、来源（PGM / PVW / 多画面 / 输入 n = 多画面纹理里那一格）。
    func apply(output: OutputState, state: MixerState, textureWidth: Int, textureHeight: Int) {
        switch output.settings.source {
        case .program:
            display.target = .program
            display.sourceRect = .full
        case .preview:
            display.target = .preview
            display.sourceRect = .full
        case .multiview:
            display.target = .multiview
            display.sourceRect = .full
        case .input(let n):
            display.target = .multiview
            if let index = state.inputs.firstIndex(where: { $0.number == n }),
               let cell = MultiviewLayout.inputCell(index: index, inputCount: state.inputs.count, width: textureWidth, height: textureHeight) {
                display.sourceRect = cell
            } else {
                display.sourceRect = .full
            }
        }
        let number = OutputExtras.displayNumber(of: output)
        if number != screenNumber {
            screenNumber = number
            if let number, let screen = NSScreen.screen(number: number) {
                if fullScreen {
                    window?.setFrame(screen.frame, display: true)
                } else {
                    window?.setFrame(NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 400, width: 640, height: 360), display: true)
                }
            }
        }
        window?.title = L("external.windowTitle", outputNumber) + " — " + output.settings.source.title(in: state)
    }

    func bind(source: (any DisplayFrameSource)?) { display.source = source }

    func present() {
        showWindow(nil)
        window?.orderFront(nil)
    }

    /// 输出从快照里消失：关窗口，不再回发 removeOutput。
    func closeFromState() {
        closingFromState = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingFromState { onUserClose?() }
    }
}
