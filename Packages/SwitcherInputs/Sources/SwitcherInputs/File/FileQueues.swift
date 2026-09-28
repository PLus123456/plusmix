import CoreVideo
import Foundation
import Synchronization
import SwitcherContracts

/// 解码线程 → 推帧线程的视频队列（预解码 3 帧；速率高时解码线程把深度加到"每拍要前进的帧数 + 2"，推帧线程一拍才能 pop 到本拍最新帧——
/// W2-A4：深度固定 3 时 4 帧 / 拍的时间线永远追不上）。解码线程满了就等；推帧线程只 pop 不等。
final class DecodedVideoQueue: @unchecked Sendable {
    struct Item: @unchecked Sendable {
        /// 展开后的媒体位置（秒）；`isEnd` 时无意义。
        let media: Rational
        let buffer: CVPixelBuffer?
        /// 解码器代数（seek 后旧代的帧作废）。
        let generation: UInt64
        /// 结尾哨兵（不循环时解码线程放一个，告诉推帧线程后面没有了）。
        let isEnd: Bool
    }
    private let lock = NSCondition()
    private var items: [Item] = []
    private var closed = false
    private var depthValue: Int

    init(depth: Int) { depthValue = max(1, depth) }

    /// 当前深度。
    var depth: Int { lock.lock(); defer { lock.unlock() }; return depthValue }

    /// 解码线程：改深度（速率变了）。加深时唤醒在等空位的 push；变浅时多出来的帧留着让推帧线程 pop 掉。
    func setDepth(_ n: Int) { lock.lock(); depthValue = max(1, n); lock.broadcast(); lock.unlock() }

    /// 解码线程：放一帧；满则等到有空位或 `close`。返回 false = 已关闭。
    func push(_ item: Item) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while items.count >= depthValue && !closed { lock.wait(until: Date(timeIntervalSinceNow: 0.005)) }
        if closed { return false }
        items.append(item)
        return true
    }

    /// 解码线程：满了吗（不等）。
    var isFull: Bool { lock.lock(); defer { lock.unlock() }; return items.count >= depthValue }

    /// 推帧线程：看队头（不取）。
    func peek() -> Item? { lock.lock(); defer { lock.unlock() }; return items.first }

    /// 推帧线程：取队头。
    func pop() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        let i = items.removeFirst()
        lock.broadcast()
        return i
    }

    /// 队头之后的一帧的媒体位置（算帧时长用）。
    func secondMedia() -> Rational? { lock.lock(); defer { lock.unlock() }; return items.count >= 2 && !items[1].isEnd ? items[1].media : nil }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    /// 清空（seek）。
    func flush() { lock.lock(); items.removeAll(); lock.broadcast(); lock.unlock() }

    func close() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }
    func reopen() { lock.lock(); closed = false; items.removeAll(); lock.unlock() }
}

/// 解码线程 → 推帧线程的音频 FIFO：float32 非交错，按展开后的 48 kHz 样本序号连续存放。
/// 解码线程 append（有空洞补零、有重叠丢弃；空洞比剩余容量还大时只补到满、让解码线程稍后重试，样本才不会放错序号），
/// 推帧线程按输出块取样（可能带线性插值的变速）。两边都不阻塞：解码线程放之前看 `status.frames < maxFrames`，推帧线程要不到样本时
/// 先 `trim` 掉比它要的还老的样本（W2A3 的互等就出在要不到样本却不 trim、解码线程被塞满的 FIFO 挡在门口）。
final class DecodedAudioFIFO: @unchecked Sendable {
    /// `copy` 的结果。
    enum CopyResult {
        /// 拿到了。
        case ok
        /// 样本还没解到这里（等，或过了跳过线再跳）。
        case notYet
        /// 要的样本已经不在 FIFO 里（队头在它后面：换代 / 大空洞之后）——永远不会再来，立刻跳过。
        case gone
    }
    /// `append` 的结果。
    enum AppendResult {
        /// 放进去了（或全部重叠、丢了）。
        case appended
        /// 代数不对 / 已关闭。
        case rejected
        /// 这块前面的空洞比剩余容量还大：只补了零到满，样本没放，等推帧线程消费掉一些再试。
        case retry
    }
    let channels: Int
    /// 最多囤多少帧（解码线程放之前看这个）。
    let maxFrames: Int
    private let lock = NSCondition()
    private var planes: [[Float]]
    /// planes[.][0] 对应的展开后样本序号。
    private var headIndex: Int64 = 0
    private var hasHead = false
    private var generation: UInt64 = 0
    private var closed = false

