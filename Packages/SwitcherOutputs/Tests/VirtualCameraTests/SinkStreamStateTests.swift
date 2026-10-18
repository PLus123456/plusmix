import Foundation
import XCTest

/// D09（Codex 2026-10-13 审查 §1.3）：虚拟摄像头扩展的 sink stream 起停。扩展本体（CameraExtension/）要 Team ID 签名才装得上（BLOCKED-签名），
/// 这里测能单独测的两块：
/// - 起停状态机 `SinkStreamState`（CameraExtension/Sources/SinkStreamState.swift，本 target 经符号链接 SinkStreamState.swift 编进来）：
///   授权回调记下获准的 client、startStream()（协议里不带 client）用它开始消费、stop / 断开 / 再 start 换代让旧链停；
/// - 扩展源码按本机 SDK 的 CMIOExtensionStreamSource 协议接线（静态核：没有协议外的 startStream(for:)、startStream() 不再传 nil）。
final class SinkStreamStateTests: XCTestCase {
    /// 假 client（CMIOExtensionClient 的 init 不开放，单元测试造不出真的）。
    final class FakeClient {
        let id = UUID()
        let name: String
        init(_ name: String) { self.name = name }
    }

    /// 授权回调里获准的 client 就是 startStream() 开始消费的那个（原实现：授权回调不存、startStream() 传 nil → 永远不 consumeNext）。
    func testD09_authorizedClientIsWhatStartStreamConsumes() throws {
        var s = SinkStreamState<FakeClient>()
        let app = FakeClient("switcher")
        XCTAssertFalse(s.isStreaming)
        XCTAssertTrue(s.authorize(app, id: app.id, allowed: true), "签名校验过了：原样交回 true")
        let session = try XCTUnwrap(s.start(), "有获准的 client，startStream() 就开始消费")
        XCTAssertTrue(session.client === app)
        XCTAssertEqual(session.clientID, app.id)
        XCTAssertTrue(s.isStreaming)
        XCTAssertTrue(s.isCurrent(session.generation), "这一代的 consumeSampleBuffer 回调要续下去")
    }

    /// 没有获准的 client（没授权过 / 被签名校验拒了）：start() 给 nil，扩展的 startStream 抛错、主程序的 CMIODeviceStartStream 失败，
    /// 不再像原来那样静悄悄地"起了但不消费"。被拒的不记，之前获准的也不被它顶掉。
    func testD09_noAuthorizedClient_startFails_rejectedClientNotStored() throws {
        var s = SinkStreamState<FakeClient>()
        XCTAssertNil(s.start(), "没授权过")
        XCTAssertFalse(s.isStreaming)
        let stranger = FakeClient("other-app")
        XCTAssertFalse(s.authorize(stranger, id: stranger.id, allowed: false), "签名不符：原样交回 false")
        XCTAssertNil(s.start(), "被拒的 client 不记")
        let app = FakeClient("switcher")
        s.authorize(app, id: app.id, allowed: true)
        s.authorize(stranger, id: stranger.id, allowed: false)
        XCTAssertTrue(try XCTUnwrap(s.start()).client === app, "被拒的不顶掉之前获准的")
    }

    /// stopStream()：这一轮停，旧链（开链时那一代）看到代次变了不再续；重复 stop 无事。
    func testD09_stopEndsSession_oldConsumeChainStops() throws {
        var s = SinkStreamState<FakeClient>()
        let app = FakeClient("switcher")
        s.authorize(app, id: app.id, allowed: true)
        let g = try XCTUnwrap(s.start()).generation
        XCTAssertTrue(s.stop())
        XCTAssertFalse(s.isStreaming)
        XCTAssertFalse(s.isCurrent(g), "停了：旧链的回调不转发、不再续")
        XCTAssertFalse(s.stop(), "已经停了")
        // 同一个 client 再起：新的一代，旧代仍不算
        let g2 = try XCTUnwrap(s.start(), "获准的 client 还记着，stop 之后可以再 start").generation
        XCTAssertNotEqual(g, g2)
        XCTAssertTrue(s.isCurrent(g2))
        XCTAssertFalse(s.isCurrent(g))
    }

    /// 没 stop 又 start（主程序换了个连接重新起流）：换一代，只剩新链在消费——不会两条链一起 consumeSampleBuffer、抢着读、乱序发出去；
    /// 用的是最近一次获准的 client。
    func testD09_restartWithoutStop_onlyNewestChainContinues_usesLatestAuthorizedClient() throws {
        var s = SinkStreamState<FakeClient>()
        let first = FakeClient("switcher-1")
        s.authorize(first, id: first.id, allowed: true)
        let a = try XCTUnwrap(s.start())
        let second = FakeClient("switcher-2")
        s.authorize(second, id: second.id, allowed: true)
        XCTAssertTrue(s.isCurrent(a.generation), "授权本身不打断正在消费的一轮")
        let b = try XCTUnwrap(s.start())
        XCTAssertTrue(b.client === second, "startStream() 用最近一次获准的 client")
        XCTAssertFalse(s.isCurrent(a.generation), "旧链停")
        XCTAssertTrue(s.isCurrent(b.generation))
    }

