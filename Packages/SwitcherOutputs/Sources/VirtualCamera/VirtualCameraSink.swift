import CoreMedia
import CoreMediaIO
import Darwin
import Foundation
import Synchronization

/// `VirtualCameraOutput` 往扩展送帧的那一端。真实现是 `CMIOSinkStreamClient`（CoreMediaIO 客户端 API）；
/// 测试给假的——真扩展要 Team ID 签名才能激活（BLOCKED-签名），连上之后的路（publishing / 丢帧记账 / 掉线重找）靠它覆盖。
/// 全部成员只在 VirtualCameraOutput 的线程上调。
public protocol VirtualCameraSink: AnyObject {
    /// 已连上 sink stream。
    var isOpen: Bool { get }
    /// 找设备 + sink stream、起流；找不到设备抛 `CMIOSinkStreamClient.Error.deviceNotFound`（= 扩展没装 / 没激活），其余错误 = 设备在但连不上。
    func open() throws
    /// 排一帧进去；排不进（队列满 = 扩展没及时取走）返回 false。
    func send(_ sampleBuffer: CMSampleBuffer) -> Bool
    func close()
    /// 扩展经 CMIO"已输出"通知回报的累计（见 `ScheduledOutputTracker`）；扩展不回报（通知没注册上）为 nil。
    var extensionReport: SinkOutputReport? { get }
}

/// 扩展回报的累计：已输出的帧、序号跳过的帧（= 扩展收了没输出，丢了）、对不上的回报（序号不是本连接排过的，不算输出也不算丢）。
public struct SinkOutputReport: Hashable, Sendable {
    public var output: UInt64
    public var dropped: UInt64
    /// 回报的序号是 kCMIOInvalidSequenceNumber、比本连接排过的都大、或是旧连接迟到的（W3-C3）。> 0 说明 CMIO 桥没把本进程挂的序号
    /// 原样带给扩展（第一次签名跑通时看它，见 issue W3C2-camera-extension-scheduled-output）。
    public var unmatched: UInt64
    public init(output: UInt64, dropped: UInt64, unmatched: UInt64 = 0) {
        self.output = output
        self.dropped = dropped
        self.unmatched = unmatched
    }
}

/// CMIO 的"已输出"通知记账（虚拟摄像头的 dropped "从扩展的丢弃计数来"，prompt 65）。
///
/// 机制是 CoreMediaIO 给输出（sink）流的标准做法，不另造协议：
/// 1. 本进程每排进 sink 一帧就在 CMSampleBuffer 上挂 CMIO 序号（`CMIOSequenceNumber`，每个连接从 0 连续编号，排不进的不占号）；
/// 2. 扩展在 `consumeSampleBuffer` 的回调里拿到这个序号（sampleBufferSequenceNumber），把帧从 source stream 发出去之后调
///    `sinkStream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber:hostTimeInNanoseconds:))`；
/// 3. 系统把它转成本进程在 sink stream 上注册的 `kCMIOStreamPropertyScheduledOutputNotificationProc`（'sonp'）回调，落到这里。
/// 相邻两次通知的序号差 − 1 = 扩展收了却没输出的帧；一个连接里第一次通知之前的序号同样算。重复 / 倒退的序号只记输出不记丢。
/// 扩展侧（第 2 步）在 CameraExtension/ 的 consumeNext（W3-C3 加上）；激活扩展本身 BLOCKED-签名，本机收不到真通知。
/// W3-C3 的守卫：sink 在排队之前记下这一帧的序号（`noteSent`）；回报的序号不是本连接排过的（kCMIOInvalidSequenceNumber、
/// 比排过的都大、新连接还没排过帧时到的旧连接回报）只记 `unmatched`——CMIO 桥万一没把序号原样带过去，Stats 里不会冒出上亿的"丢帧"。
public final class ScheduledOutputTracker: @unchecked Sendable {
    private struct State {
        var last: UInt64?
        /// 本连接排进 sink 的最大序号；nil = 还没排过。
        var highestSent: UInt64?
        var output: UInt64 = 0
        var dropped: UInt64 = 0
        var unmatched: UInt64 = 0
    }
    private let state = Mutex(State())

