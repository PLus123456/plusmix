import CoreMedia
import CoreMediaIO
import Foundation

/// CoreMediaIO 客户端 API 这一侧：找到我们的扩展设备、它的 sink stream（方向 0 = 数据从本进程流向设备；探针：普通摄像头的流方向是 1），
/// 拿到 stream 的 CMSimpleQueue，把 CMSampleBuffer 排进去。全部是 C API 的薄包装；只在 VirtualCameraOutput 的线程上用。
public final class CMIOSinkStreamClient: @unchecked Sendable {
    /// 错误。
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case deviceNotFound
        case sinkStreamNotFound
        case queueUnavailable(OSStatus)
        case startFailed(OSStatus)
        public var description: String {
            switch self {
            case .deviceNotFound: "找不到虚拟摄像头设备（扩展没装或没激活）"
            case .sinkStreamNotFound: "虚拟摄像头设备上没有 sink stream"
            case .queueUnavailable(let s): "拿不到 sink stream 的队列（\(s)）"
            case .startFailed(let s): "sink stream 起不来（\(s)）"
            }
        }
    }

    public let deviceUID: String
    public private(set) var deviceID: CMIOObjectID = 0
    public private(set) var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    public private(set) var isOpen = false

    public init(deviceUID: String = VirtualCameraConstants.deviceUID) {
        self.deviceUID = deviceUID
    }

    deinit { close() }

    // MARK: 发现

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let n = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: n)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(of object: CMIOObjectID, selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func uint32(of object: CMIOObjectID, selector: Int) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }

    /// 系统里的全部 CMIO 设备（ID、名字、UID）。
    public static func allDevices() -> [(id: CMIOObjectID, name: String, uid: String)] {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices).map {
            ($0, string(of: $0, selector: kCMIOObjectPropertyName) ?? "?", string(of: $0, selector: kCMIODevicePropertyDeviceUID) ?? "?")
        }
    }

    /// 按 UID 找设备。
    public static func findDevice(uid: String) -> CMIOObjectID? {
        allDevices().first { $0.uid == uid }?.id
    }

    /// 设备上方向为 0（本进程 → 设备）的流。
    public static func findSinkStream(device: CMIOObjectID) -> CMIOStreamID? {
        for s in objectIDs(of: device, selector: kCMIODevicePropertyStreams) {
            if uint32(of: s, selector: kCMIOStreamPropertyDirection) == 0 { return CMIOStreamID(s) }
        }
        return nil
    }

    // MARK: 打开 / 送帧 / 关闭

    /// 找设备 + sink stream，拿队列，起流。
    public func open() throws {
        guard !isOpen else { return }
        guard let dev = Self.findDevice(uid: deviceUID) else { throw Error.deviceNotFound }
        guard let sink = Self.findSinkStream(device: dev) else { throw Error.sinkStreamNotFound }
        var q: Unmanaged<CMSimpleQueue>?
        let st = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q)
        guard st == noErr, let q else { throw Error.queueUnavailable(st) }
        let started = CMIODeviceStartStream(dev, sink)
        guard started == noErr else {
            throw Error.startFailed(started)
        }
        deviceID = dev
        streamID = sink
        queue = q.takeRetainedValue()
        isOpen = true
    }

    /// 排一帧进去；队列满返回 false（调用方计数）。
    public func send(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isOpen, let queue else { return false }
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) { return false }
        let retained = Unmanaged.passRetained(sampleBuffer)   // 队列拿走这一份引用，设备取走后释放
        let st = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        if st != noErr {
            retained.release()
            return false
        }
        return true
    }

    /// 队列里现在有几帧（设备还没取走的）。
    public var queuedCount: Int { queue.map { Int(CMSimpleQueueGetCount($0)) } ?? 0 }

    public func close() {
        guard isOpen else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
        isOpen = false
    }
}
