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
    /// 界面上的显示视图在 Stats 里的项（提案 013）：主界面监视器（output 0，kind "monitor"）与多画面窗口（kind "multiviewWindow"）。
    /// 由 `MainWindowController` 注册——那两个视图归界面所有，运行时这里看不到。
    var uiDisplayEntries: (@MainActor () -> [Stats.DisplayEntry])?
    /// 当前虚拟摄像头输出的编号（reconcile 时记；没有就是 0）。
    private var virtualCameraOutput = 0

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
        virtualCameraOutput = state.outputs.first { $0.kind == .virtualCamera && $0.enabled }?.number ?? 0
        let wantCamera = virtualCameraOutput != 0
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

    /// 显示类输出在 Stats 里的全部项（提案 013，铁律 4：菜单 / API / 测试读同一个结构）。主线程调。
    /// 外部显示窗口与虚拟摄像头由 SwitcherOutputs 的 `statsEntry` 给，界面上的两个视图由 `uiDisplayEntries` 给。
    var statsEntries: [Stats.DisplayEntry] {
        var out = external.statsEntries
        if let cam = virtualCamera { out.append(cam.statsEntry(output: virtualCameraOutput)) }
        out.append(contentsOf: uiDisplayEntries?() ?? [])
        return out
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
