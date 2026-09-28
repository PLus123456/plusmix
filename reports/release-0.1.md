# G5 发布门槛会话报告（分支 release/0.1；正式检查点报告在 reports/G5.md）

worktree `.claude/worktrees/g5-release-checklist-4c8044`，桌面端起的分支 `claude/g5-release-checklist-4c8044` 改名 `release/0.1`（OWNERSHIP 的 G5 行按这个名字查归属），从 main `da44bec` 开，2026-09-28。
分支名里的 `/` 换成 `-` 就是本文件名（reports/README.md 的规矩）。

## 1. 做了什么

1. **合并**（都 `--no-ff`，顺序 App → 脚本 → 发布工程 → 文档）：W3-E4 `claude/w3-app-5-virtual-camera-47bf08`（489590e，prompt 73 批开、完成未合并，W4-C 的手册按它写，所以一起进发布分支）→ W4-A `w4-soak`（1b5caf9）→ W4-B `w4-release`（6dc19ab）→ W4-C `w4-docs`（27509c4）。
   唯一冲突 Makefile 末尾（W4-A 三个目标 vs W4-B 的 `-include`），两段都留（6249187）。两份 Localizable.strings 自动合并、查过无重复键。检查点自己 0 行代码胶水。
2. **L0 / L1 全量**：六包 `swift test` → 两工具冒烟 → `make gen` → headless 9 条 → App `xcodebuild test`（不带 -quiet，逐用例入日志）；release 版 frameprobe 编好后补跑 Outputs 里 5 条 BLOCKED-工具 的用例。
3. **L2**：`scripts/gate4.sh --minutes 10 --label g5 --baseline baselines/g4-m5max.json`（不写基线）；运行报告改名 reports/G5-run-10min.md，脚本顺手重拼的 reports/G4.md 撤回。
4. **L5**：`scripts/perf/perf-baseline.sh --label g5 --powermetrics off --report reports/G5-perf-m5max-macos27.md`，与 W4-A 的 baselines/perf-m5max-macos27.json 比。
5. **第 6 条**：`make archive-adhoc` + `make release-test`，读 verify.json（spctl 在 ad-hoc 上必 rejected：BLOCKED-账号）。
6. **1 小时 soak 交叉验证**：`scripts/soak/soak.sh --hours 1 --label g5-1h --powermetrics off --report reports/G5-soak-1h.md`（非交互：不接摄像头）。
7. **docs/KNOWN_ISSUES.md**（从模板建）、reports/G5.md（§7 模板 + 六条逐条判定 + 阻塞项归属 + 发布说明草稿）、本报告。
8. 没做的：打 tag、改版本号（判定不发）。main 的快进用户看完报告后指示做了（§3 第 2 条）。
9. **用户 2026-09-28 的后续指示**：(a) OWNERSHIP 认领 W4-A / W4-B 越界；(b) 泄漏修复派 agent 直接做 → W2-A3（prompt 74，分支 w2-inputs-3）当天修完、`--no-ff` 合入 release/0.1（e39dda3）；(c) 产品名定 PlusMix、bundle id 前缀 com.plusmix → `set-bundle-id.sh com.plusmix` 切成 `com.plusmix.switcher`（10 个文件），改名本身写成 prompt 75（W4-D）；合入与切换后的验证：`make gen build`、VirtualCameraTests / FileInputTests、App 全量、`make release-test`（结果见 §2 末行）。

