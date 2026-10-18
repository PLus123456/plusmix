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

    /// 由矩阵归类：只看线性部分 (a, b, c, d) 每一项的符号（相对最大项 1e-3 以内算 0，容下浮点噪声与缩放）；平移 (tx, ty) 只是把转过的画面
    /// 挪回第一象限，转正后的帧本来就从 (0, 0) 起，不用看。不是轴对齐（任意角度）、退化、非有限的返回 nil（调用方按原样出）。
    /// 对应关系由探针对着 AVAssetImageGenerator（appliesPreferredTrackTransform）逐一验过（reports/w2-inputs-5.md §1）。
    public init?(transform t: CGAffineTransform) {
        let m = [t.a, t.b, t.c, t.d]
        guard m.allSatisfy(\.isFinite), let scale = m.map({ abs($0) }).max(), scale > 0 else { return nil }
        func sign(_ v: CGFloat) -> Int { abs(v) <= scale * 1e-3 ? 0 : (v > 0 ? 1 : -1) }
        switch (sign(t.a), sign(t.b), sign(t.c), sign(t.d)) {
        case (1, 0, 0, 1): self = .identity
        case (0, 1, -1, 0): self = .rotate90
        case (-1, 0, 0, -1): self = .rotate180
        case (0, -1, 1, 0): self = .rotate270
        case (-1, 0, 0, 1): self = .flipHorizontal
        case (1, 0, 0, -1): self = .flipVertical
        case (0, 1, 1, 0): self = .transpose
        case (0, -1, -1, 0): self = .transverse
        default: return nil
        }
    }
}
