// Switcher App —— AppKit 主程序（W2-B：显示路径 + 主界面骨架；W2-B2：接上输入 / 命令 / API / 音频 / 录制 / 推流 / Stats；W3-E：设置面板与窗口）。
// 启动：建主窗口 → 恢复上次节目（测试宿主用空节目）→ 起引擎。退出：先问（录制 / 推流在跑、有未保存的改动，W5-B）→ LastSession 照存 → 停引擎。
// 新建 / 打开 / 打开最近 / 打开上次退出时的节目 / Finder 双击打开同样先问（AppController.requestNewShow / requestOpenShow / requestOpenLastSession）。
// 菜单栏（W5-G 按 docs/ui-study/01-菜单逻辑.md §5 重排，规则 5：主窗口里放了的每个动作菜单栏里都还在）：
//   PlusMix   关于 / 检查更新… / ─ / 设置… ⌘, / 快捷键… / MIDI 映射… / 所有设置页 ▸ / ─ / 隐藏 / ─ / 退出
//             （Q48："偏好设置…"改"设置…"；F3：快捷键 / MIDI 映射从"切换"挪来；W5-J：都打开同一个设置窗的那一页，"所有设置页"= 工具条设置▾ 的页）
//   节目      新建 / 打开… / 打开最近 ▸（同名带上级目录名，V-24）/ 打开上次退出时的节目 / ─ / 保存 / 另存为…
//   编辑      （不变）
//   输入      添加输入… ⌘I / 按类型添加 ▸ / 输入 N「名字」设置… ⇧⌘I（标题写出是 PVW 上哪一路，PVW 空时灰，O4）
//   切换      SwitchMenuController（O1：Cut / 执行当前转场 / 五种类型 / FTB / Overlay ▸，右列的键只显示）
//   输出      录制 ▸ / 推流 ▸ / 外部显示 ▸ / 全部外部显示开·关 / 多画面窗口 / 虚拟摄像头 ▸ / ─ / 七个输出设置页（▸ 的几个和底栏 ▴ / ⚙ 同一份菜单）
//   窗口      最小化 / 缩放 / ─ / 调音台 / 多画面
//   帮助      PlusMix 使用手册 / 快捷键一览 / ─ / 导出诊断包… / 打开诊断文件夹（O3；工具条"?"弹同一份）
// 菜单项一律 nil target、动作在这里：工具条（MainToolbar）的按钮挂的是同一个 selector，所以两处点下去是同一段代码，灰不灰也在 validateMenuItem 里一处定。
// 文案全部走 L10n（包里返回中文的状态在 App 侧查表，OutputStatusText）。启动参数与设置见 AppSettings。
import AppKit
import SwitcherContracts
import SwitcherControl
import SwitcherExternal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var controller: AppController!
    private var recentMenu: NSMenu?
    private var externalMenuItem: NSMenuItem?
    /// "输出 › 录制 ▸ / 推流 ▸"（打开"输出"菜单时按底栏录制 ▴ / 推流 ▴ 重建，W5-F / W5-G）。
    private var recordMenuItem: NSMenuItem?
    private var streamMenuItem: NSMenuItem?
    /// "输入"菜单、"按类型添加 ▸"（= 底栏添加输入 ▴，W5-F）与"输入 N「名字」设置…"（W5-G）。
    private var inputMenu: NSMenu?
    private var addByTypeItem: NSMenuItem?
    private var inputSettingsItem: NSMenuItem?
    private var virtualCameraStatusItem: NSMenuItem?
    /// "输出"菜单（menuNeedsUpdate 按对象认，标题已本地化）。
    private var outputMenu: NSMenu?
    /// 窗口 › 输入缩略图 ▸（W5-H）。
    private var thumbnailSizeMenu: NSMenu?
    /// "切换"菜单（W5-G：自己是 delegate，不认任何键）。
    private(set) var switchMenu: SwitchMenuController?
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
        controller.requestOpenShow(url: URL(fileURLWithPath: filename))
        return true
    }

    // MARK: 菜单

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.about"), action: #selector(showAbout(_:)), keyEquivalent: "")   // 带 credits（W5-A：版本、许可、NDI® 声明）
        appMenu.addItem(withTitle: L("menu.checkForUpdates"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.settings"), action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(SettingsMenu.hotkeysItem())   // 设置窗的快捷键页 / MIDI 页（W5-J）
        appMenu.addItem(SettingsMenu.midiItem())
        appMenu.addItem(SettingsMenu.pagesSubmenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: ProductName.display))   // 产品名 PlusMix（W4-D），不是代码名

        let show = NSMenu(title: L("menu.show"))
        show.addItem(withTitle: L("menu.show.new"), action: #selector(newShow(_:)), keyEquivalent: "n")
        show.addItem(withTitle: L("menu.show.open"), action: #selector(openShow(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: L("menu.show.openRecent"))
        recent.delegate = self
        recentMenu = recent
        show.addItem(submenu(recent, title: L("menu.show.openRecent")))
        show.addItem(ShowMenu.lastSessionItem())
        show.addItem(.separator())
        show.addItem(withTitle: L("menu.show.save"), action: #selector(saveShow(_:)), keyEquivalent: "s")
        let saveAs = show.addItem(withTitle: L("menu.show.saveAs"), action: #selector(saveShowAs(_:)), keyEquivalent: "S")
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
        input.delegate = self
        inputMenu = input
        input.addItem(withTitle: L("menu.input.add"), action: #selector(addInput), keyEquivalent: "i")
        let byType = NSMenuItem(title: L("menu.input.addByType"), action: nil, keyEquivalent: "")
        byType.submenu = NSMenu(title: L("menu.input.addByType"))
        input.addItem(byType)
        addByTypeItem = byType
        inputSettingsItem = input.addItem(withTitle: L("menu.input.settings"), action: #selector(inputSettings(_:)), keyEquivalent: "I")
        input.addItem(withTitle: L("menu.input.find"), action: #selector(focusInputSearch(_:)), keyEquivalent: "f")   // ⌘F：输入条的搜索框（W5-H，D3）
        main.addItem(submenu(input, title: L("menu.input")))

        let switching = SwitchMenuController()
        switching.state = { [weak self] in self?.controller.session?.state }
        switching.hotkeyTable = { [weak self] in self?.controller.hotkeyTable ?? .default }
        switchMenu = switching
        main.addItem(submenu(switching.menu, title: L("menu.transition")))

        // 输出菜单：录制 / 推流 / 外部显示的现场操作（和底栏 ▴ / ⚙ 同一份菜单）在上，设置页在下（W5-G 按 01 §5 重排）
        let output = NSMenu(title: L("menu.output"))
        output.delegate = self
        outputMenu = output
        let record = NSMenuItem(title: L("menu.output.recordSubmenu"), action: nil, keyEquivalent: "")
        record.submenu = NSMenu(title: L("menu.output.recordSubmenu"))
        output.addItem(record)
        recordMenuItem = record
        let stream = NSMenuItem(title: L("menu.output.streamSubmenu"), action: nil, keyEquivalent: "")
        stream.submenu = NSMenu(title: L("menu.output.streamSubmenu"))
        output.addItem(stream)
        streamMenuItem = stream
        let external = NSMenuItem(title: L("bottom.external"), action: nil, keyEquivalent: "")
        external.submenu = NSMenu(title: L("bottom.external"))
        output.addItem(external)
        externalMenuItem = external
        output.addItem(withTitle: L("menu.output.externalOn"), action: #selector(toggleExternalDisplays(_:)), keyEquivalent: "")   // 标题在 validateMenuItem 里跟状态
        output.addItem(withTitle: L("menu.window.multiview"), action: #selector(toggleMultiview), keyEquivalent: "")
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
        output.addItem(.separator())
        for page in SettingsMenu.outputPages { output.addItem(SettingsMenu.outputPageItem(key: page.key, tab: page.tab)) }
        main.addItem(submenu(output, title: L("menu.output")))

        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(withTitle: L("menu.window.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("menu.window.zoom"), action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("menu.window.mixer"), action: #selector(toggleMixer(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("menu.window.multiview"), action: #selector(toggleMultiview), keyEquivalent: "")
        // 输入缩略图 ▸ 小 / 中 / 大（W5-H，D11；与输入条右键同一份，存本机）
        let thumbnails = NSMenu(title: L("menu.window.thumbnailSize"))
        thumbnails.delegate = self
        thumbnailSizeMenu = thumbnails
        windowMenu.addItem(submenu(thumbnails, title: L("menu.window.thumbnailSize")))
        main.addItem(submenu(windowMenu, title: L("menu.window")))
        NSApp.windowsMenu = windowMenu

        // 帮助（W4-B 的诊断两项 + W5-G 的使用手册 / 快捷键一览；工具条"?"弹同一份）
        let help = HelpMenu.make()
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
        ShowMenu.fillRecentMenu(recentMenu, urls: controller.documents.recentURLs)
    }

    // MARK: 节目（新建 / 打开都先过换节目的问，W5-B；工具条"节目"组挂的是同几个 selector）

    @objc func newShow(_ sender: Any?) { controller.requestNewShow() }
    @objc func openShow(_ sender: Any?) { controller.openShowPanel() }
    @objc func openRecent(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        controller.requestOpenShow(url: url)
    }
    @objc func clearRecents(_ sender: Any?) {
        controller.documents.clearRecents()
        rebuildRecentMenu()
    }
    /// 打开上次退出时的节目（退出时自动存的 LastSession；A2）。
    @objc func openLastSession(_ sender: Any?) { controller.requestOpenLastSession() }
    @objc func saveShow(_ sender: Any?) { controller.save() }
    @objc func saveShowAs(_ sender: Any?) { controller.saveAs() }

    // MARK: 输入

    @objc private func addInput() { controller.windowController.presentAddInput() }

    /// "输入 N「名字」设置…"的对象：PVW 上那一路（PVW 空 / 那一路不在 = nil，菜单项灰；原来悄悄换成第一路，O4）。
    private var inputSettingsTarget: InputConfig? {
        guard let s = controller.session, s.state.preview != MixerState.noInput else { return nil }
        return s.state.input(s.state.preview)
    }

    /// 输入设置：PVW 上那一路（和 PVW 标题条的齿轮同一个对象，B1）。
    @objc func inputSettings(_ sender: Any?) {
        guard let input = inputSettingsTarget else { return }
        controller.panels.showInputSettings(input: input.number)
    }

    // MARK: 切换（O1；只发命令，开关看快照）

    @objc func transitionCut(_ sender: Any?) { controller.session?.send(.cut) }
    /// 执行当前转场：按状态里的类型与时长（= 回车的默认绑定）。
    @objc func transitionAuto(_ sender: Any?) { controller.session?.send(.autoTransition) }
    /// 选 T-bar 和回车用哪种：只发 setTransition（时长不变、不执行；转场进行中状态机会拒，菜单项那时是灰的）。
    @objc func pickTransitionType(_ sender: Any?) {
        guard let s = controller.session, !s.state.transition.isActive,
              let raw = (sender as? NSMenuItem)?.representedObject as? String, let type = TransitionType(rawValue: raw) else { return }
        s.send(.setTransition(type: type, durationTicks: s.state.transition.durationTicks))
    }
    @objc func transitionFTB(_ sender: Any?) {
        guard let s = controller.session else { return }
        s.send(.ftb(on: !s.state.ftb.on))
    }
    /// Overlay n：与转场列 Overlay 按钮同一口径（OverlayToggle：空通道用 PVW 那一路开；PVW 也是黑场时状态行提示）。
    @objc func transitionOverlay(_ sender: Any?) {
        guard let s = controller.session, let channel = (sender as? NSMenuItem)?.tag else { return }
        switch OverlayToggle.command(channel: channel, in: s.state) {
        case .send(let command)?: s.send(command)
        case .needsPreview?: controller.windowController.bottomBar.showNotice(L("transition.overlayNeedsPreview", channel, channel))
        case nil: break
        }
    }

    /// 叠加设置窗（W5-K / I1；底栏"叠加…"、转场列 / 格子的右键同一个窗）。
    @objc func showOverlaySettings(_ sender: Any?) { controller.panels.showOverlaySettings(channel: nil) }

    // MARK: 设置（App 菜单"设置…"下与工具条"设置▾"；W5-J：一律走 showSettings(page:)）

    @objc func showHotkeys(_ sender: Any?) { controller.panels.showSettings(page: .hotkeys) }
    @objc func showMIDI(_ sender: Any?) { controller.panels.showSettings(page: .midi) }
    /// ⌘, / 工具条"设置"主体：回到上次那一页（没开过 = 常规）。
    @objc func showPreferences(_ sender: Any?) { controller.panels.showSettings() }
    @objc func outputSettings(_ sender: Any?) {
        let tab = ((sender as? NSMenuItem)?.representedObject as? String).flatMap(OutputSettingsModel.Tab.init(rawValue:)) ?? .record
        controller.panels.showSettings(page: .output(tab))
    }
    /// 设置窗的某一页（representedObject = SettingsPage.id）。
    @objc func showSettingsPage(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String, let page = SettingsPage(id: id) else { return }
        controller.panels.showSettings(page: page)
    }
    /// 窗口 › 调音台 / 输入条右端"调音台"开关（同一个 selector，W5-H D2）。
    @objc func toggleMixer(_ sender: Any?) { controller.windowController.toggleMixerPanel() }
    /// 输入 › 搜索输入（⌘F）：焦点进输入条的搜索框（W5-H D3）。名字别用系统的 performFindPanelAction:（文本框有焦点时会被它接走）。
    @objc func focusInputSearch(_ sender: Any?) { controller.windowController.inputStrip.focusSearch() }

    /// 关于面板：系统标准面板 + credits（AboutPanel）。
    @objc func showAbout(_ sender: Any?) { AboutPanel.show() }

    // MARK: 更新与诊断（W4-B）、帮助（W5-G）

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
    /// PlusMix 使用手册（随包 HTML，生成归 103；不在包里时菜单项灰着）。
    @objc func showManual(_ sender: Any?) { HelpBook.openManual() }
    /// 快捷键一览：按当前表生成一页 HTML（临时文件）再打开。
    @objc func showHotkeyList(_ sender: Any?) { HelpBook.openHotkeyList(table: controller.hotkeyTable) }

    // MARK: 输出（W3-C）

    @objc private func toggleMultiview() { controller.windowController.toggleMultiviewWindow() }

    /// 外部显示全部开 / 关（= 底栏与工具条的外部显示主体，M1）。一路都没配、也没有第二块屏：从点的那个控件弹路由菜单（工具条主体向下开；
    /// 菜单栏里这一项那时是灰的）。
    @objc func toggleExternalDisplays(_ sender: Any?) {
        let wc = controller.windowController
        guard controller.session != nil, !wc.toggleExternalDisplays() else { return }
        guard let button = sender as? NSButton, let split = SplitBarButton.containing(button), let menu = wc.externalOutputMenu() else { return }
        split.popUp(menu, from: button)
    }

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

    /// 打开"输出"菜单时重建录制 / 推流子菜单（= 底栏录制 ▴ / 推流 ▴）、外部显示子菜单（每块屏单选，按当前快照打勾）和虚拟摄像头状态行；
    /// 打开"输入"菜单时重建"按类型添加"（= 底栏添加输入 ▴）、把"输入设置…"写成"输入 N「名字」设置…"；打开"打开最近"时按最近列表重建。
    /// NSMenuDelegate 在类声明上（"切换"菜单另有自己的 delegate）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu {
            rebuildRecentMenu()
            return
        }
        if menu === thumbnailSizeMenu {
            // 与输入条右键同一份（每次现建：菜单项不能同时挂在两个菜单里）
            let fresh = controller.windowController.inputStrip.thumbnailSizeMenu()
            menu.removeAllItems()
            menu.autoenablesItems = false
            for item in fresh.items {
                fresh.removeItem(item)
                menu.addItem(item)
            }
            return
        }
        if menu === inputMenu {
            addByTypeItem?.submenu = controller.windowController.addInputMenu() ?? NSMenu(title: L("menu.input.addByType"))
            inputSettingsItem?.title = inputSettingsTarget.map { L("menu.input.settingsNamed", $0.number, $0.name) } ?? L("menu.input.settings")
            return
        }
        guard menu === outputMenu else { return }
        recordMenuItem?.submenu = controller.windowController.bottomBar.recordMenu()
        streamMenuItem?.submenu = controller.windowController.bottomBar.streamMenu()
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

// 菜单项灰不灰（工具条按钮挂的是同样的 selector，但按钮不走这里：MainToolbar.setSessionAvailable）。
// 窗口菜单（和输出菜单）里"调音台 / 多画面"是开关：按可见性打勾（W5-A / V-31）。其它项没写的照旧按"有响应者就能点"。
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = controller.session
        switch menuItem.action {
        case #selector(toggleMixer(_:)):
            menuItem.state = controller.windowController.isMixerPanelVisible ? .on : .off
        case #selector(toggleMultiview):
            menuItem.state = controller.windowController.isMultiviewWindowVisible ? .on : .off
        case #selector(inputSettings(_:)):
            return inputSettingsTarget != nil
        case #selector(openLastSession(_:)):
            return controller.documents.hasAutosave
        case #selector(clearRecents(_:)):
            return !controller.documents.recentURLs.isEmpty
        case #selector(transitionCut(_:)), #selector(transitionAuto(_:)), #selector(transitionFTB(_:)), #selector(transitionOverlay(_:)), #selector(showOverlaySettings(_:)):
            return session != nil
        case #selector(pickTransitionType(_:)):
            return session.map { !$0.state.transition.isActive } ?? false
        case #selector(toggleExternalDisplays(_:)):
            let (title, enabled) = externalToggleTitle(session?.state)
            if menuItem.title != title { menuItem.title = title }
            return enabled
        case #selector(showManual(_:)):
            let available = HelpBook.manualURL() != nil
            let title = HelpMenu.manualTitle(available: available)
            if menuItem.title != title { menuItem.title = title }
            return available
        default:
            break
        }
        return true
    }

    /// "全部外部显示开 / 关"那一项：有开着的 → 关闭全部；都关着 → 打开全部；一路都没配 → 有第二块屏时"在副屏上显示 PGM"，没有就灰。
    private func externalToggleTitle(_ state: MixerState?) -> (String, Bool) {
        guard let state else { return (L("menu.output.externalOn"), false) }
        let outputs = state.outputs.filter { $0.kind == .externalDisplay }
        if outputs.contains(where: \.enabled) { return (L("externalMenu.closeAll"), true) }
        if !outputs.isEmpty { return (L("menu.output.externalOn"), true) }
        if ExternalDisplays.all().contains(where: { !$0.isMain }) { return (L("menu.output.externalCreate"), true) }
        return (L("menu.output.externalOn"), false)
    }
}
