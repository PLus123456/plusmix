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
}
