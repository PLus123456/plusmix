// 每路输入音频环的注册与延后重试（从 AudioRuntime 拆出来，D07 的用例要换成可控的计钟替身）。
// 同一编号刚摘掉还在淡出（removalFadeBlocks ≈ 16 ms）时 registerInput 撞 inputAlreadyRegistered：过 30 ms 再试，最多 10 次；其他错误（槽位用完）记日志放弃。
// D07（Codex 2026-10-13 审查）：每路一个代次。再注册（又换了来源）、摘除（删了这一路）、引擎停都让这一路排着的旧重试作废，重试到点先核对代次——
// 原来 A → B → C 连换两次来源时 B、C 两条重试链同时在跑，先注册上的可能是 B（生产者已停，残留音频耗尽后无声），C 那条撞满 10 次
// （时序替身：最终 B、累计重试 11 次）；B 还没注册上时删掉这一路，B 也照样会被注册上。
import Foundation
import SwitcherContracts
import SwitcherAudio
import SwitcherAudioIntegration

@MainActor
final class AudioInputRegistration {
    /// 重试间隔（毫秒）与次数上限。
    static let retryDelayMilliseconds = 30
    static let maxAttempts = 10

    /// 主线程上过 ms 毫秒做 work（真的用 DispatchQueue.main；用例换成手动拨的钟）。
    typealias Scheduler = @MainActor (_ milliseconds: Int, _ work: @escaping @MainActor () -> Void) -> Void

    static let mainQueueScheduler: Scheduler = { milliseconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { MainActor.assumeIsolated { work() } }
    }

    private let registerInEngine: @MainActor (Int, any AudioRing, AudioInputHints) throws -> Void
    private let unregisterInEngine: @MainActor (Int) -> Void
    private let schedule: Scheduler
    /// 已经注册上的编号。
    private(set) var registered: Set<Int> = []
    /// 撞 inputAlreadyRegistered 之后排过的重试次数（累计）。
    private(set) var retries = 0
    /// 每路的代次：register / unregister / removeAll 各加一次；排着的重试带着排它时的代次，到点不一样就作废。
    private var generations: [Int: UInt64] = [:]

    private func bump(_ number: Int) -> UInt64 {
        let next = (generations[number] ?? 0) &+ 1
        generations[number] = next
        return next
    }

    init(register: @escaping @MainActor (Int, any AudioRing, AudioInputHints) throws -> Void,
         unregister: @escaping @MainActor (Int) -> Void,
         schedule: @escaping Scheduler = AudioInputRegistration.mainQueueScheduler) {
        registerInEngine = register
        unregisterInEngine = unregister
        self.schedule = schedule
    }

    /// 真的：挂到 AudioEngine 上。
    convenience init(engine: AudioEngine) {
        self.init(register: { n, ring, hints in try engine.registerInput(number: n, ring: ring, hints: hints) },
                  unregister: { n in engine.unregisterInput(number: n) })
    }

    /// 注册这一路的环（新的一次：这一路之前排着的重试作废）。
    func register(number: Int, ring: any AudioRing, hints: AudioInputHints) {
        let generation = bump(number)
        attempt(number: number, ring: ring, hints: hints, attempt: 0, generation: generation)
    }

    private func attempt(number: Int, ring: any AudioRing, hints: AudioInputHints, attempt: Int, generation: UInt64) {
        guard generations[number] == generation else { return }   // 作废了：又换了来源 / 删了这一路 / 引擎停了
        do {
            try registerInEngine(number, ring, hints)
            registered.insert(number)
        } catch AudioEngineError.inputAlreadyRegistered(_) where attempt < Self.maxAttempts {
            retries += 1
            schedule(Self.retryDelayMilliseconds) { [weak self] in
                self?.attempt(number: number, ring: ring, hints: hints, attempt: attempt + 1, generation: generation)
            }
        } catch {
            NSLog("输入 \(number) 的音频环注册失败：\(error)")
        }
    }

    /// 摘掉这一路（还没注册上、在等重试的也作废）。
    func unregister(number: Int) {
        _ = bump(number)
        guard registered.remove(number) != nil else { return }
        unregisterInEngine(number)
    }

    /// 引擎停了：全部忘掉，排着的重试全部作废。
    func removeAll() {
        for number in generations.keys { _ = bump(number) }
        registered.removeAll()
    }
}
