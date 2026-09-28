// 运行中的输入表：把 MixerState.inputs（配置）变成活的 Input 对象（线程 + 帧槽 + 音频环），跟着快照增删。
// 组装规则（CONTRACTS.md §2.3 注入规则）：帧槽由这里建（W1-B 的 LockFreeFrameSlot），音频环也由这里建（W1-D 的 CAudioRing），
// 交给输入实现（InputFactory）、引擎（registerInput）和音频引擎（AudioRuntime.register）。
// W3-C：输入拿到的是 InputFrameTee（主槽 + 分支）：主槽注册给引擎（挑帧带到达余量），分支给每路的视频 ISO（OutputRuntime 按需开 / 关）。
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherISO

/// 运行中的输入表（主线程）。
@MainActor
final class InputRuntime {
    struct Entry {
        let config: InputConfig
        let made: MadeInput
        let slot: LockFreeFrameSlot
        let tee: InputFrameTee
        var input: any Input { made.input }
    }

    private let engine: Engine
    private let factory: any InputFactory
    /// 音频环的去处（nil = 不接音频）。
    private let audio: AudioRuntime?
    private(set) var entries: [Int: Entry] = [:]
    /// 输入是否已经 start（引擎起来之前先建好、注册好，引擎起来后统一 start）。
    private var started = false

    init(engine: Engine, factory: any InputFactory, audio: AudioRuntime?) {
        self.engine = engine
        self.factory = factory
        self.audio = audio
    }

    /// 某路的运行状态（没有为 nil）。
    func runtimeState(of number: Int) -> InputState? { entries[number]?.input.state }

    /// 让运行表跟上快照：新编号建 + 注册（+ start），消失的编号 stop + 注销，来源变了的重建。名字 / 设置变化不重建。
    func reconcile(_ state: MixerState, timing: ProgramTiming) {
        let wanted = Dictionary(uniqueKeysWithValues: state.inputs.map { ($0.number, $0) })
        for (number, entry) in entries where wanted[number]?.source != entry.config.source {
            remove(number)
        }
        for config in state.inputs where entries[config.number] == nil {
            add(config, timing: timing)
        }
    }

    private func add(_ config: InputConfig, timing: ProgramTiming) {
        guard config.number >= 1, config.number <= engine.maxInputs else {
            NSLog("输入 \(config.number) 超出引擎的 1…\(engine.maxInputs)，不接")
            return
        }
        let slot = LockFreeFrameSlot(capacity: 3)
        let tee = InputFrameTee(primary: slot)
        let made: MadeInput
        do {
            made = try factory.makeInput(config: config, slot: tee, timing: timing)
        } catch {
            made = MadeInput(input: PlaceholderInput(config: config, message: "\(error)"), audioRing: nil, audioBlockFrames: 0)
        }
        engine.registerInput(number: config.number, slot: slot)
        if let ring = made.audioRing, let audio {
            audio.register(number: config.number, ring: ring, blockFrames: made.audioBlockFrames)
        }
        entries[config.number] = Entry(config: config, made: made, slot: slot, tee: tee)
        if started { startInput(made.input) }
    }

    /// 给某路开一个分支槽（ISO 录制 / Aux）；没有这路或分支用完为 nil。用完 `releaseBranch`。
    func openBranch(input number: Int) -> LockFreeFrameSlot? { entries[number]?.tee.addBranch() }

    /// 某路还回来一个分支时回调（参数 = 输入编号），在还分支的调用栈上同步调。W3-E4：源是输入 n 的 NDI 发送在分支用完时靠它重新要分支（OutputRuntime）。
    var onBranchReleased: ((Int) -> Void)?

    func releaseBranch(_ slot: LockFreeFrameSlot, input number: Int) {
        entries[number]?.tee.removeBranch(slot)
        onBranchReleased?(number)
    }

    private func remove(_ number: Int) {
        guard let entry = entries.removeValue(forKey: number) else { return }
        engine.unregisterInput(number: number)
        if entry.made.audioRing != nil { audio?.unregister(number: number) }
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
