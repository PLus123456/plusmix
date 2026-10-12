// 显示类输出的接线（W3-C）：外部显示窗口（SwitcherExternal.ExternalDisplayManager，按快照里 kind = .externalDisplay 的输出增删）和
// 虚拟摄像头（SwitcherVirtualCamera.VirtualCameraOutput：快照里有 enabled 的 .virtualCamera 输出就挂到引擎上送 PGM 帧；
// SystemExtensionInstaller 管扩展的安装 / 卸载，状态给菜单 / 状态行 / 输出设置页——App 里只有这一个安装器）。
// 这两类不是编码器输出，读数进 Stats.display[]（提案 013，`statsEntries`）；给人看的文案由 App 查表（OutputStatusText），事件只带枚举。
import AppKit
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherExternal
import SwitcherVirtualCamera

@MainActor
final class AuxOutputRuntime {
    enum Event: Equatable {
        case externalDisplay(output: Int, status: ExternalDisplayWindow.Status)
        case virtualCameraStarted
        case virtualCameraStopped
        case extensionStatus(SystemExtensionInstaller.Status)
    }

    let external: ExternalDisplayManager
    let installer: SystemExtensionInstaller
    private(set) var virtualCamera: VirtualCameraOutput?
    private let engine: Engine
    private let format: ProgramFormat
    var onEvent: ((Event) -> Void)?
    /// 用户在外部窗口按 Esc → 关那一路（setOutputEnabled off，经命令总线；配置留着，与路由菜单的"关闭"同一条命令，W5-O）。
    var sendCommand: ((Command) -> Void)?
    /// 界面上的显示视图在 Stats 里的项（提案 013）：主界面监视器（output 0，kind "monitor"）与多画面窗口（kind "multiviewWindow"）。
    /// 由 `MainWindowController` 注册——那两个视图归界面所有，运行时这里看不到。
    var uiDisplayEntries: (@MainActor () -> [Stats.DisplayEntry])?
    /// 当前虚拟摄像头输出的编号（reconcile 时记；没有就是 0）。
    private var virtualCameraOutput = 0
    /// 扩展状态的观察者（输出设置 › 虚拟摄像头页）：installer 只有一个 onStatusChange，由这里扇出。
    private var extensionObservers: [(key: UInt64, block: @MainActor (SystemExtensionInstaller.Status) -> Void)] = []
    private var observerCounter: UInt64 = 0

    init(engine: Engine, source: any DisplayFrameSource, format: ProgramFormat) {
        self.engine = engine
        self.format = format
        external = ExternalDisplayManager(source: source)
        installer = SystemExtensionInstaller()
        external.onStatusChange = { [weak self] number, status in self?.onEvent?(.externalDisplay(output: number, status: status)) }
        // Esc 只关不删（W5-O，问题单 W4C2-w5-app-inputs-outputs-gaps 第 1 条）：原来发 removeOutput，现场在投影窗口上误按一下，这块屏的显示器 / 来源配置就没了
        external.onCloseRequested = { [weak self] number in self?.sendCommand?(.setOutputEnabled(output: number, on: false)) }
        installer.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.onEvent?(.extensionStatus(status))
            for o in self.extensionObservers { o.block(status) }
        }
    }

    /// 扩展状态变化时回调（立刻用当前状态回调一次）。释放凭据即取消。
    func observeExtensionStatus(_ block: @escaping @MainActor (SystemExtensionInstaller.Status) -> Void) -> ObserverToken {
        observerCounter &+= 1
        let key = observerCounter
        extensionObservers.append((key, block))
        block(installer.status)
        return ObserverToken { [weak self] in
            Task { @MainActor in self?.extensionObservers.removeAll { $0.key == key } }
        }
    }

    /// 跟快照：外部显示窗口表 + 虚拟摄像头开关。
    func reconcile(_ state: MixerState) {
        external.reconcile(outputs: state.outputs, inputs: state.inputs, format: state.format)
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
}
