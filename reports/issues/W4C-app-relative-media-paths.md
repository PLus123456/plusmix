# W4C → App 会话（W3-E4 / w3-app-5 顺手，或 G5 走 App 胶水额度）：App 里图片 / 文件输入的相对路径按进程工作目录解析，不是相对节目文件

发现于：W4-C（prompt 72，分支 w4-docs，2026-09-27），做 Samples/ 三个样例节目时；本会话只准动 docs/ Samples/ README.md，没改代码。
严重级：S2（有绕过办法；节目照跑，只是图片那几路变占位）。

## 现象

- 节目文件里 `{"image": {"path": "assets/lyrics.png"}}`（或 `file` 的 `path`）写相对路径时：
  - **headless** 相对节目文件所在目录解析（`Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift` 第 226 行：`path.hasPrefix("/") ? path : showURL.deletingLastPathComponent()…`），`scenarios/g4-show.json` 旁边的 `g4-stinger.png` 就是这么用的；
  - **App** 把路径原样交给 `ImageInput` / `FileInput`（`App/Sources/Engine/InputFactory.swift` → `SwitcherInputs` 的 `ImageInput.decode` 用 `FileManager.fileExists(atPath:)`），
    也就是相对**进程工作目录**。Finder / Dock 起的 App 工作目录是 `/`，所以"节目 › 打开…"打开 `Samples/church/church.switcher.json` 后，
    5 号"歌词字幕"、6 号"台标"两路建不出来，`InputRuntime` 换成 `PlaceholderInput`，格子上显示 **"图片不存在：assets/lyrics.png"**，Stats 里这两路 fps = 0；其余合成源照跑。
- 复现（本会话实测，App = `make gen build-app` 的 Debug 构建，2026-09-27）：

```bash
# 在样例目录里起：两路图片 fps ≈ 30（能找到 assets/）
cd Samples/church && ../../.build/DerivedData/Build/Products/Debug/Switcher.app/Contents/MacOS/Switcher --show church.switcher.json --api-listen 127.0.0.1:8799
# 在仓库根起：5 / 6 号 fps = 0，格子显示"图片不存在：assets/lyrics.png"
.build/DerivedData/Build/Products/Debug/Switcher.app/Contents/MacOS/Switcher --show Samples/church/church.switcher.json --api-listen 127.0.0.1:8799
curl -s http://127.0.0.1:8799/api/v1/state | python3 -c 'import json,sys; s=json.load(sys.stdin)["stats"]; print({k: round(v["fps"]) for k, v in s["per_input"].items()})'
```

- 同类：`RecordSettings.directory` 的相对路径 App 已经有口径（挂到 `~/Movies/Switcher/` 下，`OutputRuntime.startRecordings` 第 274 行注释），
  输入的相对路径还没有。

## 建议修法（App 内约 10 行）

在建输入之前把 `.image(path:)` / `.file(path:…)` 的非绝对路径按**节目文件所在目录**解析（与 headless 同一条规则），节目文件没保存过（新建）时退到 `~/Movies/Switcher`：

- 位置：`App/Sources/Engine/InputRuntime.swift` 调 `factory.makeInput` 之前，或 `DefaultInputFactory.makeInput` 加一个 `baseDirectory: URL?` 参数由 `SwitcherSession` 从 `ShowDocuments.currentURL` 给；
- 只改交给输入对象的路径，`MixerState` / 节目文件里仍存相对路径（"另存为"到别的目录时素材要跟着搬，这一点写进 Samples/README.md 了）；
- 一条用例：节目文件在临时目录 A、图片在 A/assets/，App 工作目录设成别处，打开后该路 state = live、fps > 0。

修好之后把 Samples/README.md "相对路径"一节的临时办法删掉即可（那一段标了"App 修好前"）。
