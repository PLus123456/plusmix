import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// W5-D：RTMP / RTMPS 地址里的 user:pass@ 传到连接层（X25）。
/// HaishinKit 2.2.5 自带的 Adobe 鉴权不能用（算错含转义字符的密码、密码错时自己狂连、和旧连接收尾有竞态，reports/w5-stream-auth.md §1），
/// 前两轮由 RTMPAdobeAuth 自己做；这里用测试网关（AdobeAuthGateway，独立实现的服务器端）验它，不需要 MediaMTX。
final class StreamAuthTests: XCTestCase {
    private var gateways: [AdobeAuthGateway] = []
    private var outputs: [StreamOutput] = []

    override func tearDown() {
        for o in outputs where o.isRunning { o.stop() }
        outputs = []
        for g in gateways { g.stop() }
        gateways = []
    }

    private func gateway(_ port: Int, user: String = "pub", password: String) throws -> AdobeAuthGateway {
        let g = try AdobeAuthGateway(listenPort: port, targetPort: nil, user: user, password: password, upstreamQuery: nil)
        gateways.append(g)
        return g
    }

    // MARK: 公式

    /// Adobe 应答公式对独立算出的参考值（Python hashlib，见报告 §2）：base64(md5(base64(md5(user + salt + password)) + opaque 或 challenge + 客户端 challenge))。
    func testE_adobeResponse_matchesReferenceVector() {
        XCTAssertEqual(RTMPAdobeAuth.response(user: "pub", password: "p@ss:w/rd%", salt: "c2FsdA==", opaque: "b3BhcXVl", challenge: "Y2hhbA==",
                                              clientChallenge: "0a1b2c3d"), "v1CkAcdsejzY/VpzmpCqzA==", "有 opaque 用 opaque")
        XCTAssertEqual(RTMPAdobeAuth.response(user: "pub", password: "p@ss:w/rd%", salt: "c2FsdA==", opaque: nil, challenge: "Y2hhbA==",
                                              clientChallenge: "0a1b2c3d"), "4SrVFs4ZMVo+Afbp1tAIHg==", "没有 opaque 用服务器的 challenge")
        XCTAssertEqual(RTMPAdobeAuth.response(user: "pub", password: "密码 1", salt: "c2FsdA==", opaque: "b3BhcXVl", challenge: nil,
                                              clientChallenge: "0a1b2c3d"), "rbSvj6lXXvIAIdKt4+QGDw==", "非 ASCII 按 UTF-8")
        // 测试网关用的是另一份实现（CryptoKit 直接写），两边要对得上
        XCTAssertEqual(AdobeAuthGateway.adobeResponse(user: "pub", password: "p@ss:w/rd%", salt: "c2FsdA==", opaqueOrChallenge: "b3BhcXVl",
                                                      clientChallenge: "0a1b2c3d"), "v1CkAcdsejzY/VpzmpCqzA==")
    }

    /// 服务器回的描述 → 参数（原样，不解码：salt 原样进 MD5）。
    func testE_adobeDescriptionParsing() {
        let p = RTMPAdobeAuth.parameters(inDescription: "[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=needauth&user=pub&salt=Ab+/c==&challenge=x%2By&opaque=o=")
        XCTAssertEqual(p["reason"], "needauth")
        XCTAssertEqual(p["salt"], "Ab+/c==")
        XCTAssertEqual(p["challenge"], "x%2By")
        XCTAssertEqual(p["opaque"], "o=")
        XCTAssertTrue(RTMPAdobeAuth.parameters(inDescription: "[ AccessManager.Reject ] : [ code=403 need auth; authmod=adobe ] : ").isEmpty)
    }

    // MARK: 前两轮 + 第三轮（对测试网关）

    /// 前两轮自己做：第 1 轮服务器要 adobe、第 2 轮拿 salt / challenge / opaque，用解码后的密码算应答；第三轮（这里用同一个最小客户端连）被接受。
    /// 密码带 RFC 3986 保留字符（HaishinKit 自带的那套在这里会算错）；三次连接里密码一个字节都不明文上线。
    func testE_rtmpAdobeAuth_negotiatesWithDecodedPassword() async throws {
        let password = "p@ss:w/rd% 密"
        let g = try gateway(19461, password: password)
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://pub:p%40ss%3Aw%2Frd%25%20%E5%AF%86@127.0.0.1:19461/s1"))
        let creds = try XCTUnwrap(d.credentials)
        XCTAssertEqual(creds.password, password)
        let target = try await RTMPAdobeAuth.authorize(connectURL: d.connectURLWithoutCredentials, credentials: creds, timeoutSeconds: 5)
        XCTAssertFalse(target.contains("@"), "交给 HaishinKit 的地址不带 userinfo：\(target)")
        XCTAssertTrue(target.hasPrefix("rtmp://127.0.0.1:19461/s1?authmod=adobe&user=pub&challenge="), target)
        let reply = try await RTMPAdobeAuth.probeConnect(url: target, timeoutSeconds: 5)
        XCTAssertEqual(reply.code, "NetConnection.Connect.Success", "\(reply)")
        XCTAssertEqual(g.attempts.map(\.outcome), [.askedForAuthmod, .challenged, .accepted])
        for a in g.attempts {
            XCTAssertNil(a.connectBytes.range(of: Data(password.utf8)), "密码明文上线了：\(a.app)")
            XCTAssertNil(a.connectBytes.range(of: Data("p%40ss".utf8)), "转义后的密码上线了：\(a.app)")
        }
    }

