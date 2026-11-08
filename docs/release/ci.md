# CI（prompt 71 交付 4；测试标准 §5）

## 工作流

| 文件 | 触发 | 跑什么 | 阻塞什么 |
|---|---|---|---|
| `.github/workflows/ci.yml` job `l0-l1` | 每次 push、每个 PR | `pin-deps.sh check` → lint（`scripts/release/ci-ownership.sh`：禁词 / 版本号 / 依赖方向 / 归属 / 自加检查）→ `make gen` → `make test`（六包 swift test、两工具冒烟、App xcodebuild test） | 红 = 提交有问题 |
| `ci.yml` job `l2` | 每个 PR（l0-l1 过了之后） | `make gate4-run`：10 分钟集成场景（V1–V7、A1–A4、E1–E3、E5、C1–C4） | 红 = PR 不能合 |
| `.github/workflows/nightly.yml` | 每天 03:00（Asia/Shanghai）、手动 | `make soak-1h`（L4 缩短版）→ `make perf-baseline`（L5，与 baselines/ 比，退步 > 10% 非零） | 红 = 性能退步或长稳失败；两个目标是 W4-A 的，合入前第一步就红并说明 |
| `.github/workflows/release.yml` | `v*` tag、手动 | 版本号与 tag 一致 → 导入证书 → `make archive`（签名、公证、DMG）→ appcast → GitHub Release 草稿；产物名从 project.yml 的 `PRODUCT_NAME` 读（`PlusMix-<版本>.dmg`，与 archive.sh 同一读法） | 没 secrets 就失败：不出未签名的发布包 |

所有跑引擎的步骤都包 `caffeinate -u -i -d -s`（W4-A 第 7 条）。`actionlint` 零告警（`make release-test` 的 R6；`.github/actionlint.yaml` 登记了 runner 标签）。

## Runner（这台 Mac 或以后的 mini）

```bash
make runner-install RUNNER_FLAGS="--url https://github.com/<owner>/<repo> --token <注册 token>"
```

`scripts/release/ci-runner-setup.sh` 下载最新 osx-arm64 runner 到 `~/actions-runner`，标签 `switcher,macOS,ARM64`，装成 **LaunchAgent**（`svc.sh`，登录会话）——
App 的 xcodebuild test、显示类用例、虚拟摄像头都要窗口服务器，LaunchDaemon 不行。装完的人工项（脚本末尾也打印）：

1. 自动登录本用户；节能里禁止自动睡眠；屏幕保护 / 锁屏关掉（锁屏会挡住 TCC 弹窗、显示类用例被盖住就红——G4 的经验）。
2. 第一次跑给 runner 进程摄像头 / 麦克风 / 屏幕录制授权；ad-hoc 构建每次签名都变，授权会反复问——CI 机器最好在 runner 环境里设 `DEVELOPMENT_TEAM`：钥匙串里只有 Apple Development 身份时 `make gen` 自动选开发签名（W4-B3，signing.md"三种签名模式"），授一次权之后重编译不再问；有 Developer ID 身份时是 Developer ID 的设置，本地 `make test` 可能停在签名（signing.md"常见错误"），这时显式 `SWITCHER_DEV_SIGN=1`。`make release-test` 的 R17（开发签名真签）在 CI 上默认跳过（`RELEASE_TEST_DEV_SIGN=1` 强制）。
3. `perf-baseline` 的 powermetrics 要免密码 sudo：`/etc/sudoers.d/switcher-ci` 写 `<用户> ALL=(root) NOPASSWD: /usr/bin/powermetrics`。
4. 装 Xcode（接受许可）、`brew install xcodegen ffmpeg mediamtx actionlint`、NDI SDK（没有 SDK 的机器 NDI 编成空实现，NDI 回环 L1 测不到）。
5. 机器要能访问 GitHub（第一次解析 Sparkle / HaishinKit 等包）。

本会话（2026-09-27）这个仓库还没有 GitHub 远程、本机也没装 runner：工作流只能 actionlint 静态验证，第一次真跑在建远程仓库之后（BLOCKED-账号，报告 §2）。

## Secrets / Variables（release.yml）

| 名字 | 是什么 | 怎么来 |
|---|---|---|
| `DEVELOPMENT_TEAM` | Team ID | developer.apple.com → Membership |
| `DEVELOPER_ID_P12_BASE64` / `DEVELOPER_ID_P12_PASSWORD` | "Developer ID Application" 证书 + 私钥的 .p12 | 钥匙串访问里导出，`base64 -i x.p12 \| pbcopy` |
| `NOTARY_KEY_ID` / `NOTARY_KEY_ISSUER` / `NOTARY_KEY_P8_BASE64` | App Store Connect API 密钥（Developer 角色够） | appstoreconnect.apple.com → Users and Access → Integrations |
| `SPARKLE_PRIVATE_KEY` | Sparkle 私钥 | `scripts/release/sparkle-keys.sh export --to key.txt`，内容进 secret，删文件 |
| 变量 `SPARKLE_FEED_URL` | appcast 固定地址 | 例如 `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` |
| 变量 `SPARKLE_PUBLIC_ED_KEY` | 公钥 base64 | `scripts/release/sparkle-keys.sh public` |

证书导进一次性钥匙串（`scripts/release/ci-keychain.sh import`），跑完 `cleanup` 删掉；公证 .p8 写到 `$RUNNER_TEMP` 跑完删。

## 本地对应

- `make lint && make test` = l0-l1；`make gate4-run` = l2；`make archive-adhoc && make release-test` = 发布脚本自检。
- 归属检查在 CI 里只对 docs/OWNERSHIP.md 有行的分支跑（PR 的合并分支没有行，只提示）。
