import CoreMIDI
import Foundation
import Synchronization
import SwitcherContracts

// CoreMIDI 控制器（设计方案 §9.4）。探针（reports/w2-control.md §5）验证的事实：
//   - MIDIClientCreateWithBlock 的通知块在"创建客户端的那条线程的 run loop"上派发：没有 run loop 就没有热插拔通知，
//     所以客户端和输入口在一条自带 CFRunLoop 的专用线程上创建，通知（源增删）也在那条线程上处理。
//   - 输入口的接收块在 CoreMIDI 自己的线程上调，与 run loop 无关；收到的是 MIDIEventList（UMP），用 unsafeSequence() 遍历，
//     packet.words 是 64 个 UInt32 的元组，wordCount 说明有效字数。
//   - 虚拟源（MIDISourceCreateWithProtocol）对本进程也是普通的源，会触发 msgObjectAdded → 热插拔路径就是测试路径。
// 派发：接收线程只解析、决定命令，然后放进一个 AsyncStream；一条常驻 Task 顺序 submit——保证 CC 的顺序不乱（tbar 不能倒退）。
// learn：设了 learn 回调后的下一条 CC / Note 交给回调、不派发。

/// 一个 MIDI 源。
public struct MIDISourceInfo: Hashable, Sendable {
    public var name: String
    public var uniqueID: Int32
    public var endpoint: MIDIEndpointRef
    public var connected: Bool
}

/// CoreMIDI 错误。
public struct MIDIError: Error, CustomStringConvertible {
    public var what: String
    public var status: OSStatus
    public var description: String { "\(what) 失败：OSStatus \(status)" }
}

/// MIDI 控制器。
public final class MIDIController: @unchecked Sendable {
    public struct Counters: Hashable, Sendable {
        public var messages: UInt64 = 0
        public var commands: UInt64 = 0
        public var rejected: UInt64 = 0
        public var ignored: UInt64 = 0
        public var learned: UInt64 = 0
    }

    public let bus: CommandBus
    public let clientName: String
    private let mapper: Mutex<MIDIMapper>
    private let learnHandler = Mutex<(@Sendable (MIDIMessage) -> Void)?>(nil)
    private let sourceTable = Mutex<[MIDIEndpointRef: MIDISourceInfo]>([:])
    private let messages = Atomic<UInt64>(0)
    private let commandsCount = Atomic<UInt64>(0)
    private let rejected = Atomic<UInt64>(0)
    private let ignored = Atomic<UInt64>(0)
    private let learned = Atomic<UInt64>(0)
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let started = Atomic<Bool>(false)
    private var dispatchTask: Task<Void, Never>?
    private var queue: AsyncStream<Command>.Continuation?
    /// 测试挂钩：每条解析出的消息（learn 之前）。
    public var onMessage: (@Sendable (MIDIMessage) -> Void)?

    public init(bus: CommandBus, table: MIDIMapTable = .default, clientName: String = "Switcher") {
        self.bus = bus
        self.clientName = clientName
        mapper = Mutex(MIDIMapper(table: table))
    }

    deinit { stop() }

    public var table: MIDIMapTable {
        get { mapper.withLock { $0.table } }
        set { mapper.withLock { $0.table = newValue } }
    }

    public var counters: Counters {
        Counters(messages: messages.load(ordering: .relaxed), commands: commandsCount.load(ordering: .relaxed),
                 rejected: rejected.load(ordering: .relaxed), ignored: ignored.load(ordering: .relaxed), learned: learned.load(ordering: .relaxed))
    }

    /// 当前看到的源（按名字排序）。
    public var sources: [MIDISourceInfo] { sourceTable.withLock { Array($0.values) }.sorted { $0.name < $1.name } }

    public var isRunning: Bool { started.load(ordering: .acquiring) }

    // MARK: 生命周期

