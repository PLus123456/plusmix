# W4-B3 发布工程续做：本机开发签名接进 project.yml——分支 w4-release-3

prompt：docs/plan/prompts/141-W4B3-开发签名接进工程.md（用户 2026-11-07 贴进会话开工）。从 G13 快进后的 main `1886bde` 开：harness 分支 `claude/w4-release-dev-signing-0e3c14` 上 `git checkout -b w4-release-3`（harness 分支留在 1886bde）。
机器：MacBook Pro M5 Max（Mac17,6）、macOS 27.0.1（26A434）、Xcode 27.2（27B52）、xcodegen 2.46.0、接电源；钥匙串 1 个签名身份 **Apple Development: 553368183@qq.com (34XFY3Q25G)**，Team **59554R22ZM**（Xcode 账户里 "Plus Chen (Personal Team)"，isFreeProvisioningTeam = 1）；没有 Developer ID。
提交（先测试后实现）：`f009c6b` R16 / R17 → `fd7f74d` project.yml / sign-mode.sh / Makefile / archive.sh → `5c0074c` 自动重新生成时沿用原来的模式 → `65f24ab` 发布文档 → 本报告与清单一处措辞（分支顶）。
验证在 2026-11-08 00:00–00:40 跑（机器上同时只有 Claude 桌面 App 与 Spotlight 索引，负载 3–4）。

## 1. 做了什么

### 1.1 交付 1：project.yml 认三种签名模式（`fd7f74d`）

两个输入由 `make gen` 从环境变量写进工程（XcodeGen 的 `${…}`），工程里派生一个 `SWITCHER_SIGN_MODE`，签名方式 / 身份 / App 权限表都按它查表：

| 模式 | 输入 | `CODE_SIGN_STYLE` / `CODE_SIGN_IDENTITY` | App 的 `CODE_SIGN_ENTITLEMENTS` | 扩展 / 测试包 |
|---|---|---|---|---|
| (a) `adhoc` | `DEVELOPMENT_TEAM` 空 | Automatic / `-`（原样） | `App/Switcher.entitlements`（原样） | 原样 |
| (b) `dev` | Team + `SWITCHER_DEV_SIGN=1` | **Manual / `Apple Development`**，不要描述文件 | **`App/Switcher-dev.entitlements`**（新：camera + audio-input + cs.disable-library-validation，不带 system-extension.install） | 扩展用自己的 `CameraExtension.entitlements`、测试包不带；都签同一身份 |
| (c) `devid` | Team + `SWITCHER_DEV_SIGN=0`（或没给且钥匙串有 Developer ID） | Automatic / `-`（原样） | `App/Switcher-signed.entitlements`（原样） | 原样 |

- 写法沿用 W3-C 的 `$(DEVELOPMENT_TEAM:default=adhoc)`：`SWITCHER_TEAM_KIND = $(DEVELOPMENT_TEAM:default=adhoc)`、`SWITCHER_DEV_SIGN_KIND = $(SWITCHER_DEV_SIGN:default=0)`，
  `SWITCHER_SIGN_MODE = $(SWITCHER_SIGN_MODE_FOR_TEAM_$(SWITCHER_TEAM_KIND):default=$(SWITCHER_SIGN_MODE_FOR_DEV_$(SWITCHER_DEV_SIGN_KIND):default=devid))`；
  查表只定义 `adhoc` / `dev` 两项，`devid` 落到 default = W4-B3 之前的值。嵌套 `:default=$(…)` 先写 20 行探针（scratchpad `probe/macro.xcconfig` + `-showBuildSettings` 五种组合）确认 Xcode 27.2 能算，再进工程。
- **`CODE_SIGN_STYLE` 分两行**：无条件 `Automatic` + `"CODE_SIGN_STYLE[sdk=macosx*]": "$(SWITCHER_CODE_SIGN_STYLE_$(SWITCHER_SIGN_MODE):default=Automatic)"`。原因：XcodeGen 把 `CODE_SIGN_STYLE` 原样抄进 TargetAttributes 的 `ProvisioningStyle`（宏也照抄，生成出 `ProvisioningStyle = "$(SWITCHER_CODE_SIGN_STYLE_…)"`）；
  先试了 target 的 `attributes: ProvisioningStyle: Automatic`，**盖不住**（XcodeGen 2.46 在 target attributes 之后才写算出来的值）。同一层里带条件的变体优先、本工程只有 macOS，所以构建时总是宏那行生效，而 (a) / (c) 的 TargetAttributes 与之前一样（R16 查 3 / 3 是 `Automatic`）。
