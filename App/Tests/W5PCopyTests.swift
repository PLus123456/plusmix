// W5-P（prompt 119）App 口径：111 留下的（鉴权停下的推流写"失败"、推流页红字分两句、编码详情、状态行不算 failed）、
// 112 留下的（格子"转场"与 T-bar 遇没选输入的 Stinger 当前组）、W4C3 写手册查出来的 S3 一批（reports/issues/W4C3-w5-app-gaps-found-by-docs.md）。
import AppKit
import SwiftUI
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class W5PCopyTests: XCTestCase {
    // MARK: 111 留下的：鉴权停下的推流

    private func streamRoute(_ n: Int, state: String?, failure: OutputRouteFailure? = nil) -> OutputRouteStatus {
        OutputRouteStatus(output: OutputState(number: n, kind: .stream, name: "推流 \(n)", enabled: true), entry: state.map {
            Stats.EncoderEntry(output: n, skipped: 0, bitrate: 0, state: $0)
        }, failure: failure)
    }

    /// 底栏：推流对象停在 failed（服务器拒绝鉴权）的写"失败"（与状态窗、Stats 同一个字；用户 2026-10-17 定），仍是深红、点主体仍重试它；
    /// 运行表起不来的照旧写"起不来"。▴ 菜单那一项同样写"失败"、点 = 单路重试。
    func testW5P111_authStoppedStreamSaysFailedInBottomBar() {
        let stopped = OutputRouteFailure(reason: "推流 2 不再重连：鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized", stoppedStream: true)
        let route = streamRoute(2, state: "failed", failure: stopped)
        let state = OutputButtonSummary.routeState(route, kind: .stream)
        XCTAssertEqual(state.text, "失败")
        XCTAssertEqual(state.severity, .error)
        let summary = OutputButtonSummary.stream([route])
        XCTAssertEqual(summary.title, "推流 · 失败", "原来写「推流 · 起不来」，状态窗写「失败」，两处不一致")
        XCTAssertTrue(summary.toolTip?.contains("推流 2：失败 — 推流 2 不再重连：鉴权失败") == true, summary.toolTip ?? "")
        XCTAssertTrue(summary.toolTip?.contains("点一下：重试起不来 / 失败的路") == true, "点主体 = 重试它：\(summary.toolTip ?? "")")
        // 运行表起不来（字符串字面量 = 这一种）：照旧"起不来"、提示照旧
        let startFailed = OutputButtonSummary.stream([streamRoute(3, state: "failed", failure: "推流 3 没有地址")])
        XCTAssertEqual(startFailed.title, "推流 · 起不来")
        XCTAssertTrue(startFailed.toolTip?.contains("点一下：重试起不来的路") == true, startFailed.toolTip ?? "")
        // ▴ 菜单：同字、点 = 单路重试
        let mixer = MixerState(outputs: [OutputState(number: 2, kind: .stream, name: "主平台", enabled: true)])
        let rows = StreamMenuRow.rows(state: mixer, encoder: [Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "failed")]) { $0 == 2 ? stopped : nil }
        XCTAssertEqual(rows.map(\.title), ["主平台 · 失败"])
        XCTAssertEqual(rows.map(\.click), [.retry])
    }

    /// 推流页：状态行写"失败：原因"，红字按原因分两句——鉴权停下的改了设置不会自己重试，写"改对后点「重试」"；起不来的照旧"改好会自动重试"。
    /// 编码详情：重试间隔"一直重试，鉴权失败除外"。
    func testW5P111_streamingPageSplitsFailureHintByCause() {
        let state = MixerState(outputs: [
            OutputState(number: 2, kind: .stream, name: "主平台", enabled: true, settings: OutputSettings(source: .program, stream: StreamSettings(url: "rtmp://127.0.0.1/live"))),
            OutputState(number: 3, kind: .stream, name: "备用", enabled: true, settings: OutputSettings(source: .program, stream: StreamSettings(url: ""))),
            OutputState(number: 4, kind: .stream, name: "关着", enabled: false, settings: OutputSettings(source: .program, stream: StreamSettings(url: ""))),
        ])
        let model = OutputSettingsModel(state: state, tab: .stream, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        model.routeFailure = { n in
            switch n {
            case 2: OutputRouteFailure(reason: "推流 2 不再重连：鉴权失败（用户名或密码不对）", stoppedStream: true)
            case 3: "推流 3 没有地址"
            case 4: "推流 4 没有地址"
            default: nil
            }
        }
        model.refreshRouteDetails()
        XCTAssertEqual(model.streamStatus(output: 2), "失败：推流 2 不再重连：鉴权失败（用户名或密码不对）")
        XCTAssertEqual(model.streamStatus(output: 3), "起不来：推流 3 没有地址")
        XCTAssertEqual(model.streamFailureHint(2), "这一路已停止、不再自己重连（服务器拒绝了鉴权）：改对地址 / 账号后点「重试」，光改设置不会自己重试；也可以先停用这一路。")
        XCTAssertEqual(model.streamFailureHint(3), "改好地址 / 密钥（回车或离开输入框）会自动重试；也可以先停用这一路。")
        XCTAssertNil(model.streamFailureHint(4), "关着的路不写红字")
        XCTAssertFalse(model.isStreamLocked(2), "停住的路照旧不锁：要能改对")
        XCTAssertEqual(L("outputSettings.stream.reconnect", 30.0), "重试间隔最长 30 s（一直重试，鉴权失败除外）")
        XCTAssertEqual(L10n.string("outputSettings.stream.statusStopped", language: "en", "x"), "Failed: x")
        XCTAssertTrue(L10n.string("outputSettings.stream.failedHintStopped", language: "en").contains("click “Retry”"))
        XCTAssertEqual(L10n.string("outputSettings.stream.reconnect", language: "en", 30.0), "Max retry interval 30 s (keeps retrying, except after an authentication failure)")
    }

    /// 状态行（W4C3 第 11 条）：failed 的推流不算在跑——原来取码率最低的那一路，起不来 / 鉴权停下的码率 0，写"推流 0 b/s"；状态窗写 —，两处不一致。
    func testW5P111_statusLineIgnoresFailedStreams() {
        func stats(_ entries: [Stats.EncoderEntry]) -> Stats {
            Stats(ts: 10, tick: Tick(600), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: entries,
                  audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 1)
        }
        let kinds: [Int: OutputKind] = [1: .record, 2: .stream, 3: .stream]
        let onlyFailed = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "failed")]),
                                                    previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(onlyFailed.first { $0.label == L("status.streamBitrate") }?.value, "—", "只有失败的那一路：推流码率写 —")
        let mixed = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "failed"),
                                                               Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 4_500_000, state: "publishing")]),
                                               previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(mixed.first { $0.label == L("status.streamBitrate") }?.value, "4.50 Mb/s", "失败的那一路不拖低在推的")
        let backoff = StatusLineFormatter.fields(current: stats([Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 0, state: "backoff")]),
                                                 previous: nil, format: .hd1080p60, kinds: kinds)
        XCTAssertEqual(backoff.first { $0.label == L("status.streamBitrate") }?.value, "0 b/s", "退避中的照旧算在跑（X28）")
    }
}
