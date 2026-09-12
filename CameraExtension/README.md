# CameraExtension（虚拟摄像头，CMIO 系统扩展）

W3-C 会话在这里实现 CMIO Camera Extension，把 PGM 的 NV12 IOSurface 作为一路系统摄像头提供给其他 App（设计方案 §8）。

现状：空目录。project.yml 里**还没有**这个 target——W3-C 加（落地方案 §2 把 `project.yml 的扩展 target` 划给了它）。

前置条件（落地方案 §6）：
- Apple Developer Program 付费账号 + Team ID（系统扩展必须签名，ad-hoc 不能激活）。
- 主 App 要带 `com.apple.developer.system-extension.install` 权限，并从 `/Applications` 运行才能激活扩展。
