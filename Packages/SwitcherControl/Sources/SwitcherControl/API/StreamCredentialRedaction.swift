import Foundation
import SwitcherContracts

// API 对外的推流凭据打码（提案 035 第 ② 步，用户 2026-10-25 批方案 A1；Codex 10-24 网络审计 NS03 / KNOWN_ISSUES"推流凭据外泄"②）。
//
// 打哪三处：GET /api/v1/state 的 state、WS snapshot 的 state、GET /api/v1/log 里的 setOutputSettings / addOutput / loadShow。
// 怎么打：每个 StreamSettings 的 streamKey 非空 → `StreamURLRedaction.marker`（空串照旧空串，客户端靠它知道"没填密钥"）；
// url → `StreamURLRedaction.redact(url:publishNameInPath:)`，密钥栏空（只有空白也算——StreamDestination 先去空白再判，诊断包 ShowRedaction 同口径）
// 时 RTMP 路径末段的发布名也换。别的字段、键名、层级一个不动：改的是值的拷贝，再走同一个 Codable 编码，形状天然一致。
// 打码函数只有契约里那一份（日志、诊断包、地址框、API 同一份名单）。状态机 / 总线日志 / 节目文件 / 界面里永远是原文，只改 API 写出去的样子。
//
// 往返：从 API 进来的 setOutputSettings 里 streamKey == 标记 = 保留这一路现在的密钥、url == "现在的 url 打码后的样子" = 保留现在的 url，
// 在 API 层换回原值再进总线；换不回去的标记（没有这一路 / 这一路没推流设置 / 地址带标记但对不上现在的值）和 addOutput / loadShow 里的标记 → 400，
// 免得把标记当密钥存下去。标记密钥只在地址最后仍是原来那个时才换回（比提案字面严一档）：否则不用 ?secrets=1 就能把原密钥"推"到别的服务器上。

/// API 写出去的推流凭据打码与写回时的换回。
enum APIStreamCredentials {
    /// 带标记、又换不回原值的命令被拒的理由（HTTP 400 / WS error）。
    static let markerRejection = "推流设置里有打码标记：原文用 ?secrets=1 读"

    // MARK: 打码

    /// 一组推流设置：streamKey 非空 → 标记；url 打码（密钥栏空时连发布名）。
    static func redacted(_ s: StreamSettings) -> StreamSettings {
        var r = s
        r.streamKey = s.streamKey.isEmpty ? "" : StreamURLRedaction.marker
        r.url = redactedURL(of: s)
        return r
    }

    /// 这组设置的 url 对外的样子；往返时拿它和客户端写回的 url 比。
    static func redactedURL(of s: StreamSettings) -> String {
        StreamURLRedaction.redact(url: s.url, publishNameInPath: s.streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func redacted(_ settings: OutputSettings) -> OutputSettings {
        guard let stream = settings.stream else { return settings }
        var r = settings
        r.stream = redacted(stream)
        return r
    }

    static func redacted(_ output: OutputState) -> OutputState {
        guard output.settings.stream != nil else { return output }
        var r = output
        r.settings = redacted(output.settings)
        return r
    }

    /// 有没有要打码的（没有推流设置的状态原样用，StateFeed 也就不用另编一份原文）。
    static func hasStreamSettings(_ outputs: [OutputState]) -> Bool {
        outputs.contains { $0.settings.stream != nil }
    }

    static func redacted(_ state: MixerState) -> MixerState {
        guard hasStreamSettings(state.outputs) else { return state }
        var r = state
        r.outputs = state.outputs.map(redacted)
        return r
    }

    /// 命令日志里的一条命令。新加的命令要在这里表态（switch 不写 default）：带 StreamSettings 的照前三条打码。
    static func redacted(_ command: Command) -> Command {
        switch command {
        case .setOutputSettings(let output, let settings):
            return .setOutputSettings(output: output, settings: redacted(settings))
        case .addOutput(let config):
            return .addOutput(config: redacted(config))
        case .loadShow(var show):
            show.outputs = show.outputs.map(redacted)
            return .loadShow(show: show)
        case .cut, .fade, .setTransition, .setTransitionParams, .autoTransition, .setPreview, .setProgram, .tbar, .ftb,
             .setTransitionSlot, .useTransitionSlot, .setFTBDuration,
             .overlay, .setOverlay, .setOverlayDecoration,
             .audioGain, .mute, .busGain, .busMute, .setAFV, .setMonitorMode, .setMonitorSource, .setBusEffects, .setInputAudio,
             .startRecord, .stopRecord, .startStream, .stopStream, .setOutputEnabled, .renameOutput,
             .setInputSettings, .renameInput, .addInput, .removeInput, .setInputSource, .setPlayback, .seekPlayback, .setInputColor,
             .removeOutput:
            return command
        }
    }

    static func redacted(_ entry: CommandLogEntry) -> CommandLogEntry {
        var r = entry
        r.command = redacted(entry.command)
        return r
    }

    // MARK: 往返（API 收到的命令）

    /// 把从 API 进来的命令里的打码标记换回原值；换不回去的抛 `CommandRejection`（理由 = `markerRejection`）。
    /// - Parameter current: 执行到这一条时的状态（批量里前一条已生效的也算）。
    static func restoringMarkers(in command: Command, current: MixerState?) throws -> Command {
        let marker = StreamURLRedaction.marker
        switch command {
        case .setOutputSettings(let output, var settings):
            guard var stream = settings.stream else { return command }
            let now = current?.outputs.first { $0.number == output }?.settings.stream
            // 换回来的原值不再查（界面里真存了带标记的字符串也照原样留着）；客户端自己给的值带标记就拒
            var keyRestored = false
            if stream.streamKey == marker, let now {
                stream.streamKey = now.streamKey
                keyRestored = true
            } else if stream.streamKey.contains(marker) {
                throw CommandRejection(reason: markerRejection, command: command)
            }
            if let now, stream.url == redactedURL(of: now) {
                stream.url = now.url
            } else if stream.url.contains(marker) {
                throw CommandRejection(reason: markerRejection, command: command)
            }
            // 换回来的密钥只跟着原来的目的地走（W2-C6 安全复查）：标记密钥 + 别的地址 = 下次开推把原密钥推到新地址，
            // 等于读不到原文的客户端（没配 token 时任何连得上的进程）绕过 ?secrets=1 把密钥拿走。换地址就得连密钥原文一起给。
            if keyRestored, let now, stream.url != now.url {
                throw CommandRejection(reason: markerRejection, command: command)
            }
            settings.stream = stream
            return .setOutputSettings(output: output, settings: settings)
        case .addOutput(let config):
            if let s = config.settings.stream, containsMarker(s) { throw CommandRejection(reason: markerRejection, command: command) }
            return command
        case .loadShow(let show):
            if show.outputs.contains(where: { $0.settings.stream.map(containsMarker) ?? false }) {
                throw CommandRejection(reason: markerRejection, command: command)
            }
            return command
        default:
            return command
        }
    }

    private static func containsMarker(_ s: StreamSettings) -> Bool {
        s.streamKey.contains(StreamURLRedaction.marker) || s.url.contains(StreamURLRedaction.marker)
    }
}