    /// 起 MIDI 线程、建客户端和输入口、连上现有的源。
    public func start() throws {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        // 顺序派发的 Task
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        queue = continuation
        dispatchTask = Task { [self] in
            for await command in stream {
                do {
                    _ = try await self.bus.submit(command, source: .midi)
                    self.commandsCount.add(1, ordering: .relaxed)
                } catch {
                    self.rejected.add(1, ordering: .relaxed)
                }
            }
        }
        let ready = DispatchSemaphore(value: 0)
        let failure = Mutex<MIDIError?>(nil)
        let t = Thread { [self] in
            if let e = setUpOnThread() {
                failure.withLock { $0 = e }
                ready.signal()
                return
            }
            runLoop = CFRunLoopGetCurrent()
            ready.signal()
            // 跑 run loop 直到 stop() 叫停；加个空端口保证有输入源、不会立即返回
            RunLoop.current.add(Port(), forMode: .default)
            while started.load(ordering: .acquiring) {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
            tearDownOnThread()
        }
        t.name = "switcher.midi"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if let e = failure.withLock({ $0 }) {
            started.store(false, ordering: .releasing)
            queue?.finish()
            thread = nil
            throw e
        }
    }

    /// 停线程、断开并销毁客户端。
    public func stop() {
        guard started.exchange(false, ordering: .acquiringAndReleasing) else { return }
        if let rl = runLoop { CFRunLoopStop(rl) }
        // 线程退出后 client 已销毁（tearDownOnThread）
        queue?.finish()
        queue = nil
        dispatchTask = nil
        thread = nil
        runLoop = nil
    }

    // MARK: learn

    /// 下一条 CC / Note 交给回调（在 CoreMIDI 线程上），不派发；之后自动退出 learn。
    public func startLearn(_ handler: @escaping @Sendable (MIDIMessage) -> Void) {
        learnHandler.withLock { $0 = handler }
    }

    public func cancelLearn() { learnHandler.withLock { $0 = nil } }

    public var isLearning: Bool { learnHandler.withLock { $0 != nil } }

    // MARK: MIDI 线程

    /// 在 MIDI 线程上：建客户端 + 输入口，连所有源。
    private func setUpOnThread() -> MIDIError? {
        var st = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            self?.handleNotification(notification)
        }
        guard st == noErr else { return MIDIError(what: "MIDIClientCreate", status: st) }
        st = MIDIInputPortCreateWithProtocol(client, "\(clientName) 输入" as CFString, ._1_0, &port) { [weak self] eventList, _ in
            self?.handleEventList(eventList)
        }
        guard st == noErr else {
            MIDIClientDispose(client)
            return MIDIError(what: "MIDIInputPortCreate", status: st)
        }
        rescanSources()
        return nil
    }

    private func tearDownOnThread() {
        let table = sourceTable.withLock { t -> [MIDIEndpointRef: MIDISourceInfo] in
            let copy = t
            t.removeAll()
            return copy
        }
        for (endpoint, info) in table where info.connected { MIDIPortDisconnectSource(port, endpoint) }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    private func handleNotification(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
        case .msgObjectAdded, .msgObjectRemoved:
            let n = notification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { $0.pointee }
            guard n.childType == .source else { return }
            if notification.pointee.messageID == .msgObjectAdded {
                connect(source: n.child)
            } else {
                disconnect(source: n.child)
            }
        case .msgSetupChanged:
            rescanSources()
        default:
            break
        }
    }

    private func rescanSources() {
        let count = MIDIGetNumberOfSources()
        var seen = Set<MIDIEndpointRef>()
        for i in 0..<count {
            let src = MIDIGetSource(i)
            seen.insert(src)
            let known = sourceTable.withLock { $0[src]?.connected ?? false }
            if !known { connect(source: src) }
        }
        // 已经不在列表里的
        let stale = sourceTable.withLock { $0.keys.filter { !seen.contains($0) } }
        for s in stale { disconnect(source: s) }
    }

    private func connect(source: MIDIEndpointRef) {
        let st = MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: Int(source)))
        let info = MIDISourceInfo(name: Self.name(of: source), uniqueID: Self.uniqueID(of: source), endpoint: source, connected: st == noErr)
        sourceTable.withLock { $0[source] = info }
    }

    private func disconnect(source: MIDIEndpointRef) {
        let was = sourceTable.withLock { $0.removeValue(forKey: source) }
        if was?.connected == true { MIDIPortDisconnectSource(port, source) }
    }

    static func name(of endpoint: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &s)
        if let name = s?.takeRetainedValue() as String?, !name.isEmpty { return name }
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &s)
        return (s?.takeRetainedValue() as String?) ?? "MIDI \(endpoint)"
    }

    static func uniqueID(of endpoint: MIDIEndpointRef) -> Int32 {
        var id: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
        return id
    }

    // MARK: CoreMIDI 接收线程

    private func handleEventList(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            var words = [UInt32](repeating: 0, count: count)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let p = raw.bindMemory(to: UInt32.self)
                for k in 0..<min(count, p.count) { words[k] = p[k] }
            }
            let ts = packet.pointee.timeStamp == 0 ? HostClock.now() : HostTime(ticks: packet.pointee.timeStamp)
            for message in MIDIUMP.parse(words: words, timestamp: ts) { handle(message) }
        }
    }

    /// 一条消息：learn 优先；否则按表映射、入队派发。
    func handle(_ message: MIDIMessage) {
        messages.add(1, ordering: .relaxed)
        onMessage?(message)
        if let handler = learnHandler.withLock({ h -> (@Sendable (MIDIMessage) -> Void)? in defer { h = nil }; return h }) {
            learned.add(1, ordering: .relaxed)
            handler(message)
            return
        }
        guard let state = bus.stateMachine.publisher.latest?.state else { return }
        guard let command = mapper.withLock({ $0.command(for: message, state: state) }) else {
            ignored.add(1, ordering: .relaxed)
            return
        }
        _ = queue?.yield(command)
    }
}
