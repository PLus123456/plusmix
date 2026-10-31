import Foundation
import Network
import XCTest
import RTMPHaishinKit
import SRTHaishinKit
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// W4-C4 问题单（S3，prompt 132 第 5 条）：推流 last_error / 状态窗"最后错误"里底层库的原样文字——
/// `socketErrorOccurred(Optional(POSIXErrorCode(rawValue: 61): Connection refused))`、`publish: requestTimedOut`、
/// `failedToConnect(SRTHaishinKit.SRTRejectReason.timeout)`（W2-D5 探针在 macOS 27 / HaishinKit 2.2.5 上实际拿到的）——换成一句中文概括，
/// 原文（打过码）只进日志。服务器回了状态的：状态码与描述照留（排障要看），前面加"服务器拒绝连接：" / "发布被拒："；鉴权失败那句不变。
final class TransportErrorTextTests: XCTestCase {
    private var outputs: [StreamOutput] = []

    override func tearDown() {
        for o in outputs where o.isRunning { o.stop() }
        outputs = []
    }

    /// last_error 里不该再出现的程序写法。
    private let rawMarkers = ["socketErrorOccurred", "POSIXErrorCode", "Optional(", "requestTimedOut", "failedToConnect", "SRTRejectReason", "NoSuchRecord",
                              "retime", "publish: ", "无状态"]

    private func assertPlain(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        for m in rawMarkers { XCTAssertFalse(s.contains(m), "\(s) 里有 \(m)", file: file, line: line) }
    }

