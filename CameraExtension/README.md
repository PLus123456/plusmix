# CameraExtension（虚拟摄像头，CMIO 系统扩展）

W3-C 实现：`Sources/` 是 CMIOExtension API 的 provider → 设备 → 两条流（source 给别的 App 读、sink 给主程序写），
设备名 / UID / 流 UID 等常量在 `Packages/SwitcherOutputs/Sources/VirtualCamera/Shared/`（project.yml 按路径编进本 target，主程序那边的 SwitcherVirtualCamera 也编它）。

- project.yml 的 target `SwitcherCameraExtension`（type system-extension，产品名 = bundle ID `com.plusmix.switcher.camera-extension`），
  嵌在 Switcher.app/Contents/Library/SystemExtensions/。`make gen` / `make build` 一起编。
- 主程序侧：`SwitcherVirtualCamera` 的 `VirtualCameraOutput`（PGM 帧 → sink stream）和 `SystemExtensionInstaller`（激活 / 卸载）。
- 帧的路：主程序 CMIOStreamCopyBufferQueue + CMSimpleQueueEnqueue → 扩展 `consumeSampleBuffer` → `sourceStream.send`（不拷像素，PTS = 拍点 host time）。
  主程序没在送时扩展自己产 30 fps 的占位画面（深灰 + 移动白条）。
- 回报"已输出"（W3-C3）：主程序给每帧挂 CMIO 序号；扩展发出去之后 `sinkStream.stream.notifyScheduledOutputChanged(序号, 此刻)`，
  主程序在 sink stream 的 'sonp' 回调里按序号跳号记扩展丢的帧（`VirtualCameraOutput.countersSnapshot.droppedExtension` → Stats 的 dropped）。
  扩展自己丢的帧不回报。第一次签名跑通时怎么看：reports/issues/W3C2-camera-extension-scheduled-output.md 末节、reports/w3-outputs-4.md §3。
- 扩展里的文字（日志、设备 / 流名、Info.plist 的显示名）用英文 / ASCII：`make test` 里 VirtualCameraTests 的 SourceLanguageTests 扫本目录。

前置条件（落地方案 §6）：
- Apple Developer Program 付费账号 + Team ID（`DEVELOPMENT_TEAM=XXXXXXXXXX make gen`）。系统扩展必须由 Apple 签发的证书签名，ad-hoc 不能激活。
- 主 App 带 `com.apple.developer.system-extension.install`（App/Switcher.entitlements），从 `/Applications` 运行才能激活。
- `systemextensionsctl developer on` 在 macOS 26.6.2 上仍要求关 SIP（实测：`At this time, this tool cannot be used if System Integrity Protection is enabled`）。
  替代验证路径见 `SystemExtensionInstaller` 的类型注释和 reports/w3-outputs2.md。