    /// provider 的 disconnect(from:)：按 clientID 认（CMIOExtensionClient 是 NSCopying，断开时给的未必是同一个对象）——
    /// 断的是正在消费的那个就停、获准记录也清掉（之后 start 失败而不是去读一个已经走了的 client）；断的是别人则无事。
    func testD09_disconnectByClientID_stopsAndForgets_othersIgnored() throws {
        var s = SinkStreamState<FakeClient>()
        let app = FakeClient("switcher")
        s.authorize(app, id: app.id, allowed: true)
        let g = try XCTUnwrap(s.start()).generation
        XCTAssertFalse(s.disconnect(id: UUID()), "别的 client 断开：不停")
        XCTAssertTrue(s.isCurrent(g))
        let copyOfAppID = UUID(uuidString: app.id.uuidString)!   // 回调里给的是另一个对象，但 clientID 相同
        XCTAssertTrue(s.disconnect(id: copyOfAppID), "正在消费的 client 断开：停")
        XCTAssertFalse(s.isStreaming)
        XCTAssertFalse(s.isCurrent(g))
        XCTAssertNil(s.authorized)
        XCTAssertNil(s.start(), "断开的 client 不再用")
        // 只授权、没起流的 client 断开：清掉记录，不涉及停
        let next = FakeClient("switcher-next")
        s.authorize(next, id: next.id, allowed: true)
        XCTAssertFalse(s.disconnect(id: next.id))
        XCTAssertNil(s.start())
    }

    /// 扩展源码按本机 SDK 的协议接线（静态核，扩展本体装不上）：本机 SDK 的 CMIOExtensionStreamSource 只有不带 client 的
    /// startStream / stopStream；扩展里不再有协议外的 startStream(for:)、startStream() 不再传 client: nil、sink 的起停走 SinkStreamState。
    func testD09_extensionWiredToSDKProtocol_noStartStreamForClient() throws {
        let root = try SourceLanguageTests.repoRoot()
        let provider = try String(contentsOf: root.appendingPathComponent("CameraExtension/Sources/CameraExtensionProvider.swift"), encoding: .utf8)
        let code = provider.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("startStream(for"), "startStream(for:) 不在 CMIOExtensionStreamSource 协议里，系统不会调")
        XCTAssertFalse(code.contains("client: nil"), "startStream() 不能再把 nil 当 client 传下去")
        XCTAssertTrue(code.contains("func startStream() throws"), "协议入口 startStream()")
        XCTAssertTrue(code.contains("func stopStream() throws"), "协议入口 stopStream()")
        XCTAssertTrue(code.contains("func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool"), "授权回调")
        XCTAssertTrue(code.contains("SinkStreamState<CMIOExtensionClient>"), "sink 的起停走 SinkStreamState")
        // 本机 SDK 的协议本身（探针：头文件里起停入口不带 client）
        let header = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreMediaIO.framework/Headers/CMIOExtensionStream.h"
        guard let h = try? String(contentsOfFile: header, encoding: .utf8) else { return }
        let proto = h.components(separatedBy: "@protocol CMIOExtensionStreamSource").dropFirst().first?.components(separatedBy: "@end").first ?? ""
        XCTAssertTrue(proto.contains("startStreamAndReturnError"), "协议的 startStream 不带 client")
        XCTAssertTrue(proto.contains("stopStreamAndReturnError"))
        XCTAssertTrue(proto.contains("authorizedToStartStreamForClient"))
        XCTAssertFalse(proto.contains("startStreamForClient"), "协议里没有带 client 的 startStream")
    }

    /// 签名环境的端到端验收：装上扩展、主程序起 sink → FaceTime / QuickTime 里看到 PGM、'sonp' 回报不跳号。
    func testD09_signedExtension_consumesPGMFromSinkClient() throws {
        throw XCTSkip("BLOCKED-签名：系统扩展要 Apple 签发的证书（DEVELOPMENT_TEAM=… make gen）、App 在 /Applications 里才能激活；"
                      + "解锁后按 reports/w3-outputs-5.md §5 的步骤验：授权回调记下主程序的 client、startStream() 开始消费、PGM 出现在摄像头里、停 / 重起不双链")
    }
}
