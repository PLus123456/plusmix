import AppKit

/// 一块显示器（NSScreen 的摘要，给菜单 / 设置面板列）。
public struct DisplayInfo: Hashable, Identifiable, Sendable {
    /// CGDirectDisplayID。
    public let id: UInt32
    /// 名字（NSScreen.localizedName）。
    public let name: String
    /// 全局坐标里的位置尺寸（点）。
    public let frame: CGRect
    /// 是不是主显示器（带菜单栏的那块）。
    public let isMain: Bool
    /// 刷新率上限（Hz）。
    public let maximumFramesPerSecond: Int
    /// 像素密度。
    public let backingScaleFactor: CGFloat

    public init(id: UInt32, name: String, frame: CGRect, isMain: Bool, maximumFramesPerSecond: Int, backingScaleFactor: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isMain = isMain
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.backingScaleFactor = backingScaleFactor
    }
}

/// 显示器枚举与查找（主线程）。
@MainActor
public enum ExternalDisplays {
    /// NSScreen.deviceDescription 里显示器 ID 的键。
    static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    /// 某块屏的 CGDirectDisplayID。
    public static func id(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value ?? 0
    }

    /// 现在接着的全部显示器，主显示器在前。
    public static func all() -> [DisplayInfo] {
        let main = NSScreen.main
        return NSScreen.screens.map { s in
            DisplayInfo(id: id(of: s), name: s.localizedName, frame: s.frame, isMain: s == main,
                        maximumFramesPerSecond: s.maximumFramesPerSecond, backingScaleFactor: s.backingScaleFactor)
        }.sorted { a, b in a.isMain && !b.isMain }
    }

    /// 按 ID 找屏；nil = 主屏；找不到返回 nil。
    public static func screen(for displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return NSScreen.main }
        return NSScreen.screens.first { id(of: $0) == displayID }
    }
}
