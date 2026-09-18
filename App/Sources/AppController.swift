// App 的总管：一个 session（节目跑起来）+ 主窗口 + 节目文件。新建 / 打开总是换一个新 session（节目格式可能变，引擎的格式在 init 定死）。
import AppKit
import SwitcherContracts

@MainActor
final class AppController {
    let windowController = MainWindowController()
    let documents: ShowDocuments
    private(set) var session: SwitcherSession?
    /// 上一次 replaceSession 抛的错（测试看）。
    private(set) var lastError: (any Error)?
    /// 是否在测试宿主里跑（不恢复上次、不写"上次文件"）。
    let isTestHost: Bool
    private var replacing = false

    init(isTestHost: Bool) {
        self.isTestHost = isTestHost
        documents = ShowDocuments(defaults: isTestHost ? UserDefaults(suiteName: "com.example.switcher.tests") ?? .standard : .standard)
    }

    // MARK: 启动 / 退出

    /// 启动：命令行指定的文件 → 恢复上次的文件 → 没有就恢复退出时自动存的 → 再没有就空节目。测试宿主永远空节目。
    func launch(showURL: URL? = nil) async {
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.makeFirstResponder(nil)   // 快捷键直接到窗口；搜索框要点了才有焦点
        var show = ShowDocuments.emptyShow()
        if let showURL {
            do { show = try documents.load(from: showURL) } catch { presentError(error, context: "打开 \(showURL.lastPathComponent)") }
        } else if !isTestHost {
            if let url = documents.lastURL, let loaded = try? documents.load(from: url) {
                show = loaded
            } else if let auto = documents.loadAutosave() {
                show = auto
                documents.startNew()
            }
        }
        await replaceSession(show: show)
    }

    /// 退出前：自动保存当前状态（未保存过的节目下次能恢复），停引擎。
    func shutdown() async {
        if let session, !isTestHost {
            documents.autosave(session.makeShow())
            if let url = documents.currentURL { try? documents.save(session.makeShow(), to: url) }
        }
        await stopSession()
    }

    // MARK: session

    func replaceSession(show: Show) async {
        guard !replacing else { return }
        replacing = true
        defer { replacing = false }
        await stopSession()
        do {
            let s = try SwitcherSession(show: show)
            session = s
            windowController.bind(session: s)
            try await s.start()
        } catch {
            lastError = error
            session = nil
            windowController.bind(session: nil)
            presentError(error, context: "起引擎")
        }
    }

    private func stopSession() async {
        guard let old = session else { return }
        windowController.bind(session: nil)
        session = nil
        await old.stop()
    }

    // MARK: 节目文件

    func newShow() async {
        documents.startNew()
        await replaceSession(show: ShowDocuments.emptyShow())
    }

    func openShow(url: URL) async {
        do {
            let show = try documents.load(from: url)
            await replaceSession(show: show)
        } catch {
            presentError(error, context: "打开 \(url.lastPathComponent)")
        }
    }

    func openShowPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择节目文件（.\(ShowDocuments.fileExtension)）"
        guard let window = windowController.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                Task { await self.openShow(url: url) }
            }
        }
    }

    /// 保存：有文件就写回，没有就另存。
    func save() {
        guard let session else { return }
        if let url = documents.currentURL {
            write(session.makeShow(), to: url)
        } else {
            saveAs()
        }
    }

    func saveAs() {
        guard let session, let window = windowController.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.name).\(ShowDocuments.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.write(session.makeShow(), to: url)
            }
        }
    }

    /// 直接写到 url（测试 / 另存的落点）。节目名 = 文件名（去掉 .switcher.json）。
    func write(_ show: Show, to url: URL) {
        do {
            var s = show
            s.name = Self.showName(for: url)
            s.layout = currentLayout()
            try documents.save(s, to: url)
            session?.name = s.name
            session?.layout = s.layout
            windowController.window?.title = "Switcher \(SwitcherVersion.current) — \(s.name)"
        } catch {
            presentError(error, context: "保存 \(url.lastPathComponent)")
        }
    }

    /// 文件名 → 节目名："a.switcher.json" → "a"。
    static func showName(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".\(ShowDocuments.fileExtension)") { name.removeLast(ShowDocuments.fileExtension.count + 1) }
        else { name = url.deletingPathExtension().lastPathComponent }
        return name.isEmpty ? "未命名" : name
    }

    /// 界面布局进 Show.layout（契约不解释内容，App 自己定义键）。
    func currentLayout() -> ShowLayout {
        var values = session?.layout.values ?? [:]
        if let frame = windowController.window?.frame {
            values["mainWindowFrame"] = .string(NSStringFromRect(frame))
        }
        values["mixerPanelVisible"] = .bool(windowController.isMixerPanelVisible)
        return ShowLayout(values: values)
    }

    private func presentError(_ error: any Error, context: String) {
        NSLog("\(context)失败：\(error)")
        guard !isTestHost, let window = windowController.window else { return }
        let alert = NSAlert()
        alert.messageText = "\(context)失败"
        alert.informativeText = "\(error)"
        alert.beginSheetModal(for: window)
    }
}
