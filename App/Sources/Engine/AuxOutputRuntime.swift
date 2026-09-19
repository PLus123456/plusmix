// 显示类输出的接线（W3-C）：外部显示窗口（SwitcherExternal.ExternalDisplayManager，按快照里 kind = .externalDisplay 的输出增删）和
// 虚拟摄像头（SwitcherVirtualCamera.VirtualCameraOutput：快照里有 enabled 的 .virtualCamera 输出就挂到引擎上送 PGM 帧；
// SystemExtensionInstaller 管扩展的安装 / 卸载，状态给菜单 / 状态行）。这两类不是编码器输出，Stats.encoder 里没有它们的项（报告 §4）。
import AppKit
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherExternal
import SwitcherVirtualCamera

@MainActor
final class AuxOutputRuntime {
    enum Event: Equatable {
        case externalDisplay(output: Int, status: String)
        case virtualCameraStarted
        case virtualCameraStopped
        case extensionStatus(String)
    }

    let external: ExternalDisplayManager
    let installer: SystemExtensionInstaller
    private(set) var virtualCamera: VirtualCameraOutput?
    /// 各外部输出的状态文案（菜单里显示）。
    private(set) var externalStatuses: [Int: String] = [:]
    private let engine: Engine
    private let format: ProgramFormat
    var onEvent: ((Event) -> Void)?
    /// 用户在外部窗口按 Esc → 删那个输出（经命令总线）。
    var sendCommand: ((Command) -> Void)?

    init(engine: Engine, source: any DisplayFrameSource, format: ProgramFormat) {
        self.engine = engine
        self.format = format
        external = ExternalDisplayManager(source: source)
        installer = SystemExtensionInstaller()
        external.onStatusChange = { [weak self] number, status in
            let text = ExternalDisplayManager.describe(status)
            self?.externalStatuses[number] = text
            self?.onEvent?(.externalDisplay(output: number, status: text))
        }
        external.onCloseRequested = { [weak self] number in self?.sendCommand?(.removeOutput(output: number)) }
        installer.onStatusChange = { [weak self] status in self?.onEvent?(.extensionStatus(SystemExtensionInstaller.describe(status))) }
    }

    /// 跟快照：外部显示窗口表 + 虚拟摄像头开关。
    func reconcile(_ state: MixerState) {
        external.reconcile(outputs: state.outputs, inputs: state.inputs, format: state.format)
        for n in externalStatuses.keys where external.windows[n] == nil { externalStatuses.removeValue(forKey: n) }
        let wantCamera = state.outputs.contains { $0.kind == .virtualCamera && $0.enabled }
        if wantCamera, virtualCamera == nil {
            let cam = VirtualCameraOutput(format: format)
            cam.start()
            engine.addConsumer(cam)
            virtualCamera = cam
            onEvent?(.virtualCameraStarted)
        } else if !wantCamera, let cam = virtualCamera {
            engine.removeConsumer(cam)
            cam.stop()
            virtualCamera = nil
            onEvent?(.virtualCameraStopped)
        }
    }

    /// 全部停掉（换节目 / 退出）。
    func stopAll() {
        external.closeAll()
        if let cam = virtualCamera {
            engine.removeConsumer(cam)
            cam.stop()
            virtualCamera = nil
        }
    }

    /// 虚拟摄像头一行状态（菜单 / 面板）。
    var virtualCameraStatusText: String {
        guard let cam = virtualCamera else { return "未启用" }
        let c = cam.countersSnapshot
        switch cam.state {
        case .idle: return "未启动"
        case .searching: return "找不到虚拟摄像头设备（扩展未安装 / 未激活）；已丢 \(c.droppedNoDevice) 帧"
        case .connected: return "已连接，送出 \(c.framesSent) 帧"
        case .stopped: return "已停止"
        }
    }
}