    /// 认得的几种给概括（连接被拒 / 域名解析不了 / 超时 / 网络不通 / 被重置 / TLS / 请求超时 / SRT 的拒绝原因），认不出的给"未知错误"；
    /// 我们自己的错误（StreamTransportError、Adobe 鉴权）本来就是中文，原样。
    func testW4C4_summaryOfCommonErrors() {
        func s(_ e: any Error) -> String { TransportErrorText.summary(of: e) }
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(NWError.posix(.ECONNREFUSED))), "连接被拒（这个地址和端口上没有服务器在听）")
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(NWError.dns(-65554))), "找不到主机（域名解析失败）")
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(NWError.posix(.ETIMEDOUT))), "连接超时（服务器没响应）")
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(NWError.posix(.EHOSTUNREACH))), "网络不通")
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(NWError.posix(.ECONNRESET))), "连接被服务器重置")
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(NWError.tls(-9836))), "TLS 握手失败")
        XCTAssertEqual(s(RTMPConnection.Error.socketErrorOccurred(nil)), "网络错误")
        XCTAssertEqual(s(RTMPConnection.Error.connectionTimedOut), "连接超时")
        XCTAssertEqual(s(RTMPConnection.Error.requestTimedOut), "服务器没回（请求超时）")
        XCTAssertEqual(s(RTMPStream.Error.requestTimedOut), "服务器没回（请求超时）")
        XCTAssertEqual(s(RTMPConnection.Error.unsupportedCommand("rtmp://u:p@h/app")), "地址不支持")
        XCTAssertEqual(s(SRTConnection.Error.failedToConnect(.timeout)), "SRT 连接超时（服务器没回）")
        XCTAssertEqual(s(SRTConnection.Error.failedToConnect(.badsecret)), "SRT 被拒（passphrase 不对）")
        XCTAssertEqual(s(SRTConnection.Error.failedToConnect(.unsecure)), "SRT 被拒（passphrase 一边有一边没有）")
        XCTAssertEqual(s(SRTConnection.Error.failedToConnect(.backlog)), "SRT 连接失败（拒绝原因 5）")
        XCTAssertEqual(s(SRTConnection.Error.unsupportedUri(URL(string: "srt://h:1?passphrase=x"))), "SRT 地址不支持")
        XCTAssertEqual(s(POSIXError(.ECONNREFUSED)), "连接被拒（这个地址和端口上没有服务器在听）")
        XCTAssertEqual(s(StreamTransportError.connectFailed("RTMP 握手超时")), "RTMP 握手超时", "我们自己的：原样")
        XCTAssertEqual(s(RTMPAdobeAuth.Failure.timedOut), "鉴权超时")
        XCTAssertEqual(s(CancellationError()), "已取消")
        struct Odd: Error {}
        XCTAssertEqual(s(Odd()), "未知错误")
    }

    /// 服务器回了状态：connect 阶段"服务器拒绝连接：<状态码> <描述>"、publish 阶段"发布被拒：<状态码> <描述>"（原文打码）；
    /// 鉴权失败那句（W2-D4，App 的 StreamWiringTests 按它断言）不变。
    func testW4C4_serverStatusTexts() {
        let m = StreamURLRedaction.marker
        XCTAssertEqual(RTMPTransport.error(code: "NetStream.Publish.BadName", description: "Stream already publishing", phase: "publish"),
                       .connectFailed("发布被拒：NetStream.Publish.BadName Stream already publishing"))
        XCTAssertEqual(RTMPTransport.error(code: "NetConnection.Connect.Rejected", description: "see rtmp://u:p@h/app", phase: ""),
                       .connectFailed("服务器拒绝连接：NetConnection.Connect.Rejected see rtmp://\(m)@h/app"))
        XCTAssertEqual(RTMPTransport.error(code: "NetStream.Publish.Unauthorized", description: "authentication failed", phase: "publish"),
                       .authenticationFailed(.publishUnauthorized, message: "鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed"))
        // 状态以外的错误（HaishinKit / 网络）：概括；publish 阶段前面加"发布："
        XCTAssertEqual(RTMPTransport.transportError(RTMPStream.Error.requestTimedOut, phase: "publish"), .connectFailed("发布：服务器没回（请求超时）"))
        XCTAssertEqual(RTMPTransport.transportError(RTMPConnection.Error.socketErrorOccurred(NWError.posix(.ECONNREFUSED)), phase: ""),
                       .connectFailed("连接被拒（这个地址和端口上没有服务器在听）"))
    }

    /// 端到端（W2-D5 探针的场景）：RTMP 连没人听的端口 / 解析不了的域名、SRT 连没人听的端口 → 传输层报中文概括；
    /// StreamOutput 的 last_error = "连接失败：<概括>"，没有程序写法。
    func testW4C4_connectFailuresArePlainChinese() async throws {
        let cases: [(url: String, expected: String)] = [
            ("rtmp://127.0.0.1:19495/live/k", "连接被拒（这个地址和端口上没有服务器在听）"),
            ("rtmp://pub:pw@127.0.0.1:19495/live/k", "连接被拒（这个地址和端口上没有服务器在听）"),
            ("rtmp://nonexistent-host.invalid/live/k", "找不到主机（域名解析失败）"),
            ("srt://127.0.0.1:19496?latency=120", "SRT 连接超时（服务器没回）"),
        ]
        for (url, expected) in cases {
            let d = try StreamDestination(settings: StreamSettings(url: url))
            let t = try HaishinKitTransportFactory(format: .hd1080p60, video: VideoEncodeSettings(), connectTimeoutSeconds: 5).makeTransport(for: d, audioFormat: nil)
            do {
                try await withTimeout(seconds: 8) { try await t.connect() }
                XCTFail("\(url) 不该连上")
            } catch let e as StreamTransportError {
                XCTAssertEqual(e, .connectFailed(expected), url)
                assertPlain(e.description)
            }
            await t.close()
        }
    }

    /// 生产路径：StreamOutput 连没人听的端口 → last_error = "连接失败：连接被拒（…）"（原来是 socketErrorOccurred(Optional(POSIXErrorCode…))）。
    func testW4C4_streamOutputLastErrorIsPlainChinese() throws {
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "w4c4-refused", url: "rtmp://127.0.0.1:19497/live/k", connectTimeout: 3)
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 5) { !o.statsEntry(previous: nil, windowSeconds: 1).lastError.isEmpty })
        let e = o.statsEntry(previous: nil, windowSeconds: 1)
        print("W4C4 last_error：\(e.lastError)")
        XCTAssertEqual(e.lastError, "连接失败：连接被拒（这个地址和端口上没有服务器在听）")
        assertPlain(e.lastError)
        o.stop()
    }
}
