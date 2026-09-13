// 每个 pass 打 os_signpost（设计方案 §11 可观测性）。用旧式 os_signpost 自由函数而不是 OSSignposter：
// 后者的 beginInterval 返回一个类对象（分配），前者只写一条 trace 记录。签名里没有格式参数，不会构造字符串。
import os

enum RenderSignposts {
    /// Instruments 里按 subsystem 过滤：app.switcher.render。
    static let log = OSLog(subsystem: "app.switcher.render", category: .pointsOfInterest)

    enum Pass {
        case frame, program, preview, multiview, nv12, submit
    }

    @inline(__always)
    static func begin(_ pass: Pass) {
        guard log.signpostsEnabled else { return }
        switch pass {
        case .frame: os_signpost(.begin, log: log, name: "frame")
        case .program: os_signpost(.begin, log: log, name: "pgm")
        case .preview: os_signpost(.begin, log: log, name: "pvw")
        case .multiview: os_signpost(.begin, log: log, name: "multiview")
        case .nv12: os_signpost(.begin, log: log, name: "nv12")
        case .submit: os_signpost(.begin, log: log, name: "submit")
        }
    }

    @inline(__always)
    static func end(_ pass: Pass) {
        guard log.signpostsEnabled else { return }
        switch pass {
        case .frame: os_signpost(.end, log: log, name: "frame")
        case .program: os_signpost(.end, log: log, name: "pgm")
        case .preview: os_signpost(.end, log: log, name: "pvw")
        case .multiview: os_signpost(.end, log: log, name: "multiview")
        case .nv12: os_signpost(.end, log: log, name: "nv12")
        case .submit: os_signpost(.end, log: log, name: "submit")
        }
    }

    /// 一次性事件（跳拍、回退分配等）。
    @inline(__always)
    static func event(_ name: StaticString) {
        guard log.signpostsEnabled else { return }
        os_signpost(.event, log: log, name: name)
    }
}