    /// 带查询串的地址：鉴权参数接在原查询串后面（& 连接），原参数不丢。
    func testE_rtmpAdobeAuth_appendsToExistingQuery() async throws {
        let g = try gateway(19462, password: "secret")
        let target = try await RTMPAdobeAuth.authorize(connectURL: "rtmp://127.0.0.1:19462/live?foo=1",
                                                       credentials: .init(user: "pub", password: "secret"), timeoutSeconds: 5)
        XCTAssertTrue(target.hasPrefix("rtmp://127.0.0.1:19462/live?foo=1&authmod=adobe&user=pub&challenge="), target)
        let reply = try await RTMPAdobeAuth.probeConnect(url: target, timeoutSeconds: 5)
        XCTAssertEqual(reply.code, "NetConnection.Connect.Success")
        XCTAssertEqual(g.attempts.map(\.app).first, "live?foo=1")
    }

    /// 用户名不对：第 2 轮服务器回 nosuchuser → 直接报鉴权失败，不再连。
    func testE_rtmpAdobeAuth_noSuchUserFailsAtSecondRound() async throws {
        let g = try gateway(19463, password: "secret")
        do {
            _ = try await RTMPAdobeAuth.authorize(connectURL: "rtmp://127.0.0.1:19463/s1", credentials: .init(user: "bob", password: "secret"), timeoutSeconds: 5)
            XCTFail("用户名不对应该失败")
        } catch let e as RTMPAdobeAuth.Failure {
            guard case .badCredentials = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(g.attempts.map(\.outcome), [.askedForAuthmod, .noSuchUser])
    }

    /// 服务器 30 s 不回话：authorize 所在的 Task 被取消（StreamOutput 的连接超时就是这么做的）后 1 s 内返回。
    func testE_rtmpAdobeAuth_cancellationReturnsPromptly() async throws {
        let g = try gateway(19464, password: "secret")
        g.rejectDelay = 30
        let task = Task { try await RTMPAdobeAuth.authorize(connectURL: "rtmp://127.0.0.1:19464/s1", credentials: .init(user: "pub", password: "secret"), timeoutSeconds: 60) }
        try await Task.sleep(for: .milliseconds(300))
        let t0 = Date()
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "取消之后没及时返回")
    }

    // MARK: 经 HaishinKit（RTMPTransport）

    /// 密码错（服务器 20 ms 往返）：一次 connect 只连 3 次（我们 2 次 + HaishinKit 1 次），在连接超时内报鉴权失败；
    /// HaishinKit 自带的那套在同样条件下 13 s 里连了 430 次、不看取消（探针，报告 §1）。
    func testE_rtmpTransport_wrongPasswordFailsFastWithoutReconnectStorm() async throws {
        let g = try gateway(19465, password: "secret")
        g.rejectDelay = 0.02
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://pub:wrong@127.0.0.1:19465/s1"))
        let transport = try HaishinKitTransportFactory(format: .hd1080p60, video: VideoEncodeSettings(), connectTimeoutSeconds: 5)
            .makeTransport(for: d, audioFormat: nil)
        let t0 = Date()
        do {
            try await withTimeout(seconds: 5) { try await transport.connect() }
            XCTFail("密码错应该连不上")
        } catch {
            XCTAssertFalse("\(error)".contains("wrong"), "错误里带了密码：\(error)")
            print("密码错：\(error)")
        }
        let elapsed = Date().timeIntervalSince(t0)
        await transport.close()
        try await Task.sleep(for: .seconds(1))
        XCTAssertLessThan(elapsed, 3, "密码错要很快失败（不是等到超时）")
        XCTAssertEqual(g.attempts.map(\.outcome), [.askedForAuthmod, .challenged, .authFailed], "一次 connect 只连 3 次，之后也不再自己连")
    }

