import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// W5-D 端到端：本地 MediaMTX 开鉴权（authMethod internal），真编码器 + HaishinKit 推 10 s，落盘帧号连续。
/// MediaMTX 1.21 的 RTMP 鉴权只认查询串 ?user=&pass=（publish 时查），不发 Adobe 挑战、也看不到 user:pass@（报告 §1），所以：
/// - 地址里写 user:pass@ 的那条走 AdobeAuthGateway（Adobe 鉴权的服务器端，独立实现）→ 验过之后换成 MediaMTX 的 user=&pass= 转给开了鉴权的 MediaMTX；
/// - 查询串那条直推 MediaMTX；
/// - 另两条记下 MediaMTX 自己的行为：不开鉴权时带 user:pass@ 照常推；开鉴权时只写 user:pass@ 推不上（它不认）。
/// 端口：MediaMTX 21950 / 28950 / 30050，网关 19470；没装 mediamtx 就 XCTSkip（BLOCKED-工具）。
final class StreamAuthMediaMTXTests: XCTestCase {
    private var instances: [MediaMTXInstance] = []
    private var outputs: [StreamOutput] = []
    private var gateways: [AdobeAuthGateway] = []

    /// MediaMTX 那边的推流账号（与网关的 Adobe 账号故意不同：网关验的是 Adobe 那套，验过再换成这一套）。
    static let mtxUser = "mtxpub"
    static let mtxPass = "mtx-secret"
    /// 开鉴权：mtxpub / mtx-secret 能推任意路径；本机匿名只给 api（MediaMTXInstance 等 API 起来、查发布状态要用）。
    static let authConfig = """
        authMethod: internal
        authInternalUsers:
        - user: \(mtxUser)
          pass: \(mtxPass)
          ips: []
          permissions:
          - action: publish
            path:
        - user: any
          pass:
          ips: ['127.0.0.1', '::1']
          permissions:
          - action: api
        """

    override func setUpWithError() throws {
        try MediaMTXInstance.requireAvailable()
        try FFprobe.requireAvailable()
    }

    override func tearDown() {
        for o in outputs where o.isRunning { o.stop() }
        outputs = []
        for g in gateways { g.stop() }
        gateways = []
        for i in instances { i.stop() }
        instances = []
    }

    private func startInstance(test: String, auth: Bool) throws -> MediaMTXInstance {
        let dir = StreamTestPaths.root.appendingPathComponent(test)
        try? FileManager.default.removeItem(at: dir)
        let mtx = try MediaMTXInstance(rtmpPort: 21950, srtPort: 28950, apiPort: 30050, recordDir: dir.appendingPathComponent("mtx"),
                                       extraConfig: auth ? Self.authConfig : nil)
        instances = [mtx]
        print("MediaMTX（鉴权 \(auth ? "开" : "关")），录制目录 \(dir.path)")
        return mtx
    }

    /// 推 [0, ticks) 拍、停、查落盘：帧数 ≥ ticks − 1（MediaMTX 录制器丢最后一帧）、无缺口 / 重复 / 不可解。
    private func pushAndCheck(_ o: StreamOutput, scene: StreamScene, mtx: MediaMTXInstance, path: String, ticks: Int) throws {
        let report = try scene.feed(outputs: [o], ticks: 0..<ticks)
        o.stop()
        let c = o.counters
        print("\(o.consumerName)：\(c)")
        XCTAssertEqual(report.framesFed, ticks)
        XCTAssertEqual(c.framesSent, UInt64(ticks))
        XCTAssertEqual(c.networkDropped, 0)
        XCTAssertEqual(c.reconnects, 0)
        XCTAssertEqual(o.videoEncoder.counters.skipped, 0)
        let files = mtx.recordings(path)
        XCTAssertEqual(files.count, 1, "\(files)")
        guard let file = files.first else { return }
        let st = try Frameprobe.stats(file)
        print("frameprobe stats：\(st)")
        XCTAssertGreaterThanOrEqual(st.totalFrames, ticks - 1, "落盘帧数（MediaMTX 丢最后一帧）")
        XCTAssertEqual(st.droppedFrames, 0)
        XCTAssertEqual(st.dropGaps, 0)
        XCTAssertEqual(st.duplicateFrames, 0)
        XCTAssertEqual(st.undecodable, 0)
    }

