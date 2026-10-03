// 运行中的输入表：把 MixerState.inputs（配置）变成活的 Input 对象（线程 + 帧槽 + 音频环），跟着快照增删。
// 组装规则（CONTRACTS.md §2.3 注入规则）：帧槽由这里建（W1-B 的 LockFreeFrameSlot），音频环也由这里建（W1-D 的 CAudioRing），
// 交给输入实现（InputFactory）、引擎（registerInput）和音频引擎（AudioRuntime.register）。
// W3-C：输入拿到的是 InputFrameTee（主槽 + 分支）：主槽注册给引擎（挑帧带到达余量），分支给每路的视频 ISO（OutputRuntime 按需开 / 关）。
// W5-H：文件输入"只有结束动作变了"（格子上的循环开关）不重建，改在跑着的那个 FileInput 上；图片输入盯着文件，外面改了对同一个输入对象重新读同一条路径
// （ImageFileWatcher；SwitcherInputs 里有监视之前的接线，问题单 W5H-w2-inputs-image-input-no-file-watch）。
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherISO

/// 运行中的输入表（主线程）。
@MainActor
final class InputRuntime {
    struct Entry {
        /// 快照里的配置（相对路径原样；只改结束动作时就地换成新的）。
        var config: InputConfig
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
    /// 素材（图片 / 视频文件）相对路径的基准目录（W3-E5，reports/issues/W4C-app-relative-media-paths.md）：节目文件所在目录；
    /// 节目没保存过 = 默认录制目录 ~/Movies/PlusMix（AppController 按 ShowDocuments 给，另存后换成新位置）。只影响之后建的输入：
    /// 已在跑的路不重建（"另存为"到别的目录时素材要跟着搬，Samples/README.md §2）。
    var mediaBaseDirectory = URL(fileURLWithPath: ShowDocuments.defaultRecordDirectory, isDirectory: true)

    init(engine: Engine, factory: any InputFactory, audio: AudioRuntime?) {
        self.engine = engine
        self.factory = factory
        self.audio = audio
    }

    /// 图片输入的文件监视（按输入编号）。
    private var imageWatchers: [Int: ImageFileWatcher] = [:]
    /// 正在监视的图片文件（已解析成绝对路径，按编号排；测试看）。
    var watchedImagePaths: [String] { imageWatchers.keys.sorted().compactMap { imageWatchers[$0]?.path } }
    /// 图片文件改了、重新读过几次（按编号；测试 / 诊断看）。
    private(set) var imageReloads: [Int: Int] = [:]

    /// 某路的运行状态（没有为 nil）。
    func runtimeState(of number: Int) -> InputState? { entries[number]?.input.state }

    /// 让运行表跟上快照：新编号建 + 注册（+ start），消失的编号 stop + 注销，来源变了的重建。名字 / 设置变化不重建；
    /// 文件输入只有结束动作变了（路径、速率都没变）也不重建：改在跑着的 FileInput 上（它的 endAction 运行中可改），播放位置接着走（W5-H，D5 的循环）。
    func reconcile(_ state: MixerState, timing: ProgramTiming) {
        let wanted = Dictionary(uniqueKeysWithValues: state.inputs.map { ($0.number, $0) })
        for (number, entry) in entries {
            guard let config = wanted[number] else { remove(number); continue }
            guard config.source != entry.config.source else { continue }
            if let endAction = Self.onlyEndActionChanged(from: entry.config.source, to: config.source), let file = entry.input as? FileInput {
                file.endAction = endAction
                entries[number]?.config = config
                continue
            }
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
            // 只改交给输入对象的那份配置：运行表 / 快照 / 节目文件里仍是相对路径
            made = try factory.makeInput(config: Self.resolvingMediaPaths(config, against: mediaBaseDirectory), slot: tee, timing: timing)
        } catch {
            made = MadeInput(input: PlaceholderInput(config: config, message: "\(error)"), audioRing: nil, audioBlockFrames: 0)
        }
        engine.registerInput(number: config.number, slot: slot)
        if let ring = made.audioRing, let audio {
            audio.register(number: config.number, ring: ring, blockFrames: made.audioBlockFrames)
        }
        entries[config.number] = Entry(config: config, made: made, slot: slot, tee: tee)
        if started { startInput(made.input) }
        if case .image(let path) = Self.resolvingMediaPaths(config, against: mediaBaseDirectory).source, made.input is ImageInput {
            let number = config.number
            imageWatchers[number] = ImageFileWatcher(path: path) { [weak self] in self?.reloadImage(number) }
        }
    }

    /// 两个来源只差结束动作（同一个文件、同一个速率）：返回新的结束动作；否则 nil。
    nonisolated static func onlyEndActionChanged(from old: InputSource, to new: InputSource) -> FileEndAction? {
        guard case .file(let oldPath, let oldEnd, let oldRate) = old, case .file(let newPath, let newEnd, let newRate) = new,
              oldPath == newPath, oldRate == newRate, oldEnd != newEnd else { return nil }
        return newEnd
    }

    /// 图片文件在外面被改了：同一个输入对象停了再起 = 按同一条路径重新解码，帧槽、引擎注册、ISO 分支都不动（PGM 上停在上一帧、下一拍换上，不闪黑）。
    /// 解码在主线程上（和加图片输入时一样，几十毫秒）；引擎还没起（started = false）时只等 startAll 去读。
    private func reloadImage(_ number: Int) {
        guard started, let input = entries[number]?.input as? ImageInput else { return }
        input.stop()
        startInput(input)
        imageReloads[number, default: 0] += 1
    }

    /// 图片 / 视频文件输入的相对路径挂到 base 下，与 headless 同一条规则（HeadlessRun 第 1 步：以 / 开头原样，否则 `showURL 所在目录/path`）；
    /// 绝对路径与别的来源原样。之前 App 把路径原样交给 ImageInput / FileInput，等于相对进程工作目录（Finder / Dock 起的 App 是 /），
    /// 从菜单打开样例节目时图片那几路建不出来、变占位（W4-C 的问题单）。
    nonisolated static func resolvingMediaPaths(_ config: InputConfig, against base: URL) -> InputConfig {
        func resolve(_ path: String) -> String { path.hasPrefix("/") ? path : base.appendingPathComponent(path).path }
        var resolved = config
        switch config.source {
        case .image(let path): resolved.source = .image(path: resolve(path))
        case .file(let path, let endAction, let rate): resolved.source = .file(path: resolve(path), endAction: endAction, rate: rate)
        default: break
        }
        return resolved
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
        imageWatchers.removeValue(forKey: number)?.stop()
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
