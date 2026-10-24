// 添加输入面板的辅助（W5-K，prompt 97 交付 1，docs/ui-study/01a G2–G12、04 Q57 / Q58）：
// - 类型分组 + 系统符号图标（G3）：设备（摄像头 / 采集卡、DeckLink、音频设备）/ 网络（NDI®）/ 屏幕 / 媒体（视频文件、图片）/ 测试（合成测试源，Q58 挪到最后、不作默认）。
//   左栏、底栏 ▴、菜单栏"按类型添加 ▸"都按 displayOrder 排（Kind 的 rawValue 不动：本机记忆里存的是它）。
// - 页顶横幅（G6）：摄像头 / 麦克风 / 屏幕录制权限被拒（"打开系统设置…"直达隐私与安全性那一页）、NDI® 运行库不在、DeckLink SDK 没编进来或驱动没装（"看说明"）。
//   系统状态与两个动作都走 AddInputEnvironment，测试注入假的；还没问过（notDetermined）不挂横幅——第一次加的时候系统自己会问。
// - 摄像头协商结果（G8）：用 SwitcherInputs 的 CameraFormatNegotiation（引擎起这一路时用的同一个纯函数）算"将以多大 · 多少帧采集"，帧率对不上标黄、写明重复帧还是丢帧。
// - 文件信息（G12）与纯音频文件（Q57）：AVURLAsset / CGImageSource 读编码、尺寸、帧率、时长、透明通道；mp3 / wav / m4a / aac 按纯音频显示——
//   这一版的文件输入（FileInput）还要求有视频轨，加上会报"文件里没有视频轨"（问题单 W5K-w2-inputs-file-audio-only），页上写明。
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwitcherContracts
import SwitcherInputs
import SwitcherDeckLink
import SwitcherNDI

/// 类型分组（G3）。
enum AddInputKindGroup: String, CaseIterable, Identifiable {
    case devices, network, screen, media, test
    var id: String { rawValue }
    var title: String { L("addInput.group.\(rawValue)") }
    var kinds: [AddInputModel.Kind] { AddInputModel.Kind.displayOrder.filter { $0.group == self } }
}

extension AddInputModel.Kind {
    /// 面板左栏与 ▴ / "按类型添加 ▸"菜单的顺序：设备 → 网络 → 屏幕 → 媒体 → 测试（合成测试源最后，Q58）。
    static let displayOrder: [Self] = [.camera, .decklink, .audio, .ndi, .screen, .file, .image, .synthetic]

    var group: AddInputKindGroup {
        switch self {
        case .camera, .decklink, .audio: .devices
        case .ndi: .network
        case .screen: .screen
        case .file, .image: .media
        case .synthetic: .test
        }
    }

    /// 系统符号图标（SF Symbols，macOS 15 起都有；自己挑的，不用参考软件的图标）。
    var symbolName: String {
        switch self {
        case .camera: "web.camera"
        case .decklink: "cable.connector"
        case .audio: "mic"
        case .ndi: "network"
        case .screen: "display"
        case .file: "film"
        case .image: "photo"
        case .synthetic: "testtube.2"
        }
    }
}

/// 页顶横幅（G6）。
struct AddInputBanner: Equatable {
    enum Action: Equatable {
        /// 打开 系统设置 › 隐私与安全性 的某一页。
        case openSystemSettings(URL)
        /// 打开手册的某一节（锚点）。
        case showHelp(String)
    }
    var title: String
    var message: String
    var action: Action
    /// 这一版编译时就没带这种输入（NDI® / DeckLink SDK 没编进来）：装什么都不会好，"添加"旁不许诺"装好后自动恢复"（W5-P，W4C3 第 14 条）。
    var buildLacksSupport = false
    var actionTitle: String {
        switch action {
        case .openSystemSettings: L("addInput.banner.openSettings")
        case .showHelp: L("addInput.banner.help")
        }
    }
    /// 是权限问题（授权后自动恢复）还是装东西（装好后自动恢复）。
    var isPermission: Bool { if case .openSystemSettings = action { true } else { false } }
}

/// 添加面板看的系统状态与外部动作（测试注入假的）。
struct AddInputEnvironment {
    enum PrivacyPane: String {
        case camera = "Privacy_Camera"
        case microphone = "Privacy_Microphone"
        case screenRecording = "Privacy_ScreenCapture"
    }
    var cameraPermission: @MainActor () -> CapturePermission.Status
    var microphonePermission: @MainActor () -> CapturePermission.Status
    var screenRecordingAllowed: @MainActor () -> Bool
    /// NDI® 运行库能用（SDK 编进来了）。
    var ndiAvailable: @MainActor () -> Bool
    var decklinkSDKAvailable: @MainActor () -> Bool
    var decklinkDriverPresent: @MainActor () -> Bool
    /// 网络上的 NDI® 源名（会阻塞 1.5 s 左右，放后台线程调）。
    var discoverNDI: @Sendable () throws -> [String]
    var openURL: @MainActor (URL) -> Void
    var openHelp: @MainActor (String) -> Void

