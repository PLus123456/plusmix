// SwitcherISO —— ISO 分路录制（W3-C，设计方案 §8 录制行"ISO 分路录制每路一个 writer，同一拍起步，共用 PTS"）与磁盘保护（S7）。
//
// 一路 ISO = 契约里一个 `kind = .record、settings.source = .input(n)` 的输出（CONTRACTS.md §8：ISO = 同一拍发多条 startRecord）。
// 视频从哪来：引擎每拍挑帧的结果只在渲染线程的 RenderInputTable 里，输出层拿不到；所以在输入和引擎的帧槽之间放一个分流器
// `InputFrameTee`（FrameSlot 装饰器）：输入线程 push 一次，主槽（引擎挑帧、带到达余量）和每个分支各收到同一帧。
// `ISOFrameTap` 是 PGM 帧的消费者：每拍（RenderedFrame 到时）在自己的分支槽上按契约规则 latest(atOrBefore: 拍点) 挑这一路的帧，
// 换上这一拍的 tick / 拍点时刻交给该路的 Recorder —— 于是 ISO 文件与 PGM 文件在同一拍点网格上，PTS 共用、起点共用。
// 各路输入的尺寸 / 像素格式可以不同：VT 会话直接吃（探针：1080p H.264 会话对 720p BGRA / 4K NV12 / UYVY / full-range 都 encode 成功），
// 录出来的文件是节目尺寸。
//
// 音轨：组装方把该路的 Recorder 挂到 AudioTapSource.input(number:)（推子后、AFV 前，W1-D2 / G3 定），本模块不碰音频。
// 同一拍起停：`SharedTickPlanner` 给同一批（同一次 reconcile、或上一批的拍还在未来）的录制器同一个起始拍 / 边界拍。
// 磁盘保护：`RecordingDiskMonitor` 轮询录制器的剩余空间和失败原因，只报事件；停录制的是 Recorder 自己（写失败 / 低于下限 → .failed），
// 推流和渲染不在这条链上，天然不受影响；切备用目录由组装方按事件做（`RecordingFallback.url(for:directory:)`）。
import SwitcherContracts

/// 模块版本 = 契约版本。
public enum SwitcherISOInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
}
