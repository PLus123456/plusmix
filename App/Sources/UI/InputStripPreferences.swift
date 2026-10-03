// 输入条的本机偏好（W5-H，01a D11）：缩略图小 / 中 / 大。红灯轮：只给签名。
import AppKit

enum ThumbnailSize: String, CaseIterable {
    case small, medium, large
}

@MainActor
final class InputStripPreferences {
    enum Keys {
        static let thumbnailSize = "inputThumbnailSize"
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var thumbnailSize: ThumbnailSize {
        get { .medium }
        set {}
    }
    func reset() {}
}
