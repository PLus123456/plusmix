# W4-B2 → W4-C（docs/user 的归属）：用户手册 4 处还写"FaceTime 里选 "Switcher" 摄像头（0.1.0 里设备名仍是代码名）"，设备名已经是 PlusMix

发现于：W4-B2（prompt 83，分支 w4-release-2，2026-09-28），改 docs/release 里同样的两句时。
严重级：S3（只是文档；但用户照着找 "Switcher" 摄像头会找不到，以为扩展没装好）。

## 现象

改名合入后 G5 已把 `Packages/SwitcherOutputs/Sources/VirtualCamera/Shared/VirtualCameraConstants.swift` 的设备 / 流名改成产品名（提交 2bc4088：
`deviceName = "PlusMix"`、`deviceModel = "PlusMix Virtual Camera"`、流名 `PlusMix Program` / `PlusMix Program Sink`），FaceTime / QuickTime 里摄像头叫 "PlusMix"。
用户手册还按 W4-D 当时的现状写着代码名：

| 文件:行 | 现在写的 |
|---|---|
| `docs/user/输出.md:99` | 在 FaceTime / QuickTime 新建影片录制里选 "Switcher" 摄像头（0.1.0 里设备名仍是代码名 Switcher）。 |
| `docs/user/en/outputs.md:110` | Pick the "Switcher" camera in FaceTime / QuickTime › New Movie Recording (in 0.1.0 the device is still named after the code name, Switcher). |
| `docs/user/故障排查.md:62` | 激活后 FaceTime 里没有 "Switcher" 摄像头（0.1.0 里虚拟摄像头的设备名仍是代码名 Switcher） |
| `docs/user/en/troubleshooting.md:63` | no "Switcher" camera in FaceTime after activation (in 0.1.0 the virtual camera device is still named after the code name, Switcher) |

docs/release 里的同一句（signing.md 干净机器验证第 3 步、checklist-first-signed-run.md 虚拟摄像头一条）本会话已改成 "PlusMix"（提交 5767a30）；
docs/user 按 docs/OWNERSHIP.md 的 w4-release-2 行只准动 Application Support 目录名那几行，这 4 行没动。

## 修法

四处的 "Switcher" → "PlusMix"，删掉括号里"仍是代码名"那半句；`python3 docs/tools/check-links.py`（或 `scripts/check-links.sh`）复查。约 4 行，
W4-C 续做或检查点走胶水额度都行。
