import CoreMIDI
import Foundation
import Synchronization
import SwitcherContracts

// 虚拟 MIDI 源：给 MIDI 映射的自测用（CoreMIDI 虚拟端点，对所有客户端可见，本进程的 MIDIController 也会热插拔连上它）。
// 也可以拿来做"软件推杆"（App 里的 T-bar 走它就和真 MIDI 推杆同一条路），所以放在正式代码里。
// 客户端 / 端点在 MIDIHost 的线程上建 / 销毁：保证进程里第一个 CoreMIDI 客户端是宿主的锚，热插拔通知永远有 run loop 收（W2-C2）。

/// 一个虚拟 MIDI 源。
/// `@unchecked Sendable` 的理由：`client` / `endpoint` 在 init 里写一次、之后只读；`disposed` 是原子量。
public final class VirtualMIDISource: @unchecked Sendable {
    public let name: String
    private let client: MIDIClientRef
    private let endpoint: MIDIEndpointRef
    private let disposed = Atomic<Bool>(false)

    public init(name: String) throws {
        self.name = name
        let made: Result<(client: MIDIClientRef, endpoint: MIDIEndpointRef), MIDIError> = MIDIHost.shared.sync {
            var client = MIDIClientRef()
            var st = MIDIClientCreateWithBlock("\(name) 客户端" as CFString, &client, nil)
            guard st == noErr else { return .failure(MIDIError(what: "MIDIClientCreate", status: st)) }
            var endpoint = MIDIEndpointRef()
            st = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &endpoint)
            guard st == noErr else {
                MIDIClientDispose(client)
                return .failure(MIDIError(what: "MIDISourceCreate", status: st))
            }
            return .success((client, endpoint))
        }
        let refs = try made.get()
        client = refs.client
        endpoint = refs.endpoint
    }

    deinit { dispose() }

    /// 销毁端点（客户端会收到 msgObjectRemoved）。
    public func dispose() {
        guard !disposed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let (client, endpoint) = (client, endpoint)
        MIDIHost.shared.sync {
            MIDIEndpointDispose(endpoint)
            MIDIClientDispose(client)
        }
    }

    /// 发一个 MIDI 1.0 通道消息（UMP 消息类型 2）。
    public func send(status: UInt8, channel: Int, data1: UInt8, data2: UInt8, timestamp: HostTime = .zero) throws {
        precondition((1...16).contains(channel))
        let word: UInt32 = 0x2000_0000 | (UInt32(status & 0xF0 | UInt8(channel - 1)) << 16) | (UInt32(data1 & 0x7F) << 8) | UInt32(data2 & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var words = [word]
        // Swift 导出的 MIDIEventListAdd 返回非可选指针（C 里失败返回 NULL）；单字消息不会装不下，直接用
        _ = words.withUnsafeMutableBufferPointer {
            MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, timestamp.ticks, 1, $0.baseAddress!)
        }
        let st = MIDIReceivedEventList(endpoint, &list)
        guard st == noErr else { throw MIDIError(what: "MIDIReceivedEventList", status: st) }
    }

    public func send(cc controller: Int, value: Int, channel: Int = 1) throws {
        try send(status: 0xB0, channel: channel, data1: UInt8(controller), data2: UInt8(value))
    }

    public func send(noteOn note: Int, velocity: Int, channel: Int = 1) throws {
        try send(status: 0x90, channel: channel, data1: UInt8(note), data2: UInt8(velocity))
    }

    public func send(noteOff note: Int, channel: Int = 1) throws {
        try send(status: 0x80, channel: channel, data1: UInt8(note), data2: 64)
    }
}
