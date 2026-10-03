// 要先问一声才做的界面操作（W5-B，02 X01–X05 / X13 / X30、01a E11 / A3 / F5 / D9）：停录制 / 推流、换节目 / 换格式 / 重起引擎、退出、
// 删 PGM 上的那一路……都在这里弹 NSAlert sheet。只有界面入口（底栏按钮、菜单、偏好设置、格子右键）走这里；快捷键 / MIDI / API 直接发命令，
// 一律不问（E11）。测试宿主照样真弹 sheet：测试从 `pending(_:)` 拿到正在问的那一个，用 `respond(_:)` 按按钮回答（按钮的 performClick，
// 与用户点的是同一条路）。
// 按钮点下的那一刻就回调，sheet 晚一点再收：NSAlert 自己的 completion 要等收起动画走完，而收起动画（endSheet）把主线程整个占住 ~0.27 s——
// 期间 Timer、主队列、主线程上的 Task 都不跑（探针见 reports/w5-app-safety.md §5），命令循环送不进总线、快照分发也不跑，运行表定停止边界就晚了 15 帧。
// 所以先回调（命令发出去），等 dismissDelay（够命令进总线、下一次快照分发让运行表按生效拍定好起止拍）再收 sheet。
import AppKit

@MainActor
final class ConfirmationCenter {
    static let shared = ConfirmationCenter()

    enum Kind: String, CaseIterable, Sendable {
        /// 底栏停录制 / 停推流（偏好设置 › 操作确认里可以关）。
        case stopRecord, stopStream
        /// 新建 / 打开节目、退出时录制 / 推流还在跑。
        case replaceShow
        /// 偏好设置里换节目格式 / 节目音频 / "应用并重起引擎"时录制 / 推流还在跑。
        case restartEngine
        /// 节目有未保存的改动：保存 / 不保存 / 取消。
        case saveChanges
        /// 删的那一路在 PGM / PVW / 叠加 / Stinger / ISO 录制上。
        case removeInput
        /// 设置窗里快捷键 / MIDI 表有没存的改动：关窗或切页前 保存 / 放弃 / 取消（W5-J，X29）。
        case unsavedSettings
        /// 导入设置 / 恢复默认会覆盖本机设置与快捷键 / MIDI 表（W5-J，F6）。
        case resetSettings
    }

    /// 被点的按钮：confirm = 做（停、换、删、保存）；alternate = 另一种做法（"不保存"）；cancel = 什么都不做。
    enum Choice: Equatable, Sendable { case confirm, alternate, cancel }

    struct Button: Equatable {
        var title: String
        var choice: Choice
        /// 破坏性操作（系统画成红字）。
        var destructive = false
    }

    struct Request: Equatable {
        var kind: Kind
        var title: String
        var message: String
        /// 显示顺序（第一个在最右）。
        var buttons: [Button]
        /// 回车落在哪个按钮上；nil = 回车不做任何事（停止 / 换节目 / 删除这类确认：误按回车不会停，要点一下按钮）。Esc 总是"取消"。
        var defaultChoice: Choice?
    }

    /// 正在问的一个（主线程：AppKit 在主线程上调按钮的 action）。
    @MainActor
    final class Pending: NSObject {
        let request: Request
        let alert: NSAlert
        private(set) weak var window: NSWindow?
        /// 点下按钮时调（按钮下标）。
        fileprivate var onButton: ((Int) -> Void)?
        init(request: Request, alert: NSAlert, window: NSWindow?) {
            self.request = request
            self.alert = alert
            self.window = window
        }
        var buttonTitles: [String] { request.buttons.map(\.title) }

        /// 按钮的 target（NSAlert 的按钮改指到这里：点下就回调，不等收起动画）。
        @objc fileprivate func buttonClicked(_ sender: NSButton) { onButton?(sender.tag) }
    }

