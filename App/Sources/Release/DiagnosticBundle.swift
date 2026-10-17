// 诊断包一键导出（W4-B，后续方案 §8.1）：一个 zip 里放 README、系统信息、设置（不含 API token）、最近一秒的 Stats（与 stats.jsonl 同一套字段，铁律 4）、
// 正在写的 stats.jsonl（若开了 --stats）、去掉密钥的节目文件、快捷键 / MIDI 表、扩展状态；用户在对话框里同意后再加崩溃诊断（MetricKit 落盘的 + 系统的
// DiagnosticReports）与最近一段的系统日志（log show）。主线程只收集能同步拿到的东西，文件 IO 与 log show 在后台。
import AppKit
import Metal
import SwitcherContracts
import SwitcherControl

struct DiagnosticBundle {
    struct Options: Sendable {
        var includeCrashLogs = true
        var includeSystemLog = true
        /// log show 取最近多少分钟（默认两小时）。
        var systemLogWindowMinutes = 120
    }

    /// 主线程收集好的材料（Sendable，交给后台线程写文件）。
    struct Snapshot: Sendable {
        var readme = ""
        var system = ""
        var settings = ""
        var statsLine: String?
        var statsLogURL: URL?
        var showJSON: Data?
        var showError: String?
        var configFiles: [URL] = []
        var crashFiles: [URL] = []
        var crashSummary: [String] = []
        var processNames: [String] = []
    }

