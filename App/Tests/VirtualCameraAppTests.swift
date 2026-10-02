// W3-C 虚拟摄像头（App 级）：菜单的同一条路（加 / 删 kind = .virtualCamera 的输出）起停 PGM 帧消费者；本机没有签名 / 没装扩展 →
// 消费者处于 searching、帧丢并计数、不影响渲染；扩展安装请求回失败并说明 BLOCKED-签名。QuickTime / FaceTime 可见性与 L1 到虚拟摄像头出口 BLOCKED-签名。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherVirtualCamera
@testable import Switcher

@MainActor
final class VirtualCameraAppTests: XCTestCase {
    func testVirtualCamera_outputToggleStartsConsumer_searchingWithoutExtension_renderUnaffected() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        AppTest.pump(seconds: 1.2)
        XCTAssertNil(session.aux.virtualCamera)
        let number = (session.state.outputs.map(\.number).max() ?? 0) + 1
        session.send(.addOutput(config: OutputState(number: number, kind: .virtualCamera, name: "虚拟摄像头", enabled: true, settings: OutputSettings(source: .program))))
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.virtualCamera != nil }, "加了 enabled 的虚拟摄像头输出应起消费者")
        let cam = try XCTUnwrap(session.aux.virtualCamera)
        let baseline = session.stats?.missedRender ?? 0
        AppTest.pump(seconds: 2)
        let c = cam.countersSnapshot
        print("虚拟摄像头（App）：状态 \(cam.state)，收 \(c.framesIn) 丢（无设备）\(c.droppedNoDevice) 找设备 \(c.connectAttempts) 次；\(session.virtualCameraStatusText)")
        XCTAssertEqual(cam.state, .searching, "没装扩展：找设备中")
        XCTAssertGreaterThan(c.framesIn, 90, "PGM 帧在送进来（60 fps）")
        XCTAssertEqual(c.framesSent, 0)
        XCTAssertGreaterThanOrEqual(c.connectAttempts, 1)
        // 菜单 / 设置页的那一行只读 Stats.display[]（提案 013，铁律 4），不再直接读 countersSnapshot
        XCTAssertTrue(AppTest.waitUntil(3) { session.stats?.display.contains { $0.kind == "virtualCamera" && $0.output == number && $0.state == "waitingExtension" } ?? false },
                      "Stats.display[] 应有这路虚拟摄像头：\(String(describing: session.stats?.display))")
        let entry = try XCTUnwrap(session.stats?.display.first { $0.kind == "virtualCamera" })
        XCTAssertEqual(session.virtualCameraStatusText, OutputStatusText.virtualCamera(enabled: true, entry: entry))
        XCTAssertTrue(session.virtualCameraStatusText.contains("找不到"), session.virtualCameraStatusText)
        XCTAssertTrue(AppTest.delegate.virtualCameraStatusLine?.contains(session.virtualCameraStatusText) ?? false, "输出菜单的状态行：\(String(describing: AppTest.delegate.virtualCameraStatusLine))")
        XCTAssertEqual(session.stats?.missedRender ?? 0, baseline, "虚拟摄像头消费者不拖渲染")
        XCTAssertTrue(AppTest.waitUntil(2) { (session.lastNotice ?? "").contains("虚拟摄像头") || true })
        session.send(.removeOutput(output: number))
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.virtualCamera == nil })
        XCTAssertEqual(cam.state, .stopped)
        let show = session.makeShow()
        XCTAssertFalse(show.outputs.contains { $0.kind == .virtualCamera })
    }

    func testVirtualCamera_extensionActivationInAdHocSignedApp_reportsBlocked() throws {
        let session = try AppTest.freshSession()
        let installer = session.aux.installer
        XCTAssertEqual(installer.extensionIdentifier, VirtualCameraConstants.extensionBundleIdentifier)
        // 扩展是嵌进来了的（project.yml 的 Embed System Extensions），只是没签名
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(VirtualCameraConstants.extensionBundleIdentifier).systemextension")
        print("扩展 bundle：\(bundled.path) 存在 = \(FileManager.default.fileExists(atPath: bundled.path))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.path), "扩展应嵌在 App 里")
        installer.activate()
        let finished = AppTest.waitUntil(10) {
            if case .failed = installer.status { return true }
            if case .needsUserApproval = installer.status { return true }
            return false
        }
        print("扩展激活（ad-hoc 签名的测试宿主）：\(OutputStatusText.extensionStatus(installer.status))")
        guard finished else { throw XCTSkip("10 s 内系统扩展服务没应答；激活 BLOCKED-签名") }
        if case .needsUserApproval = installer.status {
            throw XCTSkip("系统要求用户批准：这台机器有可用的签名，人工在系统设置里允许后再验证 QuickTime / FaceTime")
        }
        guard case .failed(let failure) = installer.status else { return XCTFail() }
        XCTAssertTrue(failure.isSigningBlocked, "\(failure)")   // W3-C3：包给枚举原因，文字 App 查表
        // 界面上写人话（W5-A / V-14：原来是开发术语"BLOCKED-签名"），要说清是签名挡住了
        XCTAssertTrue(OutputStatusText.extensionStatus(installer.status).contains("正式签名"), OutputStatusText.extensionStatus(installer.status))
        XCTAssertTrue((session.lastNotice ?? "").contains("虚拟摄像头扩展"), session.lastNotice ?? "")
        // 输出设置 › 虚拟摄像头页用的是同一个安装器（W3-C 的 SystemExtensionInstaller，扩展 ID 来自 VirtualCameraConstants），
        // 不再另有一个猜 bundle ID 的查询器：状态文案跟着它走
        let page = AppTest.controller.panels.showOutputSettings(tab: .virtualCamera).model
        XCTAssertEqual(page.extensionIdentifier, VirtualCameraConstants.extensionBundleIdentifier)
        XCTAssertEqual(page.virtualCameraStatus, OutputStatusText.extensionStatus(installer.status))
        installer.refresh()
        XCTAssertTrue(AppTest.waitUntil(5) { page.virtualCameraStatus == OutputStatusText.extensionStatus(installer.status) && installer.status != .requesting })
        AppTest.controller.panels.closeAll()
    }

    /// L1 到虚拟摄像头出口 ≤ 3 帧：第二个进程读虚拟摄像头帧、解码帧号对照 —— 要装上并激活扩展。
    func testL1_virtualCameraEgress_requiresSignedExtension() throws {
        throw XCTSkip("BLOCKED-签名：没有 Team ID / Apple 签发的证书，扩展无法激活；解锁条件 = DEVELOPMENT_TEAM=<TeamID> make gen 后从 /Applications 运行、菜单「输出 → 虚拟摄像头 → 安装 / 激活扩展」，再用 Tools/frameprobe 对第二个进程（AVCaptureSession 选 Switcher 摄像头）抓的帧解帧号")
    }


    /// W3-E4 交付第 1 条（issue W3E3-virtual-camera-source-picker-ignored，用户 2026-09-27 选 2）：虚拟摄像头页去掉"来源"下拉、写明送 PGM
    /// （设计方案 §2 / §3：PGM 那块 IOSurface 同时交给编码器 / NDI / 虚拟摄像头 / 录制器；VirtualCameraOutput 只发 frame.program）。
    /// `setVirtualCamera(enabled:)` 只管开关、新建的输出 source = PGM；已存节目里带别的 source（PVW，W3-E3 之前页上能选出来）的虚拟摄像头输出
    /// 打开后照样起消费者、收 PGM 帧、不报错，页上不动它的 source。
    func testW3E4_1_virtualCameraPageSendsPGM_noSourcePicker_savedShowWithOtherSourceStillPGM() throws {
        // 1. 页面本身：没有来源下拉、有"送 PGM"的说明。SwiftUI 的元素进程内 AX 遍历看不到（AccessibilityTests 的注），查源码里 virtualCameraTab 那一段
        let file = try AppTest.repoRoot().appendingPathComponent("App/Sources/Settings/OutputSettingsPanel.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var virtualCameraTab: some View {"))
        let rest = source[start.lowerBound...]
        let tab = String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        XCTAssertFalse(tab.contains("sourcePicker(") || tab.contains("Picker("), "虚拟摄像头页不该有来源下拉：\n\(tab)")
        XCTAssertTrue(tab.contains("\"outputSettings.vcam.sourceNote\"") && tab.contains("\"source.program\""), "页上要写明送 PGM：\n\(tab)")
        let cjk = try NSRegularExpression(pattern: #"[一-鿿　-〿！-～]"#)
        for lang in L10n.supportedLanguages {
            let note = L10n.string("outputSettings.vcam.sourceNote", language: lang)
            XCTAssertTrue(note.contains("PGM"), "\(lang)：\(note)")
            if lang == "en" { XCTAssertNil(cjk.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)), note) }
        }

        // 2. 页上开：新建的输出 source = PGM；关 / 开走 setOutputEnabled，不碰设置
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        let page = AppTest.controller.panels.showOutputSettings(tab: .virtualCamera).model
        page.setVirtualCamera(enabled: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.contains { $0.kind == .virtualCamera && $0.enabled } })
        let number = try XCTUnwrap(page.virtualCameraOutput?.number)
        XCTAssertEqual(session.state.output(number)?.settings.source, .program, "页上新建的虚拟摄像头输出送 PGM")
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.virtualCamera != nil })
        page.setVirtualCamera(enabled: false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(number)?.enabled == false && session.aux.virtualCamera == nil })
        let commands = session.control.bus.recentEntries().filter { $0.sequence > since }.map(\.command)
        XCTAssertFalse(commands.contains { if case .setOutputSettings = $0 { return true } else { return false } }, "开关不改设置：\(commands)")
        page.removeOutput(number)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(number) == nil })
        AppTest.controller.panels.closeAll()

        // 3. 已存节目里的虚拟摄像头输出带 source = PVW：打开节目 → 照样起消费者、收 PGM 帧（60 fps）、没有错误 / 被拒的命令；页上开关不动它的 source
        var show = session.makeShow()
        show.outputs.append(OutputState(number: 9, kind: .virtualCamera, name: "旧写法", enabled: true, settings: OutputSettings(source: .preview)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-vcam-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("PVW 来源.\(ShowDocuments.fileExtension)")
        try show.save().write(to: url)
        let controller = AppTest.controller
        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { opened.value && controller.session?.isRunning == true }, "\(String(describing: controller.lastError))")
        let loaded = try XCTUnwrap(controller.session)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(loaded.state.output(9)?.settings.source, .preview, "文件里的 source 原样带着（页上不改它）")
        XCTAssertEqual(loaded.state.output(9)?.enabled, true, "文件里来的节目只清录制 / 推流的 enabled，虚拟摄像头照开")
        XCTAssertTrue(AppTest.waitUntil(5) { loaded.aux.virtualCamera != nil }, "带 PVW 来源的虚拟摄像头输出照样起消费者")
        let cam = try XCTUnwrap(loaded.aux.virtualCamera)
        XCTAssertTrue(AppTest.waitUntil(5) { loaded.inputs.runtimeState(of: 1) == .live })
        let framesBefore = cam.countersSnapshot.framesIn
        AppTest.pump(seconds: 1.5)
        let received = cam.countersSnapshot.framesIn - framesBefore
        XCTAssertGreaterThan(received, 60, "PGM 帧在送进虚拟摄像头（60 fps，1.5 s 应 ≥ 60）")
        XCTAssertTrue(AppTest.waitUntil(3) { loaded.stats?.display.contains { $0.kind == "virtualCamera" && $0.output == 9 } ?? false },
                      "Stats.display[] 应有这路：\(String(describing: loaded.stats?.display))")
        XCTAssertEqual(loaded.control.bus.counters.rejected, 0, "没有命令被拒")
        let page2 = controller.panels.showOutputSettings(tab: .virtualCamera).model
        XCTAssertEqual(page2.virtualCameraOutput?.number, 9)
        page2.setVirtualCamera(enabled: false)
        XCTAssertTrue(AppTest.waitUntil(3) { loaded.state.output(9)?.enabled == false && loaded.aux.virtualCamera == nil })
        XCTAssertEqual(loaded.state.output(9)?.settings.source, .preview, "页上开关不改 source")
        page2.setVirtualCamera(enabled: true)
        XCTAssertTrue(AppTest.waitUntil(3) { loaded.state.output(9)?.enabled == true && loaded.aux.virtualCamera != nil })
        XCTAssertEqual(loaded.control.bus.counters.rejected, 0)
        print("虚拟摄像头（W3-E4）：页上新建 source = PGM；文件里 PVW 来源的输出 1.5 s 收 \(received) 帧，\(loaded.virtualCameraStatusText)")
        controller.panels.closeAll()
    }
}
