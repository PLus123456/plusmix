import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 035（API 对外状态里推流凭据打码；用户 2026-10-25 批方案 A1）第 ① 步（P5-8 / prompt 136）：`StreamURLRedaction` 从 SwitcherStreaming **原样**搬进 SwitcherContracts
/// （只用 Foundation；`marker` / `secretQueryParams` / `redact(url:marker:publishNameInPath:)` / `redact(text:marker:)` 的名字、签名、默认值一个不改），SwitcherStreaming 只留 `public typealias`。
/// 这里把搬迁前 StreamingTests 的 `StreamURLRedactionTests`（NS12 编码参数名、NS09 路径末段）、`StreamAuthTests.testE`（userinfo / SRT / 不是地址）、App `ReleaseTests` R8（诊断包）的全部输入
/// 按**搬迁前的输出**写成期望；NS09 的 935 种写法差分原来逐条交给 `StreamDestination`（SwitcherStreaming 在契约之上，这里见不到），改成金样：
/// `Fixtures/redaction-035/StreamURLRedaction-premove.json` 是 main c7d441a 上 SwitcherStreaming 版本的文件（git blob 9960823…）跑出来的输入 → 输出（1041 个地址 + 10 段文字），搬完后逐条核对、一字不差。
/// 第 ② 步（API 状态 / WS 快照 / 命令日志打码、`?secrets=1`）归 137 W2-C6，这里不测。
/// 口径变了要改金样：`SW_REDACTION_GOLDEN_WRITE=1 swift test --package-path Packages/SwitcherCore --filter SwitcherContractsTests.Contracts035Tests/test035_goldenPremove`
/// 会把金样里每条输入的期望按当前实现重算（输入不动），然后看 diff 是不是你要的。
final class Contracts035Tests: XCTestCase {
    private let m = StreamURLRedaction.marker