- 两个输入在 xcodebuild 命令行上也能盖（命令行优先级最高，派生跟着变）——`DEV_SIGN_TEAM` 别名就靠这个（1.3）。
- 硬化运行时那段注释改成"有 Team ID 时（开发签名与 Developer ID）生效"；权限表查表那段写清三张表各给谁。

### 1.2 自动识别：`scripts/dev-signing/sign-mode.sh`（`fd7f74d`）

prompt 说 (b) 要么显式 `SWITCHER_DEV_SIGN=1`、要么"自动识别没有描述文件 / Personal Team"。落成：Team 给了、`SWITCHER_DEV_SIGN` 没给时 `make gen` 调它看钥匙串——
有该 Team 的 "Developer ID Application" 身份 → 0（(c)，与 archive.sh 判 Developer ID 的条件同一条）；没有、但有它的 "Apple Development" 身份 → 1（Personal Team 一定是这样；付费账号但本机没建 Developer ID 证书时 (c) 也签不出来）；都没有 → 0（原样）。
没用"有没有描述文件"或 Xcode 偏好里的 `isFreeProvisioningTeam` 判：前者在付费账号的新机器上第一次 archive 之前也是空的（会把 (c) 误判成 (b)），后者要 Xcode 登过账户；钥匙串身份是签名真正要用的东西。
- Apple Development 证书名括号里那串（34XFY3Q25G）**不是** Team ID（G13 §10 第 6 条）：脚本按 `security find-identity` 的 SHA-1 找到证书，用 `/usr/bin/openssl x509 -subject` 读 OU。只读钥匙串、不碰私钥、不联网。
- `make gen` 打一行 `[sign-mode] …` 说选了哪种、为什么；`SWITCHER_DEV_SIGN=1` 没给 Team、值不是 1 / 0 / 空 → 退出 2、不调 XcodeGen；ad-hoc 时钥匙串里有 Apple Development 就提示一句怎么开；Team 对不上时列出钥匙串里实际的 Team。
- 另有 `--dev-team`（第一个 Apple Development 身份的 Team，R17 / 清单用）、`--list`；测试用 `SWITCHER_SIGN_IDENTITIES` 注入，不碰真钥匙串。
- 本机真钥匙串：`--list` = `dev 59554R22ZM`；`DEVELOPMENT_TEAM=59554R22ZM` → 1；`DEVELOPMENT_TEAM=34XFY3Q25G`（证书名里那串）→ 0 并提示 "钥匙串里的 Apple Development 身份是 Team 59554R22ZM"。

### 1.3 交付 2：Makefile、scripts/dev-signing/、archive.sh（`fd7f74d` + `5c0074c`）

- `export SWITCHER_DEV_SIGN ?=`（同 DEVELOPMENT_TEAM，XcodeGen 拿不到变量会原样写 `${…}`）；`gen` 先跑 sign-mode.sh 再把结果交给 XcodeGen，回显 `…generate --quiet（DEVELOPMENT_TEAM=… SWITCHER_DEV_SIGN=…）`。
- **`DEV_SIGN_TEAM` 留作别名**（G13 §7 / docs/checklists/G13.md 已经告诉用户用 `make build-app DEV_SIGN_TEAM=59554R22ZM`）：不再 `-xcconfig`，改成在 xcodebuild 命令行上盖 `DEVELOPMENT_TEAM=<Team> SWITCHER_DEV_SIGN=1`，走 project.yml 自己的派生；好处是不重新生成工程、对 ad-hoc 生成的工程也立刻生效。
- **project.yml 变了自动重新生成时沿用原来的模式**（加做，下一条坑的修法）：`$(XCODEPROJ)/project.pbxproj: project.yml` 这条规则原来是裸 `$(MAKE) gen`——拉一次 project.yml 的改动（比如 G14 bump 0.1.1 改 MARKETING_VERSION）`make build-app` 就按当时的环境重生成、悄悄退回 ad-hoc、TCC 又重问，正好打掉开发签名的意义。
  现在环境里两个签名变量都没给就从旧 pbxproj 读回 `DEVELOPMENT_TEAM = <10 位>;` / `SWITCHER_DEV_SIGN = 0|1;` 再生成（打一行"沿用工程里原来的 …"）；环境给了就听环境的；显式 `make gen` 不变。
