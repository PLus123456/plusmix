# Tests/Fixtures/ —— 跨包共用的测试素材

放在仓库根、不属于任何 SwiftPM 包，因为它们跨包共用：W1-A（frameprobe 回归样例，20 秒 H.264）和 W1-E（pattern.mov，10 秒含 click 音轨）产出，W2-A 的文件输入用它们当测试素材。

规矩：每个文件 ≤ 5 MB；`.gitignore` 对 `*.mov` / `*.mp4` 全局忽略，只对本目录放行。测试里定位路径用 `#filePath` 往上找仓库根，不要写绝对路径。
