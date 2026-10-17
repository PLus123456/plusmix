import os
import SwitcherContracts

/// Master 混音块的入口环（推流的音频编码线程从这里取）：泵线程 push 拷贝一块，编码线程 pop。
/// 存储 init 时一次分配（块数 × 声道 × 每块最大帧数），之后零分配；满了丢最旧并计数。
/// （SwitcherOutputs 里 Recorder 用的 AudioBlockRing 不是 public，这里是推流自己的一份，语义相同。）
///
/// 出口块（D05，Codex 2026-10-13 审查）：pop 在锁内把最旧那一槽拷进编码线程独占的出口块（init 时分配，push 从不碰它），
/// 交出去的是出口块的视图。以前交的是槽内指针：队列原本满时下一次 push 的尾槽正好是刚 pop 出来的那一格，
/// 编码器还没读完就被覆盖。只许一个消费者（音频编码线程）；pop / push 都不分配。
final class PCMBlockRing: @unchecked Sendable {
    /// pop 出来的块：planes 指向编码线程独占的出口块，到下一次 pop 之前有效，期间 push 不会改它。
    struct Block {
        var hostTime: HostTime
        var frameCount: Int
        var planes: UnsafePointer<UnsafePointer<Float>>
    }

    let channelCount: Int
    let maxFrames: Int
    let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private let storage: UnsafeMutablePointer<Float>
    private let planeTable: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outStorage: UnsafeMutablePointer<Float>          // 出口块：channelCount × maxFrames，只有消费者碰
    private let outPlanes: UnsafeMutablePointer<UnsafePointer<Float>>
    private var hostTimes: [HostTime]
    private var frameCounts: [Int]
    private var head = 0
    private var count = 0
    private(set) var dropped: UInt64 = 0

    init(channelCount: Int, maxFrames: Int, capacity: Int) {
        precondition(channelCount >= 1 && maxFrames >= 1 && capacity >= 1)
        self.channelCount = channelCount
        self.maxFrames = maxFrames
        self.capacity = capacity
        storage = .allocate(capacity: capacity * channelCount * maxFrames)
        storage.initialize(repeating: 0, count: capacity * channelCount * maxFrames)
        planeTable = .allocate(capacity: capacity * channelCount)
        for slot in 0..<capacity {
            for ch in 0..<channelCount {
                planeTable[slot * channelCount + ch] = UnsafePointer(storage + (slot * channelCount + ch) * maxFrames)
            }
        }
        outStorage = .allocate(capacity: channelCount * maxFrames)
        outStorage.initialize(repeating: 0, count: channelCount * maxFrames)
        outPlanes = .allocate(capacity: channelCount)
        for ch in 0..<channelCount { outPlanes[ch] = UnsafePointer(outStorage + ch * maxFrames) }
        hostTimes = Array(repeating: .zero, count: capacity)
        frameCounts = Array(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        planeTable.deallocate()
        outStorage.deallocate()
        outPlanes.deallocate()
    }

    /// 拷贝一块进来（超过 maxFrames 的部分截掉）。返回是否因满而丢了最旧的一块。
    @discardableResult
    func push(planes: UnsafePointer<UnsafePointer<Float>>, channelCount inChannels: Int, frameCount: Int, hostTime: HostTime) -> Bool {
        let n = min(frameCount, maxFrames)
        lock.lock()
        defer { lock.unlock() }
        var droppedOne = false
        if count == capacity {
            head = (head + 1) % capacity
            count -= 1
            dropped += 1
            droppedOne = true
        }
        let slot = (head + count) % capacity
        for ch in 0..<channelCount {
            // 输入声道不够时复制最后一个（单声道进立体声）
            let src = planes[min(ch, max(inChannels - 1, 0))]
            UnsafeMutablePointer(mutating: planeTable[slot * channelCount + ch]).update(from: src, count: n)
        }
        hostTimes[slot] = hostTime
        frameCounts[slot] = n
        count += 1
        return droppedOne
    }

    /// 取最旧的一块：锁内拷进出口块、把槽还给队列，返回出口块的视图（到下一次 pop 之前有效）。单消费者。
    func pop() -> Block? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let slot = head
        let n = frameCounts[slot]
        for ch in 0..<channelCount {
            (outStorage + ch * maxFrames).update(from: planeTable[slot * channelCount + ch], count: n)
        }
        head = (head + 1) % capacity
        count -= 1
        return Block(hostTime: hostTimes[slot], frameCount: n, planes: UnsafePointer(outPlanes))
    }

    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
