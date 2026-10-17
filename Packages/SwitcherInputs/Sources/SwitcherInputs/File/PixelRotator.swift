import CoreVideo
import VideoToolbox

/// 按 `FileOrientation` 把解码帧转正（Codex 审查 D15：手机竖拍的 MOV / MP4 原来按编码方向横着出）。
///
/// 用 VTPixelRotationSession 逐像素搬（不过色彩转换），目标缓冲来自自己的 CVPixelBufferPool（IOSurface、Metal 可用）。
/// 探针（reports/w2-inputs-5.md §1，M5 Max，满速读完一段 90° 矩阵的片子，手上留 3 帧）对比过三种做法：
/// - AVAssetReaderVideoCompositionOutput + `AVMutableVideoComposition.videoComposition(withPropertiesOf:)`：能直接给转正帧、
///   CPU 最省，但每个 reader 多占 100–150 MB（1080p 峰值 156–158 MB，对照不转 10–12 MB），BGRA / 10 bit ProRes 源过它的
///   色彩转换后像素值变了（最大差 52 / 2）；循环点两个 reader 并存还要再翻倍——不用。
/// - vImage（Y 用 Planar8、CbCr 当 Planar16U 转）与本类同样逐字节无损，1080p NV12 CPU 更省一点，BGRA / 4K 反而更费，八种方向要自己拆平面写。
/// - VTPixelRotationSession：一次调用管四个旋转 × 水平 / 垂直翻转，NV12（'420v' / '420f'）、BGRA 都收；1080p NV12 每帧 CPU 多 ≈ 0.18 ms、
///   占用多 ≈ 13 MB（池里几张转正后的缓冲）。选它。
///
/// 池跨 reader 共用（循环 / 定位重开 reader 不换池，渲染器的纹理表按 IOSurface 认得住）；源缓冲转完就还给 reader。
/// 只在解码线程用（会话不保证线程安全）。转不了（VT 报错 / 池给不出缓冲）返回 nil，调用方原样出、记 `failures`。
final class PixelRotator: @unchecked Sendable {
    let orientation: FileOrientation
    private let session: VTPixelRotationSession
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType) = (0, 0, 0)
    /// 转不了的帧数（这些帧原样出）。
    private(set) var failures = 0
    /// 最近一次转不了的原因。
    private(set) var lastFailure: String?

    /// identity 不用转，返回 nil；会话建不出来也返回 nil（调用方原样出、说一句）。
    init?(orientation: FileOrientation) {
        guard orientation != .identity else { return nil }
        var s: VTPixelRotationSession?
        guard VTPixelRotationSessionCreate(nil, &s) == noErr, let s else { return nil }
        self.orientation = orientation
        session = s
        // 探针结论：VT 先转再翻（转置 = 顺时针 90° 后水平翻，与 AVAssetImageGenerator 的参照一致）
        let (rotation, flipH, flipV): (CFString, Bool, Bool) = switch orientation {
        case .identity: (kVTRotation_0, false, false)
        case .rotate90: (kVTRotation_CW90, false, false)
        case .rotate180: (kVTRotation_180, false, false)
        case .rotate270: (kVTRotation_CCW90, false, false)
        case .flipHorizontal: (kVTRotation_0, true, false)
        case .flipVertical: (kVTRotation_0, false, true)
        case .transpose: (kVTRotation_CW90, true, false)
        case .transverse: (kVTRotation_CW90, false, true)
        }
        VTSessionSetProperty(s, key: kVTPixelRotationPropertyKey_Rotation, value: rotation)
        VTSessionSetProperty(s, key: kVTPixelRotationPropertyKey_FlipHorizontalOrientation, value: flipH ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTPixelRotationPropertyKey_FlipVerticalOrientation, value: flipV ? kCFBooleanTrue : kCFBooleanFalse)
    }

    deinit { VTPixelRotationSessionInvalidate(session) }

    /// 转正一帧：返回池里的新缓冲（宽高按方向互换），附件照抄源缓冲（色彩、alpha 模式——推帧线程按它判要不要预乘；
    /// 探针 4：VT 自己也会抄，这里再显式抄一遍不靠它），与方向有关的几个（clean aperture、像素宽高比、色度位置）删掉，免得转过之后还按旧方向解释。
    func rotate(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let (w, h) = orientation.swapsAxes ? (height, width) : (width, height)
        if pool == nil || poolKey != (w, h, format) {
            pool = nil
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var p: CVPixelBufferPool?
            let r = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            guard r == kCVReturnSuccess, let p else { return failed("建不出转正用的像素池（\(w)×\(h)，CVReturn \(r)）") }
            pool = p
            poolKey = (w, h, format)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard r == kCVReturnSuccess, let out else { return failed("转正用的像素池给不出缓冲（CVReturn \(r)）") }
        let status = VTPixelRotationSessionRotateImage(session, source, out)
        guard status == noErr else { return failed("VTPixelRotationSessionRotateImage 出错（OSStatus \(status)）") }
        CVBufferPropagateAttachments(source, out)
        for key in [kCVImageBufferCleanApertureKey, kCVImageBufferPixelAspectRatioKey,
                    kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            CVBufferRemoveAttachment(out, key)
        }
        return out
    }

    private func failed(_ reason: String) -> CVPixelBuffer? {
        failures += 1
        lastFailure = reason
        return nil
    }
}
