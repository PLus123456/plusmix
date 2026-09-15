// SwitcherInputs —— 输入一期（W2-A）：摄像头 / UVC（CameraInput）、屏幕（ScreenInput）、文件（FileInput）、图片（ImageInput）。
//
// 共同规则（设计方案 §3.6、§6；CONTRACTS.md §2.3、§2.4、§6 T8）：
// - 每路输入自带线程，只往组装方注入的 `FrameSlot` / `AudioRing` 里写，从不碰渲染线程和音频线程；
//   帧槽 / 环由组装方（headless / App / 测试）创建，这个包看不到它们的实现。
// - 每帧 `Frame.pts` = 采集时刻换算成 host time（摄像头经 CMSyncConvertTime，屏幕直接是 host clock，文件 = 时钟从属的位置，
//   图片 = 拍点）；`ingressTime` = push 前一刻的 `HostClock.now()`。音频块 `write(hostTime:)` = 块首样本时刻。
// - 无信号：期望帧间隔 × N（默认 3）没新帧 → `noSignal`，帧槽保留最后一帧（NoSignalWatchdog）。
// - 热插拔：AVCaptureDevice 连接 / 断开通知；断开进 noSignal，回来自动重建会话，编号和 InputSettings 不变。
// - 权限：未授权 → `.error(message:)`（文案指到系统设置），之后轮询授权状态，授权后自动恢复，不用重启。
// - 输入线程可以锁、可以分配（它们不是实时线程）；帧槽 push / 环 write 本身是无锁的。
//
// 输入需要知道节目时钟（`ProgramTiming`：格式 + 拍点时钟）：摄像头按节目帧率协商格式，屏幕默认跟节目帧率，
// 文件把播放位置锚到拍点，图片每拍把 pts 刷新为拍点。组装方在引擎 start 之前定 t0，传给输入。
import SwitcherContracts

/// 包版本标记（与契约同源）。
public enum SwitcherInputsInfo {
    /// 编译时链接的契约版本。
    public static let contractsVersion = SwitcherVersion.current
}
