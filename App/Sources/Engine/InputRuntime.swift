// 运行中的输入表：把 MixerState.inputs（配置）变成活的 Input 对象（线程 + 帧槽 + 音频环），跟着快照增删。
// 组装规则（CONTRACTS.md §2.3 注入规则）：帧槽由这里建（W1-B 的 LockFreeFrameSlot），音频环也由这里建（W1-D 的 CAudioRing），
// 交给输入实现（InputFactory）、引擎（registerInput）和音频引擎（AudioRuntime.register）。
// W3-C：输入拿到的是 InputFrameTee（主槽 + 分支）：主槽注册给引擎（挑帧带到达余量），分支给每路的视频 ISO（OutputRuntime 按需开 / 关）。
// W5-H：文件输入"只有结束动作变了"（格子上的循环开关）不重建，改在跑着的那个 FileInput 上；图片输入盯着文件，外面改了对同一个输入对象重新读同一条路径
// （ImageFileWatcher；SwitcherInputs 里有监视之前的接线，问题单 W5H-w2-inputs-image-input-no-file-watch）。
// W5-N（01a D5 / 02 V04，提案 021）：结束动作 / 速率变了（路径没变）都就地改；播放目标（`settings.playback.paused`）与定位请求
// （`seekTick` + `seekSeconds`，⟲ 与"切上 PGM 时从头播"同一条路）按快照对到跑着的 FileInput 的 pause / resume / seek 上，不重建这一路。
// W5-P（D06）：换来源只换输入对象，这一路的 tee 与引擎注册不换——ISO 录制 / Aux 窗口挂的分支跟着新来源走（replaceSource）。
import CoreVideo
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherDeckLink
import SwitcherNDI
import SwitcherISO

/// 输入对象自己报的最近一句原因（各输入类的 `lastError`：设备不在 / 被拔了、驱动没装、NDI 源找不到……）。它不在契约的 Input 协议里，
/// App 这边让各类回溯遵守，格子在无信号时写成第二行（W5-O，问题单 W4C2-w5-app-inputs-outputs-gaps 第 2 条；不改契约）。
protocol InputLastErrorReporting: AnyObject {
    var lastError: String? { get }
}

extension CameraInput: InputLastErrorReporting {}
extension ScreenInput: InputLastErrorReporting {}
extension FileInput: InputLastErrorReporting {}
extension ImageInput: InputLastErrorReporting {}
extension AudioDeviceInput: InputLastErrorReporting {}
extension DeckLinkInput: InputLastErrorReporting {}
extension NDIInput: InputLastErrorReporting {}

/// 运行中的输入表（主线程）。
@MainActor
final class InputRuntime {
    struct Entry {
        /// 快照里的配置（相对路径原样；只改结束动作 / 速率时就地换成新的）。
        var config: InputConfig
        let made: MadeInput
        let slot: LockFreeFrameSlot
        let tee: InputFrameTee
        var input: any Input { made.input }
        /// 已经对到 FileInput 上的暂停目标（start 之后才对得上：FileInput.start 把暂停清掉）。
        var appliedPaused = false
        /// 已经做过的那次定位请求（seekTick + seekSeconds）；nil = 还没做过。
        var appliedSeek: SeekRequest?
    }

    /// 一次定位请求（提案 021：seekTick 与 seekSeconds 一起构成"一次"，同一拍同一位置再发不算新的）。
    struct SeekRequest: Equatable {
        var tick: Tick
        var seconds: Double
    }

    private let engine: Engine
    private let factory: any InputFactory
    /// 音频环的去处（nil = 不接音频）。
    private let audio: AudioRuntime?
    private(set) var entries: [Int: Entry] = [:]
    /// 输入是否已经 start（引擎起来之前先建好、注册好，引擎起来后统一 start）。
    private var started = false
    /// 最近一次快照里每路的播放目标（文件输入才用；start 之后对上去）。
    private var playbackTargets: [Int: PlaybackSettings] = [:]
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

    /// 某路的运行状态（没有为 nil）。
    func runtimeState(of number: Int) -> InputState? { entries[number]?.input.state }

    /// 某路输入自己报的最近一句原因（lastError；这一类不报 / 没有为 nil）。
    func lastError(of number: Int) -> String? { (entries[number]?.input as? InputLastErrorReporting)?.lastError }

