import CoreAudio
import Foundation
import Synchronization
import SwitcherContracts

/// 一台 Core Audio 输入设备（`InputSource.audio(deviceUID:)` 里的 deviceUID 就是 `uid`）。
/// 给 Add Input 表单、探针、harness 用；不进契约。
public struct AudioInputDeviceInfo: Hashable, Sendable, Identifiable {
    /// 设备 UID（`kAudioDevicePropertyDeviceUID`）。进节目文件的就是它，重启 / 重插后不变。
    public var uid: String
    /// 显示名。
    public var name: String
    /// 厂商。
    public var manufacturer: String
    /// 输入声道数（所有输入流的声道之和）。
    public var inputChannels: Int
    /// 当前标称采样率。
    public var sampleRate: Double
    /// 设备支持的标称采样率（离散值；连续区间给 [min, max] 两个端点）。
    public var availableSampleRates: [Double]
    /// 是不是系统默认输入。
    public var isDefaultInput: Bool
    /// 设备还在（`kAudioDevicePropertyDeviceIsAlive`）。
    public var isAlive: Bool
    /// 传输类型的四字码（"usb "、"bltn"、"virt"…），给 UI 分组用。
    public var transportType: String
    /// 当前 IO 缓冲大小（帧）。
    public var bufferFrameSize: Int

    /// Identifiable：UID。
    public var id: String { uid }
    /// 支持 48 kHz（或采样率是连续区间且覆盖 48 kHz）。
    public var supports48k: Bool { AudioInputDevices.supports48k(availableSampleRates) }
}

