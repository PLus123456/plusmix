// sink stream 的起停状态机（D09，Codex 2026-10-13 审查 §1.3）：纯逻辑，不 import CoreMediaIO，对 client 的类型泛型——
// 扩展里是 CMIOExtensionClient，VirtualCameraTests 里是假 client（测试 target 用符号链接把本文件编进去，扩展本体要签名才能装，BLOCKED-签名）。
//
// 本机 SDK（MacOSX27.0.sdk 的 CMIOExtensionStream.h）里 CMIOExtensionStreamSource 协议的起停入口是
//   authorizedToStartStreamForClient:（带 client）→ startStreamAndReturnError: / stopStreamAndReturnError:（不带 client），
// 没有带 client 的 startStream。所以获准的 client 只能在授权回调里记下，startStream() 用记下的那个开始消费。
// 以前：授权回调只做签名校验、不存 client，startStream() 传 nil（于是从不 consumeNext），另写的 startStream(for:) 不在协议里、系统不会调。
//
// 代次：每次 start / stop / 断开都换一代。consumeSampleBuffer 的回调带着开链时的代次，代次不是当前的就不再续——
// 停了之后旧链自己停；不停直接再 start（新 client 起流）也只剩一条链在消费，不会两条链抢着读、乱序发出去。
// client 按 clientID 认：CMIOExtensionClient 是 NSCopying，断开回调里给的未必是授权时那个对象。
// 线程：不自带锁，由 CameraDeviceSource 在它的锁里调。只放 ASCII 字面量（SourceLanguageTests 扫本目录）。
import Foundation

struct SinkStreamState<Client> {
    /// 一轮消费：从哪个 client 读、第几代。
    struct Session {
        let client: Client
        let clientID: UUID
        let generation: UInt64
    }

    /// 最近一次获准的 client（startStream() 用它）；被拒的不记，断开的清掉。
    private(set) var authorized: (client: Client, id: UUID)?
    /// 正在消费的一轮；nil = 没在消费。
    private(set) var session: Session?
    private(set) var generation: UInt64 = 0

    var isStreaming: Bool { session != nil }

    /// authorizedToStartStream(for:)：`allowed`（签名校验的结果）为真就记下这个 client。返回 `allowed`，原样交回给系统。
    @discardableResult
    mutating func authorize(_ client: Client, id: UUID, allowed: Bool) -> Bool {
        if allowed { authorized = (client, id) }
        return allowed
    }

    /// startStream()：用记下的 client 开一轮（新的一代）。没有获准的 client 返回 nil——调用方让 startStream 抛错，
    /// 主程序的 CMIODeviceStartStream 就会失败（以前是静悄悄地不消费）。已经在消费时再 start：换一代，旧链停。
    mutating func start() -> Session? {
        guard let a = authorized else { return nil }
        generation &+= 1
        let s = Session(client: a.client, clientID: a.id, generation: generation)
        session = s
        return s
    }

    /// stopStream()：停这一轮（旧链看到代次变了不再续）。返回之前是否在消费。
    @discardableResult
    mutating func stop() -> Bool {
        guard session != nil else { return false }
        generation &+= 1
        session = nil
        return true
    }

    /// provider 的 disconnect(from:)：是获准的那个就忘掉；正在消费它就停。返回是否停了一轮。
    @discardableResult
    mutating func disconnect(id: UUID) -> Bool {
        if authorized?.id == id { authorized = nil }
        guard session?.clientID == id else { return false }
        return stop()
    }

    /// consumeSampleBuffer 的回调：开链时的这一代还在消费吗（不在 = 这条链到此为止，不转发、不再续）。
    func isCurrent(_ generation: UInt64) -> Bool { session?.generation == generation }
}
