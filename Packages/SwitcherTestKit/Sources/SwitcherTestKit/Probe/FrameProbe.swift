import Foundation
import SwitcherContracts

/// frameprobe 的编排层：文件 / 目录 → `ProbeFrame` + `ClickEvent` → `FrameAnalysis` → 报告（JSON / markdown）。
/// 命令行（Tools/frameprobe）只做参数解析，全部逻辑在这里，所以能在 TestKit 的测试里对样例做快照。
public enum FrameProbe {
    public struct Options: Sendable {
        /// 节目帧率；nil = 用容器标称帧率（目录输入用 rawFps）。
        public var fps: Double?
        /// 每路输入的帧率（键 = 输入 ID），stats 用来分设计内 / 设计外。
        public var inputFps: [Int: Double] = [:]
        /// 输出第 0 帧对应的节目拍。
        public var startTick: Int64 = 0
        /// V7 的 A / B 标称灰度。
        public var grayA = 64.0
        public var grayB = 192.0
        /// switches 判混合帧的容差。
        public var grayTolerance = 6.0
        /// fade 判混合帧的容差。
        public var fadeTolerance = 2.0
        /// Fade 时长（拍）；nil = 自动推断。
        public var fadeDuration: Int?
        /// 发 Fade 命令的拍（指定模式）。
        public var fadeAt: Int64?
        /// 序列最多列多少条。
        public var maxEvents = 200
        /// 原始 NV12 目录的尺寸与帧率。
        public var rawWidth = 1920
        public var rawHeight = 1080
        public var rawFps = 60.0
        /// frames 输出最多多少帧；nil = 全部。
        public var limit: Int?
        /// 音轨 priming 的处理（`--aac-priming auto|0|N`，见 `AudioTimeline`）。
        public var aacPriming: PrimingMode = .auto
        /// av 顺带做波形不连续检测（A1 第三项，`--discontinuities`）。
        public var discontinuities = false
        /// 不连续检测的 click 排除窗口：click 起点前后各 marginMs（click 本身按 1 ms 计）。
        public var discontinuityMarginMs = 1.0
        /// 这些拍（tick = startTick + 帧序号）的帧当作解不出（帧号 / ID / 时间戳置 nil、闪光置 false，灰度保留）：转场中间帧是两路的合成，
        /// 帧号行与 ID 块在不同拍翻转、颜色是混合值，按输入身份统计的 V4 / V6 / C3 对它们没有定义（G4 checkpoint，`frameprobe --blank-ticks`）。
        /// 总帧数（V5）不受影响；引擎侧的 stats.jsonl 计数全程照算。
        public var blankTicks: [ClosedRange<Int64>] = []
        /// 解码自证（W1-A3）：帧号行、时间戳行、ID 块、底色、节奏互相印证，认出转场合成帧。默认开；
        /// `--no-self-check` 关掉就是老口径（只按契约解码），`--blank-ticks` 两种口径下都还在。
        public var selfCheck = SelfCheck.Options()
        /// 要量的那次转场的命令拍（`wipe` / `zoom` 子命令）。
        public var transitionAt: Int64?
        /// 要量的那次转场的时长（拍）。
        public var transitionDuration: Int?
        /// Wipe 的方向（`wipe` 子命令）。
        public var wipeDirection: WipeDirection = .leftToRight
        public init() {}
    }

    /// 读进来的一个源。
    public struct Loaded: Sendable {
        public var source: String
        public var info: ProbeVideoInfo
        public var frames: [ProbeFrame]
        /// 音轨信息；`startSeconds` 已按 `timeline` 修正。
        public var audio: ProbeAudioInfo?
        /// click 时刻（已修正的时间轴）。
        public var clicks: [ClickEvent]
        /// 单声道样本（withAudio 时有；不连续检测用）。
        public var samples: [Float]
        /// 节目帧率（选项或标称）。
        public var fps: Double
        /// 灰度剖面（只有转场窗口里的帧有）。
        public var profiles: [Int: ScanProfile] = [:]
        /// 自证解码的结果。
        public var selfCheck = SelfCheck.Report(enabled: false, frames: 0, rejected: 0, byReason: [:], fits: [], examples: [], truncated: false)
    }

