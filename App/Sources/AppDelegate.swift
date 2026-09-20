// Switcher App —— AppKit 主程序（W2-B：显示路径 + 主界面骨架；W2-B2：接上输入 / 命令 / API / 音频 / 录制 / 推流 / Stats）。
// 启动：建主窗口 → 恢复上次节目（测试宿主用空节目）→ 起引擎。退出：自动保存 → 停引擎。
// 菜单：节目（新建 / 打开 / 最近 / 保存 / 另存）、输入（添加）、切换（Cut / Fade / FTB；快捷键表来自 HotkeyTable）、
// 输出（W3-C：ISO 分路、外部输出、多画面窗口、虚拟摄像头的安装 / 卸载 / 启用）、窗口（调音台 / 多画面）。
// 启动参数与设置见 AppSettings。
import AppKit
import SwitcherContracts
import SwitcherControl
import SwitcherVirtualCamera

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: AppController!
    private var recentMenu: NSMenu?
    private var externalMenuItem: NSMenuItem?
    private var virtualCameraStatusItem: NSMenuItem?
    private var settings = AppSettings()

    /// 在 xctest 宿主里（不恢复上次节目、不弹错误框）。
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        controller = AppController(isTestHost: Self.isTestHost)
        settings = AppSettings.load(arguments: ProcessInfo.processInfo.arguments, defaults: controller.defaults)
        controller.settings = settings
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await controller.launch(showURL: settings.showURL)
            if let url = settings.statsURL {
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
        transition.addItem(withTitle: "Cut", action: #selector(cut), keyEquivalent: "")
        transition.addItem(withTitle: "Fade", action: #selector(fade), keyEquivalent: "")
        transition.addItem(withTitle: "FTB", action: #selector(ftb), keyEquivalent: "")
        transition.addItem(.separator())
        // 快捷键表（用户表 hotkeys.json 或默认表）：只列出来看，改表编辑器是 W3-E 的
        let table = controller.hotkeyTable
        let header = transition.addItem(withTitle: "快捷键（\(table == .default ? "默认表" : HotkeyTable.defaultFileURL.path)）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        for b in table.bindings.prefix(40) {
            let item = transition.addItem(withTitle: "\(b.key)：\(b.note ?? "\(b.action)")", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        main.addItem(submenu(transition, title: "切换"))

        // W3-C：输出菜单
        let output = NSMenu(title: "输出")
        output.delegate = self
        output.addItem(withTitle: "ISO 分路录制…", action: #selector(isoPanel), keyEquivalent: "")
        let external = NSMenuItem(title: "外部输出", action: nil, keyEquivalent: "")
        external.submenu = NSMenu(title: "外部输出")
        output.addItem(external)
        externalMenuItem = external
        output.addItem(withTitle: "多画面窗口", action: #selector(toggleMultiview), keyEquivalent: "")
        output.addItem(.separator())
        let camera = NSMenu(title: "虚拟摄像头")
        camera.addItem(withTitle: "启用 / 停用虚拟摄像头输出", action: #selector(toggleVirtualCamera), keyEquivalent: "")
        camera.addItem(.separator())
        camera.addItem(withTitle: "安装 / 激活扩展…", action: #selector(installExtension), keyEquivalent: "")
        camera.addItem(withTitle: "卸载扩展", action: #selector(uninstallExtension), keyEquivalent: "")
        camera.addItem(withTitle: "查询扩展状态", action: #selector(refreshExtension), keyEquivalent: "")
        camera.addItem(.separator())
        let status = camera.addItem(withTitle: "状态：未知", action: nil, keyEquivalent: "")
        status.isEnabled = false
        virtualCameraStatusItem = status
        output.addItem(submenu(camera, title: "虚拟摄像头"))
        main.addItem(submenu(output, title: "输出"))

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "调音台", action: #selector(toggleMixer), keyEquivalent: "")
        windowMenu.addItem(withTitle: "多画面", action: #selector(toggleMultiview), keyEquivalent: "")
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

    // MARK: 输出（W3-C）

    @objc private func isoPanel() { controller.windowController.presentISOPanel(relativeTo: controller.windowController.bottomBar.isoButton) }
    @objc private func toggleMultiview() { controller.windowController.toggleMultiviewWindow() }

    /// 有 enabled 的虚拟摄像头输出就删掉（停），没有就加一个（起）。
    @objc private func toggleVirtualCamera() {
        guard let s = controller.session else { return }
        if let existing = s.state.outputs.first(where: { $0.kind == .virtualCamera }) {
            s.send(.removeOutput(output: existing.number))
        } else {
            let number = (s.state.outputs.map(\.number).max() ?? 0) + 1
            s.send(.addOutput(config: OutputState(number: number, kind: .virtualCamera, name: "虚拟摄像头", enabled: true, settings: OutputSettings(source: .program))))
        }
    }

    @objc private func installExtension() { controller.session?.aux.installer.activate() }
    @objc private func uninstallExtension() { controller.session?.aux.installer.deactivate() }
    @objc private func refreshExtension() { controller.session?.aux.installer.refresh() }
}

extension AppDelegate: NSMenuDelegate {
    /// 打开"输出"菜单时重建外部输出子菜单（显示器 × 源，按当前快照打勾）和虚拟摄像头状态行。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "输出" else { return }
        if let item = externalMenuItem {
            item.submenu = controller.windowController.externalOutputMenu() ?? NSMenu(title: "外部输出")
        }
        if let status = virtualCameraStatusItem, let s = controller.session {
            status.title = "状态：扩展 \(SystemExtensionInstaller.describe(s.aux.installer.status))；输出 \(s.aux.virtualCameraStatusText)"
        }
    }
}
