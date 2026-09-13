// SwitcherTestKit —— 测试工装（W1-A，测试标准 §2.1–2.4、§9 第 1 条）。
//
// 目录：
//   Threading/   RealtimeThread（time-constraint 策略 + mach_wait_until）、SPSCQueue、SplitMix64
//   Synthetic/   SyntheticTimeline（共用 t0）、SyntheticVideoInput、SyntheticAudioInput、NV12PixelBufferPool
//   Doubles/     TestKitFrameSlot / TestKitAudioRing：契约协议的测试替身（真实现在 W1-B / W1-D）
//   Stats/       StatsWriter（SPSC → 写线程 → stats.jsonl）、StatsSummary（avg / p99 / max、§4 判定、§7 表格）
//   Scenario/    ScenarioRunner（按拍发命令，拍由引擎回调驱动）
//   Probe/       frameprobe 的核心：MediaReader、ClickDetector、FrameAnalysis、FrameProbe（命令行只是壳）
//   Fixture/     SampleMovieWriter：VideoToolbox H.264 + 音轨写 .mov（只为测试素材，不依赖 W1-E）
//
// 线程规则：合成源线程不是"实时线程"意义上的渲染 / 音频线程（设计方案 §3.2、§3.5 管的是那两条），
// 但每帧 / 每块仍然不分配：像素缓冲来自预热的池，音频块来自预分配的缓冲区（见各文件说明）。
import SwitcherContracts

/// 本包与契约同版本。
public enum SwitcherTestKitInfo {
    /// 等于 `SwitcherVersion.current`。
    public static let version = SwitcherVersion.current
}