- scripts/dev-signing/：G13 的 `dev-signing.xcconfig` 删掉（逻辑进了 project.yml），`PlusMix-dev.entitlements` `git mv` 成 `App/Switcher-dev.entitlements`（注释改写）——权限表只此一份（R16 查 `scripts/` 下没有 *.entitlements / *.xcconfig）；目录里现在只有 sign-mode.sh。
- `make help` 一句（ad-hoc / 开发签名 / 自动选 / 别名 / signing.md）。
- **archive.sh 钉 `SWITCHER_DEV_SIGN=0`**：生成工程那行与 `xcodebuild archive` 的命令行都带。发布归档永远不会被自动识别成开发签名（付费账号的 release.yml runner 上即使导证书出了岔子，也只会退成 archive.sh 自己的 ad-hoc，不会签出一个开发签名的包）。

### 1.4 交付 3：发布文档（`65f24ab` + 分支顶）

- docs/release/signing.md：新节"三种签名模式"（表 + 自动识别 + Team ID 读法 + 别名 + 模式何时变 + 自检 + XcodeGen 的坑）；步骤表"生成工程"一行改成钉 0；**"权限表与硬化运行时"表加"开发签名"一列**，并加四行：签名身份、TCC（为什么稳定：指定要求按 bundle id + 证书写、不含 CDHash；ad-hoc 的指定要求就是 cdhash——本机给 /bin/ls 副本 ad-hoc 签一次验过 `designated => cdhash H"…"`）、libndi（为什么关库校验）、能做 / 不能做（含 Personal Team 的限制：只能签不带受限权限的、不能分发、证书一年一换）；常见错误加三条（GatherProvisioningInputs 那条、找不到身份、开发签名起来就 abort）。
- docs/release/checklist-first-signed-run.md：开头分两段——"开发签名第一次"（起 App 授一次权 → 重编译不重问 → `make test-app` 宿主也不重问 → libndi → 扩展装不上是预期 → release-test 之后要再 gen）与"Developer ID 第一次"（原清单原样挪进去；本机直接编那条加了"Personal Team 上停在 GatherProvisioningInputs、付费账号第一次在这里验"）。
- docs/release/README.md：表里两行、快速上手加开发签名一行、前置条件加"Apple Development 身份"一行、归属加 W4-B3 一句；release.mk 文件头、ci.md runner 第 2 条（CI 机器设 DEVELOPMENT_TEAM 现在会自动开发签名；R17 在 CI 上默认跳过）。
- docs/checklists/G13.md：前提段只加一句"用开发签名跑这份清单"（prompt 只准加这一句）。docs/user 不动。

### 1.5 交付 4：R16 / R17（`f009c6b` + `5c0074c`）

