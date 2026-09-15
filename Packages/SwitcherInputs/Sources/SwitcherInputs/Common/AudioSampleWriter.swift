import CoreMedia
import SwitcherContracts
import Synchronization

/// 把 CMSampleBuffer 里的 LPCM 音频写进环：先经 `LPCM.append` 变成 float32 非交错、`ring.channelCount` 声道，再
/// `ring.write(planes:frameCount:hostTime:)`。采样率由调用方保证已是 48 kHz（AVCaptureAudioDataOutput / AVAssetReader / SCK
/// 都能在输出设置里要 48 kHz）。只在该输入的采集线程调；scratch 数组复用（输入线程允许分配）。
final class AudioSampleWriter: @unchecked Sendable {
    let ring: any AudioRing
    private var scratch: [[Float]]
    private let planeTable: UnsafeMutablePointer<UnsafePointer<Float>>
    let blocksWritten = Atomic<UInt64>(0)
    let framesWritten = Atomic<UInt64>(0)
    let framesRejected = Atomic<UInt64>(0)
    /// 格式不是 LPCM 或声道数为 0 的块（跳过）。
    let blocksUnsupported = Atomic<UInt64>(0)

    init(ring: any AudioRing) {
        self.ring = ring
        scratch = Array(repeating: [], count: ring.channelCount)
        planeTable = .allocate(capacity: ring.channelCount)
        planeTable.initialize(repeating: UnsafePointer(bitPattern: 8)!, count: ring.channelCount)
    }

    deinit { planeTable.deallocate() }

    /// 写一个 CMSampleBuffer；`hostTime` 是它第一帧的时刻。返回实际写入的帧数。
    @discardableResult
    func write(sampleBuffer: CMSampleBuffer, hostTime: HostTime) -> Int {
        for c in 0..<scratch.count { scratch[c].removeAll(keepingCapacity: true) }
        let frames = LPCM.append(sampleBuffer: sampleBuffer, to: &scratch)
        guard frames > 0 else {
            blocksUnsupported.add(1, ordering: .relaxed)
            return 0
        }
        var written = 0
        withScratchPointers { table in
            written = ring.write(planes: table, frameCount: frames, hostTime: hostTime)
        }
        account(written: written, requested: frames)
        return written
    }

    /// 已经是 float32 非交错、声道数 == 环声道数的块。
    @discardableResult
    func write(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int {
        let n = ring.write(planes: planes, frameCount: frameCount, hostTime: hostTime)
        account(written: n, requested: frameCount)
        return n
    }

    private func withScratchPointers(_ body: (UnsafePointer<UnsafePointer<Float>>) -> Void) {
        // 逐声道取基址；数组在 body 期间不变
        func fill(_ c: Int, _ body: (UnsafePointer<UnsafePointer<Float>>) -> Void) {
            if c == scratch.count { body(UnsafePointer(planeTable)); return }
            scratch[c].withUnsafeBufferPointer { p in
                planeTable[c] = p.baseAddress ?? UnsafePointer(bitPattern: 8)!
                fill(c + 1, body)
            }
        }
        fill(0, body)
    }

    private func account(written n: Int, requested: Int) {
        blocksWritten.add(1, ordering: .relaxed)
        framesWritten.add(UInt64(n), ordering: .relaxed)
        if n < requested { framesRejected.add(UInt64(requested - n), ordering: .relaxed) }
    }
}