    public init() {}

    /// 新连接：序号从 0 重来，不和上一个连接比（累计值保留）。
    public func beginConnection() {
        state.withLock {
            $0.last = nil
            $0.highestSent = nil
        }
    }

    /// 一帧要排进 sink 了（sink 在排队之前调：扩展可能在排队调用返回之前就取走并回报）。没挂上序号的（invalid）不算。
    public func noteSent(sequence: UInt64) {
        guard sequence != CMIOSequenceNumber.invalid else { return }
        state.withLock { s in
            if s.highestSent.map({ sequence > $0 }) ?? true { s.highestSent = sequence }
        }
    }

    /// 一条"已输出"通知（CMIO 的线程上）。
    public func noteOutput(sequence: UInt64) {
        state.withLock { s in
            guard sequence != CMIOSequenceNumber.invalid, let sent = s.highestSent, sequence <= sent else {
                s.unmatched &+= 1
                return
            }
            s.output &+= 1
            if let last = s.last {
                guard sequence > last else { return }
                if sequence > last &+ 1 { s.dropped &+= sequence - last - 1 }
            } else {
                s.dropped &+= sequence   // 这个连接里它之前的 0..<sequence 都没输出
            }
            s.last = sequence
        }
    }

    public var report: SinkOutputReport {
        state.withLock { SinkOutputReport(output: $0.output, dropped: $0.dropped, unmatched: $0.unmatched) }
    }

    /// 注册给 CMIO 的 C 回调（refCon = `Unmanaged.passUnretained(tracker).toOpaque()`，tracker 的寿命由注册方保证长于注册）。
    public static let notificationProc: CMIOStreamScheduledOutputNotificationProc = { sequence, _, refCon in
        guard let refCon else { return }
        Unmanaged<ScheduledOutputTracker>.fromOpaque(refCon).takeUnretainedValue().noteOutput(sequence: sequence)
    }
}

/// CMIO 样本缓冲的序号。`CMIOSampleBuffer.h` 不在 CoreMediaIO 的 Swift 模块里（伞头文件只收了 CMIOExtension.h / CMIOHardware.h），
/// 但 C 函数照样导出——探针（报告 §1）：dlsym 取到 `CMIOSampleBufferSet/GetSequenceNumber`，设了之后样本附件里是
/// `com.apple.cmio.buffer_attachment.sequence_number`。取不到函数时直接写这个附件键。
public enum CMIOSequenceNumber {
    /// kCMIOInvalidSequenceNumber。
    public static let invalid = UInt64.max
    static let attachmentKey = "com.apple.cmio.buffer_attachment.sequence_number"

    private typealias SetFunction = @convention(c) (CFAllocator?, CMSampleBuffer, UInt64) -> Void
    private typealias GetFunction = @convention(c) (CMSampleBuffer) -> UInt64
    // RTLD_DEFAULT = (void *)-2：在已加载的全部映像里找（CoreMediaIO 由本 target 链接）
    private static let setFunction: SetFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CMIOSampleBufferSetSequenceNumber")
        .map { unsafeBitCast($0, to: SetFunction.self) }
    private static let getFunction: GetFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CMIOSampleBufferGetSequenceNumber")
        .map { unsafeBitCast($0, to: GetFunction.self) }

    /// 用的是 CoreMediaIO 的 C 函数（而不是直接写附件键）。
    public static var usesCFunctions: Bool { setFunction != nil && getFunction != nil }

    /// 挂序号（样本刚建好、只有本进程持有时调——CMIO 的要求）。
    public static func set(_ sampleBuffer: CMSampleBuffer, _ sequence: UInt64) {
        if let setFunction {
            setFunction(nil, sampleBuffer, sequence)
        } else {
            CMSetAttachment(sampleBuffer, key: attachmentKey as CFString, value: NSNumber(value: sequence), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
    }

    /// 读序号；没有为 `invalid`。
    public static func get(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        if let getFunction { return getFunction(sampleBuffer) }
        return (CMGetAttachment(sampleBuffer, key: attachmentKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint64Value ?? invalid
    }
}
