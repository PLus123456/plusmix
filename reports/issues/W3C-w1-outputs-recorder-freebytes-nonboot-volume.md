# W3-C → W1-E（Recorder）：`Recorder.freeBytes` 在非启动卷上是 0，录到磁盘镜像 / 外置盘会立刻按"低于下限"失败

提出：W3-C（2026-09-19，做 S7 磁盘保护时）。归属：`Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/Recorder.swift`（W1-E），三行改动，建议 G4 按胶水额度直接修。

## 现象

`Recorder.freeBytes(for:)` 只读 `volumeAvailableCapacityForImportantUsageKey`，读到就返回（哪怕是 0）。探针（W3-C 报告 §1 探针 3）：macOS 26.6.2 上
`hdiutil create -size 50m` 的 HFS+ 和 APFS 镜像，这个键都给 **0**，`volumeAvailableCapacity` / `systemFreeSize` 给 51 MB。
"Important usage" 是启动卷的概念（含可清理空间），非启动卷系统不算。于是：
- `Recorder.start` 里 `free < minimumFreeBytes`（默认 200 MB）→ 直接抛 `diskFull(freeBytes: 0)`，录制起不来；
- `RecorderCounters.diskFreeBytes` 恒为 0 → `Stats.encoder[i].disk_free_mb` 报 0。
W1-E 自己的磁盘测试把 `minimumFreeBytes` 设成 0 所以没撞上。外置 U 盘 / 移动硬盘（S7 "慢 U 盘"用例、用户把录制目录指到外置盘）大概率同样（本机没有外置盘，未验证）。

## 建议改法（Recorder.freeBytes）

```swift
if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
    if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
    if let available = v.volumeAvailableCapacity, available > 0 { return UInt64(available) }
}
// 再退到 attributesOfFileSystem 的 systemFreeSize（原有代码）
```

## W3-C 这边的处理

- `SwitcherISO.DiskGuard.freeBytes(for:)` 按上面的顺序算；`RecordingDiskMonitor` 自己算剩余空间、按每路下限报 `.belowMinimum`，由组装方停那一路；
- App 建 Recorder 时 `minimumFreeBytes: 0`（下限交给监视器），Stats 里 idle 录制输出的 `disk_free_mb` 改用 `DiskGuard.freeBytes`；
  **在跑的录制器的 `disk_free_mb` 仍是 Recorder 算的（非启动卷上 0）**，等 Recorder 修好自然对。
