import XCTest
import SwitcherContracts
@testable import SwitcherStreaming

final class ReconnectPolicyTests: XCTestCase {
    /// prompt：1、2、4 … 最长 30 s。
    func testBackoffSequence_1_2_4_cappedAt30() {
        let p = ReconnectPolicy()
        XCTAssertEqual((1...8).map { p.delay(forAttempt: $0) }, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertTrue(p.allows(attempt: 1_000_000))
    }

    func testBackoffConfigurableCapAndMaxAttempts() {
        let p = ReconnectPolicy(initialSeconds: 0.5, multiplier: 3, maxSeconds: 5, maxAttempts: 3)
        XCTAssertEqual((1...5).map { p.delay(forAttempt: $0) }, [0.5, 1.5, 4.5, 5, 5])
        XCTAssertTrue(p.allows(attempt: 3))
        XCTAssertFalse(p.allows(attempt: 4))
    }
}

final class StreamDestinationTests: XCTestCase {
    func testRTMP_appAndKey() throws {
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://live.example.com/app", streamKey: "k3y?x=1"))
        XCTAssertEqual(d.scheme, .rtmp)
        XCTAssertEqual(d.host, "live.example.com")
        XCTAssertEqual(d.port, 1935)
        XCTAssertEqual(d.connectURL, "rtmp://live.example.com/app")
        XCTAssertEqual(d.streamName, "k3y?x=1")
        XCTAssertFalse(d.description.contains("k3y"))
    }

    func testRTMP_keyInPathWhenNoStreamKey() throws {
        let d = try StreamDestination(settings: StreamSettings(url: "rtmps://a.b:8443/live/abc"))
        XCTAssertEqual(d.scheme, .rtmps)
        XCTAssertEqual(d.port, 8443)
        XCTAssertEqual(d.connectURL, "rtmps://a.b:8443/live")
        XCTAssertEqual(d.streamName, "abc")
    }

    func testRTMP_singleSegmentIsAppWithEmptyName() throws {
        // MediaMTX：rtmp://host/path
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://127.0.0.1:1936/s2"))
        XCTAssertEqual(d.connectURL, "rtmp://127.0.0.1:1936/s2")
        XCTAssertEqual(d.streamName, "")
    }

    func testSRT_streamKeyBecomesStreamID() throws {
        let d = try StreamDestination(settings: StreamSettings(url: "srt://127.0.0.1:8890?latency=200", streamKey: "publish:srt1"))
        XCTAssertEqual(d.scheme, .srt)
        XCTAssertEqual(d.port, 8890)
        XCTAssertEqual(d.connectURL, "srt://127.0.0.1:8890?latency=200&streamid=publish:srt1")
        let d2 = try StreamDestination(settings: StreamSettings(url: "srt://h:1?streamid=x", streamKey: "y"))
        XCTAssertEqual(d2.connectURL, "srt://h:1?streamid=x")
    }

    func testRejectsBadURLs() {
        XCTAssertThrowsError(try StreamDestination(settings: StreamSettings(url: "http://x/y")))
        XCTAssertThrowsError(try StreamDestination(settings: StreamSettings(url: "rtmp:///nohost")))
        XCTAssertThrowsError(try StreamDestination(settings: StreamSettings(url: "")))
    }

    // MARK: W5-D 地址里的 user:pass@（X25）

    /// rtmp://u:p@host/app → connect 地址带 u:p；发布名、查询串、主机端口和没写 userinfo 时一样；RTMPS 同；SRT 分支不动；日志用的描述不带 userinfo。
    func testE_streamDestination_keepsUserinfoInConnectURL() throws {
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://u:p@live.example.com/app", streamKey: "k3y?x=1"))
        XCTAssertEqual(d.connectURL, "rtmp://u:p@live.example.com/app")
        XCTAssertEqual(d.streamName, "k3y?x=1")
        XCTAssertEqual(d.host, "live.example.com")
        XCTAssertEqual(d.port, 1935)
        XCTAssertEqual(d.credentials, StreamDestination.Credentials(user: "u", password: "p"))
        XCTAssertEqual(d.connectURLWithoutCredentials, "rtmp://live.example.com/app")

        // 没有密钥：最后一段是发布名；查询串留在 connect 地址上、原样
        let d2 = try StreamDestination(settings: StreamSettings(url: "rtmp://u:p@h:1936/live/name?token=t&x=1"))
        XCTAssertEqual(d2.connectURL, "rtmp://u:p@h:1936/live?token=t&x=1")
        XCTAssertEqual(d2.connectURLWithoutCredentials, "rtmp://h:1936/live?token=t&x=1")
        XCTAssertEqual(d2.streamName, "name")
        XCTAssertEqual(d2.port, 1936)

        // RTMPS 同
        let d3 = try StreamDestination(settings: StreamSettings(url: "rtmps://u:p@a.b/live/abc"))
        XCTAssertEqual(d3.connectURL, "rtmps://u:p@a.b/live")
        XCTAssertEqual(d3.port, 443)
        XCTAssertEqual(d3.streamName, "abc")
        XCTAssertEqual(d3.credentials, StreamDestination.Credentials(user: "u", password: "p"))

        // MediaMTX 的单段路径
        let d4 = try StreamDestination(settings: StreamSettings(url: "rtmp://u:p@127.0.0.1:1936/s2"))
        XCTAssertEqual(d4.connectURL, "rtmp://u:p@127.0.0.1:1936/s2")
        XCTAssertEqual(d4.streamName, "")

        // 只写了用户名：照样保留，密码按空串
        let d5 = try StreamDestination(settings: StreamSettings(url: "rtmp://u@h/app"))
        XCTAssertEqual(d5.connectURL, "rtmp://u@h/app")
        XCTAssertEqual(d5.credentials, StreamDestination.Credentials(user: "u", password: ""))

        for x in [d, d2, d3, d4, d5] {
            XCTAssertFalse(x.description.contains("@"), "日志用的描述不带 userinfo：\(x.description)")
        }
        // 没写 userinfo 的地址照旧
        let plain = try StreamDestination(settings: StreamSettings(url: "rtmp://h/app/key"))
        XCTAssertNil(plain.credentials)
        XCTAssertEqual(plain.connectURL, "rtmp://h/app")
        XCTAssertEqual(plain.connectURLWithoutCredentials, "rtmp://h/app")
        // SRT 分支不动（passphrase / streamid 在查询串里，原样）
        let srt = try StreamDestination(settings: StreamSettings(url: "srt://h:1?streamid=x&passphrase=abcdefghij"))
        XCTAssertEqual(srt.connectURL, "srt://h:1?streamid=x&passphrase=abcdefghij")
        XCTAssertNil(srt.credentials)
    }

