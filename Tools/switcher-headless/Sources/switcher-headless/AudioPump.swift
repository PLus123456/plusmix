import Foundation
import Synchronization
import SwitcherContracts
import SwitcherAudio
import SwitcherOutputs

/// 把混音器某个消费者队列（`AudioBlockTap`，实时线程写的 SPSC）里的块搬给 `AudioBlockConsumer`（录制 / 编码）的泵线程。
/// 这是设计方案 §3.4 / W1-E 报告要求由组装方提供的"非实时泵"：实时回调永远不直接调消费者。
/// 轮询 2 ms 一次（普通线程的定时等待有 ms 级合并，队列 64 块 ≈ 340 ms 余量，够用）。
final class AudioPump: @unchecked Sendable {
    let tap: AudioBlockTap
    let consumer: any AudioBlockConsumer
    let channels: Int
    let maxFrames: Int

    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private let blocksMoved = Atomic<UInt64>(0)
    private var thread: Thread?

    init(tap: AudioBlockTap, consumer: any AudioBlockConsumer) {
        self.tap = tap
        self.consumer = consumer
        channels = tap.channels
        maxFrames = tap.maxFrames
    }

    /// 搬过的块数。
    var moved: UInt64 { blocksMoved.load(ordering: .relaxed) }
    /// 队列满被实时线程丢掉的块数（来自 tap）。
    var droppedAtTap: UInt64 { tap.dropped }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [self] in loop() }
        t.name = "switcher.audio-pump"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// 停线程并等它退出；退出前把队列里剩下的块全部搬完。
    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .releasing)
        finished.wait()
        thread = nil
    }

    private func loop() {
        // 缓冲一次分配：每声道 maxFrames 个 float；两张指针表分别给 pop（可变）和 consume（只读）
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: channels * maxFrames)
        storage.initialize(repeating: 0, count: channels * maxFrames)
        let mutablePlanes = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        let constPlanes = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        for c in 0..<channels {
            mutablePlanes[c] = storage + c * maxFrames
            constPlanes[c] = UnsafePointer(storage + c * maxFrames)
        }
        defer {
            mutablePlanes.deallocate()
            constPlanes.deallocate()
            storage.deallocate()
            finished.signal()
        }
        while true {
            let stopping = stopFlag.load(ordering: .acquiring)
            while let block = tap.pop(into: UnsafePointer(mutablePlanes)) {
                consumer.consumeAudio(planes: UnsafePointer(constPlanes), channelCount: channels, frameCount: block.frames, hostTime: block.hostTime)
                blocksMoved.wrappingAdd(1, ordering: .relaxed)
            }
            if stopping { break }
            _ = usleep(2000)
        }
    }
}