    /// 收集 → 后台写 zip → 返回 zip 路径（destination 就是 zip 的位置；同名先删）。
    @MainActor
    static func build(controller: AppController, options: Options, destination: URL) async throws -> URL {
        var snap = Snapshot()
        snap.readme = L("diagnostics.readme")
        snap.system = systemInfo(controller: controller)
        snap.settings = settingsText(controller.settings, controller: controller)
        if let session = controller.session {
            snap.statsLine = try? session.stats?.jsonLine()
            snap.statsLogURL = session.statsLogURL
            do { snap.showJSON = try ShowRedaction.redact(showData: try session.makeShow().save()) } catch { snap.showError = "\(error)" }
        }
        snap.configFiles = [controller.hotkeyFileURL, controller.midiFileURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        if options.includeCrashLogs {
            snap.crashFiles = CrashDiagnostics.shared.store.entries() + systemCrashReports()
            snap.crashSummary = CrashDiagnostics.shared.store.summaryLines()
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.plusmix.switcher"
        snap.processNames = [ProductName.executable, VirtualCameraConstantsBridge.extensionBundleIdentifier(bundleID)]
        let opts = options
        return try await Task.detached(priority: .userInitiated) { try write(snap, options: opts, destination: destination) }.value
    }

    // MARK: 收集

    @MainActor
    static func systemInfo(controller: AppController) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines: [String] = []
        lines.append("app_version: \(info["CFBundleShortVersionString"] ?? "?") (build \(info["CFBundleVersion"] ?? "?"))")
        lines.append("bundle_id: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("bundle_path: \(Bundle.main.bundlePath)")
        lines.append("signing: \(codeSignSummary(Bundle.main.bundleURL))")
        lines.append("sparkle_feed: \((info["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(none)")")
        lines.append("macos: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("model: \(sysctlString("hw.model") ?? "?")")
        lines.append("chip_or_cpu: \(sysctlString("machdep.cpu.brand_string") ?? "?")")
        lines.append("cores: \(ProcessInfo.processInfo.processorCount)")
        lines.append("memory_gb: \(String(format: "%.1f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824))")
        lines.append("gpu: \(MTLCreateSystemDefaultDevice()?.name ?? "?")")
        lines.append("uptime_s: \(Int(ProcessInfo.processInfo.systemUptime))")
        lines.append("locale: \(Locale.current.identifier); languages: \(Locale.preferredLanguages.prefix(3).joined(separator: ","))")
        lines.append("low_power_mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        lines.append("thermal_state: \(ProcessInfo.processInfo.thermalState.rawValue)")
        for (i, screen) in NSScreen.screens.enumerated() {
            lines.append("display_\(i): \(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x max_fps=\(screen.maximumFramesPerSecond) \(screen.localizedName)")
        }
        if let session = controller.session {
            let f = session.format
            lines.append("program_format: \(f.width)x\(f.height) \(f.frameRate.framesPerSecond.numerator)/\(f.frameRate.framesPerSecond.denominator)")
            lines.append("session_running: \(session.isRunning)")
            lines.append("inputs: " + session.state.inputs.map { "\($0.number)=\(kindName(of: $0))" }.joined(separator: ", "))
            lines.append("outputs: " + session.state.outputs.map { "\($0.number)=\($0.kind.rawValue)\($0.enabled ? "(on)" : "")" }.joined(separator: ", "))
            lines.append("virtual_camera_extension: \(OutputStatusText.extensionStatus(session.aux.installer.status))")
            if let notice = session.lastNotice { lines.append("last_notice: \(notice)") }
        } else {
            lines.append("session_running: false")
            if let err = controller.lastError { lines.append("last_error: \(err)") }
        }
        lines.append("crash_diagnostics_dir: \(CrashDiagnostics.shared.store.directory.path)")
        lines.append("crash_diagnostics_received_this_run: \(CrashDiagnostics.shared.receivedPayloads)")
        lines.append("exported_at: \(ISO8601DateFormatter().string(from: Date()))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 设置：与 AppSettings.save 同一组键，token 只写有没有。
    @MainActor
    static func settingsText(_ s: AppSettings, controller: AppController) -> String {
        var lines: [String] = []
        lines.append("\(AppSettings.Keys.audioDevice): \(s.audioDevice.spec)")
        lines.append("\(AppSettings.Keys.apiEnabled): \(s.apiEnabled)")
        lines.append("\(AppSettings.Keys.apiListen): \(s.apiHost):\(s.apiPort)")
        lines.append("\(AppSettings.Keys.apiToken): \((s.apiToken?.isEmpty == false) ? "(set)" : "(not set)")")
        lines.append("\(AppSettings.Keys.recordFallbackDirectory): \(s.recordFallbackDirectory ?? "(none)")")
        lines.append("\(AppSettings.Keys.recordMinimumFreeMB): \(s.recordMinimumFreeMB)")
        lines.append("\(AppSettings.Keys.compatLayerEnabled): \(s.compatLayerEnabled)")
        lines.append("\(AppSettings.Keys.compatLayerPort): \(s.compatLayerPort)")
        lines.append("\(AppSettings.Keys.overlaysInPreview): \(s.overlaysInPreview)")
        lines.append("\(AppSettings.Keys.externalBehindInterface): \(s.externalBehindInterface)")
        lines.append("stats_log: \(s.statsURL?.path ?? "(off)")")
        lines.append("show_argument: \(s.showURL?.path ?? "(none)")")
        lines.append("current_show_file: \(controller.documents.currentURL?.path ?? "(unsaved)")")
        lines.append("hotkey_table_error: \(controller.hotkeyTableError ?? "(none)")")
        lines.append("test_host: \(controller.isTestHost)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func kindName(of input: InputConfig) -> String {
        // InputSource 是枚举：取 case 名（"synthetic(settings:…)" → "synthetic"）
        let raw = "\(input.source)"
        return String(raw.prefix { $0 != "(" })
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func codeSignSummary(_ url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvv", url.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return "?" }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let keep = text.split(separator: "\n").filter { $0.hasPrefix("Authority=") || $0.hasPrefix("Signature=") || $0.hasPrefix("TeamIdentifier=") || $0.hasPrefix("Identifier=") }
        return keep.prefix(4).joined(separator: "; ")
    }

    /// 系统的崩溃报告（~/Library/Logs/DiagnosticReports/<可执行名>*.ips / .crash；可执行名 = PRODUCT_NAME = PlusMix，W4-D）。
    static func systemCrashReports() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(ProductName.executable) && ["ips", "crash"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(20).map { $0 }
    }

    // MARK: 写

    static func write(_ snap: Snapshot, options: Options, destination: URL) throws -> URL {
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
        }()
        let staging = fm.temporaryDirectory.appending(path: "switcher-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = staging.appending(path: "\(ProductName.display)-diagnostics-\(stamp)", directoryHint: .isDirectory)   // zip 里的顶层目录用产品名（W4-D）
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: root.appending(path: "crashes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        try snap.readme.write(to: root.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        try snap.system.write(to: root.appending(path: "system.txt"), atomically: true, encoding: .utf8)
        try snap.settings.write(to: root.appending(path: "settings.txt"), atomically: true, encoding: .utf8)
        try ((snap.statsLine ?? "") + "\n").write(to: root.appending(path: "stats-latest.jsonl"), atomically: true, encoding: .utf8)
        if let log = snap.statsLogURL, fm.fileExists(atPath: log.path) { try? fm.copyItem(at: log, to: root.appending(path: "stats.jsonl")) }
        if let show = snap.showJSON { try show.write(to: root.appending(path: "show.switcher.json")) }
        else { try (snap.showError ?? "no session").write(to: root.appending(path: "show.switcher.json.error.txt"), atomically: true, encoding: .utf8) }
        for f in snap.configFiles { try? fm.copyItem(at: f, to: root.appending(path: "config/\(f.lastPathComponent)")) }
        for f in snap.crashFiles { try? fm.copyItem(at: f, to: root.appending(path: "crashes/\(f.lastPathComponent)")) }
        try (snap.crashSummary.joined(separator: "\n") + "\n").write(to: root.appending(path: "crashes/INDEX.txt"), atomically: true, encoding: .utf8)
        let logText: String
        if options.includeSystemLog { logText = systemLog(processes: snap.processNames, minutes: options.systemLogWindowMinutes) } else { logText = "(system log not included)\n" }
        try logText.write(to: root.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path]
        ditto.standardOutput = Pipe(); ditto.standardError = Pipe()
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
            throw NSError(domain: "DiagnosticBundle", code: Int(ditto.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ditto exit \(ditto.terminationStatus)"])
        }
        return destination
    }

    /// `log show` 最近 N 分钟、本进程与扩展进程的日志（compact 风格）。失败把错误写进去，不抛。
    static func systemLog(processes: [String], minutes: Int) -> String {
        let predicate = processes.map { "process == \"\($0)\"" }.joined(separator: " OR ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--last", "\(max(1, minutes))m", "--style", "compact", "--info", "--predicate", predicate]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return "log show failed to start: \(error)\n" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var text = "# log show --last \(minutes)m --predicate '\(predicate)' (exit \(p.terminationStatus))\n"
        text += String(decoding: data, as: UTF8.self)
        if !errData.isEmpty { text += "\n# stderr:\n" + String(decoding: errData, as: UTF8.self) }
        return text
    }
}

/// 扩展的 bundle id = App 的 + ".camera-extension"（VirtualCameraConstants.extensionBundleIdentifier 也是这么定的；这里按运行时的 bundle id 推，
/// bundle id 换了也对）。
enum VirtualCameraConstantsBridge {
    static func extensionBundleIdentifier(_ appBundleID: String) -> String { appBundleID + ".camera-extension" }
}

/// 导出流程的界面：同意对话框 → 存储面板 → 后台打包 → 完成 / 失败提示（AppDelegate 的帮助菜单与偏好设置共用）。
@MainActor
enum DiagnosticsExport {
    static func present(controller: AppController) {
        let alert = NSAlert()
        alert.messageText = L("diagnostics.alert.title")
        alert.informativeText = L("diagnostics.alert.text")
        alert.addButton(withTitle: L("diagnostics.alert.includeAll"))
        alert.addButton(withTitle: L("diagnostics.alert.minimal"))
        alert.addButton(withTitle: L("diagnostics.alert.cancel"))
        let choice = alert.runModal()
        var options = DiagnosticBundle.Options()
        switch choice {
        case .alertFirstButtonReturn: options.includeCrashLogs = true; options.includeSystemLog = true
        case .alertSecondButtonReturn: options.includeCrashLogs = false; options.includeSystemLog = false
        default: return
        }
        let panel = NSSavePanel()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = L("diagnostics.save.name", f.string(from: Date()))
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let zip = try await DiagnosticBundle.build(controller: controller, options: options, destination: url)
                NSWorkspace.shared.activateFileViewerSelecting([zip])
                let done = NSAlert()
                done.messageText = L("diagnostics.done.title")
                done.informativeText = L("diagnostics.done.text", zip.path)
                done.runModal()
            } catch {
                let failed = NSAlert()
                failed.messageText = L("diagnostics.failed.title")
                failed.informativeText = "\(error)"
                failed.runModal()
            }
        }
    }

    static func revealFolder() {
        let dir = CrashDiagnostics.shared.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// 推流 / 录制状态窗"显示日志…"（W5-P，W4C3 第 1 条）：推流 / 录制模块打的日志只在系统日志里（诊断文件夹只有 MetricKit 交来的崩溃 / 卡死记录），
    /// 所以把最近 minutes 分钟本程序与虚拟摄像头扩展的系统日志（log show，与诊断包同一个取法）导出成一份文本、放进诊断文件夹并打开。
    /// log show 要几秒，在后台跑，做完回主线程打开。
    static func showRecentLog(minutes: Int = 10) {
        let directory = CrashDiagnostics.shared.store.directory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.plusmix.switcher"
        let processes = [ProductName.executable, VirtualCameraConstantsBridge.extensionBundleIdentifier(bundleID)]
        Task.detached(priority: .userInitiated) {
            let url = try? writeRecentLog(minutes: minutes, processes: processes, directory: directory)
            await MainActor.run {
                if let url { NSWorkspace.shared.open(url) } else { revealFolder() }
            }
        }
    }

    /// 写一份 log-yyyyMMdd-HHmmss.txt 到 directory（没有就建），返回它的位置。任意线程。
    nonisolated static func writeRecentLog(minutes: Int, processes: [String], directory: URL, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appending(path: "log-\(f.string(from: now)).txt")
        try DiagnosticBundle.systemLog(processes: processes, minutes: minutes).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
