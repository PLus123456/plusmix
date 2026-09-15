import CoreVideo
import Foundation
import Synchronization
import SwitcherContracts

/// 解码线程 → 推帧线程的视频队列（预解码 3 帧）。解码线程满了就等；推帧线程只 pop 不等。
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
    let depth: Int
    private let lock = NSCondition()
    private var items: [Item] = []
    private var closed = false

    init(depth: Int) { self.depth = max(1, depth) }

    /// 解码线程：放一帧；满则等到有空位或 `close`。返回 false = 已关闭。
    func push(_ item: Item) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while items.count >= depth && !closed { lock.wait(until: Date(timeIntervalSinceNow: 0.005)) }
        if closed { return false }
        items.append(item)
        return true
    }

    /// 解码线程：满了吗（不等）。
    var isFull: Bool { lock.lock(); defer { lock.unlock() }; return items.count >= depth }

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
/// 解码线程 append（有空洞补零、有重叠丢弃），推帧线程按输出块取样（可能带线性插值的变速）。
final class DecodedAudioFIFO: @unchecked Sendable {
    let channels: Int
    /// 最多囤多少帧（超过时解码线程等）。
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

    /// 解码线程：追加一块（样本序号 start 起）。满则等；代数不对或已关闭返回 false。
    func append(generation g: UInt64, start: Int64, planes src: [[Float]], frames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while !closed && generation == g && hasHead && (planes[0].count >= maxFrames) {
            lock.wait(until: Date(timeIntervalSinceNow: 0.005))
        }
        if closed || generation != g { return false }
        if !hasHead {
            headIndex = start
            hasHead = true
        }
        var expected = headIndex + Int64(planes[0].count)
        var offset = 0
        if start > expected {
            // 空洞：补零
            let gap = Int(min(start - expected, Int64(maxFrames)))
            for c in 0..<channels { planes[c].append(contentsOf: repeatElement(0, count: gap)) }
            expected += Int64(gap)
        } else if start < expected {
            offset = Int(expected - start)
            if offset >= frames { return true }   // 全部重叠，丢
        }
        for c in 0..<channels {
            let s = min(c, src.count - 1)
            planes[c].append(contentsOf: src[s][offset..<frames])
        }
        return true
    }

    /// 推帧线程：取 [start, start + count) 的样本（展开后序号）；不够返回 false（一个都不动）。
    /// `into` 每个声道至少能放 count 个。
    func copy(start: Int64, count: Int, into: [UnsafeMutablePointer<Float>]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hasHead, start >= headIndex else { return false }
        let offset = Int(start - headIndex)
        guard offset + count <= planes[0].count else { return false }
        for c in 0..<channels {
            planes[c].withUnsafeBufferPointer { p in into[c].update(from: p.baseAddress! + offset, count: count) }
        }
        return true
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
