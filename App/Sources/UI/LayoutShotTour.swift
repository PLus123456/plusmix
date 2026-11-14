// 检查点 1 的截图（W6-A，prompt 144 交付 11；docs/spec/大屏与时间线方案.md §9.1）。
// App 在隔离环境里跑起来（App/Tools/layout-shots.sh：拷一份改 bundle id、XCTestConfigurationFilePath=/dev/null 进测试宿主模式——独立 defaults、
// 空节目、API 端口 0；直接执行二进制，截屏权限跟着启动它的终端），环境变量 SWITCHER_LAYOUT_SHOTS=<输出目录> 打开这一段：
// 加 12 路图片输入（彩色底 + 名字），一张一张摆好（画布、窗口大小、调音台开收、新 / 旧排布），用 screencapture -l <窗口号> 只截自己的窗口，
// 文件名"窗口-画布-调音台[-说明].png"，写一份清单 shots.tsv（每张的摆法、中间那一列的档、画面尺寸……），然后退出。
// 没有这个变量什么都不做；只在测试宿主模式下认它（正常启动的 App 不会被一个环境变量带着截图）。不用示意图代替。
// 测试卡的形状跟着画布走（检查点 1 评审前 STG 会话要求：16:9 卡放进竖屏 / 宽墙画布，画面里大片黑，会被当成排布有问题）：
//   16:9 与 1366×762 画布：12 路都是 16:9 的卡，PGM = 机位 1、PVW = 机位 2；
//   竖屏画布：12 路都是 9:16 的竖卡（监看铺满），PGM / PVW 同上；
//   20.5:9 / 48:9 的墙：第 6 路"主视觉"换成和画布同形状的卡（铺满整幅）放 PGM，PVW 仍是 16:9 的"机位 2"（看得到两边留黑），其余各路 16:9。
// 换到要另一套卡的画布之前先把那几路的图片文件原地重写，再换画布（换 session 时图片输入按路径重新解码）。
import AppKit
import SwitcherContracts

@MainActor
enum LayoutShotTour {
    static let environmentKey = "SWITCHER_LAYOUT_SHOTS"

    struct Shot {
        let window: NSSize
        let canvas: (w: Int, h: Int)
        let mixer: Bool
        var arrangement: WindowArrangement = .adaptive
        var note = ""

        var fileName: String {
            var name = "\(Int(window.width))x\(Int(window.height))-\(canvas.w)x\(canvas.h)-" + (mixer ? "调音台开" : "调音台收")   // l10n-exempt：截图文件名
            if arrangement == .legacy { name += "-旧排布" }   // l10n-exempt：截图文件名
            if !note.isEmpty { name += "-" + note }
            return name + ".png"
        }
    }

    static let windows = [NSSize(width: 1100, height: 720), NSSize(width: 1440, height: 900), NSSize(width: 1728, height: 1117), NSSize(width: 2560, height: 1440)]

    /// 12 路输入的名字（截图里看得出哪一路在哪）。第 6 路"主视觉"在墙上铺满整幅。
    static let inputNames = ["机位 1", "机位 2", "机位 3", "PPT", "视频", "主视觉", "耳屏 A", "耳屏 B", "机位 4", "字幕", "采集卡", "备用"]   // l10n-exempt：截图用的输入名
    static let keyVisualInput = 6

    /// 这张画布用哪一套测试卡（见文件头）。
    enum CardSet: Equatable {
        /// 12 路都是 16:9。
        case landscape
        /// 12 路都是 9:16。
        case portrait
        /// 第 6 路是和墙同形状的卡（宽 : 高 = w : h），其余 16:9。
        case wall(w: Int, h: Int)
    }

    static func cardSet(for canvas: (w: Int, h: Int)) -> CardSet {
        if canvas.w < canvas.h { return .portrait }
        if (canvas.w, canvas.h) == (2460, 1080) || (canvas.w, canvas.h) == (5760, 1080) { return .wall(w: canvas.w, h: canvas.h) }
        return .landscape
    }

