// 运行中的输入表：把 MixerState.inputs（配置）变成活的 Input 对象（线程 + 帧槽），跟着快照增删。
// 组装规则（CONTRACTS.md §2.3 注入规则）：帧槽由这里建（W1-B 的 LockFreeFrameSlot），交给输入实现和引擎。
// W2-B 只会做合成源（TestKit 的 SyntheticVideoInput）；摄像头 / 屏幕 / 文件 / 图片的实现在 W2-A（SwitcherInputs），
// G3 合并时把它们的工厂接到 `InputFactory` 上（几行胶水），本文件不用改。
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherTestKit

/// 把一路输入配置变成运行对象。
protocol InputFactory {
    /// - Parameters:
    ///   - slot: 组装方建好的帧槽，实现只往里 push。
    ///   - timeline: 合成源共用的时间线（t0 对齐到节目拍点、提前半个节目帧，见 SwitcherSession）。
    func makeInput(config: InputConfig, slot: LockFreeFrameSlot, timeline: SyntheticTimeline) throws -> any Input
}

enum InputFactoryError: Error, CustomStringConvertible {
    /// 这种输入的实现还没合进来（W2-A）。
    case unsupported(InputKind)
    var description: String {
        switch self {
        case .unsupported(let kind): "\(kind) 输入的实现在 W2-A，合并后可用"
        }
    }
}

/// W2-B 的默认工厂：只认合成源。
struct DefaultInputFactory: InputFactory {
    func makeInput(config: InputConfig, slot: LockFreeFrameSlot, timeline: SyntheticTimeline) throws -> any Input {
        switch config.source {
        case .synthetic(let settings):
            let tl = SyntheticTimeline(t0: timeline.t0, frameRate: settings.frameRate)
            return try SyntheticVideoInput(number: config.number, name: config.name, settings: settings, videoSlot: slot,
                                           audioRing: nil, timeline: tl, seed: UInt64(config.number))
        default:
            throw InputFactoryError.unsupported(config.kind)
        }
    }
}

/// 建不出来的输入占位：编号占着、帧槽为空（画黑），state 带文案给 UI 显示。
final class PlaceholderInput: Input, @unchecked Sendable {
    let number: Int
    let name: String
    let kind: InputKind
    let state: InputState
    let videoSlot: (any FrameSlot)? = nil
    let audioRing: (any AudioRing)? = nil
    init(config: InputConfig, message: String) {
        number = config.number
        name = config.name
        kind = config.kind
        state = .error(message: message)
    }
    func start() throws {}
    func stop() {}
}

/// 运行中的输入表（主线程）。
@MainActor
final class InputRuntime {
    struct Entry {
        let config: InputConfig
        let input: any Input
        let slot: LockFreeFrameSlot
    }

    private let engine: Engine
    private let factory: any InputFactory
    private(set) var entries: [Int: Entry] = [:]
    /// 输入是否已经 start（引擎起来之前先建好、注册好，引擎起来后统一 start）。
    private var started = false

    init(engine: Engine, factory: any InputFactory) {
        self.engine = engine
        self.factory = factory
    }

    /// 某路的运行状态（没有为 nil）。
    func runtimeState(of number: Int) -> InputState? { entries[number]?.input.state }

    /// 让运行表跟上快照：新编号建 + 注册（+ start），消失的编号 stop + 注销，来源变了的重建。名字 / 设置变化不重建。
    func reconcile(_ state: MixerState, timeline: SyntheticTimeline) {
        let wanted = Dictionary(uniqueKeysWithValues: state.inputs.map { ($0.number, $0) })
        for (number, entry) in entries where wanted[number]?.source != entry.config.source {
            remove(number)
        }
        for config in state.inputs where entries[config.number] == nil {
            add(config, timeline: timeline)
        }
    }

    private func add(_ config: InputConfig, timeline: SyntheticTimeline) {
        guard config.number >= 1, config.number <= engine.maxInputs else {
            NSLog("输入 \(config.number) 超出引擎的 1…\(engine.maxInputs)，不接")
            return
        }
        let slot = LockFreeFrameSlot(capacity: 3)
        let input: any Input
        do {
            input = try factory.makeInput(config: config, slot: slot, timeline: timeline)
        } catch {
            input = PlaceholderInput(config: config, message: "\(error)")
        }
        engine.registerInput(number: config.number, slot: slot)
        entries[config.number] = Entry(config: config, input: input, slot: slot)
        if started { startInput(input) }
    }

    private func remove(_ number: Int) {
        guard let entry = entries.removeValue(forKey: number) else { return }
        engine.unregisterInput(number: number)
        entry.input.stop()
    }

    private func startInput(_ input: any Input) {
        do { try input.start() } catch { NSLog("输入 \(input.number) 启动失败：\(error)") }
    }

    /// 引擎起来之后统一 start（合成源到 t0 才出第一帧，所以顺序无所谓）。
    func startAll() {
        started = true
        for entry in entries.values { startInput(entry.input) }
    }

    /// 全部停掉并注销。
    func stopAll() {
        for number in entries.keys.sorted() { remove(number) }
        started = false
    }
}
