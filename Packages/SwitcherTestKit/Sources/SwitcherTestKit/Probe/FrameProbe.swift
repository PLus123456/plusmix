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
        public init() {}
    }

    /// 读进来的一个源。
    public struct Loaded: Sendable {
        public var source: String
        public var info: ProbeVideoInfo
        public var frames: [ProbeFrame]
        public var audio: ProbeAudioInfo?
        public var clicks: [ClickEvent]
        /// 节目帧率（选项或标称）。
        public var fps: Double
    }

    /// 读文件（.mov / .mp4）或原始 NV12 目录；`withAudio` 才读音轨找 click。
    public static func load(_ url: URL, options: Options, withAudio: Bool) async throws -> Loaded {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let r = try MediaReader.readRawNV12Directory(url: url, width: options.rawWidth, height: options.rawHeight, fps: options.fps ?? options.rawFps)
            return Loaded(source: url.path, info: r.info, frames: r.frames, audio: nil, clicks: [], fps: options.fps ?? options.rawFps)
        }
        let v = try await MediaReader.readVideo(url: url)
        var audio: ProbeAudioInfo?
        var clicks: [ClickEvent] = []
        if withAudio, let a = try await MediaReader.readAudio(url: url) {
            audio = a.info
            clicks = ClickDetector.detect(samples: a.samples, sampleRate: a.info.sampleRate, startSeconds: a.info.startSeconds)
        }
        let fps = options.fps ?? (v.info.nominalFps > 0 ? v.info.nominalFps : 60)
        return Loaded(source: url.path, info: v.info, frames: v.frames, audio: audio, clicks: clicks, fps: fps)
    }

    // MARK: 报告

    public struct FramesReport: Codable, Sendable {
        public var source: String
        public var info: ProbeVideoInfo
        public var frameCount: Int
        public var frames: [ProbeFrame]
        public var truncated: Bool
    }
    public struct StatsOutput: Codable, Sendable {
        public var source: String
        public var info: ProbeVideoInfo
        public var stats: FrameAnalysis.StatsReport
    }
    public struct SwitchesOutput: Codable, Sendable {
        public var source: String
        public var switches: FrameAnalysis.SwitchesReport
    }
    public struct FadeOutput: Codable, Sendable {
        public var source: String
        public var fade: FrameAnalysis.FadeReport
    }
    public struct AVOutput: Codable, Sendable {
        public var source: String
        public var audio: ProbeAudioInfo?
        public var av: FrameAnalysis.AVReport
    }
    public struct AVMultiOutput: Codable, Sendable {
        public var sources: [String]
        public var perFile: [FrameAnalysis.AVReport]
        public var multi: FrameAnalysis.MultiFileAVReport
    }

    public static func frames(_ url: URL, options: Options = Options()) async throws -> FramesReport {
        let l = try await load(url, options: options, withAudio: false)
        let limited = options.limit.map { Array(l.frames.prefix($0)) } ?? l.frames
        return FramesReport(source: l.source, info: l.info, frameCount: l.frames.count, frames: limited, truncated: limited.count < l.frames.count)
    }

    public static func stats(_ url: URL, options: Options = Options()) async throws -> StatsOutput {
        let l = try await load(url, options: options, withAudio: false)
        return StatsOutput(source: l.source, info: l.info, stats: FrameAnalysis.stats(frames: l.frames, programFps: l.fps, inputFps: options.inputFps, maxEvents: options.maxEvents))
    }

    public static func switches(_ url: URL, options: Options = Options()) async throws -> SwitchesOutput {
        let l = try await load(url, options: options, withAudio: false)
        return SwitchesOutput(source: l.source, switches: FrameAnalysis.switches(frames: l.frames, startTick: options.startTick, grayTolerance: options.grayTolerance))
    }

    public static func fade(_ url: URL, options: Options = Options()) async throws -> FadeOutput {
        let l = try await load(url, options: options, withAudio: false)
        let r = FrameAnalysis.fade(frames: l.frames, grayA: options.grayA, grayB: options.grayB, durationTicks: options.fadeDuration,
                                   at: options.fadeAt, tolerance: options.fadeTolerance, startTick: options.startTick)
        return FadeOutput(source: l.source, fade: r)
    }

    public static func av(_ url: URL, options: Options = Options()) async throws -> AVOutput {
        let l = try await load(url, options: options, withAudio: true)
        return AVOutput(source: l.source, audio: l.audio, av: FrameAnalysis.av(frames: l.frames, clicks: l.clicks, frameDurationSeconds: 1 / l.fps))
    }

    public static func avMulti(_ urls: [URL], options: Options = Options()) async throws -> AVMultiOutput {
        var loaded: [Loaded] = []
        for u in urls { loaded.append(try await load(u, options: options, withAudio: true)) }
        let fps = loaded.first?.fps ?? 60
        let per = loaded.map { FrameAnalysis.av(frames: $0.frames, clicks: $0.clicks, frameDurationSeconds: 1 / fps) }
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

    public static func markdown(_ r: SwitchesOutput) -> String {
        let t = r.switches
        var s = "**\(r.source)** 标称灰度：" + t.nominalGrays.map { "输入 \($0.inputID) = \(f($0.gray, 0))" }.joined(separator: "，") + "；容差 \(f(t.grayTolerance, 0))；startTick \(t.startTick)\n\n"
        s += "| 帧 | 拍 | pts (s) | 从 | 到 | 类型 | 中间帧 | 前一帧混合 | 该帧混合 | 后一帧混合 | 干净 Cut（V6） |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
        for w in t.switches {
            s += "| \(w.index) | \(w.tick) | \(f(w.ptsSeconds, 4)) | \(w.from.map(String.init) ?? "—") | \(w.to) | \(w.kind) | \(w.betweenFrames) | \(w.mixedBefore ? "是" : "否") | \(w.mixedAt ? "是" : "否") | \(w.mixedAfter ? "是" : "否") | \(w.kind == "cut" ? mark(w.cleanCut) : "—") |\n"
        }
        s += "\n所有 Cut 干净：\(mark(t.allCutsClean))\n"
        return s
    }

    public static func markdown(_ r: FadeOutput) -> String {
        let t = r.fade
        var s = "**\(r.source)** A = \(f(t.grayA, 0))，B = \(f(t.grayB, 0))；比例 = (gray − A) / (B − A)\n\n"
        for (i, fd) in t.fades.enumerated() {
            s += "Fade \(i + 1)：帧 \(fd.startIndex)–\(fd.endIndex)（拍 \(fd.startTick) 起），\(fd.direction)，混合 \(fd.mixedFrames) 帧，D = \(fd.durationTicks)，最大偏差 \(f(fd.maxDeviationFrames, 2)) 帧（进度误差 \(pct(fd.maxProgressError))），单调 \(fd.monotonic ? "是" : "否")，V7 \(mark(fd.passV7))\n\n"
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
        if let a = r.audio { s += " 音轨 \(f(a.sampleRate, 0)) Hz × \(a.channels)，起点 \(f(a.startSeconds, 4)) s，\(a.sampleCount) 样本" } else { s += " 没有音轨" }
        s += "\n\n| 项 | 值 |\n|---|---|\n"
        s += "| 闪光 / click / 配上 | \(t.flashCount) / \(t.clickCount) / \(t.matchedCount) |\n"
        s += "| 偏移（音频超前为正） | 均值 \(f(t.meanMs)) ms，标准差 \(f(t.stdMs)) ms，最大绝对值 \(f(t.maxAbsMs)) ms |\n"
        s += "| 漂移 | 斜率 \(f(t.slopeMsPerSecond, 4)) ms/s × \(f(t.spanSeconds, 1)) s = \(f(t.driftOverSpanMs)) ms（A3 口径） |\n"
        s += "| A2（≤ \(f(t.thresholdMs, 2)) ms） | \(mark(t.passA2)) |\n\n"
        s += "| 闪光帧 | 闪光 (s) | genTimeMs | click (s) | 偏移 (ms) |\n|---|---|---|---|---|\n"
        for p in t.pairs {
            s += "| \(p.flashIndex) | \(f(p.flashTimeSeconds, 4)) | \(p.genTimeMs.map(String.init) ?? "—") | \(p.clickTimeSeconds.map { f($0, 5) } ?? "—") | \(p.offsetMs.map { f($0) } ?? "—") |\n"
        }
        return s
    }

    public static func markdown(_ r: AVMultiOutput) -> String {
        var s = "多文件对齐（A4）：" + r.sources.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "；") + "\n\n"
        for (i, p) in r.perFile.enumerated() {
            s += "[\(i)] 闪光 \(p.flashCount)、click \(p.clickCount)，偏移均值 \(f(p.meanMs)) ms，最大 \(f(p.maxAbsMs)) ms\n"
        }
        let m = r.multi
        s += "\n| 事件 | " + r.sources.indices.map { "闪光[\($0)] (s)" }.joined(separator: " | ") + " | 闪光极差 (ms) | " + r.sources.indices.map { "click[\($0)] (s)" }.joined(separator: " | ") + " | click 极差 (ms) |\n"
        s += "|---|" + String(repeating: "---|", count: r.sources.count * 2 + 2) + "\n"
        for e in m.events {
            s += "| \(e.key) | " + e.flashTimes.map { $0.map { f($0, 4) } ?? "—" }.joined(separator: " | ") + " | \(e.flashSpreadMs.map { f($0) } ?? "—") | "
            s += e.clickTimes.map { $0.map { f($0, 5) } ?? "—" }.joined(separator: " | ") + " | \(e.clickSpreadMs.map { f($0) } ?? "—") |\n"
        }
        s += "\n最大闪光极差 \(f(m.maxFlashSpreadMs)) ms，最大 click 极差 \(f(m.maxClickSpreadMs)) ms，阈值 \(f(m.thresholdMs, 2)) ms：A4 \(mark(m.passA4))\n"
        return s
    }
}
