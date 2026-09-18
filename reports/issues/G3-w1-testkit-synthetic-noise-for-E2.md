归属会话 / 分支：W1-A / w1-testkit（SwitcherTestKit 的 `SyntheticVideoInput`；底色枚举 `TestPattern.Background` 在契约里，加 case 要走提案）
发现于：G3 检查点 / scenarios/g3.json 10 分钟 L2 运行 / 提交 10942e4
现象：E2 码率遵从在 L2 运行的录制文件上量不出来：设定 6 Mbps，实际整段平均 0.101 Mbps（`ffprobe` 包表，36000 个视频包），
      10 s 滑窗"误差" 98.9%、1 s 峰值 0.035×。不是编码器的问题——合成源只有灰底 + 帧号块 + 闪光块，几乎没有信息量，
      VideoToolbox 的码率控制不会往目标码率填充。W1-E 的 E2 用例（`VideoEncoderTests`，噪声纹理）0.57% / 1.067×，
      W2-D 的 `MediaMTXTests.testE2E3`（`PatternFeeder.Texture.noise(amplitude: 24)`）0.61% / 1.050×，都过；
      但那两个是专项用例，测试标准 §3 的 E2 做法是"录制文件或 MediaMTX 落盘文件用 ffprobe 算"，L2 长跑里应该也能判。
      G3 的 gate3-report 现在对"平均码率 < 25% 设定"的情况标"本场景不适用"、以专项用例为准（reports/G3.md）。
复现步骤：`make gate3-run`，看 `.build/gate3/10min/packets-v.csv` 或 `ffprobe -show_entries format=bit_rate .build/gate3/10min/out.mov`。
严重级：S3（只影响 L2 / 长稳里 E2 的可判性；产品无影响）。
建议：`SyntheticVideoInput` 支持带噪声的底纹（`TestPattern.Background` 加 `.noise(level: UInt8, amplitude: UInt8, seed: UInt64)` 之类，零均值噪声叠在灰底上，
      这样 frameprobe 的中心灰度均值仍等于 level，V6 / V7 不受影响；帧号块 / ID 块 / 闪光块区域不加噪声）。
      `PatternFeeder.Texture.noise` 已经有 CPU 实现可以搬。契约要加 case，先写 docs/contract-changes/ 提案（编号 006）。
      落地后 G3Factory 的 8 路输入改成噪声底纹（振幅 24，与 W2-D 一致），gate3-report 去掉"不适用"分支。