- **R16 `test-r16-sign-modes.sh`**（不要签名身份、CI 也跑）：开发表的键恰好是三条、发布表不关库校验、ad-hoc 表空、scripts/ 下没有第二份；sign-mode.sh 决策表（11 种输入 + 两条提示 + `--dev-team` 两条）；`-showBuildSettings` 在 5 种输入组合 × 3 个 target 下的签名方式 / 身份 / 权限表 / Team / 硬化运行时 / 描述文件为空——(a) / (c) 的值与 W4-B3 之前逐项相同；临时目录生成查 XcodeGen 写进工程的两个值与 TargetAttributes；假 xcodegen 查 `make gen` 交给 XcodeGen 的环境（含 SWITCHER_DEV_SIGN=1 没给 Team 时不调）；假工程查"project.yml 变了自动重生成时沿用原来的模式"；archive.sh 两处钉 0；`make -n` 查别名只盖两个输入、不再 `-xcconfig`；`make help`。
- **R17 `test-r17-dev-signing.sh`**：Team 取 `RELEASE_TEST_DEV_TEAM` > 钥匙串里有身份的 `DEVELOPMENT_TEAM` > `sign-mode.sh --dev-team`；按别名路径 `xcodebuild build-for-testing DEVELOPMENT_TEAM=<Team> SWITCHER_DEV_SIGN=1` 进 `.build/DerivedData`，查 App 的 TeamIdentifier / flags 含 runtime / Authority=Apple Development / 三条权限 / 没有 system-extension.install / 指定要求含 `anchor apple generic` 与 bundle id、不含 cdhash / `codesign --verify --deep --strict`；扩展同一 Team、沙盒、app group `<Team>.<bundle id>.camera`；测试包同一 Team、不带受限权限；App 起来 4 秒不崩。
  跳过（77，BLOCKED-签名）：钥匙串里没有 Apple Development 身份（写解锁办法）；`CI` 非空且没 `RELEASE_TEST_DEV_SIGN=1`（runner 无 GUI 会话时钥匙串锁着、私钥授权框没人点会挂住——今天的工作流本来就不跑 release-test）；签名时 errSecInternalComponent（钥匙串锁着）。bundle id 从构建出的 Info.plist 读，set-bundle-id.sh 换前缀后照样对。
- **R17 的起来 4 秒是有效的**（反证）：Debug 构建的主二进制是个桩，libndi 链在 `PlusMix.debug.dylib` 上、rpath 指 `/Library/NDI SDK for Apple/lib/macOS`（libndi 是 NewTek 的 Developer ID W8U66ET244 签的）。把构建出的 App 拷一份、用同一身份 + runtime + 去掉 `cs.disable-library-validation` 的权限表重签：起来即 **退出 134**，dyld：`… libndi.dylib' not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`——与 G13 §4.4 测试宿主那次同一条。

### 1.6 交付 5：README 的 R15（`65f24ab`）

docs/release/README.md 第 19 行"R1–R6、R11–R14" → "R1–R6、R11–R17（R15 G12 加，R16 / R17 W4-B3 加；R17 没有 Apple Development 身份时跳过）"；release.mk 文件头同一处一起改。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

本会话没有数值阈值；R1–R15 的"阈值"是 W4-B3 之前的断言一条不改、全过（prompt："别把 (c) 弄坏（R1–R15 全过）"）。

| 测试 / 检查 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| **R16** 三种签名模式（静态，CI 也跑） | 96 / 96 项断言（16–22 s）；改之前 44 / 92 红 | 全过 | ✅ |
| **R17** 开发签名真签一次 | 21 / 21 项断言：TeamIdentifier=59554R22ZM、`flags=0x10000(runtime)`、Authority=Apple Development、三条权限在、没有 system-extension.install、指定要求 `identifier "com.plusmix.switcher" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: 553368183@qq.com (34XFY3Q25G)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`（不含 cdhash）、`--verify --deep --strict` 过、扩展 / 测试包同一 Team、起来 4 秒；冷编 40 s、增量 12 s | 全过 | ✅ |
| R17 的"起来 4 秒"有没有用（反证） | 同一份 App 去掉 `cs.disable-library-validation` 重签 → 退出 134，dyld `… different Team IDs` | 必须起不来 | ✅ |
| R1–R6、R11–R15（(a) / (c) 没弄坏） | R1 42（ad-hoc 归档 + DMG + 起来 4 秒，114 s）、R2 4、R3 6、R4 5、R5 19、R6 30、R11 24、R12 7、R13 15、R14 14、R15 13 | 全过、断言不改 | ✅ |
| `make release-test` 整套 | **PASS 13  FAIL 0  SKIP 0**（约 3 分钟） | 无 FAIL | ✅ |
| (b) 生成时自动识别 + App 全量用例 | `DEVELOPMENT_TEAM=59554R22ZM make gen`（没给 SWITCHER_DEV_SIGN）→ `[sign-mode] 开发签名（…只有该 Team 的 Apple Development 身份、没有 Developer ID…）`；`make build-app` 的 App：TeamIdentifier=59554R22ZM、runtime、Apple Development；`make test-app XCB_FLAGS=`：**Executed 336 tests, with 4 tests skipped and 0 failures**（439 s）。4 跳与 G13 的同四条：键盘导航 BLOCKED-系统设置、空闲唤醒探针要环境变量、内置摄像头 BLOCKED-权限（Claude 的 Bash 起的拿不到 TCC）、虚拟摄像头 L1 BLOCKED-签名；`VirtualCameraAppTests` 的激活用例回 "Missing entitlement com.apple.developer.system-extension.install"、判成签名挡住、过 | 与 G13 ad-hoc 的 336 条同样 0 红 | ✅ |
| (a) ad-hoc 本机构建（R1 之后工程是 ad-hoc） | `make build-app`：`Signature=adhoc`、`flags=0x2(adhoc)`、TeamIdentifier=not set、指定要求 `cdhash H"…"`、权限只有 Xcode 加的 get-task-allow | 与之前一样 | ✅ |
| (c) Developer ID 的设置在本机（Personal Team） | `DEVELOPMENT_TEAM=59554R22ZM SWITCHER_DEV_SIGN=0 make gen` + `xcodebuild build` → 退出 65：`"Switcher" has entitlements that require signing with a development certificate. Enable development signing…`——与 G13 §4.4 同一步、同一句 | 行为不变 | ✅（真跑 BLOCKED-账号） |
| 开发签名给错 Team | `make build-app DEV_SIGN_TEAM=34XFY3Q25G` → `No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "34XFY3Q25G" with a private key was found.`（原文进了 signing.md 常见错误） | 报错说得清 | ✅ |
| `make lint BRANCH=w4-release-3` | `LC_ALL=C` 与 `zh_CN.UTF-8` 各一遍全绿：禁词 / 版本号 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属"15 个改动文件都在允许范围内" / check-help / check-links 227 个 Markdown / check-rt-symbols 0 违规 | 全绿 | ✅ |
| shellcheck `-S warning` | sign-mode.sh、R16、R17：0 条 | 0 | ✅ |

