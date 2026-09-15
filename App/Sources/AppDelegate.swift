// Switcher App —— AppKit 主程序（W2-B：显示路径 + 主界面骨架）。
// 启动：建主窗口 → 恢复上次节目（测试宿主用空节目）→ 起引擎。退出：自动保存 → 停引擎。
// 菜单：节目（新建 / 打开 / 最近 / 保存 / 另存）、输入（添加）、切换（Cut / Fade / FTB，快捷键见 KeyCommandMap）、窗口（调音台）。
import AppKit
import SwitcherContracts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: AppController!
    private var recentMenu: NSMenu?
    /// `--stats <路径>`：把每秒的 Stats 也写进 stats.jsonl（排障 / 对照测试）。
    private var statsLogURL: URL?
    /// `--show <路径>`：启动时打开这个节目文件（不走"上次"）。
    private var showURL: URL?

    /// 在 xctest 宿主里（不恢复上次节目、不弹错误框）。
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        controller = AppController(isTestHost: Self.isTestHost)
        buildMenu()
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--stats"), i + 1 < args.count {
            statsLogURL = URL(fileURLWithPath: args[i + 1])
        }
        if let i = args.firstIndex(of: "--show"), i + 1 < args.count {
            showURL = URL(fileURLWithPath: args[i + 1])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await controller.launch(showURL: showURL)
            if let url = statsLogURL {
                do { try controller.session?.startStatsLog(url: url) } catch { NSLog("stats.jsonl 打不开：\(error)") }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { await controller.openShow(url: URL(fileURLWithPath: filename)) }
        return true
    }

    // MARK: 菜单

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Switcher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Switcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Switcher"))

        let show = NSMenu(title: "节目")
        show.addItem(withTitle: "新建", action: #selector(newShow), keyEquivalent: "n")
        show.addItem(withTitle: "打开…", action: #selector(openShow), keyEquivalent: "o")
        let recent = NSMenu(title: "打开最近")
        recentMenu = recent
        show.addItem(submenu(recent, title: "打开最近"))
        show.addItem(.separator())
        show.addItem(withTitle: "保存", action: #selector(saveShow), keyEquivalent: "s")
        let saveAs = show.addItem(withTitle: "另存为…", action: #selector(saveShowAs), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu(show, title: "节目"))

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "编辑"))

        let input = NSMenu(title: "输入")
        input.addItem(withTitle: "添加输入…", action: #selector(addInput), keyEquivalent: "i")
        main.addItem(submenu(input, title: "输入"))

        let transition = NSMenu(title: "切换")
        transition.addItem(withTitle: "Cut（空格）", action: #selector(cut), keyEquivalent: "")
        transition.addItem(withTitle: "Fade（回车）", action: #selector(fade), keyEquivalent: "")
        transition.addItem(withTitle: "FTB（F）", action: #selector(ftb), keyEquivalent: "")
        transition.addItem(.separator())
        for row in KeyCommandMap.table {
            let item = transition.addItem(withTitle: "\(row.key)：\(row.action)", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        main.addItem(submenu(transition, title: "切换"))

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "调音台", action: #selector(toggleMixer), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "窗口"))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
        rebuildRecentMenu()
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func rebuildRecentMenu() {
        guard let recentMenu else { return }
        recentMenu.removeAllItems()
        let urls = controller.documents.recentURLs
        for url in urls {
            let item = recentMenu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
        }
        if urls.isEmpty {
            recentMenu.addItem(withTitle: "（无）", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            recentMenu.addItem(.separator())
            recentMenu.addItem(withTitle: "清除列表", action: #selector(clearRecents), keyEquivalent: "")
        }
    }

    @objc private func newShow() { Task { await controller.newShow(); rebuildRecentMenu() } }
    @objc private func openShow() { controller.openShowPanel() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { await controller.openShow(url: url); rebuildRecentMenu() }
    }
    @objc private func clearRecents() { controller.documents.clearRecents(); rebuildRecentMenu() }
    @objc private func saveShow() { controller.save(); rebuildRecentMenu() }
    @objc private func saveShowAs() { controller.saveAs() }
    @objc private func addInput() { controller.windowController.presentAddInput() }
    @objc private func cut() { controller.session?.send(.cut) }
    @objc private func fade() {
        guard let s = controller.session else { return }
        s.send(.fade(durationTicks: s.state.transition.durationTicks))
    }
    @objc private func ftb() {
        guard let s = controller.session else { return }
        s.send(.ftb(on: !s.state.ftb.on))
    }
    @objc private func toggleMixer() { controller.windowController.toggleMixerPanel() }
}
