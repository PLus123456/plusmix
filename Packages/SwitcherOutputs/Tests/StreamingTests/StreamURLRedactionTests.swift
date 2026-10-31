import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherStreaming

/// 推流地址脱敏（StreamURLRedaction，日志 / 错误文字 / 诊断包 / 地址框共用）的两个口子：
/// - NS12（Codex 10-24 审计 [12]）：查询参数名按原文比名单，`pa%73s=` 这种编码写法不打码——Foundation / 服务器解出来就是 pass；
/// - NS09（审计 [9]，W5D 问题单）：密钥栏空着、发布名（密钥）写在 RTMP 地址最后一段时，路径原样保留。诊断包传 `publishNameInPath: true`。
/// 提案 035 第 ① 步（P5-8）之后类型本身在 SwitcherContracts，这里经 `public typealias` 调到同一份代码；`test035_` 用搬迁前的金样证明逐字相同。
final class StreamURLRedactionTests: XCTestCase {
    private let m = StreamURLRedaction.marker

    // MARK: NS12 编码过的参数名

    /// 参数名先百分号解码（解不开按原文）再不分大小写比名单：pass / pa%73s / %70ass / PASS / %50%41%53%53 都打码；
    /// 打码只换值，参数名照原文留着（地址框编辑完按原文名字换回原值）；不在名单里的参数整项原样（包括它的编码）。
    func testNS12_encodedSecretParamNamesAreRedacted() {
        for name in ["pass", "pa%73s", "%70ass", "PASS", "Pa%53s", "%50%41%53%53", "pass%77ord", "%74oken", "stream%69d"] {
            XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/live?\(name)=demo-secret&x=1"), "rtmp://h/live?\(name)=\(m)&x=1", name)
        }
        let r = StreamURLRedaction.redact(url: "rtmp://h:1935/live?user=alice&pa%73s=x")
        XCTAssertEqual(r, "rtmp://h:1935/live?user=\(m)&pa%73s=\(m)")
        XCTAssertFalse(r.contains("=x"), r)
        // Foundation 确实把 pa%73s 解成 pass（审计的复现）：脱敏的口径要跟它一样
        XCTAssertEqual(URLComponents(string: "rtmp://h/live?pa%73s=x")?.queryItems?.first?.name, "pass")
        // 不在名单里的：原样（编码不动）；解不开的名字按原文比，不崩
        XCTAssertEqual(StreamURLRedaction.redact(url: "srt://h:1?la%74ency=120&foo%20bar=%41&pa%zzs=1&x"), "srt://h:1?la%74ency=120&foo%20bar=%41&pa%zzs=1&x")
        // 文字里的地址同样
        let text = StreamURLRedaction.redact(text: "连接失败 rtmp://h/live?%70ass=s3cret 之后")
        XCTAssertEqual(text, "连接失败 rtmp://h/live?%70ass=\(m) 之后")
        // 地址框的记号同一个函数
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/live?pa%73s=x", marker: "•••"), "rtmp://h/live?pa%73s=•••")
    }

    // MARK: NS09 路径里的发布名