    /// 读文件（.mov / .mp4）或原始 NV12 目录；`withAudio` 才读音轨找 click。
    /// 音轨时间轴：AVFoundation 的解码起点 + `audioTimeline` 算出的修正（容器里音轨相对视频的偏移 + 按 `options.aacPriming` 加回的 priming）。
    public static func load(_ url: URL, options: Options, withAudio: Bool) async throws -> Loaded {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let fps = options.fps ?? options.rawFps
            let r = try MediaReader.readRawNV12Directory(url: url, width: options.rawWidth, height: options.rawHeight, fps: fps,
                                                         profileAt: profilePredicate(options: options, fps: fps))
            let (frames, report) = check(r, options: options, fps: fps)
            return Loaded(source: url.path, info: r.info, frames: frames, audio: nil, clicks: [], samples: [], fps: fps,
                          profiles: r.profiles, selfCheck: report)
        }
        // 剖面窗口按拍号圈，拍号要用真帧率换算：没给 --fps 就先只读一次容器的标称帧率（59.94 的文件按 60 算，第 7800 拍会偏 8 拍）
        var probeFps = options.fps ?? 0
        if probeFps <= 0 && options.transitionAt != nil { probeFps = (try? await MediaReader.nominalFps(url: url)) ?? 60 }
        let v = try await MediaReader.readVideo(url: url, profileAt: profilePredicate(options: options, fps: probeFps))
        let (frames, selfCheck) = check(v, options: options, fps: options.fps ?? (v.info.nominalFps > 0 ? v.info.nominalFps : 60))
        var audio: ProbeAudioInfo?
        var clicks: [ClickEvent] = []
        var samples: [Float] = []
        if withAudio, let a = try await MediaReader.readAudio(url: url) {
            let index = try? MP4Index.scan(url: url)
            let timeline = audioTimeline(decoded: a, index: index, mode: options.aacPriming)
            var info = a.info
            info.startSeconds = timeline.avfoundationStartSeconds + timeline.correctionSeconds
            info.timeline = timeline
            audio = info
            clicks = ClickDetector.detect(samples: a.samples, sampleRate: a.info.sampleRate, startSeconds: info.startSeconds)
            samples = a.samples
        }
        let fps = options.fps ?? (v.info.nominalFps > 0 ? v.info.nominalFps : 60)
        return Loaded(source: url.path, info: v.info, frames: frames, audio: audio, clicks: clicks, samples: samples, fps: fps,
                      profiles: v.profiles, selfCheck: selfCheck)
    }

    /// 自证 + `--blank-ticks`。两者判掉的帧都置成解不出，报告里分开记。
    static func check(_ v: MediaReader.VideoResult, options: Options, fps: Double) -> ([ProbeFrame], SelfCheck.Report) {
        let checked = SelfCheck.apply(frames: v.frames, readings: v.readings, options: options.selfCheck,
                                      startTick: options.startTick, maxEvents: options.maxEvents, fps: options.fps)
        let frames = blank(checked.frames, options: options, fps: fps)
        var report = checked.report
        let blanked = zip(checked.frames, frames).filter { $0.inputID != nil && $1.inputID == nil }.count
        if blanked > 0 {
            report.byReason[SelfCheck.Reason.blank.rawValue, default: 0] += blanked
            report.rejected += blanked
        }
        return (frames, report)
    }

    /// 哪些帧要算灰度剖面：转场窗口 [s, s + D] 的每一拍（`wipe` / `zoom` 子命令）。
    static func profilePredicate(options: Options, fps: Double) -> (@Sendable (Double) -> Bool)? {
        guard let at = options.transitionAt, let d = options.transitionDuration, d >= 2, fps > 0 else { return nil }
        let startTick = options.startTick
        let window = at...(at + Int64(d))
        return { pts in window.contains(startTick + Int64((pts * fps).rounded())) }
    }

    /// `options.blankTicks` 里的帧置成解不出（见 Options.blankTicks）。拍号按 pts 算（tick = startTick + round(pts × fps)），
    /// 不按文件序号：文件里漏了帧（missed_render）之后序号与拍就错位了（G4 第一次跑 2 次跳拍，34030 拍之后全部错 2 帧，标记就标偏了）。
    static func blank(_ frames: [ProbeFrame], options: Options, fps: Double) -> [ProbeFrame] {
        guard !options.blankTicks.isEmpty else { return frames }
        return frames.map { f in
            let tick = options.startTick + (fps > 0 ? Int64((f.ptsSeconds * fps).rounded()) : Int64(f.index))
            guard options.blankTicks.contains(where: { $0.contains(tick) }) else { return f }
            return ProbeFrame(index: f.index, ptsSeconds: f.ptsSeconds, frameNumber: nil, inputID: nil, genTimeMs: nil, flash: false, gray: f.gray)
        }
    }

    /// 由解码结果与容器索引算音轨时间轴的修正（`AudioTimeline` 的说明）。
    public static func audioTimeline(decoded a: MediaReader.AudioResult, index: MP4Index?, mode: PrimingMode) -> AudioTimeline {
        let track = index?.audioTrack
        let hasEditList = track?.hasEditList ?? false
        let containerOffset = index?.audioStartRelativeToVideoSeconds ?? 0
        let sr = max(1, a.info.sampleRate)
        // ffmpeg 口径：有编辑列表时 AVFoundation 已经裁对、挪对（修正 0）；没有时它裁了 primingTrimmed 个样本却没挪时间轴，加回去
        let ffmpegAddBack = hasEditList ? 0 : a.primingTrimmedSamples
        let ffmpegCorrection = hasEditList ? 0 : containerOffset + Double(ffmpegAddBack) / sr
        let addBack: Int
        let correction: Double
        switch mode {
        case .auto:
            addBack = ffmpegAddBack
            correction = ffmpegCorrection
        case .samples(let n):
            addBack = n
            correction = containerOffset + Double(n) / sr
        }
        // 有编辑列表时两种口径重合（AVFoundation 按 elst 裁并挪，ffmpeg 也按 elst 跳过），标 avfoundation
        let applied = hasEditList && abs(correction) < 1e-9 ? "avfoundation"
            : abs(correction - ffmpegCorrection) < 1e-9 ? "ffmpeg" : (abs(correction) < 1e-9 ? "avfoundation" : "custom")
        return AudioTimeline(mode: mode.label, applied: applied, codec: a.codec, isFragmented: index?.isFragmented ?? false,
                             hasEditList: hasEditList, editListMediaTime: track?.editList.first { $0.mediaTime >= 0 }?.mediaTime,
                             avfoundationStartSeconds: a.info.startSeconds, containerOffsetSeconds: containerOffset,
                             primingTrimmedSamples: a.primingTrimmedSamples, primingAddedBackSamples: addBack,
                             correctionSeconds: correction, ffmpegCorrectionSeconds: ffmpegCorrection)
    }

    // MARK: 报告

    public struct FramesReport: Codable, Sendable {
        public var source: String
        public var info: ProbeVideoInfo
        public var frameCount: Int
        public var frames: [ProbeFrame]
        public var truncated: Bool
        /// 自证解码判掉了哪些帧（W1-A3）。
        public var selfCheck: SelfCheck.Report?
    }
    public struct StatsOutput: Codable, Sendable {
        public var source: String
        public var info: ProbeVideoInfo
        public var stats: FrameAnalysis.StatsReport
        /// 自证解码判掉了哪些帧（W1-A3）。
        public var selfCheck: SelfCheck.Report?
    }
    public struct SwitchesOutput: Codable, Sendable {
        public var source: String
        public var switches: FrameAnalysis.SwitchesReport
    }
    public struct FadeOutput: Codable, Sendable {
        public var source: String
        public var fade: FrameAnalysis.FadeReport
    }
    /// `wipe` / `zoom` 子命令的输出。
    public struct CurveOutput: Codable, Sendable {
        public var source: String
        public var curve: FrameAnalysis.TransitionCurve
    }
    public struct AVOutput: Codable, Sendable {
        public var source: String
        public var audio: ProbeAudioInfo?
        /// 采用口径（`audio.timeline.applied`）下的 A2 / A3。
        public var av: FrameAnalysis.AVReport
        /// 两种口径的整秒配对对照。
        public var timelines: AVTimelineComparison?
        /// `--discontinuities` 时有：A1 第三项。
        public var discontinuities: FrameAnalysis.DiscontinuityReport?
    }
    /// AVFoundation 原生（不修正）与 ffmpeg 口径（容器偏移 + 不裁 priming）各自的整秒配对统计；采用的是哪个见 `applied`。
    public struct AVTimelineComparison: Codable, Sendable {
        public var applied: String
        public var appliedCorrectionMs: Double
        public var avfoundation: FrameAnalysis.AVStats
        public var ffmpegCorrectionMs: Double
        public var ffmpeg: FrameAnalysis.AVStats
    }
    public struct AVMultiOutput: Codable, Sendable {
        public var sources: [String]
        public var perFile: [FrameAnalysis.AVReport]
        public var multi: FrameAnalysis.MultiFileAVReport
    }

    public static func frames(_ url: URL, options: Options = Options()) async throws -> FramesReport {
        let l = try await load(url, options: options, withAudio: false)
        let limited = options.limit.map { Array(l.frames.prefix($0)) } ?? l.frames
        return FramesReport(source: l.source, info: l.info, frameCount: l.frames.count, frames: limited,
                            truncated: limited.count < l.frames.count, selfCheck: l.selfCheck.enabled ? l.selfCheck : nil)
    }

    public static func stats(_ url: URL, options: Options = Options()) async throws -> StatsOutput {
        let l = try await load(url, options: options, withAudio: false)
        return StatsOutput(source: l.source, info: l.info,
                           stats: FrameAnalysis.stats(frames: l.frames, programFps: l.fps, inputFps: options.inputFps, maxEvents: options.maxEvents),
                           selfCheck: l.selfCheck.enabled ? l.selfCheck : nil)
    }

    /// Wipe 的进度曲线（V7）。要 `transitionAt` / `transitionDuration` / `wipeDirection`。
    public static func wipe(_ url: URL, options: Options = Options()) async throws -> CurveOutput {
        let l = try await load(url, options: options, withAudio: false)
        let curve = FrameAnalysis.wipeCurve(frames: l.frames, profiles: l.profiles, direction: options.wipeDirection,
                                            at: options.transitionAt ?? 0, durationTicks: options.transitionDuration ?? 0,
                                            startTick: options.startTick, fps: l.fps)
        return CurveOutput(source: l.source, curve: curve)
    }

    /// Zoom 的进度曲线（V7）。要 `transitionAt` / `transitionDuration`。
    public static func zoom(_ url: URL, options: Options = Options()) async throws -> CurveOutput {
        let l = try await load(url, options: options, withAudio: false)
        let curve = FrameAnalysis.zoomCurve(frames: l.frames, profiles: l.profiles, at: options.transitionAt ?? 0,
                                            durationTicks: options.transitionDuration ?? 0, startTick: options.startTick, fps: l.fps)
        return CurveOutput(source: l.source, curve: curve)
    }

    /// 转场落点按 pts 换算的节目拍号（W1-A6，Codex T02）。拍号用的帧率只认 `--fps`；没给就按相邻帧 pts 差估（`FrameAnalysis.programFps`），
    /// **不用** `l.fps` 里的容器 nominalFrameRate——它是"样本数 / 时长"，漏了帧就偏低（gate4 的 switches / fade 不带 --fps）。
    public static func switches(_ url: URL, options: Options = Options()) async throws -> SwitchesOutput {
        let l = try await load(url, options: options, withAudio: false)
        return SwitchesOutput(source: l.source, switches: FrameAnalysis.switches(frames: l.frames, startTick: options.startTick, grayTolerance: options.grayTolerance,
                                                                                 fps: options.fps, maxEvents: options.maxEvents))
    }

    /// 拍号口径同 `switches`。
    public static func fade(_ url: URL, options: Options = Options()) async throws -> FadeOutput {
        let l = try await load(url, options: options, withAudio: false)
        let r = FrameAnalysis.fade(frames: l.frames, grayA: options.grayA, grayB: options.grayB, durationTicks: options.fadeDuration,
                                   at: options.fadeAt, tolerance: options.fadeTolerance, startTick: options.startTick,
                                   fps: options.fps, maxEvents: options.maxEvents)
        return FadeOutput(source: l.source, fade: r)
    }

    public static func av(_ url: URL, options: Options = Options()) async throws -> AVOutput {
        let l = try await load(url, options: options, withAudio: true)
        let report = FrameAnalysis.av(frames: l.frames, clicks: l.clicks, frameDurationSeconds: 1 / l.fps, startTick: options.startTick)
        var comparison: AVTimelineComparison?
        if let a = l.audio, let t = a.timeline {
            // 同一批 click 按另外两个修正量平移，只看整秒配对
            func stats(correction: Double) -> FrameAnalysis.AVStats {
                let shifted = l.clicks.map { ClickEvent(sampleIndex: $0.sampleIndex, timeSeconds: $0.timeSeconds - t.correctionSeconds + correction, peak: $0.peak) }
                return FrameAnalysis.av(frames: l.frames, clicks: shifted, frameDurationSeconds: 1 / l.fps, startTick: options.startTick).onSecond
            }
            comparison = AVTimelineComparison(applied: t.applied, appliedCorrectionMs: t.correctionSeconds * 1000,
                                              avfoundation: stats(correction: 0),
                                              ffmpegCorrectionMs: t.ffmpegCorrectionSeconds * 1000, ffmpeg: stats(correction: t.ffmpegCorrectionSeconds))
        }
        var disc: FrameAnalysis.DiscontinuityReport?
        if options.discontinuities, let a = l.audio {
            disc = FrameAnalysis.discontinuities(samples: l.samples, sampleRate: a.sampleRate, startSeconds: a.startSeconds, clicks: l.clicks,
                                                 marginSeconds: options.discontinuityMarginMs / 1000, maxEvents: options.maxEvents)
        }
        return AVOutput(source: l.source, audio: l.audio, av: report, timelines: comparison, discontinuities: disc)
    }

    public static func avMulti(_ urls: [URL], options: Options = Options()) async throws -> AVMultiOutput {
        var loaded: [Loaded] = []
        for u in urls { loaded.append(try await load(u, options: options, withAudio: true)) }
        let fps = loaded.first?.fps ?? 60
        let per = loaded.map { FrameAnalysis.av(frames: $0.frames, clicks: $0.clicks, frameDurationSeconds: 1 / fps, startTick: options.startTick) }
        let multi = FrameAnalysis.avMulti(files: loaded.map { ($0.source, $0.frames, $0.clicks) }, frameDurationSeconds: 1 / fps)
        return AVMultiOutput(sources: loaded.map(\.source), perFile: per, multi: multi)
    }

    // MARK: markdown

    static func f(_ v: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", v) }
    static func pct(_ v: Double) -> String { String(format: "%.3f%%", v * 100) }
    static func mark(_ b: Bool?) -> String { b.map { $0 ? "✅" : "❌" } ?? "—" }

    public static func markdown(_ r: FramesReport) -> String {
        var s = "**\(r.source)** \(r.info.width)×\(r.info.height) \(f(r.info.nominalFps, 2)) fps，\(r.frameCount) 帧，\(f(r.info.durationSeconds, 3)) s\(r.truncated ? "（只列前 \(r.frames.count) 帧）" : "")\n\n"
        s += "| index | pts (s) | frameNumber | inputID | genTimeMs | flash | gray |\n|---|---|---|---|---|---|---|\n"
        for x in r.frames {
            s += "| \(x.index) | \(f(x.ptsSeconds, 4)) | \(x.frameNumber.map(String.init) ?? "—") | \(x.inputID.map(String.init) ?? "—") | \(x.genTimeMs.map(String.init) ?? "—") | \(x.flash ? "●" : "") | \(f(x.gray, 1)) |\n"
        }
        return s
    }

    public static func markdown(_ r: StatsOutput) -> String {
        let t = r.stats
        var s = "**\(r.source)** \(r.info.width)×\(r.info.height)，节目 \(f(t.programFps, 3)) fps\n\n"
        s += "| 项 | 值 |\n|---|---|\n"
        s += "| 总帧数（V5） | \(t.totalFrames)，时长 \(f(t.durationSeconds, 3)) s × \(f(t.programFps, 3)) fps = 期望 \(t.expectedFrames)，差 \(t.frameCountDelta >= 0 ? "+" : "")\(t.frameCountDelta) |\n"
        s += "| 帧号读不出 | \(t.undecodableFrames) |\n| 输入 ID 读不出（混合 / 黑场） | \(t.unidentifiedFrames) |\n\n"
        if let c = r.selfCheck { s += markdown(c) + "\n" }
        s += "| 输入 | 帧 | 不同帧号 | 重复帧 | 重复比例 | 设计内 | 设计外 | 丢弃帧 | 丢弃比例 | 设计内 | 设计外 | 倒退 | V4 |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for i in t.inputs {
            s += "| \(i.inputID)\(i.inputFps.map { "（\(f($0, 2)) fps）" } ?? "") | \(i.frames) | \(i.uniqueFrames) | \(i.duplicateFrames) | \(pct(i.duplicateRatio)) | \(i.designDuplicateRatio.map(pct) ?? "—") | \(i.excessDuplicateRatio.map(pct) ?? "—") | \(i.droppedFrames) | \(pct(i.dropRatio)) | \(i.designDropRatio.map(pct) ?? "—") | \(i.excessDropRatio.map(pct) ?? "—") | \(i.backwardJumps) | \(mark(i.passV4)) |\n"
        }
        for i in t.inputs where !i.dropGaps.isEmpty || !i.duplicateRuns.isEmpty {
            s += "\n输入 \(i.inputID) 的缺口（前 \(i.dropGaps.count) 条）：" + i.dropGaps.prefix(20).map { "#\($0.index) \($0.from)→\($0.to) 缺 \($0.missing)" }.joined(separator: "；") + "\n"
            s += "输入 \(i.inputID) 的重复段（前 \(i.duplicateRuns.count) 条）：" + i.duplicateRuns.prefix(20).map { "#\($0.index)×\($0.length)" }.joined(separator: "；") + "\n"
        }
        if t.truncated { s += "\n（序列被 maxEvents 截断）\n" }
        return s
    }

    /// 自证解码的小结。
    public static func markdown(_ c: SelfCheck.Report) -> String {
        guard c.enabled else { return "自证解码：关（`--no-self-check`）\n" }
        var s = "自证解码（W1-A3）：\(c.frames) 帧里判掉 \(c.rejected)（"
        s += SelfCheck.Reason.allCases.compactMap { r in c.byReason[r.rawValue].map { "\(r.rawValue) \($0)" } }.joined(separator: "、")
        s += "）\n\n| 输入 | 帧 | 每帧 ms | 最大残差 ms | 标称灰度 | 按节奏判掉 | 时间轴离群（只报） | 最大时间轴偏离 ms |\n"
        s += "|---|---|---|---|---|---|---|---|\n"
        for f in c.fits {
            s += "| \(f.inputID) | \(f.frames) | \(self.f(f.msPerFrame, 4)) | \(self.f(f.maxResidualMs, 2)) | \(self.f(f.nominalGray, 1)) | \(f.rejected) | \(f.timelineOutliers) | \(self.f(f.maxTimelineDeviationMs, 1)) |\n"
        }
        if !c.examples.isEmpty {
            s += "\n判掉的帧（前 \(min(12, c.examples.count)) 条\(c.truncated ? "，已截断" : "")）：" +
                c.examples.prefix(12).map { "拍 \($0.tick) \($0.reason.rawValue)（\(self.f($0.value, 1))）" }.joined(separator: "；") + "\n"
        }
        return s
    }

    /// `wipe` / `zoom` 的曲线表（与 `fade` 同形）。
    /// 漏帧的一句话："漏帧 N 拍（a, b, …）"；没有漏帧为空串。
    static func missingSummary(_ list: [Int64]?, _ count: Int?, label: String = "漏帧") -> String {
        guard let n = count, n > 0 else { return "" }
        let shown = (list ?? []).prefix(12).map(String.init).joined(separator: ", ")
        return "\(label) \(n) 拍（\(shown)\(n > min(12, list?.count ?? 0) ? ", …" : "")）"
    }

    public static func markdown(_ r: CurveOutput) -> String {
        let t = r.curve
        var s = "**\(r.source)** \(t.kind)\(t.direction.map { " \($0)" } ?? "")：第 \(t.startTick) 拍起 \(t.durationTicks) 拍，"
        s += "最大偏差 \(f(t.maxDeviationFrames, 3)) 帧（进度误差 \(pct(t.maxProgressError))），单调 \(t.monotonic ? "是" : "否")，V7 \(mark(t.passV7))"
        let missing = missingSummary(t.missingFrames, t.missingFrameCount, label: "；窗口里漏帧")
        s += missing + "\n\n"
        if let n = t.note { s += "\(n)\n\n" }
        s += "| 帧 | 拍 | 进度 | 期望 | 偏差（帧） | 取样点 |\n|---|---|---|---|---|---|\n"
        for x in t.samples {
            s += "| \(x.index) | \(x.tick) | \(f(x.progress, 4)) | \(f(x.expectedProgress, 4)) | \(f(x.deviationFrames, 3)) | \(x.usable) |\n"
        }
        return s
    }

    /// 拍号口径的一句话（帧率、漏帧）。
    static func tickBasis(fps: Double?, missing: [Int64]?, missingCount: Int?) -> String {
        var s = "拍号 = startTick + round((pts − 第一帧 pts) × \(fps.map { f($0, 3) } ?? "—") fps)"
        let m = missingSummary(missing, missingCount, label: "；文件里漏帧")
        s += m.isEmpty ? "；没有漏帧" : m + "（单独列，不挪转场落点）"
        return s
    }

    public static func markdown(_ r: SwitchesOutput) -> String {
        let t = r.switches
        var s = "**\(r.source)** 标称灰度：" + t.nominalGrays.map { "输入 \($0.inputID) = \(f($0.gray, 0))" }.joined(separator: "，") + "；容差 \(f(t.grayTolerance, 0))；startTick \(t.startTick)\n\n"
        s += tickBasis(fps: t.fps, missing: t.missingFrames, missingCount: t.missingFrameCount) + "\n\n"
        s += "| 帧 | 拍 | pts (s) | 从 | 到 | 类型 | 中间帧 | 中间漏拍 | 前一帧混合 | 该帧混合 | 后一帧混合 | 干净 Cut（V6） |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for w in t.switches {
            s += "| \(w.index) | \(w.tick) | \(f(w.ptsSeconds, 4)) | \(w.from.map(String.init) ?? "—") | \(w.to) | \(w.kind) | \(w.betweenFrames) | \(w.missingBetween.map(String.init) ?? "") | \(w.mixedBefore ? "是" : "否") | \(w.mixedAt ? "是" : "否") | \(w.mixedAfter ? "是" : "否") | \(w.kind == "cut" ? mark(w.cleanCut) : "—") |\n"
        }
        s += "\n所有 Cut 干净：\(mark(t.allCutsClean))\n"
        return s
    }

    public static func markdown(_ r: FadeOutput) -> String {
        let t = r.fade
        var s = "**\(r.source)** A = \(f(t.grayA, 0))，B = \(f(t.grayB, 0))；比例 = (gray − A) / (B − A)\n\n"
        s += tickBasis(fps: t.fps, missing: t.missingFrames, missingCount: t.missingFrameCount) + "\n\n"
        for (i, fd) in t.fades.enumerated() {
            s += "Fade \(i + 1)：帧 \(fd.startIndex)–\(fd.endIndex)（拍 \(fd.startTick) 起），\(fd.direction)，混合 \(fd.mixedFrames) 帧，D = \(fd.durationTicks)，最大偏差 \(f(fd.maxDeviationFrames, 2)) 帧（进度误差 \(pct(fd.maxProgressError))），单调 \(fd.monotonic ? "是" : "否")，V7 \(mark(fd.passV7))"
            s += missingSummary(fd.missingFrames, fd.missingFrameCount, label: "；窗口里漏帧") + "\n\n"
            s += "| 帧 | 拍 | gray | 比例 | 进度 | 期望 | 偏差（帧） |\n|---|---|---|---|---|---|---|\n"
            for x in fd.samples {
                s += "| \(x.index) | \(x.tick) | \(f(x.gray, 1)) | \(f(x.ratio, 3)) | \(f(x.progress, 3)) | \(f(x.expectedProgress, 3)) | \(f(x.deviationFrames, 2)) |\n"
            }
            s += "\n"
        }
        if t.fades.isEmpty { s += "没有找到 Fade。\n" }
        s += "全部 V7 通过：\(mark(t.allPassV7))\n"
        return s
    }

    public static func markdown(_ r: AVOutput) -> String {
        let t = r.av
        var s = "**\(r.source)**"
        if let a = r.audio {
            s += " 音轨 \(f(a.sampleRate, 0)) Hz × \(a.channels)，起点 \(f(a.startSeconds, 4)) s，\(a.sampleCount) 样本"
            if let tl = a.timeline {
                s += "（\(tl.codec)；AVFoundation 解码起点 \(f(tl.avfoundationStartSeconds, 4)) s + 修正 \(f(tl.correctionSeconds * 1000)) ms = 容器偏移 \(f(tl.containerOffsetSeconds * 1000)) ms + 加回 priming \(tl.primingAddedBackSamples) 样本；"
                s += "\(tl.isFragmented ? "分片" : "非分片")、\(tl.hasEditList ? "有编辑列表 media_time \(tl.editListMediaTime ?? 0)" : "无编辑列表")、AVFoundation 裁了 \(tl.primingTrimmedSamples) 样本；--aac-priming \(tl.mode) → \(tl.applied) 口径）"
            }
        } else { s += " 没有音轨" }
        s += "\n\n| 项 | 值 |\n|---|---|\n"
        s += "| 闪光 / click / 配上 | \(t.flashCount) / \(t.clickCount) / \(t.matchedCount)（整秒拍 \(t.onSecond.count)，非整秒拍 \(t.offSecondCount)） |\n"
        s += "| 整秒拍配对（A2 / A3 口径，音频超前为正） | 均值 \(f(t.onSecond.meanMs)) ms，标准差 \(f(t.onSecond.stdMs)) ms，最大绝对值 \(f(t.onSecond.maxAbsMs)) ms |\n"
        s += "| 整秒拍漂移 | 斜率 \(f(t.onSecond.slopeMsPerSecond, 4)) ms/s × \(f(t.onSecond.spanSeconds, 1)) s = \(f(t.onSecond.driftOverSpanMs)) ms（A3 口径） |\n"
        s += "| 全部配对（只报不判） | 均值 \(f(t.meanMs)) ms，标准差 \(f(t.stdMs)) ms，最大绝对值 \(f(t.maxAbsMs)) ms，斜率 \(f(t.slopeMsPerSecond, 4)) ms/s |\n"
        if let c = r.timelines {
            s += "| 两种口径（整秒配对均值 / 最大） | AVFoundation 原生 \(f(c.avfoundation.meanMs)) / \(f(c.avfoundation.maxAbsMs)) ms；ffmpeg 口径（修正 \(f(c.ffmpegCorrectionMs)) ms）\(f(c.ffmpeg.meanMs)) / \(f(c.ffmpeg.maxAbsMs)) ms；采用 \(c.applied)（修正 \(f(c.appliedCorrectionMs)) ms） |\n"
        }
        s += "| A2（整秒配对最大绝对值 ≤ \(f(t.thresholdMs, 2)) ms） | \(mark(t.passA2)) |\n"
        if let d = r.discontinuities {
            s += "| 不连续（A1 第三项：跳变 > \(f(Double(d.threshold), 2)) 满幅，click ±\(f(d.marginMs, 1)) ms 排除） | \(d.count) 次（click 位置排除了 \(d.jumpsAtClicks) 次跳变，\(d.clickCount) 个 click，\(d.sampleCount) 样本）\(mark(d.passA1)) |\n"
        }
        if let n = t.note { s += "\n\(n)\n" }
        s += "\n| 闪光帧 | 拍 | 整秒 | 闪光 (s) | genTimeMs | click (s) | 偏移 (ms) |\n|---|---|---|---|---|---|---|\n"
        for p in t.pairs {
            s += "| \(p.flashIndex) | \(p.tick) | \(p.onSecondTick ? "●" : "") | \(f(p.flashTimeSeconds, 4)) | \(p.genTimeMs.map(String.init) ?? "—") | \(p.clickTimeSeconds.map { f($0, 5) } ?? "—") | \(p.offsetMs.map { f($0) } ?? "—") |\n"
        }
        if let d = r.discontinuities, !d.events.isEmpty {
            s += "\n不连续位置（前 \(d.events.count) 条\(d.truncated ? "，已截断" : "")）：" + d.events.map { "\(f($0.timeSeconds, 4)) s（样本 \($0.sampleIndex)，跳 \(f(Double($0.jump), 2))）" }.joined(separator: "；") + "\n"
        }
        return s
    }

    public static func markdown(_ r: AVMultiOutput) -> String {
        var s = "多文件对齐（A4）：" + r.sources.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "；") + "\n\n"
        for (i, p) in r.perFile.enumerated() {
            s += "[\(i)] 闪光 \(p.flashCount)、click \(p.clickCount)，整秒配对 \(p.onSecond.count) 对偏移均值 \(f(p.onSecond.meanMs)) ms，最大 \(f(p.onSecond.maxAbsMs)) ms（全部配对均值 \(f(p.meanMs)) ms）\n"
        }
        let m = r.multi
        s += "\nclick 取法：第一个配上 click 的文件（锚，通常是 [0] PGM）用它自己配的那个，其他文件取离锚最近的；闪光离锚 click 在半秒 ±1 帧内的事件只列不判（W1-A5）；"
        s += "判定事件里有文件在锚 ±0.5 s 内没有 click 算 A4 不过（W1-A6）\n"
        s += "\n| 事件 | " + r.sources.indices.map { "闪光[\($0)] (s)" }.joined(separator: " | ") + " | 闪光极差 (ms) | " + r.sources.indices.map { "click[\($0)] (s)" }.joined(separator: " | ") + " | click 极差 (ms) | 锚 | 判定 | 缺 click |\n"
        s += "|---|" + String(repeating: "---|", count: r.sources.count * 2 + 5) + "\n"
        for e in m.events {
            s += "| \(e.key) | " + e.flashTimes.map { $0.map { f($0, 4) } ?? "—" }.joined(separator: " | ") + " | \(e.flashSpreadMs.map { f($0) } ?? "—") | "
            s += e.clickTimes.map { $0.map { f($0, 5) } ?? "—" }.joined(separator: " | ") + " | \(e.clickSpreadMs.map { f($0) } ?? "—") | "
            s += "\(e.anchorFile.map { "[\($0)]" } ?? "—") | \(e.halfSecond == true ? "半秒，只列" : "●") | "
            s += (e.missingClickFiles ?? []).map { "[\($0)]" }.joined(separator: " ") + " |\n"
        }
        let half = m.halfSecondEventCount ?? 0
        s += "\n判定事件 \(m.events.count - half) 个（半秒事件 \(half) 个只列不判）：最大闪光极差 \(f(m.maxFlashSpreadMs)) ms，最大 click 极差 \(f(m.maxClickSpreadMs)) ms，阈值 \(f(m.thresholdMs, 2)) ms"
        if let n = m.missingClickEventCount, n > 0 { s += "；其中 \(n) 个有文件缺 click" }
        if let n = m.missingFlashEventCount, n > 0 { s += "；其中 \(n) 个有文件缺闪光" }
        if let n = m.unanchoredEventCount, n > 0 { s += "；没有锚（一个文件都没配上 click）的事件 \(n) 个只比闪光" }
        s += "：A4 \(mark(m.passA4))\n"
        if let n = m.note { s += "\n\(n)\n" }
        return s
    }
}
