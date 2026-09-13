import os
import SwitcherContracts

/// 音频块的有界环（录制器 / 编码器的入口缓冲）：泵线程 push 拷贝一块进来，消费线程 pop 取走。
/// 存储在 init 时按（块数 × 每块最大帧数 × 声道）一次分配，之后零分配；满了丢最旧并计数。
final class AudioBlockRing: @unchecked Sendable {
    /// 一块的视图：planes 里每个指针指向 frameCount 个 float。只在 pop 后到下一次 pop 前有效。
    struct Block {
        var hostTime: HostTime
        var frameCount: Int
        var planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    }

    let channelCount: Int
    let maxFrames: Int
    let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private let storage: UnsafeMutablePointer<Float>           // capacity × channelCount × maxFrames
    private let planeTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>> // capacity × channelCount
    private var hostTimes: [HostTime]
    private var frameCounts: [Int]
    private var head = 0
    private var count = 0
    private(set) var dropped: UInt64 = 0   // lock

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
                planeTable[slot * channelCount + ch] = storage + (slot * channelCount + ch) * maxFrames
            }
        }
        hostTimes = Array(repeating: .zero, count: capacity)
        frameCounts = Array(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        planeTable.deallocate()
    }

    /// 拷贝一块进来（frameCount > maxFrames 的部分截掉）。返回是否因满而丢了最旧的一块。
    @discardableResult
    func push(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Bool {
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
            planeTable[slot * channelCount + ch].update(from: planes[ch], count: n)
        }
        hostTimes[slot] = hostTime
        frameCounts[slot] = n
        count += 1
        return droppedOne
    }

    /// 取最旧的一块。返回的视图指向环内存储，下一次 push 可能覆盖它 —— 消费者要在下一次 pop 前用完
    /// （环深度 ≥ 2 且单消费者时，pop 出来的槽要再过 capacity − 1 次 push 才会被覆盖）。
    func pop() -> Block? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let slot = head
        head = (head + 1) % capacity
        count -= 1
        return Block(hostTime: hostTimes[slot], frameCount: frameCounts[slot], planes: planeTable + slot * channelCount)
    }

    /// 当前块数。
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