    /// 点下按钮到收 sheet 之间留的时间（见文件头）。
    static let dismissDelay: Duration = .milliseconds(120)

    private var pendings: [Pending] = []
    /// 每种问过几次（测试看"没问"）。
    private(set) var askedCount: [Kind: Int] = [:]

    /// 正在问的（某种的）最近一个。
    func pending(_ kind: Kind? = nil) -> Pending? {
        guard let kind else { return pendings.last }
        return pendings.last { $0.request.kind == kind }
    }

    /// 弹 sheet 问一声；completion 收到被点的按钮（sheet 收起时、在主线程）。同一个窗口上已经有一问没答完：这一问直接当"取消"（菜单栏不被 sheet 挡住，
    /// 问的过程中又按 ⌘N 之类不会叠出第二个）。window 为 nil 时挂到主窗口。
    func ask(_ request: Request, in window: NSWindow?, completion: @escaping @MainActor (Choice) -> Void) {
        askedCount[request.kind, default: 0] += 1
        guard let host = window ?? NSApp.mainWindow ?? NSApp.keyWindow else {
            completion(.cancel)
            return
        }
        if pendings.contains(where: { $0.window === host }) {
            NSSound.beep()
            completion(.cancel)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        let entry = Pending(request: request, alert: alert, window: host)
        for (i, b) in request.buttons.enumerated() {
            let button = alert.addButton(withTitle: b.title)
            button.hasDestructiveAction = b.destructive
            button.keyEquivalent = ""
            button.tag = i
            button.target = entry
            button.action = #selector(Pending.buttonClicked(_:))
        }
        if let d = request.defaultChoice, let i = request.buttons.firstIndex(where: { $0.choice == d }) {
            alert.buttons[i].keyEquivalent = "\r"
        }
        if let i = request.buttons.firstIndex(where: { $0.choice == .cancel }), alert.buttons[i].keyEquivalent.isEmpty {
            alert.buttons[i].keyEquivalent = "\u{1b}"
        }
        pendings.append(entry)
        // 窗口最小化了 / App 在后台（从程序坞退出、注销时）：sheet 没人看得见，退出就一直等着——先还原窗口、叫到前台
        if host.isMiniaturized { host.deminiaturize(nil) }
        if !NSApp.isActive { NSApp.activate() }
        var answered = false
        let finish: @MainActor (Choice) -> Void = { [weak self] choice in
            guard !answered else { return }
            answered = true
            self?.pendings.removeAll { $0 === entry }
            completion(choice)
        }
        // 点下按钮：先回调（停 / 换 / 删在这一刻发生），dismissDelay 之后再收 sheet（收起动画占住主线程，见文件头）
        entry.onButton = { [weak host] i in
            finish(request.buttons[i].choice)
            for b in alert.buttons { b.isEnabled = false }   // 回答过了：收起之前再点不算
            Task { @MainActor in
                try? await Task.sleep(for: Self.dismissDelay)
                host?.endSheet(alert.window, returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + i))
            }
        }
        // sheet 因为别的原因收掉（窗口关了）：当"取消"
        alert.beginSheetModal(for: host) { _ in
            MainActor.assumeIsolated { finish(.cancel) }
        }
    }

    /// 按正在问的（某种的）那一个上的按钮（测试；与用户点同一条路：按钮的 performClick → sheet 收起 → completion）。
    func respond(_ choice: Choice, kind: Kind? = nil) {
        guard let p = pending(kind), let i = p.request.buttons.firstIndex(where: { $0.choice == choice }) else { return }
        p.alert.buttons[i].performClick(nil)
    }

    /// 收掉所有没答完的（测试收尾：上一条用例失败时留下的 sheet 不挡下一条）。
    func dismissAll() {
        for p in pendings.reversed() {
            if let i = p.request.buttons.firstIndex(where: { $0.choice == .cancel }) { p.alert.buttons[i].performClick(nil) }
        }
        pendings.removeAll()
    }
}
