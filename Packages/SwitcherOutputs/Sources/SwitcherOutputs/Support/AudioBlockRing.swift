import Foundation
import os
import Synchronization
import SwitcherContracts

/// 音频块的有界环（录制器 / 编码器的入口缓冲）：泵线程 push 拷贝一块进来，消费线程 pop 取走。
/// 存储在 init 时按（块数 × 每块最大帧数 × 声道）一次分配，之后零分配；满了丢最旧并计数。
///
/// 出口块（D05，Codex 2026-10-13 审查）：pop 在锁内把最旧那一槽拷进消费者独占的出口块（init 时分配，push 从不碰它），
/// 交出去的是出口块的视图。以前交的是槽内指针：pop 已经把槽还给队列，队列原本满时下一次 push 的尾槽正好是这一格，
/// 消费者还没读完就被覆盖（样本变成新块的、PTS 还是旧块的）。只许一个消费者（录制器的 writer 队列）；pop / push 都不分配。
final class AudioBlockRing: @unchecked Sendable {
    /// 一块的视图：planes 里每个指针指向 frameCount 个 float，指的是消费者独占的出口块——到下一次 pop 之前有效，期间 push 不会改它。
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
    private let outStorage: UnsafeMutablePointer<Float>        // 出口块：channelCount × maxFrames，只有消费者（pop 的调用方）碰
    private let outPlanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>  // channelCount
    private var hostTimes: [HostTime]
    private var frameCounts: [Int]
    private var head = 0
    private var count = 0
    private(set) var dropped: UInt64 = 0   // lock

    #if DEBUG
    /// 测试用（D05 的端到端录制背压探针，RecorderBackpressureTests）：每次 pop 拿到块、交给消费者之前睡这么多微秒——
    /// 模拟消费者被拖慢（编码 / 写盘慢）：环一直满着，消费者读块的窗口里生产者照推。只在 DEBUG 构建里有，0（默认）= 不睡。
    static let consumerStallMicrosecondsForTesting = Atomic<UInt32>(0)
    #endif

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
        outStorage = .allocate(capacity: channelCount * maxFrames)
        outStorage.initialize(repeating: 0, count: channelCount * maxFrames)
        outPlanes = .allocate(capacity: channelCount)
        for ch in 0..<channelCount { outPlanes[ch] = outStorage + ch * maxFrames }
        hostTimes = Array(repeating: .zero, count: capacity)
        frameCounts = Array(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        planeTable.deallocate()
        outStorage.deallocate()
        outPlanes.deallocate()
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

    /// 取最旧的一块：锁内拷进出口块、把槽还给队列，返回出口块的视图（到下一次 pop 之前有效）。单消费者。
    func pop() -> Block? {
        lock.lock()
        guard count > 0 else { lock.unlock(); return nil }
        let slot = head
        let n = frameCounts[slot]
        for ch in 0..<channelCount {
            outPlanes[ch].update(from: planeTable[slot * channelCount + ch], count: n)
        }
        let block = Block(hostTime: hostTimes[slot], frameCount: n, planes: outPlanes)
        head = (head + 1) % capacity
        count -= 1
        lock.unlock()
        #if DEBUG
        let stall = Self.consumerStallMicrosecondsForTesting.load(ordering: .relaxed)
        if stall > 0 { usleep(stall) }
        #endif
        return block
    }

    /// 当前块数。
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
