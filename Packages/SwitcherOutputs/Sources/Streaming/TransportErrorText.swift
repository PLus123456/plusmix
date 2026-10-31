import Foundation
import Network
import os
import RTMPHaishinKit
import SRTHaishinKit

/// last_error / 状态窗"最后错误"那一句里的原因（W4-C4 问题单，S3）：底层库（HaishinKit / Network.framework / libsrt）的错误给一句中文概括，
/// 原文（打过码）只进日志。原来 `"\(error)"` 把程序写法原样写进去——W2-D5 探针在 macOS 27 / HaishinKit 2.2.5 上拿到的：
/// 端口没人听 `socketErrorOccurred(Optional(POSIXErrorCode(rawValue: 61): Connection refused))`、域名解析不了 `socketErrorOccurred(Optional(-65554: NoSuchRecord))`、
/// SRT 没人听 `failedToConnect(SRTHaishinKit.SRTRejectReason.timeout)`。我们自己的错误（StreamTransportError、Adobe 鉴权）本来就是中文，原样。
/// 服务器回了状态的（状态码 + 描述）不经这里：RTMPTransport.error(code:description:phase:) 照留原文（排障要看）。
enum TransportErrorText {
    private static let logger = Logger(subsystem: "switcher.streaming", category: "Transport")

    /// 概括。`logContext` 非空时把原文（打过码）和概括记一条日志：last_error 里只剩概括，原文得留个地方。
    static func summary(of error: any Error, logContext context: String? = nil) -> String {
        let s = describe(error)
        if let context {
            logger.notice("[\(context, privacy: .public)] \(s, privacy: .public)；原文：\(StreamURLRedaction.redact(text: String(reflecting: error)), privacy: .public)")
        }
        return s
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let e as StreamTransportError: return e.description
        case let e as RTMPAdobeAuth.Failure: return e.description
        case is CancellationError: return "已取消"
        case RTMPConnection.Error.socketErrorOccurred(let underlying): return underlying.map(network) ?? "网络错误"
        case RTMPConnection.Error.connectionTimedOut: return "连接超时"
        case RTMPConnection.Error.requestTimedOut, RTMPStream.Error.requestTimedOut: return "服务器没回（请求超时）"
        case RTMPConnection.Error.invalidState, RTMPStream.Error.invalidState: return "连接状态不对"
        case RTMPConnection.Error.unsupportedCommand: return "地址不支持"
        case RTMPStream.Error.unsupportedCodec: return "编码格式不支持"
        case RTMPConnection.Error.requestFailed, RTMPStream.Error.requestFailed: return "服务器拒绝了请求"   // 带状态的由 RTMPTransport 先认掉
        case SRTConnection.Error.failedToConnect(let reason): return srt(reason)
        case SRTConnection.Error.unsupportedUri: return "SRT 地址不支持"
        case SRTConnection.Error.invalidState: return "SRT 连接状态不对"
        default: return network(error)
        }
    }

    /// Network.framework / POSIX 的错误；都不是 = 未知错误。
    private static func network(_ error: any Error) -> String {
        if let e = error as? NWError {
            switch e {
            case .posix(let code): return posix(code)
            case .dns: return "找不到主机（域名解析失败）"
            case .tls: return "TLS 握手失败"
            default: return "网络错误"
            }
        }
        if let e = error as? POSIXError { return posix(e.code) }
        return "未知错误"
    }

    private static func posix(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ECONNREFUSED: return "连接被拒（这个地址和端口上没有服务器在听）"
        case .ETIMEDOUT: return "连接超时（服务器没响应）"
        case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN: return "网络不通"
        case .ECONNRESET: return "连接被服务器重置"
        case .ECONNABORTED, .EPIPE, .ENOTCONN, .ESHUTDOWN: return "连接断开了"
        default: return "网络错误（POSIX \(code.rawValue)）"
        }
    }

    /// libsrt 的拒绝原因（SRT_REJ_*）。
    private static func srt(_ reason: SRTRejectReason) -> String {
        switch reason {
        case .timeout: return "SRT 连接超时（服务器没回）"
        case .badsecret: return "SRT 被拒（passphrase 不对）"
        case .unsecure: return "SRT 被拒（passphrase 一边有一边没有）"
        case .peer: return "SRT 被服务器拒绝"
        case .close: return "SRT 连接被关闭"
        default: return "SRT 连接失败（拒绝原因 \(reason.rawValue)）"
        }
    }
}