    /// 系统设置 › 隐私与安全性 的某一页（macOS 13 起老的 com.apple.preference.security 链接仍会跳到新设置窗的对应页）。
    static func privacyURL(_ pane: PrivacyPane) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    }

    static var live: AddInputEnvironment {
        AddInputEnvironment(cameraPermission: { CapturePermission.status(for: .video) },
                            microphonePermission: { CapturePermission.status(for: .audio) },
                            screenRecordingAllowed: { CGPreflightScreenCaptureAccess() },
                            ndiAvailable: { SwitcherNDIInfo.isSDKAvailable },
                            decklinkSDKAvailable: { SwitcherDeckLinkInfo.isSDKAvailable },
                            decklinkDriverPresent: { SwitcherDeckLinkInfo.isDriverPresent },
                            discoverNDI: { try NDIFinder.discover(timeoutMs: 1500).map(\.name) },
                            openURL: { NSWorkspace.shared.open($0) },
                            openHelp: { HelpBook.openManual(anchor: $0) })
    }

    /// 这一类现在要不要挂横幅。
    @MainActor
    func banner(for kind: AddInputModel.Kind) -> AddInputBanner? {
        func denied(_ s: CapturePermission.Status) -> Bool { s == .denied || s == .restricted || s == .deniedWithoutPrompt }
        switch kind {
        case .camera where denied(cameraPermission()):
            return AddInputBanner(title: L("addInput.banner.camera.title"), message: L("addInput.banner.camera.message"),
                                  action: .openSystemSettings(Self.privacyURL(.camera)))
        case .audio where denied(microphonePermission()):
            return AddInputBanner(title: L("addInput.banner.microphone.title"), message: L("addInput.banner.microphone.message"),
                                  action: .openSystemSettings(Self.privacyURL(.microphone)))
        case .screen where !screenRecordingAllowed():
            return AddInputBanner(title: L("addInput.banner.screen.title"), message: L("addInput.banner.screen.message"),
                                  action: .openSystemSettings(Self.privacyURL(.screenRecording)))
        case .ndi where !ndiAvailable():
            return AddInputBanner(title: L("addInput.banner.ndi.title"), message: L("addInput.banner.ndi.message"), action: .showHelp("ndi"), buildLacksSupport: true)
        case .decklink where !decklinkSDKAvailable():
            return AddInputBanner(title: L("addInput.banner.decklinkSDK.title"), message: L("addInput.banner.decklinkSDK.message"), action: .showHelp("decklink"),
                                  buildLacksSupport: true)
        case .decklink where !decklinkDriverPresent():
            return AddInputBanner(title: L("addInput.banner.decklinkDriver.title"), message: L("addInput.banner.decklinkDriver.message"), action: .showHelp("decklink"))
        default:
            return nil
        }
    }
}

/// 最近文件的一项（G11）：文件不在了灰着、不能双击直接加。
struct AddInputRecentFile: Identifiable, Hashable {
    var path: String
    var exists: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
}

/// 摄像头协商结果的一行（G8）。
struct CameraNegotiationSummary: Equatable {
    var text: String
    /// 帧率和节目对不上（标黄）。
    var frameRateMismatch: Bool

    /// 用引擎起这一路时同一个纯函数（CameraFormatNegotiation.choose）算；设备没报格式为 nil。
    static func make(candidates: [CameraFormatNegotiation.Candidate], program: ProgramFormat) -> CameraNegotiationSummary? {
        guard let choice = CameraFormatNegotiation.choose(candidates, program: program) else { return nil }
        let size = "\(choice.candidate.width)×\(choice.candidate.height)"
        let rate = Self.rateText(choice.frameRate)
        let programRate = Self.rateText(program.frameRate.approximateFramesPerSecond)
        let sizeNote = choice.candidate.width == program.width && choice.candidate.height == program.height ? "" : L("addInput.camera.negotiated.scaled", program.width, program.height)
        if choice.matchesProgramFrameRate {
            return CameraNegotiationSummary(text: L("addInput.camera.negotiated.match", size, rate) + sizeNote, frameRateMismatch: false)
        }
        let effect = choice.frameRate < program.frameRate.approximateFramesPerSecond ? L("addInput.camera.negotiated.repeats") : L("addInput.camera.negotiated.drops")
        return CameraNegotiationSummary(text: L("addInput.camera.negotiated.mismatch", size, rate, programRate, effect) + sizeNote, frameRateMismatch: true)
    }

    /// "59.94" / "60" / "29.97"。
    static func rateText(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }
}

/// 选好的文件的信息（G12）与纯音频文件（Q57）。
struct MediaFileInfo: Equatable, Sendable {
    var summary: String
    /// 纯音频文件（mp3 / wav / m4a / aac，或文件里只有音轨）。
    var isAudioOnly: Bool