    /// 用户名 / 密码里的保留字符按 RFC 3986 只转义一次：已经转义过的不再转（不出 %2540），手敲没转义的 @ 空格 中文转一次，
    /// 字面的 % 转成 %25；userinfo 里本来就能原样写的子分隔符不动。解一次就是原文（credentials）。
    func testE_streamDestination_escapesReservedCharsOnce() throws {
        // "鉴权…"对话框写回的就是这种：已转义
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://me%40example.com:p%40ss%3Aw%2Frd%25@h/app/key"))
        XCTAssertEqual(d.connectURL, "rtmp://me%40example.com:p%40ss%3Aw%2Frd%25@h/app")
        XCTAssertEqual(d.credentials, StreamDestination.Credentials(user: "me@example.com", password: "p@ss:w/rd%"))
        XCTAssertEqual(URLComponents(string: d.connectURL)?.password, "p@ss:w/rd%", "解一次就是原密码（转两次会解出 p%40ss…）")
        XCTAssertFalse(d.connectURL.contains("%2540"), "不许双重转义：\(d.connectURL)")
        XCTAssertEqual(d.streamName, "key")

        // 手敲、没转义的 @ / 空格 / 中文：转义一次
        let raw = try StreamDestination(settings: StreamSettings(url: "rtmp://u:p@ss w密@h/app"))
        XCTAssertEqual(raw.connectURL, "rtmp://u:p%40ss%20w%E5%AF%86@h/app")
        XCTAssertEqual(raw.credentials?.password, "p@ss w密")

        // 密码字面上就是 "%41"（百分号 + 41）：写成 %2541，不能当成已转义的 A
        let literal = try StreamDestination(settings: StreamSettings(url: "rtmp://u:%2541@h/app"))
        XCTAssertEqual(literal.connectURL, "rtmp://u:%2541@h/app")
        XCTAssertEqual(literal.credentials?.password, "%41")

        // 子分隔符 ! $ & ' ( ) * + , ; = 在 userinfo 里本来就能原样写：不动
        let sub = try StreamDestination(settings: StreamSettings(url: "rtmp://u:a!$&'()*+,;=b@h/app"))
        XCTAssertEqual(sub.connectURL, "rtmp://u:a!$&'()*+,;=b@h/app")
        XCTAssertEqual(sub.credentials?.password, "a!$&'()*+,;=b")

        // 用户名里的冒号必须转（不然就成了用户名 / 密码分隔符）；密码里的冒号按 Foundation 的口径也转；解出来都是原文
        let colon = try StreamDestination(settings: StreamSettings(url: "rtmps://a%3Ab:c:d@h/app"))
        XCTAssertEqual(colon.credentials, StreamDestination.Credentials(user: "a:b", password: "c:d"))
        XCTAssertEqual(colon.connectURL, "rtmps://a%3Ab:c%3Ad@h/app")
        XCTAssertEqual(colon.connectURLWithoutCredentials, "rtmps://h/app")
    }

    /// 解析失败的错误里带的是打过码的地址（App 会把错误原文写进日志 / 提示）。
    func testE_streamDestination_errorsDoNotCarryUserinfo() {
        XCTAssertThrowsError(try StreamDestination(settings: StreamSettings(url: "rtmp://u:s3cret@h:bad/app"))) { error in
            XCTAssertFalse("\(error)".contains("s3cret"), "\(error)")
        }
        XCTAssertThrowsError(try StreamDestination(settings: StreamSettings(url: "ftp://u:s3cret@h/app"))) { error in
            XCTAssertFalse("\(error)".contains("s3cret"), "\(error)")
        }
    }
}