    /// 让运行表跟上快照：新编号建 + 注册（+ start），消失的编号 stop + 注销，来源变了的换输入对象（`replaceSource`：帧出口不换）。名字 / 设置变化不重建；
    /// 文件输入只有结束动作 / 速率变了（路径没变）也不重建：改在跑着的 FileInput 上（两样都运行中可改），播放位置接着走（W5-H 的循环、W5-N 的速率）。
    /// 播放目标（暂停 / 定位）随后由 `applyPlayback` 对上去。
    func reconcile(_ state: MixerState, timing: ProgramTiming) {
        playbackTargets = Self.playbackTargets(of: state)
        let wanted = Dictionary(uniqueKeysWithValues: state.inputs.map { ($0.number, $0) })
        for (number, entry) in entries {
            guard let config = wanted[number] else { remove(number); continue }
            guard config.source != entry.config.source else { continue }
            if let change = Self.inPlaceFileChange(from: entry.config.source, to: config.source), let file = entry.input as? FileInput {
                if file.endAction != change.endAction { file.endAction = change.endAction }
                if file.rate != change.rate { file.rate = change.rate }
                entries[number]?.config = config
                continue
            }
            replaceSource(number, with: config, timing: timing)
        }
        for config in state.inputs where entries[config.number] == nil {
            add(config, timing: timing)
        }
        applyPlayback(state)
    }

    /// 播放目标对到跑着的文件输入上（提案 021；快照里任何一路的 `settings.playback` 变了就调，SwitcherSession.pollSnapshot）：
    /// paused 与已对上的不同 → pause / resume；(seekTick, seekSeconds) 是新的一次请求 → seek（暂停中定位：停在目标那一帧、仍暂停）。
    /// 还没 start 的路只记下，start 之后 `startInput` 再对（FileInput.start 会把暂停清掉、定位要等文件打开）。
    func applyPlayback(_ state: MixerState) {
        playbackTargets = Self.playbackTargets(of: state)
        guard started else { return }
        for number in entries.keys.sorted() { syncPlayback(number) }
    }

    private static func playbackTargets(of state: MixerState) -> [Int: PlaybackSettings] {
        Dictionary(state.inputs.map { ($0.number, $0.settings.playback) }, uniquingKeysWith: { first, _ in first })
    }

    /// 快照里这一路现有的定位请求（建对象那一刻已经在的请求不再做：那是给上一个对象的，例如换了文件之后不该跳到旧文件的位置）。
    private func currentSeekRequest(_ number: Int) -> SeekRequest? {
        guard let p = playbackTargets[number], let tick = p.seekTick, let seconds = p.seekSeconds else { return nil }
        return SeekRequest(tick: tick, seconds: seconds)
    }

    private func syncPlayback(_ number: Int) {
        guard let entry = entries[number], let file = entry.input as? FileInput, let target = playbackTargets[number] else { return }
        if target.paused != entry.appliedPaused {
            if target.paused { file.pause() } else { file.resume() }
            entries[number]?.appliedPaused = target.paused
        }
        if let tick = target.seekTick, let seconds = target.seekSeconds {
            let request = SeekRequest(tick: tick, seconds: seconds)
            if request != entry.appliedSeek {
                file.seek(toSeconds: seconds)
                entries[number]?.appliedSeek = request
            }
        }
    }

    private func add(_ config: InputConfig, timing: ProgramTiming) {
        guard config.number >= 1, config.number <= engine.maxInputs else {
            NSLog("输入 \(config.number) 超出引擎的 1…\(engine.maxInputs)，不接")
            return
        }
        let slot = LockFreeFrameSlot(capacity: 3)
        let tee = InputFrameTee(primary: slot)
        let made = make(config, slot: tee, timing: timing)
        engine.registerInput(number: config.number, slot: slot)
        if let ring = made.audioRing, let audio {
            audio.register(number: config.number, ring: ring, blockFrames: made.audioBlockFrames)
        }
        entries[config.number] = Entry(config: config, made: made, slot: slot, tee: tee, appliedSeek: currentSeekRequest(config.number))
        if started {
            startInput(made.input)
            syncPlayback(config.number)
        }
        watchImage(config, made)
    }

    /// 换来源（D06，Codex 2026-10-13 审查；用户 2026-10-17 定：ISO 录制中换源跟着新来源继续录、Recorder 不断）：这一路的帧出口——tee（主槽 + 各分支）
    /// 与引擎注册——不换，只把往里推帧的输入对象换掉。原来每次换源都建新 tee，挂在旧 tee 分支上的 ISO 录制 / Aux 窗口接着读一个再没人推的槽，
    /// 每拍重复旧来源的最后一帧、录像一直定格到停。现在它们不用重挂，新来源的帧照常进同一个分支，节目拍点连续、录制器不断；
    /// 新来源第一帧到之前，各槽重复旧来源的最后一帧（引擎 per_input 的 dup、ISO tap 的 repeated 记账）。
    /// 先停旧的再建新的：同一个 tee 的生产者从旧输入换成新输入，SPSC 槽不能两个线程同时推（各输入的 stop 都同步收掉线程 / 回调队列）。
    /// 新来源不出画面（建不出来的占位、纯音频设备、start 当场失败的——例如图片文件不在）而旧来源推过帧：往 tee 里推一帧黑——
    /// 与新加这种输入时"空槽画黑"一致，不停在旧来源的最后一帧上。起来之后才没信号的（设备晚到、NDI 源不在）照旧停在最后一帧，同来源中途断掉。
    private func replaceSource(_ number: Int, with config: InputConfig, timing: ProgramTiming) {
        guard let old = entries[number] else {
            add(config, timing: timing)
            return
        }
        imageWatchers.removeValue(forKey: number)?.stop()
        if old.made.audioRing != nil { audio?.unregister(number: number) }
        old.input.stop()
        let made = make(config, slot: old.tee, timing: timing)
        if let ring = made.audioRing, let audio {
            audio.register(number: number, ring: ring, blockFrames: made.audioBlockFrames)
        }
        entries[number] = Entry(config: config, made: made, slot: old.slot, tee: old.tee, appliedSeek: currentSeekRequest(number))
        var startFailed = false
        if started {
            startFailed = !startInput(made.input)
            syncPlayback(number)
        }
        if made.input.videoSlot == nil || startFailed, old.slot.stats.pushed > 0 {
            Self.pushBlackFrame(into: old.tee, input: number, format: timing.format)
        }
        watchImage(config, made)
    }