    /// 第 n 路在这一套里的图片尺寸（像素）：16:9 = 1280×720，9:16 = 720×1280，墙 = 720 高、按墙的比例宽。
    static func cardSize(input: Int, in set: CardSet) -> NSSize {
        switch set {
        case .landscape: return NSSize(width: 1280, height: 720)
        case .portrait: return NSSize(width: 720, height: 1280)
        case .wall(let w, let h):
            guard input == keyVisualInput else { return NSSize(width: 1280, height: 720) }
            return NSSize(width: (720 * CGFloat(w) / CGFloat(h)).rounded(), height: 720)
        }
    }

    /// PGM 放哪一路：墙上放铺满的"主视觉"，别的画布放机位 1。PVW 都是机位 2。
    static func programInput(for set: CardSet) -> Int {
        if case .wall = set { return keyVisualInput }
        return 1
    }

    /// 清单（prompt 144 交付 11）：横屏 4 种窗口 × 调音台开 / 收；竖屏 3 种窗口；1366×762、2460×1080、5760×1080 各一组（四种窗口）；
    /// 中间那一列四档都在里面（1440×900 配 16:9 = 全、1440×900 配 20.5:9 = 不带时钟、1100×720 配 16:9 = 紧凑、1100×720 配 20.5:9 = 最小）；新 / 旧排布对照一组。
    static var plan: [Shot] {
        var shots: [Shot] = []
        for w in windows { for m in [true, false] { shots.append(Shot(window: w, canvas: (1920, 1080), mixer: m)) } }
        shots.append(Shot(window: windows[1], canvas: (1920, 1080), mixer: true, arrangement: .legacy))
        for w in windows.prefix(3) { shots.append(Shot(window: w, canvas: (1080, 1920), mixer: true)) }
        shots.append(Shot(window: windows[1], canvas: (1080, 1920), mixer: false))
        shots.append(Shot(window: windows[1], canvas: (1080, 1920), mixer: true, arrangement: .legacy))
        for canvas in [(1366, 762), (2460, 1080), (5760, 1080)] {
            for w in windows { shots.append(Shot(window: w, canvas: canvas, mixer: true)) }
        }
        shots.append(Shot(window: windows[1], canvas: (2460, 1080), mixer: true, arrangement: .legacy))
        shots.append(Shot(window: windows[1], canvas: (5760, 1080), mixer: true, arrangement: .legacy))
        return shots
    }