## 3. 没做的和原因

- **Developer ID / 公证 / Sparkle**：BLOCKED-账号（prompt 明说不做）。(c) 的生成与 archive 设置逐项与之前相同（R16），本机能跑到的那一步失败点也与 G13 相同（§2）。
- **虚拟摄像头扩展装不上**：Personal Team 拿不到 `system-extension.install`；开发签名的宿主里激活实测回 "Missing entitlement com.apple.developer.system-extension.install"。signing.md / 清单写清楚了，没有别的路。
- **(c) 的本机 `make build-app`**（有 Developer ID 时 `DEVELOPMENT_TEAM=… make gen build-app`）：按 W4-B 的设计是 `CODE_SIGN_IDENTITY "-"` + 带受限权限的签名表，付费账号上多半也会停在 GatherProvisioningInputs（只有 archive 带 `-allowProvisioningUpdates`）。prompt 说 (c) 不动，我没改；清单"Developer ID 第一次"写成"付费账号第一次在这里验证，不行就加 -allowProvisioningUpdates，或本机清单改用开发签名"。拿到账号的会话再定。
- **人工三项没在本会话做**：授一次权 / 重编译不重问 / `make test-app` 宿主不重问都要在机器前点系统授权框，Claude 的 Bash 起的进程拿不到 TCC。机制上的证据是 R17 查的指定要求（按 bundle id + 证书、不含 cdhash）与 ad-hoc 对照（就是 cdhash）；步骤写进了 checklist-first-signed-run.md"开发签名第一次"，docs/checklists/G13.md 加了一句指过去。
- docs/user 不动（prompt：用户不碰签名）；App 代码、阈值、docs/OWNERSHIP.md（W4-B3 行 G13 已写好）都没动。

## 4. 对契约的疑问

无：没碰 SwitcherContracts、JSON 字段、测试图案；也没碰 App 代码。

## 5. 下一个会话需要知道的坑

