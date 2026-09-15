import os
import SwitcherContracts
import SwitcherOutputs

/// 一路推流自己的有界发送队列：视频帧一个环、音频包一个环。生产者（编码器回调线程）push，消费者（发送 Task）pop。
/// 存储在 init 时分配好；锁是 os_unfair_lock，临界区只有下标操作。
///
/// 丢帧策略（StreamCounters 的口径）：
/// - 视频满：丢**新来的**这一帧，并置 `waitingKeyframe`：之后的非关键帧一律丢，直到下一个关键帧且队列有位。
///   丢新不丢旧，队列里已排好的 GOP 仍然完整可解码；送出去的每一帧都能解 —— E9 的"落盘缺帧"才恰好等于我们数的丢帧。
/// - 音频满：丢最旧的一个包（音频只有视频的 2–3%，正常永远满不了；满了说明连接早就死了）。
/// - `accepting == false`（断线 / 退避 / 未启动）：push 直接丢，计 droppedDisconnected。
final class SendQueue: @unchecked Sendable {
    enum PushResult: Equatable {
        case queued
        case droppedFull
        case droppedWaitingKeyframe
        case droppedNotAccepting
    }

    let videoCapacity: Int
    let audioCapacity: Int
    private let lock = OSAllocatedUnfairLock()
    private var video: [EncodedVideoSample?]
    private var videoHead = 0
    private var videoCount = 0
    private var audio: [EncodedAudioPacket?]
    private var audioHead = 0
    private var audioCount = 0
    private var accepting = false
    private var waitingKeyframe = true

    init(videoCapacity: Int, audioCapacity: Int) {
        precondition(videoCapacity >= 1 && audioCapacity >= 1)
        self.videoCapacity = videoCapacity
        self.audioCapacity = audioCapacity
        video = Array(repeating: nil, count: videoCapacity)
        audio = Array(repeating: nil, count: audioCapacity)
    }

    // MARK: 生产者

    /// 开一段会话：清空、开始接收、下一帧必须是关键帧。
    func beginSession() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
        accepting = true
        waitingKeyframe = true
    }

    /// 关一段会话：不再接收；返回被丢弃的（还没送出的）帧数 / 包数。
    @discardableResult
    func endSession() -> (video: Int, audio: Int) {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        let n = (videoCount, audioCount)
        clearLocked()
        return n
    }

    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    func pushVideo(_ sample: EncodedVideoSample) -> PushResult {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return .droppedNotAccepting }
        if waitingKeyframe && !sample.isKeyframe { return .droppedWaitingKeyframe }
        if videoCount == videoCapacity {
            waitingKeyframe = true
            return .droppedFull
        }
        waitingKeyframe = false
        video[(videoHead + videoCount) % videoCapacity] = sample
        videoCount += 1
        return .queued
    }

    /// 放一个包；满了丢最旧的（返回 .droppedFull 表示有一个被丢了，新包已入队）。
    func pushAudio(_ packet: EncodedAudioPacket) -> PushResult {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return .droppedNotAccepting }
        var result = PushResult.queued
        if audioCount == audioCapacity {
            audio[audioHead] = nil
            audioHead = (audioHead + 1) % audioCapacity
            audioCount -= 1
            result = .droppedFull
        }
        audio[(audioHead + audioCount) % audioCapacity] = packet
        audioCount += 1
        return result
    }

    // MARK: 消费者

    func peekVideo() -> EncodedVideoSample? {
        lock.lock()
        defer { lock.unlock() }
        return videoCount > 0 ? video[videoHead] : nil
    }

    func peekAudio() -> EncodedAudioPacket? {
        lock.lock()
        defer { lock.unlock() }
        return audioCount > 0 ? audio[audioHead] : nil
    }

    /// 最新（队尾）的音频包。
    func lastAudio() -> EncodedAudioPacket? {
        lock.lock()
        defer { lock.unlock() }
        return audioCount > 0 ? audio[(audioHead + audioCount - 1) % audioCapacity] : nil
    }

    func popVideo() -> EncodedVideoSample? {
        lock.lock()
        defer { lock.unlock() }
        guard videoCount > 0 else { return nil }
        let s = video[videoHead]
        video[videoHead] = nil
        videoHead = (videoHead + 1) % videoCapacity
        videoCount -= 1
        return s
    }

    func popAudio() -> EncodedAudioPacket? {
        lock.lock()
        defer { lock.unlock() }
        guard audioCount > 0 else { return nil }
        let p = audio[audioHead]
        audio[audioHead] = nil
        audioHead = (audioHead + 1) % audioCapacity
        audioCount -= 1
        return p
    }

    /// 丢掉队头所有 hostTime < time 的音频包，返回丢的个数（起步对齐用）。
    @discardableResult
    func dropAudio(before time: HostTime) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var n = 0
        while audioCount > 0, let p = audio[audioHead], p.hostTime < time {
            audio[audioHead] = nil
            audioHead = (audioHead + 1) % audioCapacity
            audioCount -= 1
            n += 1
        }
        return n
    }

    /// 起步对齐：选原点包 —— nearest = false：最后一个 hostTime ≤ time 的包（没有就是第一个包）；true：|hostTime − time| 最小的包。
    /// 丢掉原点前面、除了保留 preroll 个之外的更早的包，返回原点包的时刻和丢的个数；队列空返回 nil。
    func alignAudio(to time: HostTime, nearest: Bool, preroll: Int) -> (origin: HostTime, dropped: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard audioCount > 0 else { return nil }
        var originIndex = 0
        var bestDistance = Int64.max
        for i in 0..<audioCount {
            guard let p = audio[(audioHead + i) % audioCapacity] else { continue }
            if nearest {
                let d = (p.hostTime - time).magnitude.ticks
                if d < bestDistance { bestDistance = d; originIndex = i }
            } else {
                if p.hostTime <= time { originIndex = i } else { break }
            }
        }
        let keepFrom = max(0, originIndex - max(0, preroll))
        for _ in 0..<keepFrom {
            audio[audioHead] = nil
            audioHead = (audioHead + 1) % audioCapacity
            audioCount -= 1
        }
        guard let origin = audio[(audioHead + (originIndex - keepFrom)) % audioCapacity]?.hostTime else { return nil }
        return (origin, keepFrom)
    }

    /// 队列里是否存在 hostTime ≥ time 的音频包（说明 time 之前的都已经到齐）。
    func hasAudio(atOrAfter time: HostTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard audioCount > 0, let last = audio[(audioHead + audioCount - 1) % audioCapacity] else { return false }
        return last.hostTime >= time
    }

    var depth: (video: Int, audio: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (videoCount, audioCount)
    }

    private func clearLocked() {
        for i in video.indices { video[i] = nil }
        for i in audio.indices { audio[i] = nil }
        videoHead = 0
        videoCount = 0
        audioHead = 0
        audioCount = 0
    }
}