    /// `publishNameInPath: true`（诊断包在密钥栏空时传）：RTMP / RTMPS 地址路径 ≥ 2 段 → 最后一段（发布名）换成标记，
    /// 其余（主机、端口、app、查询串的非密钥项）照旧；userinfo、查询串的密钥照旧打码。默认 false：路径原样（日志 / 地址框）。
    func testNS09_publishNameInPathRedacted() {
        func r(_ url: String) -> String { StreamURLRedaction.redact(url: url, publishNameInPath: true) }
        XCTAssertEqual(r("rtmp://a.rtmp.example.com/live2/xxxx-yyyy-zzzz"), "rtmp://a.rtmp.example.com/live2/\(m)")
        XCTAssertEqual(r("rtmps://u:p@h:443/app/sub/KEY?x=1&token=t#f"), "rtmps://\(m)@h:443/app/sub/\(m)?x=1&token=\(m)#f")
        XCTAssertEqual(r("RTMP://h/live/KEY"), "RTMP://h/live/\(m)", "协议名不分大小写（StreamDestination 也是）")
        XCTAssertEqual(r("rtmp://h/live/KEY/"), "rtmp://h/live/\(m)/", "末尾的 / 不算一段")
        XCTAssertEqual(r("rtmp://h//live//KEY"), "rtmp://h//live//\(m)", "空段不算")
        XCTAssertEqual(r("  rtmp://h/live/KEY  "), "  rtmp://h/live/\(m)  ", "前后空白（StreamDestination 会去掉）")
        XCTAssertEqual(r("rtmp://h/live/KEY/ "), "rtmp://h/live/\(m)/ ", "末尾 / 加空白：末段是 KEY，不是那个空白")
        XCTAssertEqual(r("rtmp://h/live/KEY/\n"), "rtmp://h/live/\(m)/\n", "末尾 / 加换行")
        XCTAssertEqual(r("rtmp://h/live/KEY\t"), "rtmp://h/live/\(m)\t")
        XCTAssertEqual(r("rtmp://h/live \n"), "rtmp://h/live \n", "去掉空白后只有一段")
        XCTAssertEqual(r("rtmp://u:pa/ss@h/app/KEY"), "rtmp://\(m)@h/app/\(m)", "解析不了的 userinfo：先按最后一个 @ 打码，再拆路径")
        // 只有一段（MediaMTX 的 rtmp://host/path）：那一段是 app、没有发布名，原样
        XCTAssertEqual(r("rtmp://h/live"), "rtmp://h/live")
        XCTAssertEqual(r("rtmp://h/live/"), "rtmp://h/live/")
        XCTAssertEqual(r("rtmp://h"), "rtmp://h")
        XCTAssertEqual(r("rtmp://h?user=a"), "rtmp://h?user=\(m)")
        // StreamDestination 按解码后的路径拆（%2F 也是分隔）：换掉含最后一个解码段的整个原文段，只多盖、不漏
        XCTAssertEqual(r("rtmp://h/live/a%2Fb"), "rtmp://h/live/\(m)")
        XCTAssertEqual(r("rtmp://h/live/KEY/%2F"), "rtmp://h/live/\(m)/%2F", "末段解出来全是 /：发布名是前一段")
        XCTAssertEqual(r("rtmp://h/a%2Fb"), "rtmp://h/\(m)", "原文一段、解码后两段：StreamDestination 认 b 是发布名")
        // 不是 RTMP：原样（SRT 的密钥在 streamid / passphrase 查询参数里，名单照旧打码）
        XCTAssertEqual(r("srt://h:9000/x/y?streamid=publish:k&latency=1"), "srt://h:9000/x/y?streamid=\(m)&latency=1")
        XCTAssertEqual(r("not a url/x/y"), "not a url/x/y")
        // 默认（日志、错误文字、地址框）：路径照旧保留
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/live/KEY"), "rtmp://h/live/KEY")
        XCTAssertEqual(StreamURLRedaction.redact(text: "连接失败 rtmp://h/live/KEY"), "连接失败 rtmp://h/live/KEY")
    }

    /// 差分：各种写法（首尾空白 / 换行 / 制表符、末尾 /、空段、%2F 在段首段尾、无效转义、多字节转义、; 参数、..、片段、查询串、userinfo、端口、大写协议）
    /// 逐条交给 StreamDestination：它认出了发布名（密钥栏空）的，publishNameInPath 的结果里原文、解码后都不剩这个名字；它认不出的（一段 / 解析失败）不管。
    func testNS09_publishNameRedaction_differentialAgainstStreamDestination() throws {
        let heads = ["rtmp://h", "RTMPS://u:p@h:443", "rtmp://h:1935", "  rtmp://h", "\trtmp://u@h"]
        let paths = ["/live/Zq7NAME", "/live/Zq7NAME/", "/live//Zq7NAME", "/a/b/Zq7NAME", "/live/Zq7NA%4DE", "/live/x%2FZq7NAME", "/live/Zq7NAME/%2F",
                     "/live/Zq7NAME%2F", "/live/%2FZq7NAME", "/live/Zq7NAME;p=1", "/live/../Zq7NAME", "/live/Zq7NAME%20x", "/live/Zq7NAME%FF",
                     "/live/Zq7%E5%AF%86", "/Zq7a%2FZq7NAME", "/live/Zq7NAME/%2f/", "/live/Zq7NAME%zz"]
        let tails = ["", "?x=1", "#f", " ", "\n", "/ ", "\t", "/\n", "?pass=1 ", "/\r\n", "\u{3000}"]
        var checked = 0
        for h in heads {
            for p in paths {
                for t in tails {
                    let url = h + p + t
                    guard let d = try? StreamDestination(settings: StreamSettings(url: url)), !d.streamName.isEmpty else { continue }
                    checked += 1
                    let out = StreamURLRedaction.redact(url: url, publishNameInPath: true)
                    XCTAssertFalse(out.contains(d.streamName), "\(url.debugDescription) → \(out.debugDescription)（发布名 \(d.streamName.debugDescription)）")
                    XCTAssertFalse((out.removingPercentEncoding ?? out).contains(d.streamName), "解码后：\(url.debugDescription) → \(out.debugDescription)")
                    XCTAssertTrue(out.contains("h"), out)
                }
            }
        }
        print("NS09 差分：\(heads.count * paths.count * tails.count) 种写法里 StreamDestination 认出发布名的 \(checked) 种全部遮住")
        XCTAssertGreaterThan(checked, 400)
    }

