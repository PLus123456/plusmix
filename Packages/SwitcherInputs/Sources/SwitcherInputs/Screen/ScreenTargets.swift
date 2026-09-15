import CoreGraphics
@preconcurrency import ScreenCaptureKit
import SwitcherContracts

/// 屏幕采集目标清单（探针、UI 用）。需要屏幕录制权限，没有就抛 SCStreamError -3801。
public enum ScreenTargets {
    public struct DisplayInfo: Hashable, Sendable {
        public var id: UInt32
        /// 像素尺寸。
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// 点尺寸。
        public var pointWidth: Int
        public var pointHeight: Int
    }
    public struct WindowInfo: Hashable, Sendable {
        public var id: UInt32
        public var title: String
        public var applicationName: String
        public var bundleID: String
        public var pointWidth: Int
        public var pointHeight: Int
        public var isOnScreen: Bool
    }
    public struct ApplicationInfo: Hashable, Sendable {
        public var bundleID: String
        public var name: String
        public var pid: Int32
    }

    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    public static func displays() async throws -> [DisplayInfo] {
        try await content().displays.map { d in
            DisplayInfo(id: d.displayID, pixelWidth: CGDisplayPixelsWide(d.displayID), pixelHeight: CGDisplayPixelsHigh(d.displayID),
                        pointWidth: d.width, pointHeight: d.height)
        }
    }

    public static func windows() async throws -> [WindowInfo] {
        try await content().windows.map { w in
            WindowInfo(id: w.windowID, title: w.title ?? "", applicationName: w.owningApplication?.applicationName ?? "",
                       bundleID: w.owningApplication?.bundleIdentifier ?? "", pointWidth: Int(w.frame.width), pointHeight: Int(w.frame.height),
                       isOnScreen: w.isOnScreen)
        }
    }

    public static func applications() async throws -> [ApplicationInfo] {
        try await content().applications.map { ApplicationInfo(bundleID: $0.bundleIdentifier, name: $0.applicationName, pid: $0.processID) }
    }

    /// 把 ScreenTarget 解析成 SCContentFilter + 源像素尺寸。找不到目标抛 ScreenInput.ScreenInputError。
    static func resolve(_ target: ScreenTarget) async throws -> (SCContentFilter, width: Int, height: Int, description: String) {
        let c = try await content()
        switch target {
        case .display(let id):
            guard let d = c.displays.first(where: { $0.displayID == id }) ?? (id == 0 ? c.displays.first : nil) else {
                throw ScreenInput.ScreenInputError.targetNotFound("显示器 \(id)")
            }
            let filter = SCContentFilter(display: d, excludingWindows: [])
            return (filter, CGDisplayPixelsWide(d.displayID), CGDisplayPixelsHigh(d.displayID), "显示器 \(d.displayID) \(d.width)×\(d.height) pt")
        case .window(let id):
            guard let w = c.windows.first(where: { $0.windowID == id }) else { throw ScreenInput.ScreenInputError.targetNotFound("窗口 \(id)") }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let scale = Int(filter.pointPixelScale.rounded())
            return (filter, max(2, Int(w.frame.width) * max(scale, 1)), max(2, Int(w.frame.height) * max(scale, 1)),
                    "窗口 \(w.windowID)「\(w.title ?? "")」（\(w.owningApplication?.applicationName ?? "")）")
        case .application(let bundleID):
            guard let app = c.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw ScreenInput.ScreenInputError.targetNotFound("应用 \(bundleID)")
            }
            guard let d = c.displays.first else { throw ScreenInput.ScreenInputError.targetNotFound("显示器") }
            let filter = SCContentFilter(display: d, including: [app], exceptingWindows: [])
            return (filter, CGDisplayPixelsWide(d.displayID), CGDisplayPixelsHigh(d.displayID), "应用 \(app.applicationName)（\(bundleID)）在显示器 \(d.displayID)")
        }
    }
}