    /// 生产路径：StreamOutput（真编码器）+ 密码错：一直连不上，但每次尝试只连 3 次；stop() 立刻返回（不被卡在连接里）。
    func testE_streamOutput_wrongPassword_backsOffAndStopsPromptly() throws {
        let g = try gateway(19466, password: "secret")
        g.rejectDelay = 0.02
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-wrong", url: "rtmp://pub:wrong@127.0.0.1:19466/s1", connectTimeout: 3)
        outputs = [o]
        try o.start()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertNotEqual(o.state, .publishing)
        let t0 = Date()
        o.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "stop() 被卡住了")
        let attempts = Int(o.counters.connectAttempts)      // stop 之后读：两边的数都定了
        XCTAssertGreaterThanOrEqual(attempts, 1)
        XCTAssertLessThanOrEqual(g.attempts.count, 3 * attempts, "每次尝试最多 3 次连接：\(g.attempts.map(\.outcome))")
        XCTAssertFalse(g.attempts.contains { $0.outcome == .accepted })
    }

    // MARK: 鉴权失败就停（W2-D4）

    /// 服务器回的状态 → 类型化的鉴权失败原因：只看状态码，加上 Adobe 那套写在描述里的 reason / authmod 参数；不是鉴权的拒绝返回 nil（照旧退避）。
    /// 转成的 StreamTransportError：鉴权类 = "鉴权失败（…）：<状态码> <描述>"（原文），其余 = connectFailed（publish 阶段带前缀）。
    func testE_rtmpStatus_classifiesAuthFailures() {
        let rejected = "NetConnection.Connect.Rejected"
        let authfailed = "[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=authfailed&opaque=b3BhcXVl"
        XCTAssertEqual(RTMPTransport.authFailure(code: rejected, description: authfailed), .badCredentials)
        XCTAssertEqual(RTMPTransport.authFailure(code: rejected, description: "[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=nosuchuser&opaque=x"), .noSuchUser)
        XCTAssertEqual(RTMPTransport.authFailure(code: "NetStream.Publish.Unauthorized", description: "authentication failed"), .publishUnauthorized)
        XCTAssertEqual(RTMPTransport.authFailure(code: rejected, description: "[ AccessManager.Reject ] : [ code=403 need auth; authmod=adobe ] : "), .credentialsRequired)
        XCTAssertEqual(RTMPTransport.authFailure(code: rejected, description: "[ AccessManager.Reject ] : [ authmod=llnw ] : "), .unsupportedMethod)
        XCTAssertNil(RTMPTransport.authFailure(code: rejected, description: "Connection rejected."))
        XCTAssertNil(RTMPTransport.authFailure(code: "NetStream.Publish.BadName", description: "Stream already publishing"))
        XCTAssertNil(RTMPTransport.authFailure(code: "NetConnection.Connect.Closed", description: ""))
        XCTAssertEqual(RTMPTransport.error(code: rejected, description: authfailed, phase: ""),
                       .authenticationFailed(.badCredentials, message: "鉴权失败（用户名或密码不对）：\(rejected) \(authfailed)"))
        XCTAssertEqual(RTMPTransport.error(code: "NetStream.Publish.Unauthorized", description: "authentication failed", phase: "publish"),
                       .authenticationFailed(.publishUnauthorized, message: "鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed"))
        XCTAssertEqual(RTMPTransport.error(code: "NetStream.Publish.BadName", description: "busy", phase: "publish"), .connectFailed("publish: NetStream.Publish.BadName busy"))
        XCTAssertEqual(RTMPTransport.error(code: rejected, description: "see rtmp://u:p@h/app", phase: ""),
                       .connectFailed("\(rejected) see rtmp://\(StreamURLRedaction.marker)@h/app"), "原文里的地址照样打码")
    }

    /// W2-D4（Adobe 密码错）：StreamOutput（真编码器 + HaishinKit）第一次就停在 failed——网关正好 3 次连接（我们 2 次 + HaishinKit 1 次），
    /// 之后照喂 10 s 帧（原来按退避 1、2、4 s 会再试 3 次 = 再 9 个连接）一次都不再连；Stats 项 state = failed、attempt 0、dropped 0、
    /// last_error = "鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected …reason=authfailed…"（不带密码）；stop() 立刻返回、收尾成 stopped。
    func testE_streamOutput_adobeWrongPassword_failsFirstTimeNoRetry() throws {
        let g = try gateway(19467, password: "secret")
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-adobe-wrong", url: "rtmp://pub:wr%40ng-pass@127.0.0.1:19467/s1", connectTimeout: 3)
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 5) { if case .failed = o.state { return true } else { return false } }, "\(o.state)，网关：\(g.attempts.map(\.outcome))")
        let before = o.counters
        try scene.feed(outputs: [o], ticks: 0..<600)
        let c = o.counters, e = o.statsEntry(previous: nil, windowSeconds: 1)
        print("Adobe 密码错：\(e.lastError)；\(c)")
        XCTAssertEqual(g.attempts.map(\.outcome), [.askedForAuthmod, .challenged, .authFailed], "一次尝试 3 个连接，之后 10 s 不再连")
        XCTAssertEqual(c.connectAttempts, 1)
        XCTAssertEqual(o.failure, .authentication(.badCredentials))
        XCTAssertEqual(e.state, "failed")
        XCTAssertEqual(e.attempt, 0)
        XCTAssertEqual(e.dropped, 0, "没连上过：不算网络丢帧")
        XCTAssertEqual(c.framesReceived, before.framesReceived, "failed 之后喂的帧不进编码器")
        XCTAssertTrue(e.lastError.hasPrefix("鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected"), e.lastError)
        XCTAssertTrue(e.lastError.contains("reason=authfailed"), "服务器回的原文照留：\(e.lastError)")
        XCTAssertFalse(e.lastError.contains("wr@ng") || e.lastError.contains("wr%40ng"), "last_error 里有密码：\(e.lastError)")
        let t0 = Date()
        o.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "stop() 被卡住了")
        XCTAssertEqual(o.state, .stopped)
    }

    /// W2-D4：publish 的拒绝比 HaishinKit 的 publish 请求超时（3 s）来得晚——MediaMTX 鉴权失败随机等 0–4 s 才回——超时之后照样从状态流里接住
    /// 那条 NetStream.Publish.Unauthorized，报类型化的鉴权失败（不是"连接失败"去退避重试）。服务器：PublishRejectServer，publish 之后 3.5 s 才回。
    func testE_rtmpTransport_latePublishUnauthorizedStillAuthFailure() async throws {
        let server = try PublishRejectServer(port: 19468, publishReplyDelay: 3.5)
        defer { server.stop() }
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://127.0.0.1:19468/s1?user=pub&pass=wrong"))
        let transport = try HaishinKitTransportFactory(format: .hd1080p60, video: VideoEncodeSettings(), connectTimeoutSeconds: 5)
            .makeTransport(for: d, audioFormat: nil)
        let t0 = Date()
        do {
            try await withTimeout(seconds: 5) { try await transport.connect() }
            XCTFail("publish 被拒应该失败")
        } catch StreamTransportError.authenticationFailed(let reason, let message) {
            XCTAssertEqual(reason, .publishUnauthorized)
            XCTAssertEqual(message, "鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed")
        } catch {
            XCTFail("应是类型化的鉴权失败：\(error)")
        }
        let elapsed = Date().timeIntervalSince(t0)
        await transport.close()
        XCTAssertGreaterThan(elapsed, 3.4, "回复确实是在 HaishinKit 的 3 s 超时之后才到的")
        XCTAssertLessThan(elapsed, 4.5)
        XCTAssertEqual([server.connectionCount, server.publishCount], [1, 1])
    }

    // MARK: 脱敏（日志 / 错误）

    /// 地址：userinfo 整段换成标记、查询串里的密钥参数换成标记，主机、端口、路径保留；文字里的每个地址都这样处理。
    func testE_streamURLRedaction_hidesUserinfoAndSecretParams() {
        let m = StreamURLRedaction.marker
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@h:1935/app"), "rtmp://\(m)@h:1935/app")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmps://me%40x.com:p%40ss@h/app?token=t&x=1"), "rtmps://\(m)@h/app?token=\(m)&x=1")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@ss@h/app"), "rtmp://\(m)@h/app", "没转义的 @：按最后一个 @ 分")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:pa/ss@h/app"), "rtmp://\(m)@h/app", "解析不了的地址（密码里有 /）：保守地按最后一个 @ 打码")
        XCTAssertEqual(StreamURLRedaction.redact(url: "srt://h:9000?passphrase=abc&latency=120"), "srt://h:9000?passphrase=\(m)&latency=120")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://a.example/live"), "rtmp://a.example/live")
        XCTAssertEqual(StreamURLRedaction.redact(url: "not a url"), "not a url")
        let text = #"connectFailed("unsupportedCommand(\"rtmp://pub:s3cret@h/app?authmod=adobe&user=pub\")") 和 srt://h:1?passphrase=zzz"#
        let r = StreamURLRedaction.redact(text: text)
        XCTAssertFalse(r.contains("s3cret"), r)
        XCTAssertFalse(r.contains("zzz"), r)
        XCTAssertTrue(r.contains("rtmp://\(m)@h/app?authmod=adobe&user=\(m)"), "查询串里的 user 也算密钥（与诊断包同一份名单）：\(r)")
        XCTAssertTrue(r.hasSuffix("srt://h:1?passphrase=\(m)"), r)
    }
}
