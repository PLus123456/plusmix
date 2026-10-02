// Switcher App —— AppKit 主程序（W2-B：显示路径 + 主界面骨架；W2-B2：接上输入 / 命令 / API / 音频 / 录制 / 推流 / Stats；W3-E：设置面板与窗口）。
// 启动：建主窗口 → 恢复上次节目（测试宿主用空节目）→ 起引擎。退出：先问（录制 / 推流在跑、有未保存的改动，W5-B）→ LastSession 照存 → 停引擎。
// 新建 / 打开 / 打开最近 / Finder 双击打开同样先问（AppController.requestNewShow / requestOpenShow）。
// 菜单：App 菜单（标题是产品名 PlusMix，W4-D：关于 / 检查更新 / 偏好设置）、节目（新建 / 打开 / 最近 / 保存 / 另存）、输入（添加 / 设置）、切换（Cut / Fade / FTB / 快捷键编辑器 / MIDI 映射）、
// 输出（W3-E：录制 / ISO / 推流 / 外部输出 / NDI / 虚拟摄像头设置页；W3-C：外部输出子菜单、多画面窗口、虚拟摄像头的安装 / 卸载 / 启用）、
// 窗口（调音台 / 多画面）、帮助（W4-B：导出诊断包 / 打开诊断文件夹；App 菜单加"检查更新…"）。文案全部走 L10n（W3-C 那几项 W3-E2 补齐；包里返回中文的状态在 App 侧查表，OutputStatusText）。启动参数与设置见 AppSettings。
import AppKit
import SwitcherContracts
import SwitcherControl

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var controller: AppController!
    private var recentMenu: NSMenu?
    private var externalMenuItem: NSMenuItem?
    private var virtualCameraStatusItem: NSMenuItem?
    /// "输出"菜单（menuNeedsUpdate 按对象认，标题已本地化）。
    private var outputMenu: NSMenu?
    private var settings = AppSettings()
    /// 退出那一问已经过了、正在收尾（再来一次 terminate 不再问）。
    private var quitting = false

    /// 自动更新（W4-B）；AppController 持有，这里只是入口。
    var updateController: UpdateController { controller.updateController }

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
        // W4-B：崩溃诊断落盘（MetricKit 在下次启动才交付，所以一起来就订阅）；测试宿主不写用户目录
        if !Self.isTestHost { CrashDiagnostics.shared.start() }
        Task { @MainActor in
            await controller.launch(showURL: settings.showURL)
            if let url = settings.statsURL {
                do { try controller.session?.startStatsLog(url: url) } catch { NSLog("stats.jsonl 打不开：\(error)") }
            }
        }
    }

    /// 退出（菜单 / ⌘Q / 关主窗口）：录制 / 推流在跑先确认，有未保存的改动问 保存 / 不保存 / 取消（W5-B，Q67 (a)）；过了才 shutdown。
    /// 取消 = 不退。等回答期间 AppKit 在 modal panel 模式下跑 run loop，sheet 照常弹。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        controller.prepareToQuit { [weak self] ok in
            // 回答可能是同步给的（什么都不用问）：挪到下一轮，先让 applicationShouldTerminate 返回 .terminateLater
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard ok else {
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    self.quitting = true
                    Task { @MainActor in
                        await self.controller.shutdown()
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        controller.requestOpenShow(url: URL(fileURLWithPath: filename)) { [weak self] in self?.rebuildRecentMenu() }
        return true
    }

    // MARK: 菜单

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.about"), action: #selector(showAbout(_:)), keyEquivalent: "")   // 带 credits（W5-A：版本、许可、NDI® 声明）
        appMenu.addItem(withTitle: L("menu.checkForUpdates"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.preferences"), action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: ProductName.display))   // 产品名 PlusMix（W4-D），不是代码名

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

        // 输出菜单：W3-E 的六个设置页入口 + W3-C 的外部输出子菜单 / 多画面窗口 / 虚拟摄像头（G4 合并：以 W3-C 的运行表为准、保留 W3-E 的面板）
        let output = NSMenu(title: L("menu.output"))
        output.delegate = self
        outputMenu = output
        for (title, tab) in [(L("menu.output.record"), OutputSettingsModel.Tab.record), (L("menu.output.iso"), .iso), (L("menu.output.stream"), .stream),
                             (L("menu.output.external"), .external), (L("menu.output.ndi"), .ndi), (L("menu.output.virtualCamera"), .virtualCamera),
                             (L("menu.output.multiview"), .multiview)] {
            let item = output.addItem(withTitle: title, action: #selector(outputSettings(_:)), keyEquivalent: "")
            item.representedObject = tab.rawValue
        }
        output.addItem(.separator())
        let external = NSMenuItem(title: L("bottom.external"), action: nil, keyEquivalent: "")
        external.submenu = NSMenu(title: L("bottom.external"))
        output.addItem(external)
        externalMenuItem = external
        output.addItem(withTitle: L("menu.window.multiview"), action: #selector(toggleMultiview), keyEquivalent: "")
        output.addItem(.separator())
        let camera = NSMenu(title: L("menu.output.virtualCamera.title"))
        camera.addItem(withTitle: L("menu.output.virtualCamera.toggle"), action: #selector(toggleVirtualCamera), keyEquivalent: "")
        camera.addItem(.separator())
        camera.addItem(withTitle: L("menu.output.virtualCamera.install"), action: #selector(installExtension), keyEquivalent: "")
        camera.addItem(withTitle: L("menu.output.virtualCamera.uninstall"), action: #selector(uninstallExtension), keyEquivalent: "")
        camera.addItem(withTitle: L("menu.output.virtualCamera.refresh"), action: #selector(refreshExtension), keyEquivalent: "")
        camera.addItem(.separator())
        let status = camera.addItem(withTitle: L("menu.output.virtualCamera.statusUnknown"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        virtualCameraStatusItem = status
        output.addItem(submenu(camera, title: L("menu.output.virtualCamera.title")))
        main.addItem(submenu(output, title: L("menu.output")))

        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(withTitle: L("menu.window.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("menu.window.zoom"), action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("menu.window.mixer"), action: #selector(toggleMixer), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("menu.window.multiview"), action: #selector(toggleMultiview), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: L("menu.window")))
        NSApp.windowsMenu = windowMenu

        // W4-B：帮助菜单（诊断包导出、诊断文件夹）
        let help = NSMenu(title: L("menu.help"))
        help.addItem(withTitle: L("menu.help.exportDiagnostics"), action: #selector(exportDiagnostics(_:)), keyEquivalent: "")
        help.addItem(withTitle: L("menu.help.showDiagnosticsFolder"), action: #selector(showDiagnosticsFolder(_:)), keyEquivalent: "")
        main.addItem(submenu(help, title: L("menu.help")))
        NSApp.helpMenu = help

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
            recentMenu.addItem(withTitle: L("menu.show.noRecent"), action: nil, keyEquivalent: "").isEnabled = false
        } else {
            recentMenu.addItem(.separator())
            recentMenu.addItem(withTitle: L("menu.show.clearRecent"), action: #selector(clearRecents), keyEquivalent: "")
        }
    }

    // 新建 / 打开都先过换节目的问（录制 / 推流在跑、未保存的改动；W5-B）
    @objc private func newShow() { controller.requestNewShow { [weak self] in self?.rebuildRecentMenu() } }
    @objc private func openShow() { controller.openShowPanel { [weak self] in self?.rebuildRecentMenu() } }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        controller.requestOpenShow(url: url) { [weak self] in self?.rebuildRecentMenu() }
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

    /// 关于面板：系统标准面板 + credits（AboutPanel）。
    @objc func showAbout(_ sender: Any?) { AboutPanel.show() }

    // MARK: 更新与诊断（W4-B）

    /// 检查更新：配置了 Sparkle 就交给它（自己的窗口）；开发 / ad-hoc 构建没有更新源，弹一句说明。
    @objc func checkForUpdates(_ sender: Any?) {
        if updateController.isConfigured {
            updateController.checkForUpdates()
        } else if !Self.isTestHost {
            let alert = NSAlert()
            alert.messageText = L("update.alert.unconfigured.title")
            alert.informativeText = L("update.alert.unconfigured.text")
            alert.runModal()
        }
    }

    @objc func exportDiagnostics(_ sender: Any?) { DiagnosticsExport.present(controller: controller) }
    @objc func showDiagnosticsFolder(_ sender: Any?) { DiagnosticsExport.revealFolder() }

    // MARK: 输出（W3-C）

    @objc private func toggleMultiview() { controller.windowController.toggleMultiviewWindow() }

    /// 有虚拟摄像头输出就翻它的 enabled（提案 012 的 setOutputEnabled：来源等设置留着，运行表看到的是开关而不是删了重加），没有就加一个开着的。
    @objc private func toggleVirtualCamera() {
        guard let s = controller.session else { return }
        if let existing = s.state.outputs.first(where: { $0.kind == .virtualCamera }) {
            s.send(.setOutputEnabled(output: existing.number, on: !existing.enabled))
        } else {
            let number = (s.state.outputs.map(\.number).max() ?? 0) + 1
            s.send(.addOutput(config: OutputState(number: number, kind: .virtualCamera, name: L("outputSettings.vcam.name"), enabled: true,
                                                  settings: OutputSettings(source: .program))))
        }
    }

    @objc private func installExtension() { controller.session?.aux.installer.activate() }
    @objc private func uninstallExtension() { controller.session?.aux.installer.deactivate() }
    @objc private func refreshExtension() { controller.session?.aux.installer.refresh() }

    /// 打开"输出"菜单时重建外部输出子菜单（显示器 × 源，按当前快照打勾）和虚拟摄像头状态行（NSMenuDelegate 在类声明上）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === outputMenu else { return }
        if let item = externalMenuItem {
            item.submenu = controller.windowController.externalOutputMenu() ?? NSMenu(title: L("bottom.external"))
        }
        if let status = virtualCameraStatusItem, let line = virtualCameraStatusLine {
            status.title = line
        }
    }

    /// 虚拟摄像头子菜单的状态行：扩展状态（安装器）+ 输出状态（Stats.display[]，提案 013）。没有 session 为 nil。
    var virtualCameraStatusLine: String? {
        guard let s = controller.session else { return nil }
        return L("menu.output.virtualCamera.status", OutputStatusText.extensionStatus(s.aux.installer.status), s.virtualCameraStatusText)
    }
}

// 窗口菜单（和输出菜单）里"调音台 / 多画面"是开关：按可见性打勾（W5-A / V-31）。其它项照旧按"有响应者就能点"。
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMixer):
            menuItem.state = controller.windowController.isMixerPanelVisible ? .on : .off
        case #selector(toggleMultiview):
            menuItem.state = controller.windowController.isMultiviewWindowVisible ? .on : .off
        default:
            break
        }
        return true
    }
}