    /// 视频文件页接受的纯音频扩展名（Q57）。
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac"]
    static func isAudioFile(_ path: String) -> Bool { audioExtensions.contains((path as NSString).pathExtension.lowercased()) }

    /// 视频文件页的打开面板接受的类型：视频 + 四种纯音频。
    static var movieContentTypes: [UTType] {
        [.movie, .video, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio] + [UTType("public.aac-audio")].compactMap { $0 }
    }

    /// 读视频 / 音频文件（AVURLAsset 异步载入；读不出来给一句原因）。
    static func loadMovie(path: String) async -> MediaFileInfo {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return MediaFileInfo(summary: L("addInput.fileInfo.missing"), isAudioOnly: isAudioFile(path)) }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let length = Self.durationText(duration.seconds)
            if let video = videos.first {
                let size = try await video.load(.naturalSize)
                let transform = try await video.load(.preferredTransform)
                let fps = try await video.load(.nominalFrameRate)
                let formats = try await video.load(.formatDescriptions)
                var codec = "?"
                var alpha = false
                var coded = (width: Int(size.width.rounded()), height: Int(size.height.rounded()))
                if let f = formats.first {
                    let dims = CMVideoFormatDescriptionGetDimensions(f)   // 编码尺寸取格式描述（FileInfo.width / height 同一来源）
                    if dims.width > 0, dims.height > 0 { coded = (Int(dims.width), Int(dims.height)) }
                    codec = Self.codecName(CMFormatDescriptionGetMediaSubType(f))
                    let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] ?? [:]
                    if let v = ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool { alpha = v }
                    else if let n = ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? NSNumber { alpha = n.boolValue }
                    if !alpha, let depth = ext[kCMFormatDescriptionExtension_Depth as String] as? Int, depth == 32 { alpha = true }
                }
                var parts = [codec, Self.sizeText(codedWidth: coded.width, codedHeight: coded.height, transform: transform),
                             L("addInput.fileInfo.fps", CameraNegotiationSummary.rateText(Double(fps))), length]
                if alpha { parts.append(L("addInput.fileInfo.alpha")) }
                if audios.isEmpty { parts.append(L("addInput.fileInfo.noAudio")) }
                return MediaFileInfo(summary: parts.joined(separator: " · "), isAudioOnly: false)
            }
            guard let audio = audios.first else { return MediaFileInfo(summary: L("addInput.fileInfo.noTracks"), isAudioOnly: false) }
            var parts = [L("addInput.fileInfo.audioOnly")]
            if let f = try await audio.load(.formatDescriptions).first {
                parts.append(Self.codecName(CMFormatDescriptionGetMediaSubType(f)))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    parts.append(String(format: "%.1f kHz", asbd.mSampleRate / 1000).replacingOccurrences(of: ".0 kHz", with: " kHz"))
                    parts.append(L("addInput.fileInfo.channels", Int(asbd.mChannelsPerFrame)))
                }
            }
            parts.append(length)
            return MediaFileInfo(summary: parts.joined(separator: " · "), isAudioOnly: true)
        } catch {
            return MediaFileInfo(summary: L("addInput.fileInfo.unreadable", "\(error.localizedDescription)"), isAudioOnly: isAudioFile(path))
        }
    }

    /// 尺寸那一段（W5-Q，117 §3）：先写转正后的尺寸 = FileInput 出帧的尺寸（与 FileInfo.displayWidth / displayHeight 同一套方向归类 FileOrientation），
    /// 竖拍这类宽高互换的片子编码尺寸放括号里；方向矩阵认不出（任意角度）时 FileInput 按原样出，这里也只写编码尺寸。
    static func sizeText(codedWidth w: Int, codedHeight h: Int, transform: CGAffineTransform) -> String {
        let coded = "\(w)×\(h)"
        guard FileOrientation(transform: transform)?.swapsAxes == true else { return coded }
        return L("addInput.fileInfo.sizeRotated", "\(h)×\(w)", coded)
    }

    /// 读图片（CGImageSource：格式、像素尺寸、有没有透明通道）。
    static func loadImage(path: String) -> MediaFileInfo {
        guard FileManager.default.fileExists(atPath: path) else { return MediaFileInfo(summary: L("addInput.fileInfo.missing"), isAudioOnly: false) }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return MediaFileInfo(summary: L("addInput.fileInfo.unreadable", (path as NSString).lastPathComponent), isAudioOnly: false)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() } ?? "?"
        var parts = [type, "\(width)×\(height)"]
        if props[kCGImagePropertyHasAlpha] as? Bool == true { parts.append(L("addInput.fileInfo.alpha")) }
        return MediaFileInfo(summary: parts.joined(separator: " · "), isAudioOnly: false)
    }

    /// 四字码 → 常见的编码名（不认识的照写四字码）。
    static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy:
            return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ: return "ProRes 4444"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleLossless: return "ALAC"
        default: return CameraDevices.fourCC(code).trimmingCharacters(in: .whitespaces)
        }
    }

    /// "0:10" / "1:02:03"。
    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
