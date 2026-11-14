// 输入条的本机偏好（W5-H，01a D11）：缩略图小 / 中 / 大三档。存 UserDefaults（本机偏好，和节目文件无关；测试宿主是自己的 suite，
// AppTest.freshSession 每条用例开头清掉）。01a D11 建议放设置"节目格式与显示"页，设置体系归 96（W5-J）：这里先放输入条右键与"窗口 › 输入缩略图 ▸"。
import AppKit

/// 缩略图三档：格子宽（原来固定 200 = "中"）；缩略图框的高按裁切后的比例算（V-23，InputCellView.thumbnailHeight）。
/// W6-A（docs/spec/大屏与时间线方案.md §2.3）加第四档"紧凑"：竖的小格，宽 72、只有标题条 + 和画布同形状的缩略图，按钮进右键菜单；
/// 竖屏排法里输入区固定用它（InputStripView.forcesCompact），横屏也能选。
enum ThumbnailSize: String, CaseIterable {
    case small, medium, large, compact

    var width: CGFloat {
        switch self {
        case .small: 160
        case .medium: 200
        case .large: 256
        case .compact: 72
        }
    }

    var title: String { L("strip.size.\(rawValue)") }
}

@MainActor
final class InputStripPreferences {
    enum Keys {
        static let thumbnailSize = "inputThumbnailSize"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 缩略图大小（没存过 = 中）。
    var thumbnailSize: ThumbnailSize {
        get { defaults.string(forKey: Keys.thumbnailSize).flatMap(ThumbnailSize.init(rawValue:)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Keys.thumbnailSize) }
    }

    /// 回到默认（测试每条用例开头调）。
    func reset() {
        defaults.removeObject(forKey: Keys.thumbnailSize)
    }
}