    init(channels: Int, maxFrames: Int) {
        self.channels = channels
        self.maxFrames = maxFrames
        planes = Array(repeating: [], count: channels)
        for c in 0..<channels { planes[c].reserveCapacity(maxFrames + 8192) }
    }

    /// 当前代数（seek 时推帧线程 reset，解码线程按新代数 append）。
    var currentGeneration: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }

    /// 解码线程：追加一块（样本序号 start 起）。不等：放之前自己看 `status.frames < maxFrames`。
    func append(generation g: UInt64, start: Int64, planes src: [[Float]], frames: Int) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        if closed || generation != g { return .rejected }
        if !hasHead {
            headIndex = start
            hasHead = true
        }
        var expected = headIndex + Int64(planes[0].count)
        var offset = 0
        if start > expected {
            // 空洞：补零。比剩余容量还大（音轨比视频短很多）就只补到满、让解码线程稍后重试——以前补到 maxFrames 就把样本接在后面，序号错位、整圈 A/V 不同步
            let gap = start - expected
            let room = max(0, maxFrames - planes[0].count)
            if gap > Int64(room) {
                if room > 0 { for c in 0..<channels { planes[c].append(contentsOf: repeatElement(0, count: room)) } }
                return .retry
            }
            for c in 0..<channels { planes[c].append(contentsOf: repeatElement(0, count: Int(gap))) }
            expected += gap
        } else if start < expected {
            offset = Int(expected - start)
            if offset >= frames { return .appended }   // 全部重叠，丢
        }
        for c in 0..<channels {
            let s = min(c, src.count - 1)
            planes[c].append(contentsOf: src[s][offset..<frames])
        }
        return .appended
    }

    /// 推帧线程：取 [start, start + count) 的样本（展开后序号）；不够时一个都不动，返回为什么不够。
    /// `into` 每个声道至少能放 count 个。
    func copy(start: Int64, count: Int, into: [UnsafeMutablePointer<Float>]) -> CopyResult {
        lock.lock()
        defer { lock.unlock() }
        guard hasHead else { return .notYet }
        guard start >= headIndex else { return .gone }
        let offset = Int(start - headIndex)
        guard offset + count <= planes[0].count else { return .notYet }
        for c in 0..<channels {
            planes[c].withUnsafeBufferPointer { p in into[c].update(from: p.baseAddress! + offset, count: count) }
        }
        return .ok
    }

    /// 推帧线程：丢掉序号 < before 的样本。
    func trim(before: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard hasHead, before > headIndex else { return }
        let n = Int(min(before - headIndex, Int64(planes[0].count)))
        for c in 0..<channels { planes[c].removeFirst(n) }
        headIndex += Int64(n)
        lock.broadcast()
    }

    /// 已囤的帧数与队头序号。
    var status: (head: Int64?, frames: Int) { lock.lock(); defer { lock.unlock() }; return (hasHead ? headIndex : nil, planes[0].count) }

    /// 推帧线程：seek → 换代清空。
    func reset(generation g: UInt64) {
        lock.lock()
        generation = g
        for c in 0..<channels { planes[c].removeAll(keepingCapacity: true) }
        hasHead = false
        lock.broadcast()
        lock.unlock()
    }

    func close() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }
    func reopen() { lock.lock(); closed = false; lock.unlock() }
}
