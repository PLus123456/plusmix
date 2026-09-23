# W3C2 → 渲染器的主人（W3-B2 / 之后动 SwitcherRender 的会话）：着色器实际是构建时编好的 default.metallib（fast-math），RenderResources 的注释过时了

来源：W3-C2（prompt 65）做 Aux 全分辨率时拿渲染器的换算逐像素对照（报告 reports/w3-outputs-3.md §1 实验）。只是信息，不要求改东西。

## 看到的

- `RenderResources.swift` 第 32–33 行的注释说"`swift build` 只会把 .metal 原样拷进 bundle，这时读源码在运行时编译"，`ShaderLibrary.load` 的后备路径用 `mathMode = .safe`。
- 实际（Xcode 27 的 swiftbuild）：`Packages/*/.build/out/Products/Debug/SwitcherCore_SwitcherRender.bundle/Contents/Resources/default.metallib` 存在，
  `makeDefaultLibrary(bundle:)` 先成功，**运行时编译那条路根本不走**。default.metallib 是 Metal 编译器默认选项编的 = fast-math。
  App（Xcode 构建）同样是 default.metallib。
- 证据：把 Aux 的着色器（与 Compositor.metal 的 ycbcrToRGB / fetch 逐项相同）分别用 `.safe` / `.fast` / `.relaxed` 编，
  对一张随机色度的 1080p NV12 帧与 OfflineRenderer 的 PGM 比：`.safe` 有 12 / 2073600 像素差 1 LSB（单精度求值顺序不同、落在舍入边界上），`.fast` / `.relaxed` 逐像素相等。

## 影响

- V9 / V8 这些"逐电平精确"的结论是在 fast-math 下拿到的（仍然成立，只是和注释说的不是同一种编译）。
- W3-C2 的 Aux 着色器按 `.fast` 编，以跟渲染器逐像素相同；**渲染器哪天改成真的 `.safe`（或改了换算）**，
  `ExternalTests.AuxInputTests.testAux_inputWindowDrawsFullResolutionFrame`（色度噪声那一帧）会红——到时把 `AuxShaders.swift` 的 `mathMode` 跟着改。

## 建议

改注释即可（"swift build 与 Xcode 都会编成 default.metallib；运行时编译只在包里没有 metallib 时作后备"）。
若确实想要 `.safe` 的语义，得在 Package.swift 给 Metal 编译传 `-fno-fast-math`（SwiftPM 没有正式开关）或干脆总是运行时编译——那是渲染器的决定。