10. **用户 2026-09-28 下午："改名也派个 agent 做吧，另外查到的那些 bug 依次派个 agent 干了，之后全都合进 main"**：本会话依次派 agent、检查、`--no-ff` 合入 release/0.1、快进 main。记录（合入顺序）：
    - W4-D 改名 PlusMix（w4-rename = bd03b15 → 合入 023e138）：63 文件；agent 自验 App 92 用例 88 过 0 失败 4 跳、archive-adhoc 出 PlusMix.app / PlusMix-0.1.0.dmg、release-test 9 / 10（R11 已知）、check-links 119、lint 全绿；检查点顺手改 VirtualCameraConstants 的 4 个设备 / 流名（2bc4088，VirtualCameraTests 12 / 12），把 release.yml 产物名、Application Support 目录名 / MIDI 客户端名 / serverName、App 侧跟改分别加进 prompt 83 / 78 / 79。
    - W2-A4 文件输入空拍 / 饿死（w2-inputs-4 = 52cdfee → 合入 8760ce5）：ProRes 1080p60 循环 20 圈空拍 2 → 0，速率 8 十秒 7 圈 → 401 圈、lateWakes 298 万 → 0，fileprobe 466 Mb/s ProRes 300 s starved 128 → 0；Inputs 109 用例 0 失败；lateWakes / framesRejected 口径变了（8 小时数据别直接比）。
    - W2-D2 推流首秒音频（w2-stream-2 = a702956 → 合入 f8fabbf）：长稳那 47 包其实是 headless 音频引擎早起 1 s 被起步对齐裁掉、错在计进 audioDropped；真问题是 App 顺序下握手期间的帧 / 包直接丢。修：start 起就缓冲、两轨从第一个送出的关键帧同一原点起送，原点之前记 before-start 不算丢。RTMP App 顺序用例丢 29 / 22 → 0 / 0、落盘从帧号 0；MediaMTX 六条全过；Outputs 105 用例 0 失败。
    - W2-C2 MIDI 热插拔 + 控制包产品名（w2-control-2 = 0f05e36 → 合入）：CoreMIDI 通知放到进程级常驻线程 + 永不销毁的锚客户端；新用例修前 15 处断言失败 → 修后三轮全过；UserConfig 目录 / MIDI 客户端名 / API serverName → PlusMix；Control 58 用例 0 失败；App 侧 LastSession 路径与文档旧路径分别加进 prompt 79 / 83。
    - W3-E5 App 相对路径 / 状态行 / LastSession（w3-app-6 = cd72bfe → 合入）：相对路径相对节目文件（用例修前占位 fps 0 → 修后 live）、状态行按 output 对号、LastSession 进 UserConfig 目录、删 MIDINotificationAnchor；App 95 用例 94 过 0 失败 1 跳（摄像头权限这轮由系统对话框给了、那条真跑过）。
    - W1-B3 启动停顿 / 突发跳拍（w1-core-3 = 98ee850 → 合入）：停顿根因在 App 启动顺序（时钟起在 t0 之后 472 ms），引擎加 warmUp() / clockStartLag、渲染器首帧空渲染，App 顺序归 W3-E6（prompt 84）；突发跳拍是系统突发让整个进程非实时线程和 GPU 一起停 100 ms，加完成线程实时策略与 skipped 归因；gate4 w1b3 第二次 19 / 19（V1 1.993、V2 0）、第一次 V2 = 8 一次突发；Core 三包 0 失败、参考图一张没动。
    - W3-E6 App 启动顺序（w3-app-7 = e0960b3 → 合入，Opus）：预热完再定 t0；真 App 冷启动 clockStartLag 491–507 ms / missed 29–30 → 0 / 0；App 99 用例 97 过 0 失败 2 跳。MIDI 冷启动（第一次连 MIDIServer 约 0.6 s）仍在主线程，只是不再拖时钟。
    - W1-A4 frameprobe 内存（w1-testkit-4 = 2af7b53 → 合入，Opus）：根因不是缺池而是多声道音频每块 reserveCapacity 的 O(n²) 重拷；10 分钟录像峰值 7.6 GB → 172 MB、1 小时 41 GB → 795 MB，输出逐字节相同；TestKit 71 用例 0 失败。
    - W4-B2 发布脚本收尾（w4-release-2，Opus）：进行中。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

全表在 reports/G5.md §5；这里只列结论：

| 项 | 结果 |
|---|---|
| L0 / L1 六包 | 703 个用例：0 失败；跳 26 → 补跑 5 条后 **682 过、21 跳、0 失败**（补跑的 E7 / E8 / RTMP / SRT / A4 全过） |
| App | 90 个：88 过、0 失败、2 跳（摄像头 TCC、扩展签名） |
| L2 10 分钟 g5 | ✅ 20 项全过（V1 2.067 / 2.481 ms、V2 0、V4 设计外 0、V7 ≤ 0.252 帧、A2 0.000 ms、A4 0.208 ms、C1 50 / 50、C3 / C4 0） |
| L4 8 小时（W4-A） | S1 ✅、A3 ✅（0.00 ms）、**S2 ❌ 60.8 MB/h**、S3 CPU ❌ 60.1%（用户定不阻塞）；1 小时交叉验证 ✅（S1 13 / 13 窗口、A3 0.00 ms、CPU 54.6%；S2 参考 87 MB/h 同一根因） |
| L5 | ✅ 无退步（g5b：V1 1.919 / 2.415 ms、CPU 42.0%、GPU 31.8%、VMAF 91.005，全部等于或好于基线；脚本因 V3 p99 +52 µs、GPU p95 +4 pt 退出 1 = W4-A 已记的误报，第一次 g5 被桌面抢 GPU 不采信） |
| 第 6 条 | ad-hoc 归档走通、`make release-test` 10 / 10 过；spctl rejected / 公证 / staple / Sparkle 装更新 = **BLOCKED-账号 / 签名** |
| bundle id 切换 + W2-A3 合入后的验证（13:30–13:38） | `make gen build` 过；VirtualCameraTests 12 / 12；FileInputTests 12 / 12（S2 用例 20.4 → 20.5 MB、0.002 MB/圈）；App 90 = 88 过 2 跳 0 失败（宿主已是 com.plusmix.switcher）；`make release-test` **9 / 10**：R1 归档 verify.json 的 bundle_id = com.plusmix.switcher、R11 一条断言写死占位前缀 com.example 而红（issue G5-w4-release-r11-assumes-placeholder-prefix，S3，W4-B 一行修） |
| lint / check-links / pin-deps | 全绿 |

