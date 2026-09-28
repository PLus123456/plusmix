# W4-A → W4-B：nightly 跑 `make soak-1h` / `make perf-baseline` 要在自托管 runner 上准备的东西，和一处会闪的判定

归属会话 / 分支：W4-B 发布工程（`w4-release`，prompt 71 第 4 条 "nightly 跑 soak-1h + perf-baseline；退步阻塞（make perf-baseline 非零）"）
发现于：W4-A（`w4-soak`，2026-09-27），本会话在这台 M5 Max 上把两个目标都跑过（会话里是非交互环境，和 CI 一样）
严重级：S2（不准备的话 nightly 会少测东西或时红时绿；不影响产品）

## 1. 入口与退出码

| 目标 | 脚本 | 退出码 | 产物 |
|---|---|---|---|
| `make soak-1h` | `scripts/soak/soak.sh --hours 1 --label 1h` | 0 通过；1 S1 / S2（判得了时）/ A3 有不过；2 前置条件不满足（没工具、端口被占、没接电源、磁盘不够） | `reports/W4-soak-1h.md`、`.build/soak/1h/`（summary.json、anomalies/、stats.jsonl、录像） |
| `make perf-baseline` | `scripts/perf/perf-baseline.sh` | 0 无退步且都在必须档内；1 退步（同机同 macOS 大版本的上一版基线）或掉出必须档；2 产物缺失 | `reports/W4-perf-<机器>-macos<大版本>.md`、`.build/perf/perf/perf-summary.json` |

Makefile 的这三个目标（含 `make soak`）是 W4-A 加的、**越出了 W4-A 的归属**，等用户批（W4-A 报告 §4 第 1 条）；不批的话 CI 直接调上面的脚本，参数一样。

## 2. runner 上要有的

- 工具：`mediamtx`、`ffmpeg`（要带 libvmaf，E4 用；没有会退到 PSNR 并在报告里写明）、`ffprobe`、`curl`；Xcode（swiftc 编两个 20 行的探针）。NDI SDK 装在 `/Library/NDI SDK for Apple`（没有就不开 NDI 发送，报告里算偏离标准负载）。
- 接电源（soak 没接电源直接退出 2；`--allow-battery` 可以硬跑）；磁盘：soak-1h 约 23 GB 余量（录制 6 Mb/s + 20 GB 余量），perf 约 5 GB。
- **串行**：soak / perf 期间同一台机器上不要有别的编译 / 测试任务（prompt 70 第 7 条；本会话实测别的会话一编译，V2 就可能 +1、CPU / GPU 起伏 ±10%）。脚本会把在跑的 swift-frontend / xcodebuild / xctest 记进报告，但不会拦。
- 端口：soak 用 RTMP 19350、MediaMTX API 19997、SRT 18890（都只绑 127.0.0.1）；leaks.sh 用 19351 / 19998 / 18891。避开了 W2-D 测试的 1935–1937 / 8890–8892 / 9997–9999。

## 3. 三个权限（非交互时脚本不会弹框、不会挂住，只会少测并写明）

| 权限 | 不给的后果 | 怎么给 |
|---|---|---|
| 摄像头（TCC，归属于跑脚本的那个 App：runner 的服务进程 / 终端） | 非交互且授权未决：soak 不接摄像头（报告 §2 标 ⚠️，负载少一路）；被拒：CameraInput 停在 error、画黑 | 在 runner 用的账号下、用同一个宿主进程交互跑一次 `make soak-1h`，开跑前会弹授权框，点允许 |
| `sudo -n /usr/bin/powermetrics` | GPU 只有 IOKit 口径（§3 S3 的正式口径，够判），没有 powermetrics 对照、频率与 thermal pressure | sudoers 给 runner 账号 `NOPASSWD: /usr/bin/powermetrics`（安全设置，用户自己决定） |
| 开发者工具访问（`DevToolsSecurity -enable`） | `scripts/soak/leaks.sh`（S2 的 Instruments Leaks）直接写 BLOCKED-权限 退出（有 90 s 看门狗，不会挂一整晚） | 管理员执行一次 `DevToolsSecurity -enable`；Leaks 不必每晚跑 |

## 4. 会闪的：L5 的"退步 > 10%"在 V3 上

本会话同一份代码连跑三轮（`.build/perf/run1..3`）：V3 p99 = 0.049 / 0.047 / 0.053 ms，第 3 轮对第 2 轮 +6 µs = **+13% → 判退步、退出 1**；CPU avg 44.2–49.1%、GPU avg 27.6–30.2%，也贴着 10%。
E4（VMAF 91.003 ×3）和 V1（起伏 ≤ 3%）是稳的。怎么判（给 V3 / CPU / GPU 加绝对下限、或每晚跑三轮取中位数）等用户定（W4-A 报告 §4 第 2 条）；
定了之后只改 `scripts/perf/regression.json`（`floor` 字段已经支持），CI 不用改。定之前建议 CI 把 perf 的退出 1 标成"要人看"，别直接阻塞合并。

## 5. 复现

```bash
make soak-1h
make perf-baseline
```