    /// 启动后调（AppDelegate）：测试宿主模式 + 环境变量给了输出目录才跑。
    static func runIfRequested(controller: AppController) {
        guard AppDelegate.isTestHost, let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return }
        Task { @MainActor in
            await run(controller: controller, output: URL(fileURLWithPath: path, isDirectory: true))
            await controller.shutdown()
            exit(0)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func run(controller: AppController, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for _ in 0..<200 where controller.session?.isRunning != true { await sleep(0.1) }
        guard let session = controller.session else { return }
        let wc = controller.windowController
        guard let window = wc.window as? MainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.allowsFrameBeyondVisibleArea = true
        // 12 路图片输入（彩色底 + 名字），先按第一张的画布写一套卡
        let images = output.appendingPathComponent(".inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var cards = cardSet(for: plan.first?.canvas ?? (1920, 1080))
        writeCards(cards, into: images, onlyChangedFrom: nil)
        for (i, name) in inputNames.enumerated() {
            session.send(.addInput(config: InputConfig(number: i + 1, name: name, source: .image(path: cardURL(i + 1, in: images).path))))
        }
        for _ in 0..<100 where session.state.inputs.count < inputNames.count { await sleep(0.05) }
        setTally(session, cards: cards)
        var rows = ["文件\t窗口\t画布\t调音台\t排布\t摆法\t中间那一列\t画面\t上半区\t下边一行\t监看下面空"]   // l10n-exempt：清单表头
        for shot in plan {
            let format = ProgramFormat(width: shot.canvas.w, height: shot.canvas.h, frameRate: .fps30)
            // 这张画布要另一套卡：先原地重写那几路的图片，换画布（换 session）时图片输入按路径重新读
            let wanted = cardSet(for: shot.canvas)
            if wanted != cards {
                writeCards(wanted, into: images, onlyChangedFrom: cards)
                cards = wanted
            }
            if controller.session?.format != format {
                await controller.changeProgramFormat(format)
                for _ in 0..<200 where controller.session?.isRunning != true { await sleep(0.05) }
                if let s = controller.session { setTally(s, cards: cards) }
                await sleep(1.0)
            }
            wc.setArrangement(shot.arrangement)
            if wc.isMixerPanelVisible != shot.mixer { wc.toggleMixerPanel() }
            place(window, size: shot.window)
            await sleep(0.8)
            window.contentView?.layoutSubtreeIfNeeded()
            await sleep(0.4)
            let file = output.appendingPathComponent(shot.fileName)
            capture(window: window, to: file)
            rows.append(describe(shot, wc: wc))
        }
        wc.setArrangement(.adaptive)
        try? (rows.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("shots.tsv"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: images)
    }

    /// PGM（墙 = 主视觉，别的 = 机位 1）、PVW = 机位 2；已经是了就不发（重复的命令状态行会提示"命令被忽略"，截进图里）。
    private static func setTally(_ session: SwitcherSession, cards: CardSet) {
        let program = programInput(for: cards)
        if session.state.program != program { session.send(.setProgram(input: program)) }
        if session.state.preview != 2 { session.send(.setPreview(input: 2)) }
    }

    private static func cardURL(_ input: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("input-\(input).png")
    }

    /// 写一套卡（previous 给了就只重写尺寸变了的那几路）。
    private static func writeCards(_ set: CardSet, into directory: URL, onlyChangedFrom previous: CardSet?) {
        for (i, name) in inputNames.enumerated() {
            let n = i + 1
            let size = cardSize(input: n, in: set)
            if let previous, cardSize(input: n, in: previous) == size { continue }
            writeImage(to: cardURL(n, in: directory), name: name, hue: CGFloat(i) / CGFloat(inputNames.count), size: size)
        }
    }

    /// 窗口摆成正好这么大：屏幕放得下就靠可见区左上，放不下（2560×1440 的窗口在 2560×1440 的屏上）就从屏幕左上角摆。
    private static func place(_ window: NSWindow, size: NSSize) {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let full = screen?.frame ?? visible
        let fits = size.width <= visible.width && size.height <= visible.height
        let origin = fits ? NSPoint(x: visible.minX, y: visible.maxY - size.height) : NSPoint(x: full.minX, y: full.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// 只截自己的窗口（不带阴影）。
    private static func capture(window: NSWindow, to file: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("LayoutShotTour: screencapture 起不来：\(error)")
        }
    }

    /// 清单的一行：这一张实际排成什么样（从布局里量）。
    private static func describe(_ shot: Shot, wc: MainWindowController) -> String {
        let canvas = "\(shot.canvas.w)×\(shot.canvas.h)"
        let window = "\(Int(shot.window.width))×\(Int(shot.window.height))"
        let mixer = shot.mixer ? "开" : "收"   // l10n-exempt：清单
        let tier = ["全", "不带时钟", "紧凑", "最小"][wc.transitionPanel.tier.rawValue]   // l10n-exempt：清单（方案表里的叫法）
        let picture = wc.previewMonitor.display.frame.size
        let pictureText = "\(Int(picture.width))×\(Int(picture.height.rounded()))"
        guard shot.arrangement == .adaptive, let r = wc.arrangementResult else {
            return [shot.fileName, window, canvas, mixer, "旧排布", "调音台在右侧通高", tier, pictureText, "—", "—", "—"].joined(separator: "\t")   // l10n-exempt：清单
        }
        let mode = r.mode == .stacked ? "叠放" : (r.mode == .portrait ? "竖屏" : "并排")   // l10n-exempt：清单
        let fmt = { (v: CGFloat) in String(Int(v.rounded())) }
        return [shot.fileName, window, canvas, mixer, "新排布", mode, tier, pictureText, fmt(r.topHeight), fmt(r.bottomHeight), fmt(r.slack)].joined(separator: "\t")   // l10n-exempt：清单
    }

    /// 一张卡：彩色底、细框、正中写名字（截图里看得出哪一路在哪）。尺寸按这张画布的那一套（cardSize）。
    private static func writeImage(to url: URL, name: String, hue: CGFloat, size: NSSize) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80).frame(withWidth: 6)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 150, weight: .bold), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: name, attributes: attributes)
        let t = text.size()
        text.draw(at: NSPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
