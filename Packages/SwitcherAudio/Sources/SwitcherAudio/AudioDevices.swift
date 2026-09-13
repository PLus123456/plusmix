// AudioDevices.swift —— CoreAudio HAL 设备枚举与属性（非实时）。
import Foundation
import CoreAudio
import SwitcherContracts
import CSwitcherAudioRT

/// 设备层错误。
public enum AudioDeviceError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case noDevice
    case sampleRateUnsupported(Double)
    case alreadyRunning
    public var description: String {
        switch self {
        case .osStatus(let what, let st): "\(what) 失败：OSStatus \(st)"
        case .noDevice: "没有可用设备"
        case .sampleRateUnsupported(let r): "设备不支持 48 kHz（当前 \(r)）"
        case .alreadyRunning: "已在运行"
        }
    }
}

/// 一台设备的静态信息。
public struct AudioDeviceInfo: Hashable, Sendable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var transportType: UInt32
    public var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
    public var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
}

/// HAL 属性的薄封装。
public enum AudioHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       as type: T.Type, initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard st == noErr else { throw AudioDeviceError.osStatus("AudioObjectGetPropertyData(\(selector))", st) }
        return value
    }

    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       value: T) throws {
        var addr = address(selector, scope: scope)
        var v = value
        let st = AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        guard st == noErr else { throw AudioDeviceError.osStatus("AudioObjectSetPropertyData(\(selector))", st) }
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let st = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    /// 设备某个方向的通道布局：设备通道 k → (buffer, offset, stride)。从 StreamConfiguration（AudioBufferList）算。
    static func channelLayout(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [sw_channel_location] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var locs = [sw_channel_location]()
        for (bi, buf) in abl.enumerated() {
            let n = Int(buf.mNumberChannels)
            for c in 0..<n { locs.append(sw_channel_location(buffer: UInt32(bi), offset: UInt32(c), stride: UInt32(n))) }
        }
        return locs
    }

    /// 所有设备。
    public static func devices() -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { info($0) }
    }

    /// 一台设备的信息。
    public static func info(_ id: AudioDeviceID) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, name: getString(id, kAudioObjectPropertyName), uid: getString(id, kAudioDevicePropertyDeviceUID),
                        inputChannels: channelLayout(id, scope: kAudioObjectPropertyScopeInput).count,
                        outputChannels: channelLayout(id, scope: kAudioObjectPropertyScopeOutput).count,
                        transportType: (try? get(id, kAudioDevicePropertyTransportType, as: UInt32.self, initial: 0)) ?? 0)
    }

    /// 默认输出 / 输入设备。
    public static func defaultOutputDevice() -> AudioDeviceID? {
        let id = (try? get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioDeviceID.self, initial: 0)) ?? 0
        return id == 0 ? nil : id
    }
    public static func defaultInputDevice() -> AudioDeviceID? {
        let id = (try? get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, as: AudioDeviceID.self, initial: 0)) ?? 0
        return id == 0 ? nil : id
    }
    /// 按名字找（精确或包含）。
    public static func device(named name: String) -> AudioDeviceInfo? {
        let all = devices()
        return all.first { $0.name == name } ?? all.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    /// 名义采样率。
    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        (try? get(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self, initial: 0)) ?? 0
    }
    /// 设名义采样率并等它生效（最多 timeout 秒）。
    public static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double, timeout: TimeInterval = 2) throws {
        if nominalSampleRate(id) == rate { return }
        try set(id, kAudioDevicePropertyNominalSampleRate, value: Float64(rate))
        let deadline = Date().addingTimeInterval(timeout)
        while nominalSampleRate(id) != rate {
            if Date() > deadline { throw AudioDeviceError.sampleRateUnsupported(nominalSampleRate(id)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    /// buffer size（帧）与范围。
    public static func bufferFrameSize(_ id: AudioDeviceID) -> Int {
        Int((try? get(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self, initial: 0)) ?? 0)
    }
    public static func bufferFrameSizeRange(_ id: AudioDeviceID) -> ClosedRange<Int> {
        let r = (try? get(id, kAudioDevicePropertyBufferFrameSizeRange, as: AudioValueRange.self, initial: AudioValueRange(mMinimum: 0, mMaximum: 0))) ?? AudioValueRange(mMinimum: 0, mMaximum: 0)
        return Int(r.mMinimum)...max(Int(r.mMinimum), Int(r.mMaximum))
    }
    /// 设 buffer size（钳到范围），返回实际值。
    @discardableResult
    public static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: Int) throws -> Int {
        let range = bufferFrameSizeRange(id)
        let want = min(max(frames, range.lowerBound), range.upperBound)
        try set(id, kAudioDevicePropertyBufferFrameSize, value: UInt32(want))
        return bufferFrameSize(id)
    }
    /// 安全偏移 / 设备延迟（帧）。
    public static func safetyOffset(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        Int((try? get(id, kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self, initial: 0)) ?? 0)
    }
    public static func latency(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        Int((try? get(id, kAudioDevicePropertyLatency, scope: scope, as: UInt32.self, initial: 0)) ?? 0)
    }
    /// 设备是否还在。
    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        ((try? get(id, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self, initial: 0)) ?? 0) != 0
    }

    /// 创建一个私有聚合设备（不出现在系统设置里、不持久），返回它的 ID。测试聚合设备路径用。
    public static func createPrivateAggregateDevice(name: String, subDeviceUIDs: [String], masterUID: String? = nil) throws -> AudioDeviceID {
        var desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "switcher.test.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceUIDs.map { [kAudioSubDeviceUIDKey: $0] },
        ]
        if let m = masterUID { desc[kAudioAggregateDeviceMainSubDeviceKey] = m }
        var id: AudioDeviceID = 0
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
        guard st == noErr else { throw AudioDeviceError.osStatus("AudioHardwareCreateAggregateDevice", st) }
        return id
    }
    public static func destroyAggregateDevice(_ id: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

/// 设备回调统计（sw_device_client_stats 的 Swift 形态）。
public struct DeviceCallbackStats: Hashable, Sendable {
    public var callbacks: UInt64
    public var frames: UInt64
    /// 最近一次回调的帧数 = 实际 buffer size。
    public var lastFrames: Int
    public var nominalPeriodTicks: UInt64
    /// |回调间隔 − 名义周期| 最大值（ticks）。
    public var maxJitterTicks: UInt64
    /// 抖动直方图，每桶 100 µs。
    public var jitterHistogram: [UInt64]
    public var maxLeadTicks: UInt64
    public var minLeadTicks: UInt64
    public var inputFramesWritten: UInt64
    public var inputOverruns: UInt64
    public var timestampFallbacks: UInt64
    public var maxJitterMs: Double { HostDuration(ticks: Int64(maxJitterTicks)).milliseconds }
    /// p99 抖动（ms，按直方图桶上沿）。
    public var p99JitterMs: Double {
        let total = jitterHistogram.reduce(0, +)
        guard total > 0 else { return 0 }
        var acc: UInt64 = 0
        for (i, n) in jitterHistogram.enumerated() {
            acc += n
            if Double(acc) >= Double(total) * 0.99 { return Double(i + 1) * 0.1 }
        }
        return 3.2
    }
    init(_ c: sw_device_client_stats) {
        callbacks = c.callbacks; frames = c.frames; lastFrames = Int(c.last_frames); nominalPeriodTicks = c.nominal_period_ticks
        maxJitterTicks = c.max_jitter_ticks
        jitterHistogram = withUnsafeBytes(of: c.jitter_hist) { Array($0.bindMemory(to: UInt64.self)) }
        maxLeadTicks = c.max_lead_ticks; minLeadTicks = c.min_lead_ticks
        inputFramesWritten = c.input_frames_written; inputOverruns = c.input_overruns; timestampFallbacks = c.timestamp_fallbacks
    }
}