/// Core Audio 输入设备清单与属性读写（全部在普通线程调；实时回调里一个都不许调）。
public enum AudioInputDevices {
    // MARK: 属性地址

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 读一个定长属性。
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var out = fallback
        let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? out : fallback
    }

    /// 读一个 CFString 属性。
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: CFString?
        let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let out else { return nil }
        return out as String
    }

    /// 四字码 → 字符串（传输类型等）。
    public static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(decoding: bytes.map { $0 >= 0x20 && $0 < 0x7f ? $0 : 0x3f }, as: UTF8.self)
    }

    // MARK: 设备清单

    /// 系统里所有音频设备的对象 ID。
    static func allDeviceIDs() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 系统默认输入设备的对象 ID（没有 = 0）。
    public static func defaultInputDeviceID() -> AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))
    }

    /// 系统默认输入设备的 UID。
    public static func defaultInputUID() -> String? {
        let id = defaultInputDeviceID()
        return id == 0 ? nil : string(id, kAudioDevicePropertyDeviceUID)
    }

    /// 输入声道数（把输入 scope 上所有流的声道加起来）。
    public static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 输入 AudioBufferList 里每个 buffer 的声道数（交错设备是 [N]，非交错是 [1, 1, …]）。
    /// IOProc 拿到的就是这个结构，声道映射按它算。
    public static func inputBufferChannelCounts(_ device: AudioObjectID) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// 设备支持的标称采样率。
    public static func availableSampleRates(_ device: AudioObjectID) -> [Double] {
        var a = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &ranges) == noErr else { return [] }
        var out: [Double] = []
        for r in ranges {
            out.append(r.mMinimum)
            if r.mMaximum != r.mMinimum { out.append(r.mMaximum) }
        }
        return out
    }

    /// 采样率表里有没有 48 kHz（连续区间按 [min, max] 两个端点判区间内）。
    static func supports48k(_ rates: [Double]) -> Bool {
        let target = Double(AudioFormat.sampleRate)
        if rates.contains(where: { abs($0 - target) < 0.5 }) { return true }
        // 成对的端点 = 连续区间
        var i = 0
        while i + 1 < rates.count {
            if rates[i] < target, rates[i + 1] > target { return true }
            i += 2
        }
        return false
    }

    /// 一台设备的信息（不是输入设备返回 nil）。
    public static func info(of device: AudioObjectID, defaultInput: AudioObjectID? = nil) -> AudioInputDeviceInfo? {
        let channels = inputChannelCount(device)
        guard channels > 0, let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInputDeviceInfo(
            uid: uid,
            name: string(device, kAudioObjectPropertyName) ?? uid,
            manufacturer: string(device, kAudioObjectPropertyManufacturer) ?? "",
            inputChannels: channels,
            sampleRate: value(device, kAudioDevicePropertyNominalSampleRate, default: 0.0),
            availableSampleRates: availableSampleRates(device),
            isDefaultInput: device == (defaultInput ?? defaultInputDeviceID()),
            isAlive: value(device, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0,
            transportType: fourCC(value(device, kAudioDevicePropertyTransportType, default: UInt32(0))),
            bufferFrameSize: Int(value(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeInput, default: UInt32(0)))
        )
    }

    /// 当前所有有输入声道的设备（Add Input 表单、探针用）。默认输入排在最前，其余按名字。
    public static func list() -> [AudioInputDeviceInfo] {
        let def = defaultInputDeviceID()
        let all = allDeviceIDs().compactMap { info(of: $0, defaultInput: def) }
        return all.sorted { a, b in
            if a.isDefaultInput != b.isDefaultInput { return a.isDefaultInput }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 按 UID 找设备对象 ID（找不到返回 0）。空串 = 系统默认输入；"0"、"1" 这样的下标也认（命令行方便）。
    public static func deviceID(uid: String) -> AudioObjectID {
        if uid.isEmpty { return defaultInputDeviceID() }
        let ids = allDeviceIDs()
        for id in ids where string(id, kAudioDevicePropertyDeviceUID) == uid { return id }
        if let index = Int(uid) {
            let inputs = ids.filter { inputChannelCount($0) > 0 }
            if index >= 0, index < inputs.count { return inputs[index] }
        }
        return 0
    }

    // MARK: 采样率

    /// 当前标称采样率。
    public static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: 0)
    }

    /// 把设备的标称采样率设成 `rate` 并等它生效（HAL 是异步的，实测内置麦克风 ≈ 150 ms）。
    /// 返回是否真的变成了目标值。设备不支持该采样率时 `AudioObjectSetPropertyData` 直接报错。
    @discardableResult
    public static func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double, timeout: HostDuration) -> Bool {
        if abs(nominalSampleRate(device) - rate) < 0.5 { return true }
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var v = rate
        guard AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Double>.size), &v) == noErr else { return false }
        let deadline = HostClock.now() + timeout
        while HostClock.now() < deadline {
            if abs(nominalSampleRate(device) - rate) < 0.5 { return true }
            usleep(10_000)
        }
        return abs(nominalSampleRate(device) - rate) < 0.5
    }

    /// 输入流的"虚拟格式"（HAL 交给客户端的格式；IOProc 拿到的就是它）。
    public static func inputStreamFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription {
        value(device, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, default: AudioStreamBasicDescription())
    }

    // MARK: 设备增删通知

    /// 设备清单变化的订阅（`kAudioHardwarePropertyDevices` + 默认输入变化）。`stop()` 或析构时摘掉。
    public final class Subscription: @unchecked Sendable {
        private let queue: DispatchQueue
        private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        private let stopped = Atomic<Bool>(false)

        init(queue: DispatchQueue, selectors: [AudioObjectPropertySelector], onChange: @escaping @Sendable () -> Void) {
            self.queue = queue
            for selector in selectors {
                var a = AudioInputDevices.address(selector)
                let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
                if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block) == noErr {
                    listeners.append((a, block))
                }
            }
        }

        /// 摘掉监听（可重复调）。
        public func stop() {
            guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
            for (addr, block) in listeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
            }
            listeners.removeAll()
        }

        deinit { stop() }
    }

    /// 订阅"设备清单变了 / 默认输入变了"。回调在 `queue` 上；UI 收到后重新 `list()`。
    public static func observeChanges(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Subscription {
        Subscription(queue: queue, selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice], onChange: onChange)
    }
}