    private static var packageDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/redaction-035/StreamURLRedaction-premove.json")
    }

    // 差分那张表（与搬迁前 StreamURLRedactionTests.testNS09_publishNameRedaction_differentialAgainstStreamDestination 逐字相同）：5 × 17 × 11 = 935 种写法
    static let heads = ["rtmp://h", "RTMPS://u:p@h:443", "rtmp://h:1935", "  rtmp://h", "\trtmp://u@h"]
    static let paths = ["/live/Zq7NAME", "/live/Zq7NAME/", "/live//Zq7NAME", "/a/b/Zq7NAME", "/live/Zq7NA%4DE", "/live/x%2FZq7NAME", "/live/Zq7NAME/%2F",
                        "/live/Zq7NAME%2F", "/live/%2FZq7NAME", "/live/Zq7NAME;p=1", "/live/../Zq7NAME", "/live/Zq7NAME%20x", "/live/Zq7NAME%FF",
                        "/live/Zq7%E5%AF%86", "/Zq7a%2FZq7NAME", "/live/Zq7NAME/%2f/", "/live/Zq7NAME%zz"]
    static let tails = ["", "?x=1", "#f", " ", "\n", "/ ", "\t", "/\n", "?pass=1 ", "/\r\n", "\u{3000}"]

    // MARK: 公开接口一个不改

    /// 名字、签名、默认值与搬迁前相同：`marker` = "<redacted>"、名单 11 个名字、`redact(url:)` 的 marker 默认 = marker / publishNameInPath 默认 false、`redact(text:)` 同。
    /// 文件只 import Foundation（check-deps.sh 管包级依赖，这里钉文件级：契约不许带别的包）。
    func test035_publicSurfaceUnchanged() throws {
        XCTAssertEqual(StreamURLRedaction.marker, "<redacted>")
        XCTAssertEqual(StreamURLRedaction.secretQueryParams, ["passphrase", "key", "token", "password", "secret", "streamid", "auth", "user", "pass", "pwd", "response"])
        // 默认值
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@h/live/KEY"), "rtmp://\(m)@h/live/KEY", "marker 默认 <redacted>、publishNameInPath 默认 false")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@h/live/KEY", marker: "•••"), "rtmp://•••@h/live/KEY")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@h/live/KEY", publishNameInPath: true), "rtmp://\(m)@h/live/\(m)")
        XCTAssertEqual(StreamURLRedaction.redact(text: "x rtmp://u:p@h/live/KEY"), "x rtmp://\(m)@h/live/KEY")
        XCTAssertEqual(StreamURLRedaction.redact(text: "x rtmp://u:p@h/live/KEY", marker: "•••"), "x rtmp://•••@h/live/KEY")
        // 完整签名（标签、顺序、类型）：函数引用能赋给这个类型才编得过
        let redactURL: (String, String, Bool) -> String = StreamURLRedaction.redact(url:marker:publishNameInPath:)
        let redactText: (String, String) -> String = StreamURLRedaction.redact(text:marker:)
        XCTAssertEqual(redactURL("rtmp://u:p@h/a/K", "#", true), "rtmp://#@h/a/#")
        XCTAssertEqual(redactText("x rtmp://u:p@h", "#"), "x rtmp://#@h")
        // 契约里的这个文件只用 Foundation
        let source = try String(contentsOf: Self.packageDir.appendingPathComponent("Sources/SwitcherContracts/StreamURLRedaction.swift"), encoding: .utf8)
        XCTAssertEqual(source.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init), ["import Foundation"])
    }

    // MARK: NS12 编码过的参数名（搬迁前 StreamURLRedactionTests.testNS12 的全部输入）

    /// 参数名先百分号解码（解不开按原文）再不分大小写比名单：pass / pa%73s / %70ass / PASS / %50%41%53%53 都打码；打码只换值，参数名照原文留着；不在名单里的整项原样（包括它的编码）。
    func test035_NS12_encodedSecretParamNamesAreRedacted() {
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
        XCTAssertEqual(StreamURLRedaction.redact(text: "连接失败 rtmp://h/live?%70ass=s3cret 之后"), "连接失败 rtmp://h/live?%70ass=\(m) 之后")
        // 地址框的记号同一个函数
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/live?pa%73s=x", marker: "•••"), "rtmp://h/live?pa%73s=•••")
        // 名单里的 11 个名字原样 / 大写都打码，别的参数留着
        for name in StreamURLRedaction.secretQueryParams {
            XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/app?\(name)=v&keep=1"), "rtmp://h/app?\(name)=\(m)&keep=1")
            XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/app?\(name.uppercased())=v&keep=1"), "rtmp://h/app?\(name.uppercased())=\(m)&keep=1")
        }
    }

    // MARK: NS09 路径里的发布名（搬迁前 testNS09_publishNameInPathRedacted / testNS09_publishNameMatchesStreamDestinationSplit 的全部输入）

    /// `publishNameInPath: true`（诊断包在密钥栏空时传）：RTMP / RTMPS 地址路径 ≥ 2 段 → 最后一段换成标记，其余照旧；userinfo、查询串的密钥照旧打码。默认 false：路径原样。
    /// 拆法与 StreamDestination 一致（先 trim 首尾空白、按解码后的路径以 / 拆、空段不算、%2F 也是分隔、换掉含最后一个解码段的整个原文段）。
    func test035_NS09_publishNameInPathRedacted() {
        func r(_ url: String) -> String { StreamURLRedaction.redact(url: url, publishNameInPath: true) }
        XCTAssertEqual(r("rtmp://a.rtmp.example.com/live2/xxxx-yyyy-zzzz"), "rtmp://a.rtmp.example.com/live2/\(m)")
        XCTAssertEqual(r("rtmps://u:p@h:443/app/sub/KEY?x=1&token=t#f"), "rtmps://\(m)@h:443/app/sub/\(m)?x=1&token=\(m)#f")
        XCTAssertEqual(r("RTMP://h/live/KEY"), "RTMP://h/live/\(m)", "协议名不分大小写")
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
        XCTAssertEqual(r("rtmpt://h/app/KEY"), "rtmpt://h/app/KEY", "只认 rtmp / rtmps")
        // 默认（日志、错误文字、地址框）：路径照旧保留
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/live/KEY"), "rtmp://h/live/KEY")
        XCTAssertEqual(StreamURLRedaction.redact(text: "连接失败 rtmp://h/live/KEY"), "连接失败 rtmp://h/live/KEY")
        // 拆法用例（搬迁前对照 StreamDestination.streamName 的那六条）：主机和 app 保留、发布名一个字不剩
        XCTAssertEqual(r("rtmp://ingest.example.com/live/Name-0a1b"), "rtmp://ingest.example.com/live/\(m)")
        XCTAssertEqual(r("rtmp://ingest.example.com:1936/app/inner/Name-2c3d"), "rtmp://ingest.example.com:1936/app/inner/\(m)")
        XCTAssertEqual(r("rtmps://pub:pw@ingest.example.com/live/Name-4e5f?x=1"), "rtmps://\(m)@ingest.example.com/live/\(m)?x=1")
        XCTAssertEqual(r("rtmp://ingest.example.com/live/Name-6a7b/"), "rtmp://ingest.example.com/live/\(m)/")
        XCTAssertEqual(r("rtmp://ingest.example.com/live/Na%6De-8c9d"), "rtmp://ingest.example.com/live/\(m)")
        XCTAssertEqual(r("rtmp://ingest.example.com/live/pre%2FName-0e1f"), "rtmp://ingest.example.com/live/\(m)")
        // 诊断包（App ReleaseTests R7）密钥栏空时的整条地址
        XCTAssertEqual(r("rtmp://127.0.0.1:1935/live/KEY-1234"), "rtmp://127.0.0.1:1935/live/\(m)")
    }

    /// 差分表里挑的代表（期望 = 搬迁前跑出的原文；全部 935 种在金样里）：大写协议 + userinfo + 端口、制表符开头 + 查询串密钥 + 尾空白、%2f 段 + 全角空格、
    /// .. 段 + CRLF、原文一段解码两段 + 片段、无效转义 + 换行、多字节转义、; 参数、%2F 在段首、%2F 在段尾、末段全是 %2F + 片段。
    func test035_NS09_differentialRepresentatives() {
        func r(_ url: String) -> String { StreamURLRedaction.redact(url: url, publishNameInPath: true) }
        XCTAssertEqual(r("rtmp://h/live/Zq7NAME"), "rtmp://h/live/\(m)")
        XCTAssertEqual(r("RTMPS://u:p@h:443/live/Zq7NAME/ "), "RTMPS://\(m)@h:443/live/\(m)/ ")
        XCTAssertEqual(r("\trtmp://u@h/live/x%2FZq7NAME?pass=1 "), "\trtmp://\(m)@h/live/\(m)?pass=\(m)", "查询串的尾空白跟着值一起换掉（原来就这样）")
        XCTAssertEqual(r("  rtmp://h/live/Zq7NAME/%2f/\u{3000}"), "  rtmp://h/live/\(m)/%2f/\u{3000}")
        XCTAssertEqual(r("rtmp://h:1935/live/../Zq7NAME/\r\n"), "rtmp://h:1935/live/../\(m)/\r\n")
        XCTAssertEqual(r("rtmp://h/Zq7a%2FZq7NAME#f"), "rtmp://h/\(m)#f")
        XCTAssertEqual(r("rtmp://h/live/Zq7NAME%zz\n"), "rtmp://h/live/\(m)\n")
        XCTAssertEqual(r("RTMPS://u:p@h:443/live/Zq7%E5%AF%86?x=1"), "RTMPS://\(m)@h:443/live/\(m)?x=1")
        XCTAssertEqual(r("rtmp://h/live/Zq7NAME;p=1\t"), "rtmp://h/live/\(m)\t")
        XCTAssertEqual(r("rtmp://h/live/%2FZq7NAME/ "), "rtmp://h/live/\(m)/ ")
        XCTAssertEqual(r("rtmp://h/live/Zq7NAME%2F"), "rtmp://h/live/\(m)")
        XCTAssertEqual(r("rtmp://h/live/Zq7NAME/%2F#f"), "rtmp://h/live/\(m)/%2F#f")
    }

    // MARK: userinfo / SRT / 不是地址（搬迁前 StreamAuthTests.testE 与 App ReleaseTests R8 的全部输入）

    /// 地址：userinfo 整段换成标记（没转义的 @ 按最后一个分；密码里有 / 的解析不了也保守打码）、查询串里的密钥参数换成标记，主机、端口、路径保留；不是 `scheme://…` 的原样返回。
    func test035_userinfoSRTAndNonURL() {
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@h:1935/app"), "rtmp://\(m)@h:1935/app")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmps://me%40x.com:p%40ss@h/app?token=t&x=1"), "rtmps://\(m)@h/app?token=\(m)&x=1")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:p@ss@h/app"), "rtmp://\(m)@h/app", "没转义的 @：按最后一个 @ 分")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u:pa/ss@h/app"), "rtmp://\(m)@h/app", "解析不了的地址（密码里有 /）：保守地按最后一个 @ 打码")
        XCTAssertEqual(StreamURLRedaction.redact(url: "srt://h:9000?passphrase=abc&latency=120"), "srt://h:9000?passphrase=\(m)&latency=120")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://a.example/live"), "rtmp://a.example/live")
        XCTAssertEqual(StreamURLRedaction.redact(url: "not a url"), "not a url")
        // 诊断包 R8
        XCTAssertEqual(StreamURLRedaction.redact(url: "srt://host:9000?passphrase=abc&latency=120"), "srt://host:9000?passphrase=\(m)&latency=120")
        XCTAssertEqual(StreamURLRedaction.redact(url: "srt://h:1?streamid=publish:path:user:pw"), "srt://h:1?streamid=\(m)")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmps://h/app?token=t&KEY=k"), "rtmps://h/app?token=\(m)&KEY=\(m)")
        // 边角（期望 = 搬迁前的输出）：空串 / 只有协议 / 空 userinfo 也换、只有用户名也换、没 = 的参数不动、空值也换、只按第一个 = 拆、空项保留、片段原样
        XCTAssertEqual(StreamURLRedaction.redact(url: ""), "")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://"), "rtmp://")
        XCTAssertEqual(StreamURLRedaction.redact(url: "://"), "://")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://@h/app"), "rtmp://\(m)@h/app")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://u@h/app"), "rtmp://\(m)@h/app")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/p?pass"), "rtmp://h/p?pass")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/p?pass=&x="), "rtmp://h/p?pass=\(m)&x=")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/p?pass=a=b"), "rtmp://h/p?pass=\(m)")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/p?a=1&&pass=2"), "rtmp://h/p?a=1&&pass=\(m)")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/p?pass=1#frag?pass=2"), "rtmp://h/p?pass=\(m)#frag?pass=2")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/app?Pass=1&pAsS=2&pass%3D=3"), "rtmp://h/app?Pass=\(m)&pAsS=\(m)&pass%3D=3")
        XCTAssertEqual(StreamURLRedaction.redact(url: "x+y-z.1://u:p@h/a"), "x+y-z.1://\(m)@h/a")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://[::1]:1935/app/KEY", publishNameInPath: true), "rtmp://[::1]:1935/app/\(m)")
        XCTAssertEqual(StreamURLRedaction.redact(url: "rtmp://h/直播/密钥", publishNameInPath: true), "rtmp://h/直播/\(m)")
    }

    // MARK: 文字里的地址

    /// 一段文字里每个 `scheme://` 地址都按 `redact(url:)` 处理：地址到空白或 " < > \ ^ ` { | } 为止（Swift 打印字符串关联值时引号前的反斜杠也在其中）；协议名往前只收 ASCII 字母数字 + - .。
    func test035_textRedaction_everyAddressInText() {
        let text = #"connectFailed("unsupportedCommand(\"rtmp://pub:s3cret@h/app?authmod=adobe&user=pub\")") 和 srt://h:1?passphrase=zzz"#
        let r = StreamURLRedaction.redact(text: text)
        XCTAssertEqual(r, #"connectFailed("unsupportedCommand(\"rtmp://\#(m)@h/app?authmod=adobe&user=\#(m)\")") 和 srt://h:1?passphrase=\#(m)"#)
        XCTAssertFalse(r.contains("s3cret") || r.contains("zzz"), r)
        XCTAssertEqual(StreamURLRedaction.redact(text: "NetConnection.Connect.Rejected see rtmp://u:p@h/app"), "NetConnection.Connect.Rejected see rtmp://\(m)@h/app")
        XCTAssertEqual(StreamURLRedaction.redact(text: "a rtmp://u:p@h/x\"b rtmp://u:p@h/y<c rtmp://u:p@h/z>d {rtmp://u:p@h/w} |rtmp://u:p@h/v| `rtmp://u:p@h/u` ^rtmp://u:p@h/t^ \\rtmp://u:p@h/s\\ 中://u:p@h/r x+y-z.1://u:p@h/q 9rtmp://u:p@h/p"),
                       "a rtmp://\(m)@h/x\"b rtmp://\(m)@h/y<c rtmp://\(m)@h/z>d {rtmp://\(m)@h/w} |rtmp://\(m)@h/v| `rtmp://\(m)@h/u` ^rtmp://\(m)@h/t^ \\rtmp://\(m)@h/s\\ 中://\(m)@h/r x+y-z.1://\(m)@h/q 9rtmp://\(m)@h/p")
        XCTAssertEqual(StreamURLRedaction.redact(text: "rtmp://u:p@h/a\nrtmp://u:q@h/b\tsrt://h?passphrase=z"), "rtmp://\(m)@h/a\nrtmp://\(m)@h/b\tsrt://h?passphrase=\(m)")
        XCTAssertEqual(StreamURLRedaction.redact(text: "rtmp://u:p@h/a 和 rtmp://h/live/KEY?token=t", marker: "•••"), "rtmp://•••@h/a 和 rtmp://h/live/KEY?token=•••")
        XCTAssertEqual(StreamURLRedaction.redact(text: "no url here"), "no url here")
        XCTAssertEqual(StreamURLRedaction.redact(text: ""), "")
        XCTAssertEqual(StreamURLRedaction.redact(text: "://u:p@h"), "://\(m)@h", "没有协议名的 :// 也按地址处理（原来就这样）")
    }

    // MARK: 金样：搬迁前的 1041 + 10 条输入 → 输出逐字相同

    struct URLCase: Codable { let group: String; let url: String; let publishNameInPath: Bool; let marker: String; let expected: String }
    struct TextCase: Codable { let group: String; let text: String; let marker: String; let expected: String }
    struct Golden: Decodable { let note: String; let sourceCommit: String?; let sourceBlob: String?; let heads: [String]; let paths: [String]; let tails: [String]; let urlCases: [URLCase]; let textCases: [TextCase] }

    /// 金样 = main c7d441a 上 SwitcherStreaming 版本的 StreamURLRedaction.swift 跑出的输入 → 输出：NS12 / NS09 / 拆法 / userinfo / 诊断包 / 名单 / 边角 + 差分表全部 935 种（5 × 17 × 11，顺序同表）。
    /// 搬进 SwitcherContracts 之后每条都要一字不差——这就是"搬迁前后打码结果逐字相同"的证据（StreamingTests 那边经 typealias 再跑一遍同一份金样）。
    func test035_goldenPremove_everyInputRedactsIdentically() throws {
        if ProcessInfo.processInfo.environment["SW_REDACTION_GOLDEN_WRITE"] == "1" {
            try Self.rewriteGolden(try Self.loadGolden())
            print("Contracts035Tests：金样已按当前实现重写（输入不变）：\(Self.goldenURL.path)")
        }
        let golden = try Self.loadGolden()
        XCTAssertEqual(golden.urlCases.count, 1041)
        XCTAssertEqual(golden.textCases.count, 10)
        // 差分输入就是上面那张表、同一顺序，全部 publishNameInPath、默认标记
        XCTAssertEqual(golden.heads, Self.heads)
        XCTAssertEqual(golden.paths, Self.paths)
        XCTAssertEqual(golden.tails, Self.tails)
        var combos: [String] = []
        for h in Self.heads { for p in Self.paths { for t in Self.tails { combos.append(h + p + t) } } }
        let differential = golden.urlCases.filter { $0.group == "differential" }
        XCTAssertEqual(differential.count, 935)
        XCTAssertEqual(differential.map(\.url), combos)
        XCTAssertTrue(differential.allSatisfy { $0.publishNameInPath && $0.marker == m })
        XCTAssertEqual(Set(golden.urlCases.map(\.group)), ["ns12", "ns09", "ns09-default", "split", "differential", "userinfo", "app-r8", "params", "edge", "edge-pnp"])
        // 逐条核对
        var mismatches: [String] = []
        for c in golden.urlCases {
            let got = StreamURLRedaction.redact(url: c.url, marker: c.marker, publishNameInPath: c.publishNameInPath)
            if got != c.expected { mismatches.append("[\(c.group)] \(c.url.debugDescription) → \(got.debugDescription)，金样 \(c.expected.debugDescription)") }
        }
        for c in golden.textCases {
            let got = StreamURLRedaction.redact(text: c.text, marker: c.marker)
            if got != c.expected { mismatches.append("[\(c.group) text] \(c.text.debugDescription) → \(got.debugDescription)，金样 \(c.expected.debugDescription)") }
        }
        XCTAssertTrue(mismatches.isEmpty, "与搬迁前的输出不同 \(mismatches.count) 条：\n" + mismatches.prefix(20).joined(separator: "\n"))
        print("035 金样：\(golden.urlCases.count) 个地址 + \(golden.textCases.count) 段文字与搬迁前逐字相同（差分 \(differential.count) 种）")
    }

    private static func loadGolden() throws -> Golden { try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL)) }

    /// 只在 SW_REDACTION_GOLDEN_WRITE=1 时调：输入、分组、顺序、格式（一条一行）不变，期望按当前实现重算。
    private static func rewriteGolden(_ g: Golden) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func line<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }
        let urls = try g.urlCases.map { c in
            try line(URLCase(group: c.group, url: c.url, publishNameInPath: c.publishNameInPath, marker: c.marker,
                             expected: StreamURLRedaction.redact(url: c.url, marker: c.marker, publishNameInPath: c.publishNameInPath)))
        }
        let texts = try g.textCases.map { c in try line(TextCase(group: c.group, text: c.text, marker: c.marker, expected: StreamURLRedaction.redact(text: c.text, marker: c.marker))) }
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var out = "{\n"
        out += "\"note\": " + (try line("由 Contracts035Tests 在 \(day) 重生成（SW_REDACTION_GOLDEN_WRITE=1）：输入不变，期望按当时 SwitcherContracts 的实现重算；搬迁前（main c7d441a）的原始金样见 git 历史。")) + ",\n"
        out += "\"heads\": " + (try line(g.heads)) + ",\n\"paths\": " + (try line(g.paths)) + ",\n\"tails\": " + (try line(g.tails)) + ",\n"
        out += "\"urlCases\": [\n" + urls.joined(separator: ",\n") + "\n],\n"
        out += "\"textCases\": [\n" + texts.joined(separator: ",\n") + "\n]\n}\n"
        try out.write(to: goldenURL, atomically: true, encoding: .utf8)
    }
}
