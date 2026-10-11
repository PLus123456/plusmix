# frameprobe 多文件 A4：闪光落在半秒时各文件各自配"最近的 click"，20 µs 的差就选到不同的秒（G8 gate4 误报 999.979 ms）

归属会话 / 分支：W1-A 系（`Packages/SwitcherTestKit/Sources/SwitcherTestKit/Probe/FrameAnalysis.swift` 的 `avMulti` / `av`，`Tools/frameprobe`）
发现于：G8b（prompt 107，分支 `g8`）2026-10-11 的 `make gate4-run GATE4_CHECKPOINT=G8 …`（树 9815082，`.build/gate4/g8/`）
严重级：S3（工具误报；文件本身对齐——按整秒配对五个文件的 click 极差 0.187 ms）

## 现象

- 运行报告 reports/G8-run-g8.md 的 A4 行：`click 时刻极差最大 999.979 ms`，❌；闪光极差 0.000。600 个事件里只有 #491–#500 这 10 个超阈值，而且每次都是**同一个文件** `out.iso3.mov` 的 click 比其他四个早整整 1 s（`clickTimes: [495, 495, 495, 494.00002, 495]`，`flashTimes` 全是 494.5）。
- 这 10 个事件的闪光时刻都在 **xxx.5 s**（490–500 s 这段 PGM 是 59.94 fps 的 3 / 4 号源，闪光帧落在半秒，报告里"含 59.94 在播段的假象"那句说的就是它）。`avMulti` 的做法是每个文件各自用 `av` 把闪光配到**离它最近的 click**，再按事件键比较各文件的 click 时刻：闪光在 494.5、click 在整秒，前后两个 click 各差 500 ms——**平局**。iso3 的 click 比别的文件晚 20 µs（音频输入 3 的消费者流重采样 +100 ppm，`494.00002` / `495.00002`），于是它的"最近"是 494.00002（499.98 ms），别的文件是 495.0（恰好 500 ms、按实现取后一个），差 1 s 不是对齐差、是选到了不同的秒。
- 另：iso3 检出 592 个 click、其他文件 593 个——第 500 s 的 click 没检出（ffmpeg 解出来那一秒峰值 1.584、在 +0.0 ms，声音是在的），也与 +20 µs 的偏移落在检测窗边上有关。
- 文件本身没问题：headless 收尾打印四路 ISO 都是"音频漂移 −0.010 ms 硬校正 0、tap 丢 0"，stats.jsonl 全程 dropouts / underruns / 不连续 0；用 `perFile[*].pairs` 的 click 时刻按整秒各取最近的一个比较，600 秒里**最大极差 0.187 ms（第 1 秒）**，没有一秒超过 1 帧——与 G7 / W1-D3 自己那轮 gate4 的 A4（0.188 ms）一样。

## 复现

```bash
# 任何 gate4 产物（五个文件）：
python3 - <<'PY'
import json; d=json.load(open('.build/gate4/g8/probe-av-multi.json'))
print([e for e in d['multi']['events'] if (e.get('clickSpreadMs') or 0) > 16.67][:3])
PY
```
要稳定复现：PGM 上放 59.94 fps 源（闪光落在半秒），其中一路 ISO 的 click 比别的晚 / 早几十微秒（±100 ppm 的消费者流就够）。

## 建议

1. `avMulti` 的 click 不要各文件独立配"最近"：以第一个文件（PGM）配到的 click 时刻为锚，其他文件取**离这个锚最近**的 click（容差 ≤ 1 帧）；或者统一向后取（flash 之后第一个 click），平局时各文件一致。
2. 闪光在半秒的事件（|flash − round(flash)| ≈ 0.5）A2 那边已经按"整秒配对"过滤了，A4 也该只用整秒事件比较、半秒事件只列不判。
3. 检测窗边上漏掉的 click（iso3 第 500 s）：看一下 `ClickEvent` 检测的窗口对齐（是否按整秒切窗、+20 µs 落到下一窗）。
4. 修好后 G8 的产物在 `.build/gate4/g8/`（不入库）可直接重算；G8b 本轮按上面的整秒配对结论对 A4 `--waive`（reports/G8.md §5）。