    /// 建输入对象（交给它的是 slot，一般是这一路的 tee）；建不出来画占位。只改交给输入对象的那份配置：运行表 / 快照 / 节目文件里仍是相对路径。
    private func make(_ config: InputConfig, slot: any FrameSlot, timing: ProgramTiming) -> MadeInput {
        do {
            return try factory.makeInput(config: Self.resolvingMediaPaths(config, against: mediaBaseDirectory), slot: slot, timing: timing)
        } catch {
            return MadeInput(input: PlaceholderInput(config: config, message: "\(error)"), audioRing: nil, audioBlockFrames: 0)
        }
    }

    /// 图片输入盯着文件（W5-H）。
    private func watchImage(_ config: InputConfig, _ made: MadeInput) {
        if case .image(let path) = Self.resolvingMediaPaths(config, against: mediaBaseDirectory).source, made.input is ImageInput {
            let number = config.number
            imageWatchers[number] = ImageFileWatcher(path: path) { [weak self] in self?.reloadImage(number) }
        }
    }

    /// 往一路的 tee 里推一帧黑（节目尺寸、BGRA、IOSurface 背后；主线程，只在换源换到不出画面的来源时用一次）。旧输入已经停了、新输入不推，
    /// 这一刻主线程是这个 tee 唯一的生产者。pts = 现在：下一拍起引擎与各分支都挑到它。
    static func pushBlackFrame(into slot: any FrameSlot, input number: Int, format: ProgramFormat) {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, max(16, format.width), max(16, format.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
            for y in 0..<height {
                let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width { row[x] = 0xFF00_0000 }   // B G R = 0，A = 255（预乘也是黑）
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let now = HostClock.now()
        slot.push(Frame(pixelBuffer: buffer, pts: now, duration: HostDuration(seconds: format.frameDuration.doubleValue), color: .sRGBFull,
                        inputNumber: number, sequence: 0, ingressTime: now))
    }

    /// 两个来源是同一个文件、只差结束动作和 / 或速率（都能运行中改）：返回新的结束动作与速率；否则 nil（路径变了 / 不是文件 / 没变）。
    nonisolated static func inPlaceFileChange(from old: InputSource, to new: InputSource) -> (endAction: FileEndAction, rate: Double)? {
        guard case .file(let oldPath, let oldEnd, let oldRate) = old, case .file(let newPath, let newEnd, let newRate) = new,
              oldPath == newPath, oldEnd != newEnd || oldRate != newRate, newRate > 0, newRate.isFinite else { return nil }
        return (newEnd, newRate)
    }

    /// 图片文件在外面被改了：同一个输入对象停了再起 = 按同一条路径重新解码，帧槽、引擎注册、ISO 分支都不动（PGM 上停在上一帧、下一拍换上，不闪黑）。
    /// 解码在主线程上（和加图片输入时一样，几十毫秒）；引擎还没起（started = false）时只等 startAll 去读。
    private func reloadImage(_ number: Int) {
        guard started, let input = entries[number]?.input as? ImageInput else { return }
        input.stop()
        startInput(input)
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

    /// 起一路输入；起不来记日志、返回 false（格子上照它的 state 显示原因）。
    @discardableResult
    private func startInput(_ input: any Input) -> Bool {
        do {
            try input.start()
            return true
        } catch {
            NSLog("输入 \(input.number) 启动失败：\(error)")
            return false
        }
    }

    /// 引擎起来之后统一 start（合成源到 t0 才出第一帧，所以顺序无所谓）；文件输入随后对上播放目标（节目里存着"暂停"的那一路 start 完就停住）。
    func startAll() {
        started = true
        for entry in entries.values { startInput(entry.input) }
        for number in entries.keys.sorted() { syncPlayback(number) }
    }

    /// 全部停掉并注销。
    func stopAll() {
        for number in entries.keys.sorted() { remove(number) }
        started = false
    }
}