**判定：不发**（硬性项 L4 S2 红；L3 有 S1；无签名账号）。

## 3. 没做的和原因

1. **没打 tag、没改版本号**：任何硬性项不过就不发（prompt 80）；版本号仍 0.1.0，`bump-version.sh` 留给真正发布的那次。
2. **main 的快进**：先按 G4 先例留给用户定；用户 2026-09-28 看完报告指示快进，已 `git -C /Users/plus/plusmix merge --ff-only release/0.1`（main 的 worktree 当时干净）。
3. **8 小时长稳没重跑**：S2 的根因在 W2-A（文件输入解码线程无自动释放池），修好前重跑只会再红一次；且 8 小时要用户终端（摄像头授权、sudo）。本会话只跑了 1 小时交叉验证。
4. **L3 人工清单没做**：docs/checklists/G4.md 的 38 + 17 项要 TCC / 硬件 / 人眼，Claude 会话做不了；清单里 0 项有执行记录，报告如实写 BLOCKED-人工。
5. **E7–E9 没重跑**：要 `sudo scripts/netem.sh serve`；推流实现自 G3 起没变，沿用 G3-net 结果。
6. **NDI 回环 L1 / 编译矩阵没重跑**：`gate4-ndi.sh` / `gate4-matrix.sh` 会重拼 reports/G4.md；Inputs / NDISend 包自 g4g 起没变，沿用 G4 结果。
7. **bundle id 没切、Sparkle 更新源没定**：只有用户能定域名；脚本（`set-bundle-id.sh`）备好。
8. **CHANGELOG.md 没建**：不在 G5 归属里；发布说明草稿在 reports/G5.md §9。
9. **OWNERSHIP 改了两处认领 + 两行新增**（用户 2026-09-28 授权"都认领"）：W4-A 行加 Makefile、W4-B 行加 20 个文件；G5 行补 docs/OWNERSHIP.md 与 docs/plan/prompts/ 的记录；按补充规则 6 加 W2-A3 行（w2-inputs-3）与 prompt 74（泄漏修复，用户指派 agent 直接做）。
10. **App 的相对路径（W4C 问题单，约 10 行）没修**：G5 行没有 App 胶水额度（`~App/:50` 只在 G2–G4 行），进 KNOWN_ISSUES。
11. **docs/testing/README.md 的 G5 那行没改**（仍写"待做 / 未生成"）：docs/ 归 W4-C，不在 G5 归属里；下一个动 docs/ 的会话把它改成"2026-09-28 · 不发（S2 泄漏、签名账号）· reports/G5.md"。
12. **check-links 没挂进 make lint**：scripts/ 不在 G5 归属里；一行 `scripts/check-links.sh` 转调即可，下一个检查点或用户认领后做。

## 4. 对契约的疑问

没有。四路合入都没碰 SwitcherContracts；W3-E4 报告 §4 第 2 条（给 `EncoderEntry` 加 `ndiStates` 常量方便对表）不急，留给下一个契约会话。

## 5. 下一个会话需要知道的坑

