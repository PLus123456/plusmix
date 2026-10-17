import CoreGraphics

/// 视频轨 `preferredTransform`（显示矩阵）归成的方向：八种轴对齐的情形（四个旋转 × 是否镜像）。
/// 手机竖拍的 MOV / MP4 编码是横的，靠这个矩阵告诉播放器"转 90° 再显示"（Codex 审查 D15）。
public enum FileOrientation: String, Sendable, Hashable, CaseIterable {
    /// 恒等：编码方向就是显示方向。
    case identity
    /// 顺时针 90°（矩阵 (0, 1, −1, 0)，手机竖拍、Home 键在下）。
    case rotate90
    /// 180°（(−1, 0, 0, −1)）。
    case rotate180
    /// 顺时针 270° = 逆时针 90°（(0, −1, 1, 0)；ffmpeg `-display_rotation 90` 打的就是它）。
    case rotate270
    /// 水平镜像（(−1, 0, 0, 1)）。
    case flipHorizontal
    /// 垂直镜像（(1, 0, 0, −1)）。
    case flipVertical
    /// 沿主对角线翻（(0, 1, 1, 0)）= 顺时针 90° 再水平翻。
    case transpose
    /// 沿副对角线翻（(0, −1, −1, 0)）= 顺时针 90° 再垂直翻。
    case transverse

    /// 宽高互换（90° / 270° 一族）。
    public var swapsAxes: Bool {
        switch self {
        case .rotate90, .rotate270, .transpose, .transverse: true
        default: false
        }
    }

    /// 由矩阵归类；不是轴对齐（任意角度）、退化、非有限的返回 nil。
    public init?(transform t: CGAffineTransform) {
        return nil
    }
}