    /// 地址里写 user:pass@（密码带 RFC 3986 保留字符和中文，转义一次）→ Adobe 鉴权（前两轮我们自己、第三轮 HaishinKit）→ 网关验过 → 开鉴权的 MediaMTX；
    /// 10 s 落盘 599 帧、帧号连续；网关只见到 3 次 connect（没有 HaishinKit 自带鉴权那种狂连）；密码原文 / 转义形式都没上线。
    func testE_streamAuth_adobeUserinfo_mediamtxAuth_10s_framesContinuous() throws {
        let mtx = try startInstance(test: "auth-adobe-e2e", auth: true)
        let password = "p@ss:w/rd% 密"
        let gw = try AdobeAuthGateway(listenPort: 19470, targetPort: mtx.rtmpPort, user: "pub", password: password,
                                      upstreamQuery: "user=\(Self.mtxUser)&pass=\(Self.mtxPass)")
        gateways = [gw]
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-adobe-e2e", url: "rtmp://pub:p%40ss%3Aw%2Frd%25%20%E5%AF%86@127.0.0.1:19470/s1")
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 10) { o.state == .publishing }, "\(o.state)，网关：\(gw.attempts.map(\.outcome))")
        try pushAndCheck(o, scene: scene, mtx: mtx, path: "s1", ticks: 600)
        XCTAssertEqual(gw.attempts.map(\.outcome), [.askedForAuthmod, .challenged, .accepted])
        for a in gw.attempts {
            XCTAssertNil(a.connectBytes.range(of: Data(password.utf8)), "密码明文上线了：\(a.app)")
            XCTAssertNil(a.connectBytes.range(of: Data("p%40ss".utf8)), "转义后的密码上线了：\(a.app)")
            XCTAssertFalse(a.tcUrl.contains("@"), "tcUrl 不带 userinfo：\(a.tcUrl)")
        }
    }

    /// MediaMTX 自己的方式：查询串 ?user=&pass=（StreamDestination 原样带到 connect 的 app / tcUrl）→ 10 s 帧号连续。
    func testE_streamAuth_mediamtxQueryCredentials_10s_framesContinuous() throws {
        let mtx = try startInstance(test: "auth-query-e2e", auth: true)
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-query-e2e", url: mtx.rtmpURL("s1") + "?user=\(Self.mtxUser)&pass=\(Self.mtxPass)")
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 10) { o.state == .publishing }, "\(o.state)")
        try pushAndCheck(o, scene: scene, mtx: mtx, path: "s1", ticks: 600)
    }

    /// W2-D4（查询串密码错）：开鉴权的 MediaMTX、地址 ?user=mtxpub&pass=错的 → 第一次就停在 failed。MediaMTX 先随机等 0–4 s 才回
    /// NetStream.Publish.Unauthorized（比 HaishinKit 的 publish 请求超时 3 s 晚的那一次也得认出来）；之后照喂 10 s 帧，MediaMTX 日志里
    /// 始终只有这 1 个连接（原来按退避 1、2、4 s 会再连 3 次）；Stats 项 state = failed、attempt 0、dropped 0、
    /// last_error = "鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed"（不带密码）。
    /// 改对密码之后（新的 StreamOutput——App 的"点底栏重试"也是新对象）照常推上、last_error 空。
    func testE_streamAuth_mediamtxQueryWrongPassword_failsFirstTimeNoRetry() throws {
        let mtx = try startInstance(test: "auth-query-wrong", auth: true)
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-query-wrong", url: mtx.rtmpURL("s1") + "?user=\(Self.mtxUser)&pass=wrong-\(Self.mtxPass)")
        outputs = [o]
        let t0 = Date()
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 6) { if case .failed = o.state { return true } else { return false } }, "\(o.state)")
        print("查询串密码错：\(String(format: "%.2f", Date().timeIntervalSince(t0))) s 进 failed")
        let before = o.counters
        try scene.feed(outputs: [o], ticks: 0..<600)
        let c = o.counters, e = o.statsEntry(previous: nil, windowSeconds: 1)
        print("查询串密码错：\(e.lastError)；\(c)")
        XCTAssertEqual(c.connectAttempts, 1, "鉴权失败不重试")
        XCTAssertEqual(Self.connectionsOpened(mtx), 1, "MediaMTX 10 s 里只见过 1 个连接")
        XCTAssertEqual(o.failure, .authentication(.publishUnauthorized))
        XCTAssertEqual([e.state, e.lastError], ["failed", "鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed"])
        XCTAssertEqual(e.attempt, 0)
        XCTAssertEqual(e.dropped, 0, "没推上过：不算网络丢帧")
        XCTAssertEqual(c.framesReceived, before.framesReceived, "failed 之后喂的帧不进编码器")
        o.stop()
        XCTAssertEqual(o.state, .stopped)
        // 改对密码：新对象照常推上
        let fixed = try scene.makeOutput(name: "auth-query-fixed", url: mtx.rtmpURL("s1") + "?user=\(Self.mtxUser)&pass=\(Self.mtxPass)")
        outputs.append(fixed)
        try fixed.start()
        XCTAssertTrue(waitUntil(timeout: 10) { fixed.state == .publishing }, "\(fixed.state)")
        XCTAssertEqual(fixed.statsEntry(previous: nil, windowSeconds: 1).lastError, "")
        XCTAssertNil(fixed.failure)
        fixed.stop()
    }

    /// MediaMTX 日志里 RTMP 连接"opened"的行数（服务器那边看见几次连接）。
    private static func connectionsOpened(_ mtx: MediaMTXInstance) -> Int {
        let log = (try? String(contentsOf: mtx.recordDir.appendingPathComponent("mediamtx-\(mtx.rtmpPort).log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { $0.contains("[RTMP] [conn") && $0.hasSuffix("opened") }.count
    }

    /// 服务器 connect 阶段不要鉴权（MediaMTX 不开鉴权）时地址带 user:pass@：第 1 轮就被接受，交给 HaishinKit 的是不带 userinfo 的地址，照常推。
    /// 推 6 s：MediaMTX 连上之后约 3 s 才认出音视频两轨、开始录（之前的照样从头录进去），推 2 s 就停的话它一个文件都不写。
    func testE_streamAuth_userinfoToServerWithoutConnectAuth_publishes() throws {
        let mtx = try startInstance(test: "auth-none-userinfo", auth: false)
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-none-userinfo", url: "rtmp://pub:secret@127.0.0.1:\(mtx.rtmpPort)/s1")
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 10) { o.state == .publishing }, "\(o.state)")
        try pushAndCheck(o, scene: scene, mtx: mtx, path: "s1", ticks: 360)
    }

    /// 记下来的 MediaMTX 行为（报告 §1）：开鉴权时只在地址里写 user:pass@ 推不上——它 connect 阶段不要鉴权、publish 时只看查询串；
    /// 我们这边是"连不上、按退避重试"，不是卡住：stop() 立刻返回。
    func testE_streamAuth_mediamtxIgnoresUserinfo_documented() throws {
        let mtx = try startInstance(test: "auth-mtx-userinfo", auth: true)
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "auth-mtx-userinfo", url: "rtmp://\(Self.mtxUser):\(Self.mtxPass)@127.0.0.1:\(mtx.rtmpPort)/s1", connectTimeout: 4)
        outputs = [o]
        try o.start()
        XCTAssertFalse(waitUntil(timeout: 6) { o.state == .publishing }, "MediaMTX 认了 userinfo？那报告 §1 要改")
        XCTAssertGreaterThanOrEqual(o.counters.connectAttempts, 1)
        let t0 = Date()
        o.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6, "stop() 被卡住了")
        XCTAssertFalse(mtx.isPublishing("s1"))
    }
}
