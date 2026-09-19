// Switcher App —— AppKit 主程序（W2-B：显示路径 + 主界面骨架；W2-B2：接上输入 / 命令 / API / 音频 / 录制 / 推流 / Stats；W3-E：设置面板与窗口）。
// 启动：建主窗口 → 恢复上次节目（测试宿主用空节目）→ 起引擎。退出：自动保存 → 停引擎。
// 菜单：Switcher（偏好设置）、节目（新建 / 打开 / 最近 / 保存 / 另存）、输入（添加 / 设置）、切换（Cut / Fade / FTB / 快捷键编辑器 / MIDI 映射）、
// 输出（录制 / ISO / 推流 / 外部输出 / NDI / 虚拟摄像头设置）、窗口（调音台 / 多画面 / 外部显示）。文案全部走 L10n。
import AppKit
import SwitcherContracts
import SwitcherControl

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var controller: AppController!
    private var recentMenu: NSMenu?
    private var externalDisplayItem: NSMenuItem?
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
        appMenu.addItem(withTitle: L("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.preferences"), action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Switcher"))

        let show = NSMenu(title: L("menu.show"))
        show.addItem(withTitle: L("menu.show.new"), action: #selector(newShow), keyEquivalent: "n")
        show.addItem(withTitle: L("menu.show.open"), action: #selector(openShow), keyEquivalent: "o")
        let recent = NSMenu(title: L("menu.show.openRecent"))
        recentMenu = recent
        show.addItem(submenu(recent, title: L("menu.show.openRecent")))
        show.addItem(.separator())
        show.addItem(withTitle: L("menu.show.save"), action: #selector(saveShow), keyEquivalent: "s")
        let saveAs = show.addItem(withTitle: L("menu.show.saveAs"), action: #selector(saveShowAs), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu(show, title: L("menu.show")))

        let edit = NSMenu(title: L("menu.edit"))
        edit.addItem(withTitle: L("menu.edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("menu.edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("menu.edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("menu.edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("menu.edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("menu.edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: L("menu.edit")))

        let input = NSMenu(title: L("menu.input"))
        input.addItem(withTitle: L("menu.input.add"), action: #selector(addInput), keyEquivalent: "i")
        input.addItem(withTitle: L("menu.input.settings"), action: #selector(inputSettings), keyEquivalent: "I")
        main.addItem(submenu(input, title: L("menu.input")))

        let transition = NSMenu(title: L("menu.transition"))
        transition.addItem(withTitle: "Cut", action: #selector(cut), keyEquivalent: "")
        transition.addItem(withTitle: "Fade", action: #selector(fade), keyEquivalent: "")
        transition.addItem(withTitle: "FTB", action: #selector(ftb), keyEquivalent: "")
        transition.addItem(.separator())
        transition.addItem(withTitle: L("menu.transition.hotkeys"), action: #selector(showHotkeys), keyEquivalent: "")
        transition.addItem(withTitle: L("menu.transition.midi"), action: #selector(showMIDI), keyEquivalent: "")
        main.addItem(submenu(transition, title: L("menu.transition")))

        let output = NSMenu(title: L("menu.output"))
        for (title, tab) in [(L("menu.output.record"), OutputSettingsModel.Tab.record), (L("menu.output.iso"), .iso), (L("menu.output.stream"), .stream),
                             (L("menu.output.external"), .external), (L("menu.output.ndi"), .ndi), (L("menu.output.virtualCamera"), .virtualCamera)] {
            let item = output.addItem(withTitle: title, action: #selector(outputSettings(_:)), keyEquivalent: "")
            item.representedObject = tab.rawValue
        }
        main.addItem(submenu(output, title: L("menu.output")))

        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(withTitle: L("menu.window.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("menu.window.zoom"), action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("menu.window.mixer"), action: #selector(toggleMixer), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("menu.window.multiview"), action: #selector(showMultiview), keyEquivalent: "")
        let external = NSMenuItem(title: L("menu.externalDisplay"), action: nil, keyEquivalent: "")
        external.submenu = NSMenu(title: L("menu.externalDisplay"))
        external.submenu?.delegate = self
        windowMenu.addItem(external)
        externalDisplayItem = external
        main.addItem(submenu(windowMenu, title: L("menu.window")))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
        rebuildRecentMenu()
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// "外部显示"子菜单每次打开时按当前屏幕 / 输入重建。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === externalDisplayItem?.submenu else { return }
        menu.removeAllItems()
        for item in controller.panels.makeExternalDisplayMenu().items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
        for item in menu.items where item.submenu != nil {
            for sub in item.submenu?.items ?? [] where sub.target == nil { sub.target = controller.panels }
        }
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
            recentMenu.addItem(withTitle: L("menu.show.noRecent"), action: nil, keyEquivalent: "").isEnabled = false
        } else {
            recentMenu.addItem(.separator())
            recentMenu.addItem(withTitle: L("menu.show.clearRecent"), action: #selector(clearRecents), keyEquivalent: "")
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
    /// 输入设置：PVW 上那一路，没有就第一路。
    @objc private func inputSettings() {
        guard let s = controller.session else { return }
        let number = s.state.preview != MixerState.noInput ? s.state.preview : (s.state.inputs.first?.number ?? 0)
        guard number != MixerState.noInput else { return }
        controller.panels.showInputSettings(input: number)
    }
    @objc private func cut() { controller.session?.send(.cut) }
    @objc private func fade() {
        guard let s = controller.session else { return }
        s.send(.fade(durationTicks: s.state.transition.durationTicks))
    }
    @objc private func ftb() {
        guard let s = controller.session else { return }
        s.send(.ftb(on: !s.state.ftb.on))
    }
    @objc private func showHotkeys() { controller.panels.showHotkeyEditor() }
    @objc private func showMIDI() { controller.panels.showMIDIMapping() }
    @objc private func showPreferences() { controller.panels.showPreferences() }
    @objc private func outputSettings(_ sender: NSMenuItem) {
        let tab = (sender.representedObject as? String).flatMap(OutputSettingsModel.Tab.init(rawValue:)) ?? .record
        controller.panels.showOutputSettings(tab: tab)
    }
    @objc private func toggleMixer() { controller.windowController.toggleMixerPanel() }
    @objc private func showMultiview() { controller.panels.showMultiview() }
}
