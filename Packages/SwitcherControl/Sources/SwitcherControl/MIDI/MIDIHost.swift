import CoreMIDI
import Foundation

// 进程级的 CoreMIDI 宿主（W2-C2，reports/issues/W3E-w2-control-midi-hotplug-after-restart.md）。
// 探针（reports/w2-control-2.md §1）证实：CoreMIDI 把进程里**所有**客户端的通知（源增删 = 热插拔）派到"进程里第一次
// MIDIClientCreate 时的那条 run loop"上；那条线程退出后，之后建的客户端（哪怕建在一条活着的 run loop 线程上）一条通知也收不到——
// 换过节目 = 第一个控制器停过，再插的设备连不上。偶尔能收到一两条是新线程复用了旧线程的 run loop 对象，靠不住。
// 所以：一条常驻线程 + 它的 run loop + 一个永不销毁的锚客户端，进程里第一个客户端就是这个锚（在宿主线程上建）。之后
// MIDIController / VirtualMIDISource 的客户端都在宿主线程上建 / 销毁，所有通知都落在宿主线程上、与建 / 销毁串行。控制器 stop 只销毁
// 自己的输入口和客户端，宿主线程和锚一直活着。若 App 在此之前已在主线程建过客户端（App 的 MIDINotificationAnchor），通知会落在主线程，
// 控制器的通知处理会跳回宿主线程再做，两种情况行为一样（探针里别的线程、甚至没有 run loop 的线程建的客户端，通知也都到宿主线程）。

/// 进程级 CoreMIDI 宿主线程：所有客户端的建 / 销毁与通知处理都在它上面串行。
/// `@unchecked Sendable` 的理由：`thread` / `runLoop` / `anchor` / `anchorStatus` 只在 init 里（宿主线程就绪、信号量返回之后）写一次、之后只读；
/// 没有别的可变状态。跨线程只通过 `sync` / `async` 把 `@Sendable` 闭包送到宿主线程执行。
final class MIDIHost: @unchecked Sendable {
    static let shared = MIDIHost()

    let thread: Thread
    private let runLoop: CFRunLoop
    /// 锚客户端（建失败为 0）。不干活、不销毁：它把整个进程的通知 run loop 钉在宿主线程上。
    let anchor: MIDIClientRef
    let anchorStatus: OSStatus

    /// init 与宿主线程之间的一次性交接：线程就绪前写、`ready` 信号量之后读，各一次。
    private final class Handoff: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var anchor = MIDIClientRef()
        var status: OSStatus = noErr
    }

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let handoff = Handoff()
        let t = Thread {
            var client = MIDIClientRef()
            let status = MIDIClientCreateWithBlock("PlusMix MIDI anchor" as CFString, &client) { _ in }
            handoff.runLoop = CFRunLoopGetCurrent()
            handoff.anchor = status == noErr ? client : 0
            handoff.status = status
            ready.signal()
            // 跑 run loop 直到进程结束；加个空端口保证有输入源、不会立即返回
            RunLoop.current.add(Port(), forMode: .default)
            while true {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        t.name = "switcher.midi"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        thread = t
        runLoop = handoff.runLoop!
        anchor = handoff.anchor
        anchorStatus = handoff.status
    }

    var isCurrent: Bool { Thread.current === thread }

    /// 在宿主线程上同步跑 body、拿回结果；已经在宿主线程上就直接跑（不然会等自己）。
    /// W2-C3：离开 `withoutActuallyEscaping` 时运行时检查闭包没被别人留着，留着就 trap（"non-escaping closure has escaped"，Debug / Release 都是）。
    /// 交给 run loop 的块要等它返回、被 run loop 释放时才放掉捕获的东西，可调用方在 signal 之后随时会走——所以块不直接捕获闭包，
    /// 闭包放在 `SyncCall` 里，宿主线程跑完先清掉、再放行调用方（修前块里先 signal，调用方抢在块被释放之前离开就崩，
    /// reports/issues/W5A-w2-control-midihost-sync-escaping-crash.md）。
    func sync<T: Sendable>(_ body: @Sendable () -> T) -> T {
        if isCurrent { return body() }
        return withoutActuallyEscaping(body) { escapable in
            let call = SyncCall(escapable)
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { call.run() }
            CFRunLoopWakeUp(runLoop)
            return call.wait()
        }
    }

    /// `sync` 的一次交接：闭包在宿主线程上跑完就清掉，块晚些被释放时只放掉对本对象的引用、不再牵着闭包。
    /// `@unchecked Sendable` 的理由：`body` 在调用方线程 init 时写、宿主线程 `run` 里读并清空；`result` 宿主线程写、调用方 `wait` 返回后读；
    /// 前后由入队（CFRunLoopPerformBlock 内部加锁）和信号量隔开，同一时刻只有一条线程碰它们。
    private final class SyncCall<T: Sendable>: @unchecked Sendable {
        private var body: (@Sendable () -> T)?
        private var result: T?
        private let done = DispatchSemaphore(value: 0)

        init(_ body: @escaping @Sendable () -> T) { self.body = body }

        /// 宿主线程：跑 → 清掉闭包 → 放行调用方，顺序不能换。
        func run() {
            result = body?()
            body = nil
            done.signal()
        }

        func wait() -> T {
            done.wait()
            return result!
        }
    }

    /// 送到宿主线程上异步跑；已经在宿主线程上就直接跑（保持通知的先后顺序）。
    func async(_ body: @escaping @Sendable () -> Void) {
        if isCurrent {
            body()
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }
}

/// 通知里要用的内容：回调给的指针只在回调期间有效，先抄出来再跳线程。
enum MIDINotice: Sendable {
    case sourceAdded(MIDIEndpointRef)
    case sourceRemoved(MIDIEndpointRef)
    case setupChanged

    init?(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
        case .msgObjectAdded, .msgObjectRemoved:
            let n = notification.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { $0.pointee }
            guard n.childType == .source else { return nil }
            self = notification.pointee.messageID == .msgObjectAdded ? .sourceAdded(n.child) : .sourceRemoved(n.child)
        case .msgSetupChanged:
            self = .setupChanged
        default:
            return nil
        }
    }
}
