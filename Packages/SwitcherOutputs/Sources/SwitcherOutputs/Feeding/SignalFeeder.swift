import Foundation
import SwitcherContracts

/// 合成音频喂料：用契约的 TestSignal 按块（默认 256 帧）产样本，每块 host time = 块首样本的时刻，喂给 AudioBlockConsumer。
/// `feed(upTo:)` 是增量的：把"到时刻 t 为止应当已经产出的样本"补齐，所以视频喂料循环每拍调一次就能保持音视频同源同步。
public final class SignalFeeder {
    public let signal: TestSignal
    public let channelCount: Int
    public let blockFrames: Int
    /// 已经产出的样本数（下一块从这里开始）。
    public private(set) var nextSample: Int64
    private let buffer: UnsafeMutablePointer<Float>
    private let planes: UnsafeMutablePointer<UnsafePointer<Float>>

    public init(signal: TestSignal, channelCount: Int = 2, blockFrames: Int = AudioFormat.defaultBlockFrames, startSample: Int64 = 0) {
        precondition(channelCount >= 1 && blockFrames >= 1)
        self.signal = signal
        self.channelCount = channelCount
        self.blockFrames = blockFrames
        nextSample = startSample
        buffer = .allocate(capacity: blockFrames)
        buffer.initialize(repeating: 0, count: blockFrames)
        planes = .allocate(capacity: channelCount)
        for ch in 0..<channelCount { planes[ch] = UnsafePointer(buffer) }   // 各声道同一份（单声道信号复制到每个声道）
    }

    deinit {
        buffer.deallocate()
        planes.deallocate()
    }

    /// 把 [nextSample, sampleIndex(at: time)] 的样本按块喂出去；最后不足一块的部分留到下次。返回喂出的块数。
    @discardableResult
    public func feed(upTo time: HostTime, to consumers: [any AudioBlockConsumer]) -> Int {
        let target = signal.sampleIndex(at: time)
        var blocks = 0
        while target - nextSample >= Int64(blockFrames) {
            signal.render(into: buffer, frameCount: blockFrames, startingAt: nextSample)
            let hostTime = signal.hostTime(ofSample: nextSample)
            for c in consumers {
                c.consumeAudio(planes: UnsafePointer(planes), channelCount: channelCount, frameCount: blockFrames, hostTime: hostTime)
            }
            nextSample += Int64(blockFrames)
            blocks += 1
        }
        return blocks
    }

    /// 精确喂到某个样本序号（含尾部不足一块的部分，作为一个短块）。停止录制前用它把音频补齐到停止时刻。
    public func flush(upToSample end: Int64, to consumers: [any AudioBlockConsumer]) {
        while nextSample < end {
            let n = Int(min(Int64(blockFrames), end - nextSample))
            signal.render(into: buffer, frameCount: n, startingAt: nextSample)
            let hostTime = signal.hostTime(ofSample: nextSample)
            for c in consumers {
                c.consumeAudio(planes: UnsafePointer(planes), channelCount: channelCount, frameCount: n, hostTime: hostTime)
            }
            nextSample += Int64(n)
        }
    }
}