1. **新 worktree 先编 release 版 frameprobe 再跑 `make test`**：`swift build -c release --package-path Tools/frameprobe`，否则 SwitcherOutputs 的 E7 / E8 / RTMP / SRT / A4 五条按 BLOCKED-工具 跳过（G4 的 worktree 里早编过所以没人注意）。`make test` 本身不编它。
2. **`scripts/gate4.sh` 写死 reports/G4-run-<label>.md 并重拼 reports/G4.md**：G5 跑 L2 后要 `git checkout reports/G4.md`、把 G4-run-g5.md 改名成 G5-run-10min.md。下一个改 scripts/ 的会话给它加 `--run-report` / `--report`（gate3-report.py 已经有这两个参数，只是 gate4.sh 没透传）。
3. **L5 要在桌面安静时跑**：本会话第一次 perf 的 2–5 分钟里 WindowServer 30–45%、Safari 的 WebKit GPU / WebContent 在跑（load.log 每 5 s 一行看得到），GPU 占用从 32% 跳到 66%、V1 p99 从 2.5 翻到 4.7 ms，被判"退步 87% / 38% / 103%"；0–1 分钟与基线逐分钟一致，代码路径又与基线提交逐字节相同（`git diff af2414f..HEAD -- Tools/ Packages/` 为空），所以是环境。perf 脚本只记在跑的编译 / 测试进程，不看 WindowServer / WebKit；判退步前先看 `.build/perf/<label>/load.log`。建议 perfjudge 把 WindowServer > 25% 或 WebKit.GPU 出现标成"环境不干净、本次不判"。
4. **合并顺序与冲突**：App 分支先合（W3-E4），再脚本（W4-A）、发布工程（W4-B）、文档（W4-C）；唯一冲突是 Makefile 末尾（两边都在文件尾追加），两段都留。两份 Localizable.strings 自动合并成功，但要 `grep -oE '^"[^"]+"' | sort | uniq -d` 查一遍重复键（这次 0）。
5. **本机 git 的 `merge-tree --write-tree --merge-base=main A B` 直接报用法错误**，预检冲突不如直接 `git merge` 看结果（冲突了再解，`git merge --abort` 随时能退）。
6. **Bash 工具里长流水线的做法**：脚本每步往 status.log 写一行 `STEP <名> EXIT <码>`，Monitor 工具挂一个 20 s 轮询该文件的循环（最长 30 分钟、到期重挂）；第二阶段脚本 `until grep -q PIPELINE_DONE …` 等前一阶段。要中途改顺序就起一个 watcher 等某一行出现再 `kill <具体 PID>`（别用宽匹配的 pkill，W4-A 坑 12）。
7. **`ls -t .build/DerivedData/Logs/Test/*.xcresult | head -1` 只有一个 bundle 时会列出它的内容**（Info.plist），用 `ls -td`；App 用例数照旧从 xcresulttool 读（这次 90 / 88 / 0 / 2）。
8. **App 全量现在是 90 条**（W3-E4 的 86 + W4-B 的 ReleaseTests 4）；跳过的两条不变（内置摄像头 TCC、扩展签名）。223 s。
9. **`make release-test` 的 R1 会再归档一次**（89 s，产物 `.build/release-tests/r1/`），与 `make archive-adhoc` 的 `.build/release/0.1.0/` 是两份；release-report.md 的"提交"是跑时的 HEAD，报告草稿没提交时会写"工作树有未提交改动"。
10. **soak / perf 两个脚本都有 `--report <md>`**，G5 用它把报告写到 reports/G5-*.md，不覆盖 W4-A 的 reports/W4-*.md；`--label` 决定 `.build/soak|perf/<label>/`。Claude 会话里 soak 不接摄像头（TCC 未决不弹框）、没 powermetrics，只作参考。
11. **Sparkle 的 SwiftPM 二进制包缓存在 `~/Library/Caches/org.swift.swiftpm/artifacts/`**（W4-B 放好的），新 worktree 的 `make gen` / xcodebuild 解析没再卡；`$TMPDIR` 里那几个 0 字节的 `*.lock` 是 SwiftPM 的 flock 文件，没人持有时无害，别顺手删。
12. **check-links 现在扫 110 个 Markdown**（含新写的 docs/KNOWN_ISSUES.md），docs/ 下任何新文件的相对链接都会被它抓；它还没挂进 make lint。
13. **`test-r11-set-bundle-id.sh` 第 10 行写死了占位前缀 com.example**：bundle id 一切就红一条（21 / 22 过），一行改成从 project.yml 读前缀即可（issue G5-w4-release-r11-…，归 W4-B）。
14. **W2-A2 留给检查点的清单（reports/issues/W2A2-g5-pending-items.md）**：1-1 / 1-2 / 1-3 / 2-1 已由 W3-E2 / W3-B2 做完，3-2（headless 接纯音频输入）G4 第一批续做合入时做了（G4-notes §10.1），3-1（探针子命令）与 4-x 硬件项仍开着；W3C2-g5-swift-collections-1.7-dyld-crash 的正式修法 W3-E2 + W4-B 已落地（三份 Package.resolved 入库 + 模板 + pin-deps.sh）。
