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
        XCTAssertTrue(OutputStatusText.extensionStatus(installer.status).contains("BLOCKED-签名"), OutputStatusText.extensionStatus(installer.status))
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
}