1. **XcodeGen 把 `CODE_SIGN_STYLE` 原样抄进 TargetAttributes 的 `ProvisioningStyle`**（宏也抄），target 的 `attributes:` 盖不住（2.46 先写 target attributes、后写算出来的值）。要按模式换签名方式就用 project.yml 现在的写法：无条件 `CODE_SIGN_STYLE: Automatic` + `CODE_SIGN_STYLE[sdk=macosx*]` 宏。别把两行合成一行宏——生成的 TargetAttributes 会变，(c) 本机测不了。
2. **两个输入能在 xcodebuild 命令行上盖**：派生的 `SWITCHER_SIGN_MODE` 跟着变，`DEV_SIGN_TEAM` 别名、R16 / R17 都靠这个；嵌套 `$(A:default=$(B))` Xcode 27.2 能算（本会话先写探针验的）。`xcodebuild -showBuildSettings` 带 `-derivedDataPath` 时必须配 `-scheme`；`-alltargets` 会把 Switcher 列两遍。
3. **zsh 又撞分词**：探针里 `for ov in "DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=1"; do xcodebuild … $ov` 没分开，DEVELOPMENT_TEAM 成了 `" SWITCHER_DEV_SIGN=1"`、全判成 devid；要 `${=ov}`（G13 §10 第 1 条同类）。脚本都用 bash，不受影响。
4. **写进工程的模式什么时候变**：显式 `make gen` 只看环境变量；`make release-test`（R1 跑 `archive.sh --adhoc`）/ `make archive-adhoc` 之后是 ad-hoc；project.yml 变了 build-app / test-app 自动重新生成时沿用旧 pbxproj 里的 Team 与开关。**G14 bump 0.1.1 之后**用户 `make build-app` 不会掉回 ad-hoc；要开发签名跑 L3 就 `DEVELOPMENT_TEAM=59554R22ZM make gen build-app`（`make gen` 打出 `[sign-mode] 开发签名…` 才对）。
5. **Debug 构建的主二进制是个桩**：`otool -L PlusMix.app/Contents/MacOS/PlusMix` 看不到 libndi，它和 SDK 目录的 rpath 都在 `PlusMix.debug.dylib` 上；查 Debug 构建的链接 / rpath 看 debug.dylib（Release 归档没有它）。
6. **R17 的产物落 `.build/DerivedData`**（与 make build-app 同一处，所以快）：跑完 Debug 产物是开发签名的，之后不给别名的 `make build-app` 按工程里的模式重签回去；第一次冷编 40 s（M5 Max）。CI 上默认跳过（`RELEASE_TEST_DEV_SIGN=1` 强制）——今天的工作流本来就不跑 release-test。
7. **Team ID 不是证书名括号里那串**（34XFY3Q25G 是个人证书编号）：sign-mode.sh 按 SHA-1 找证书、读 OU；`make gen` 给错 Team 时会列钥匙串里实际的 Team；xcodebuild 的报错原文见 §2。
8. **TCC 记在谁名下**：`open …/PlusMix.app`（LaunchServices）→ 记在 PlusMix（bundle id + 指定要求，开发签名下稳定、不看路径——换 worktree 编出来的也应不重问，清单里让人顺手验）；直接跑 `Contents/MacOS/PlusMix` → 记在 Terminal 名下，测不出签名的作用；Claude 的 Bash 起的拿不到。xcodebuild test 的宿主自己是 TCC 客户端（G13 的第 2 遍沾光就是这样）。
9. 反证留下一份崩溃报告 `~/Library/Logs/DiagnosticReports/PlusMix-2026-11-08-000959.ips`（scratchpad 副本里的 dyld abort，procPath 在 /private/tmp），预期、不是回归。App 全量日志里的 "Thread Performance Checker" 回溯是渲染线程起步的优先级反转提示，ad-hoc 时也有，与签名无关。
10. `VirtualCameraAppTests.testVirtualCamera_extensionActivationInAdHocSignedApp_reportsBlocked` 在开发签名宿主里也过（原因换成 Missing entitlement），但名字和打印里的"ad-hoc 签名的测试宿主"不准了——不是缺陷，App 会话哪天碰这个文件顺手改名。
11. `git mv` 先 stage 了改名，之后 `git add <几个文件> && git commit` 会把那次改名一起带走（本会话撞了一次、重做了两个本地提交）。
12. 给 G14：合入后 `make gen` 每次多打一行 `[sign-mode] …`（ad-hoc 时提示钥匙串里有 Apple Development 可用）；docs/checklists/G14.md 照 G13.md 写时把前提段"用开发签名跑这份清单"那句带上；本分支只改 project.yml 的签名段与 App target 的权限表段，bump-version 改的 MARKETING_VERSION 行不重叠。