    /// 拆法与 StreamDestination 一致：它认出的发布名（密钥栏空时）在 publishNameInPath 的结果里一个字都不剩，主机和 app 还在。
    func testNS09_publishNameMatchesStreamDestinationSplit() throws {
        let cases: [(url: String, app: String)] = [
            ("rtmp://ingest.example.com/live/Name-0a1b", "/live/"),
            ("rtmp://ingest.example.com:1936/app/inner/Name-2c3d", "/app/inner/"),
            ("rtmps://pub:pw@ingest.example.com/live/Name-4e5f?x=1", "/live/"),
            ("rtmp://ingest.example.com/live/Name-6a7b/", "/live/"),
            ("rtmp://ingest.example.com/live/Na%6De-8c9d", "/live/"),
            ("rtmp://ingest.example.com/live/pre%2FName-0e1f", "/live/"),
        ]
        for (url, app) in cases {
            let name = try StreamDestination(settings: StreamSettings(url: url)).streamName
            XCTAssertTrue(name.hasPrefix("Name-"), "\(url) → \(name)")
            let out = StreamURLRedaction.redact(url: url, publishNameInPath: true)
            XCTAssertFalse(out.contains(name), "\(url) → \(out)")
            XCTAssertFalse(out.removingPercentEncoding?.contains(name) ?? false, "解码后也不剩：\(out)")
            XCTAssertTrue(out.contains("ingest.example.com") && out.contains(app), "主机和 app 保留：\(out)")
        }
        // 只有一段：StreamDestination 的发布名是空的，脱敏也不动路径
        XCTAssertEqual(try StreamDestination(settings: StreamSettings(url: "rtmp://h/live")).streamName, "")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/live", publishNameInPath: true), "rtmp://h/live")
    }

    // MARK: 035 第 ① 步：类型搬进了 SwitcherContracts

    /// 提案 035 第 ① 步（P5-8 / prompt 136）：`StreamURLRedaction` 搬进 SwitcherContracts，这个包里只剩 `public typealias`——同一个类型、同一份代码，推流日志 / App 的调用点一行不改。
    /// 搬迁前（main c7d441a 的 SwitcherStreaming 版本）跑出的金样（Contracts 测试目录 Fixtures/redaction-035/，1041 个地址 + 10 段文字，含上面差分表全部 935 种）
    /// 经这个包的名字再跑一遍，逐字相同。
    func test035_movedToContracts_sameTypeAndPremoveOutputsIdentical() throws {
        XCTAssertTrue(SwitcherStreaming.StreamURLRedaction.self == SwitcherContracts.StreamURLRedaction.self, "typealias 指向契约里的那个类型")
        let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: packageDir.appendingPathComponent("Sources/Streaming/StreamURLRedaction.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("public typealias StreamURLRedaction = SwitcherContracts.StreamURLRedaction"), source)
        XCTAssertFalse(source.contains("enum StreamURLRedaction"), "实现只在 SwitcherContracts 一份")
        struct URLCase: Decodable { let group: String; let url: String; let publishNameInPath: Bool; let marker: String; let expected: String }
        struct TextCase: Decodable { let group: String; let text: String; let marker: String; let expected: String }
        struct Golden: Decodable { let urlCases: [URLCase]; let textCases: [TextCase] }
        let goldenURL = packageDir.deletingLastPathComponent().appendingPathComponent("SwitcherCore/Tests/SwitcherContractsTests/Fixtures/redaction-035/StreamURLRedaction-premove.json")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
        XCTAssertEqual(golden.urlCases.count, 1041)
        XCTAssertEqual(golden.textCases.count, 10)
        XCTAssertEqual(golden.urlCases.filter { $0.group == "differential" }.count, 935)
        var mismatches: [String] = []
        for c in golden.urlCases {
            let got = SwitcherStreaming.StreamURLRedaction.redact(url: c.url, marker: c.marker, publishNameInPath: c.publishNameInPath)
            if got != c.expected { mismatches.append("[\(c.group)] \(c.url.debugDescription) → \(got.debugDescription)，金样 \(c.expected.debugDescription)") }
        }
        for c in golden.textCases {
            let got = SwitcherStreaming.StreamURLRedaction.redact(text: c.text, marker: c.marker)
            if got != c.expected { mismatches.append("[\(c.group) text] \(c.text.debugDescription) → \(got.debugDescription)，金样 \(c.expected.debugDescription)") }
        }
        XCTAssertTrue(mismatches.isEmpty, "与搬迁前的输出不同 \(mismatches.count) 条：\n" + mismatches.prefix(20).joined(separator: "\n"))
    }
}
