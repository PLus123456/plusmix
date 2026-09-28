# W4-B2 发布脚本收尾——分支 w4-release-2

prompt：docs/plan/prompts/83-W4B2-发布脚本收尾.md（用户 2026-09-28 指派 agent 直接做）。从 main `7a2a73f` 开（W4-D 改名、W2-C2、W1-A4 都已合入）。
机器：M5 Max，macOS 27.0（26A428），Xcode 27.0（27A266a），xcodegen 2.46.0，actionlint 1.7.12（带 shellcheck 0.11.0），接电源；0 个代码签名身份（ad-hoc）。
提交（先测试后实现，每条交付一次提交）：`88fb567` R11 → `9090db9` check-links 挂 lint → `83ae1c7` release.yml 产物名 → `5767a30` docs/release →
`12d3994` Application Support 目录名 → `17afc39` 断言库去掉管道竞争 → `2aff69a` 问题单 → `e522943` 发布脚本其余四处同类竞争 → 本报告（分支顶）。
验证在 2026-09-28 21:45–21:48 跑（`make release-test` 1 分 56 秒）；当时 G5 的 phase5 正在另一个 worktree 跑 SwitcherOutputs 的 `swift test`，协调方确认可以并行（屏幕锁着，本线没有显示类用例）。

## 1. 做了什么

### 1.1 交付 1：R11 不再写死占位前缀（`88fb567`）

`scripts/release/tests/test-r11-set-bundle-id.sh` 原第 10–11 行断言 `--check` 报出 `com.example` / `com.plusmix`，G5 按用户裁定切到 com.plusmix 之后必红（问题单 G5-w4-release-r11-assumes-placeholder-prefix）。现在：

- App 前缀从 project.yml 读：`sed -n 's/^ *bundleIdPrefix: *\([^ #]*\).*/\1/p'`（行尾注释不带进来）；Stream Deck 前缀从 `Tools/streamdeck-plugin/*.sdPlugin/manifest.json` 的顶层 `UUID` 读（python3 json，去掉 `.switcher`）。
  两处都**不是** set-bundle-id.sh 自己读的地方（它读 `PRODUCT_BUNDLE_IDENTIFIER` 与目录名），所以脚本报的和仓库对不上也会红。
- 断言收紧成带标签的整句：`App / 扩展 bundle id 前缀：<前缀>（`、`Stream Deck 插件前缀：<空白><前缀>（`（点号转义，bash 3.2 下验过）。
- 顺手把同一类写死也按读到的前缀拼：`--list` 里的插件目录（从 manifest 所在目录取）、"副本里旧前缀一处不剩"的旧 id——否则下次再切一次还是同一个坑。

### 1.2 交付 2：`scripts/check-links.sh`（`9090db9`）

`exec python3 "$(dirname "$0")/../docs/tools/check-links.py" "$@"`，可执行；按补充规则 4 被 Makefile 的 `EXTRA_LINTS` 与 CI 的 `scripts/release/ci-ownership.sh` 自动带上（没改 Makefile）。
先写断言：R13 加 7 条（可执行、`make -n lint` 里有它、在副本里放一个坏链接从 `/` 调用也退出非 0 并点名 `docs/a.md:1: 目标不存在`、给范围参数时只查那个范围、链接都对时退出 0）。

### 1.3 交付 3：release.yml 产物名跟 PRODUCT_NAME（`83ae1c7`）

`.github/workflows/release.yml` 的 `ver` 这步在版本号之外用 **archive.sh 同一条 sed** 读 App target 的 `PRODUCT_NAME`（读不到 `::error::` 停），`{ echo version=…; echo product=…; } >> "$GITHUB_OUTPUT"`；
问题单点名的四处全改：appcast 那步的更新说明 `"$dir/$PRODUCT-$VERSION.md"`（两处）、上传产物 `…/${{ steps.ver.outputs.product }}-*.dmg(.sha256)`、
`gh release create --title "$PRODUCT $VERSION" --notes-file "$dir/$PRODUCT-$VERSION.md" "$dir/$PRODUCT-$VERSION.dmg" "$dir/$PRODUCT-$VERSION.dmg.sha256"`；
两步的 `env` 加 `PRODUCT: ${{ steps.ver.outputs.product }}`。文件头注释写明产物名只在 project.yml 一处定义。
先写断言：R6 加 12 条——不写死 `Switcher-` 与 `"Switcher ` 标题；release.yml 里含 archive.sh 那条 sed 的原文（`grep -F`，两边读法绑死）；六个用到产物名的片段都在；
**把 ver 这步的 `run: |` 从 YAML 里抠出来（不依赖 PyYAML），在仓库根按 tag `v<MARKETING_VERSION>`、`bash -e` 真跑一遍**，输出 `product` = lib.sh 的 `product_name`（PlusMix）、`version` = 0.1.0。

### 1.4 交付 4：docs/release 跟上裁定与改名（`5767a30`）

| 文件 | 改了什么 |
|---|---|
| bundle-id.md | 标题与开头记"已定 com.plusmix.switcher（用户 2026-09-28 定前缀 com.plusmix，G5 用 set-bundle-id.sh 切，提交 62289ac）"；"现状 / 决定项"改成"已定的值 / 为什么定了就不再改 / 切换脚本（G5 已跑过；留给以后）"；验证一句写上 R11 现在读当前前缀 |
| signing.md | 干净机器第 2 步："右键 → 打开也能起"改成 macOS 15 起的真实步骤（被拦弹窗只有"完成"/"移到废纸篓" → 系统设置 › 隐私与安全性 › 底部"安全性"一栏"仍要打开"，尝试打开后约一小时内有按钮，要输密码 / 触控 ID）；补上隔离属性的坑（见 §5 第 4 条）；第 3 步 FaceTime 里选 "PlusMix" |
| KNOWN_ISSUES-template.md | 同一条"右键 → 打开"改成"仍要打开"的步骤（与 G5 的 docs/KNOWN_ISSUES.md 同一说法）。docs/release/README.md 里其实没有"右键"那句，prompt 说的 README 只有这份模板对得上 |
| checklist-first-signed-run.md | FaceTime 选 "PlusMix"（G5 在改名合入后把 `VirtualCameraConstants.deviceName` 改了，2bc4088）；扩展进程名 `com.plusmix.switcher.camera-extension`；Gatekeeper 一条写明装 `PlusMix-<版本>.dmg` 且 DMG 要带隔离属性 |
| versioning.md | 发布顺序第 3 步写产物名 `PlusMix-X.Y.Z.dmg` / Release 标题 "PlusMix X.Y.Z"；第 4 步原来指向不存在的"docs/release/README.md §4"，改成指向 signing.md 那一节的链接（check-links 验锚点） |
| ci.md / diagnostics.md / README.md | release.yml 一行写产物名从 PRODUCT_NAME 读；log 谓词写实际值（扩展进程名 = 它的 bundle id）；目录表 bundle-id 一行、归属段加 W4-B2 一句 |
| sparkle.md | W4-D 已改好，没动（`SWITCHER_APPCAST_URL=… open -a PlusMix` 这句我探针验过是对的，见 §5 第 6 条） |

### 1.5 交付 5：配置目录名（`12d3994`）

`~/Library/Application Support/Switcher/` → `PlusMix/`，**只改点名的 7 行**：docs/user/概念.md:90、快捷键.md:25 / 57、en/concepts.md:98、en/shortcuts.md:28 / 60、docs/release/diagnostics.md:7（`git diff -U0` 核对只有这 7 行）。
依据：W2-C2 已把 `UserConfig.directory` 改成 PlusMix，App 的 `autosaveURL` 现在就是 `UserConfig.directory/LastSession.switcher.json`（main 上核对过），`.switcher.json` 后缀是代码名不动。

### 1.6 顺手：R6 一次性红的根因——`printf | grep -q` 在 pipefail 下的竞争（`17afc39`、`e522943`）

W4-D 报告 §5 第 9 条记了 R6 一次性红（nightly.yml 明明有 soak-1h 却"找不到"），当时查不出机制。本会话探针（铁律 10）：

- FIFO 探针：读端先阻塞，bash 3.2 的 `printf '%s' "$多行"` 写进来，读端第一次 read 只拿到 81–567 字节（1–7 行），`cat` 同样内容一次拿到 8099 字节——**printf 内建往管道按行 write**。
- 于是 `printf … | grep -q` 在前几行命中时 grep 先退出，printf 再写就吃 SIGPIPE，`set -o pipefail` 下整条管道 141：`assert_contains` 报"找不到"、`assert_not_contains` 反而报**通过**。
  小内容是竞争（无负载时 nightly.yml 2000 次 0 次撞上；W4-D 那次正并行 swift build，soak-1h 在第 1 行），内容超过管道容量时必现（496 KB 内容 300 / 300 次返回 141，here-string 0 次）。
- 修法：`scripts/release/tests/lib.sh` 的两个断言改用 here-string 喂 grep（不走管道，语义不变）；R6 开头加一条回归（120 KB、命中在第 1 行的内容；旧库必红、新库绿）。
- 同一机制在发布脚本里还有四处，后果更糟，一并改成 here-string / 先收进变量：`archive.sh` 认 Team 身份（撞上会误退 ad-hoc）、`verify.sh` 查扩展 app-sandbox（撞上会误报缺权限）与 NDI LC_RPATH（多条 rpath 时可能漏报）、
  `pin-deps.sh verify-runtime`（只有真引用坏符号时才可能撞上 → 漏报；nm -u 实测 4000 行 / 168 KB）、R5 两条 appcast 版本号断言。`otool -L | grep -q`（实测 7 KB，小于 16 KB 的 stdio 缓冲，推断是一次写完，没单独探针）与单行内容的没动。

### 1.7 问题单（`2aff69a`）

reports/issues/W4B2-w4-docs-virtual-camera-device-name.md：docs/user 4 处还写 FaceTime 里的摄像头叫 "Switcher"（设备名已是 PlusMix），docs/user 按归属本会话只准动 Application Support 那几行。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

### 2.1 `make release-test`（scripts/release/tests/，日志 `.build/release-tests/`）：**PASS 10 / FAIL 0 / SKIP 0**，共 165 项断言，1 分 56 秒

| ID | 测什么 | 数值 | 阈值 | 通过否 |
|---|---|---|---|---|
| R1 `test-r1-archive-adhoc` | ad-hoc 全链 + 产物名 | 42 / 42，102 s：`PlusMix.xcarchive` / `PlusMix.app` / `PlusMix-0.1.0.dmg(.sha256)`；verify.json：signature_valid true、adhoc、bundle_id `com.plusmix.switcher`、extension_signed / extension_sandboxed / ndi_bundled / ndi_rpath_clean / sparkle_signed 都 true、notarized false（BLOCKED-账号，预期）；App 起 4 s 不崩 | 全过 | ✅ |
| R2 `test-r2-verify-rejects-unsigned` | 坏包被 verify.sh 拒 | 4 / 4 | 全过 | ✅ |
| R3 `test-r3-pinned-deps` | 依赖钉版本、改坏一份要红 | 6 / 6 | 全过 | ✅ |
| R4 `test-r4-runtime-symbols` | 主二进制与 dylib 不引用 `_swift_initBorrow` | 4 / 4（走的是改过的 pin-deps.sh verify-runtime） | 全过 | ✅ |
| R5 `test-r5-appcast` | appcast 生成与 EdDSA 验签 | 19 / 19，11 s | 全过 | ✅ |
| R6 `test-r6-workflows` | actionlint + 工作流关键字 + **产物名（新）** + **断言库回归（新）** | 30 / 30（原 17 + 产物名 12 + 回归 1）；改 release.yml 之前 10 / 29 红，旧 lib.sh 下回归那条必红 | 全过 | ✅ |
| R11 `test-r11-set-bundle-id` | bundle id 一键切换（**当前前缀改为从仓库读**） | 24 / 24；另在三种状态上各跑一遍都 24 / 24：切换前（62289ac^ 快照，com.example / com.plusmix）、现在（com.plusmix / com.plusmix）、副本再切到 org.sample-co；把 bundleIdPrefix 改得与 PRODUCT_BUNDLE_IDENTIFIER 不一致时红在"--check 报出当前 App 前缀"；旧 R11 在现在的树上 1 / 22 红（复现问题单） | 全过、切换前后都绿 | ✅ |
| R12 `test-r12-extension-strings` | 扩展显示名 | 7 / 7 | 全过 | ✅ |
| R13 `test-r13-make-targets` | make 入口 + **check-links 挂进 make lint（新）** | 15 / 15；加 check-links.sh 之前 5 / 15 红 | 全过 | ✅ |
| R14 `test-r14-version-changelog` | 版本号 / 变更日志工具 | 14 / 14 | 全过 | ✅ |

### 2.2 其他检查

| 项 | 结果 | 通过否 |
|---|---|---|
| `make lint BRANCH=w4-release-2` | 全绿：禁词、版本号 0.1.0 一致、Package.swift 约束、依赖方向 8 个包、**归属 23 个改动文件都在范围内**（报告提交后是 24 个）、**check-links（新挂上）120 个 Markdown 通过**、CSwitcherAudioRT 实时符号 | ✅ |
| `scripts/release/ci-ownership.sh --no-ownership`（CI 的 lint） | 也带上了 `scripts/check-links.sh` | ✅ |
| `actionlint`（1.7.12，带 shellcheck 0.11.0；确认过 shellcheck 规则在生效） | 0 告警，退出 0 | ✅ |
| `python3 docs/tools/check-links.py` | 120 个 Markdown 的相对链接与锚点都能解析（含新加的 `signing.md#gatekeeper-与干净机器验证人工`），Samples 节目文件合法 | ✅ |
| 交付 5 只改 7 行 | `git diff -U0` 核对：docs/user 6 行 + diagnostics.md 1 行，别处没动 | ✅ |

## 3. 没做的和原因

1. **release.yml 没在 GitHub 上真跑**：仓库没有远程、没装 runner、没有 secrets（BLOCKED-账号，同 W4-B）。只能静态验证：actionlint 零告警 + R6 把 ver 这步抠出来在本机真跑。
2. **macOS 15 起的"仍要打开"流程没在干净账户上实操**：要带隔离属性的 DMG + 图形界面 + 另一个用户账户，是 signing.md / checklist 里的人工项；写法按 Apple 对 macOS 15 的公开说明（右键 → 打开不再绕过 Gatekeeper，改到 系统设置 › 隐私与安全性"仍要打开"）。
   隔离属性这半截探针验过（§1.4、§5 第 4 条）。
3. **docs/user 里 FaceTime 摄像头名还写 "Switcher" 的 4 行没改**：docs/user 按 OWNERSHIP 只准动 Application Support 那几行 → 问题单 W4B2-w4-docs-virtual-camera-device-name（`2aff69a`）。
4. **`scripts/check-rt-symbols.sh:67` 同一类管道竞争没改**：`printf '%s\n' "$defined" | grep -qx -- "$s"`，在 pipefail 下命中提前退出时会把已定义符号当成"未审计"，是**假红**（安全方向，make lint 红一次复跑就过）；
   第 65–66 行是单行内容，没有竞争。scripts/ 顶层这个文件归 W1-D，不在本会话范围。
5. **R4 还是没有正例**（一个真引用 `_swift_initBorrow` 的 Mach-O）：可以用 `clang -Wl,-undefined,dynamic_lookup` 造一个；不在本次交付里，没做。
6. `docs/tools/check-links.py` 的 docstring 还写"要挂进 make lint 只需在 scripts/ 下加一个调它的 check-*.sh"——现在已经挂上了；docs/tools 归 W4-C，不影响行为，没动。
7. Stream Deck 插件的 `npm test` 没跑（worktree 没有 node_modules，本会话也没碰插件）。

## 4. 对契约的疑问

没有。没碰 SwitcherContracts、JSON 字段、测试图案；bundle id / 产品名是 G5 / W4-D 已落的裁定，本会话只让脚本与文档跟上。

## 5. 下一个会话需要知道的坑

1. **bash 3.2 的 `printf` 内建往管道按行写**：`printf '%s' "$多行" | grep -q …` 在 `set -o pipefail` 下，grep 命中前几行就退出，printf 再写吃 SIGPIPE，整条管道 141。
   断言会随调度翻转，内容超过管道容量（64 KB）时必现。发布脚本与断言库已改成 here-string（`grep -q -- "$pat" <<< "$var"`）；新写脚本照这个写，或先把命令输出收进变量再 grep。
   仓库里还剩 `scripts/check-rt-symbols.sh:67` 一处（§3 第 4 条）。
2. **R11 现在从仓库读当前前缀**：App 前缀 = project.yml 的 `bundleIdPrefix`，Stream Deck 前缀 = manifest 顶层 UUID 去掉 `.switcher`。手改 project.yml 时 `bundleIdPrefix` 与 `PRODUCT_BUNDLE_IDENTIFIER` 要一致（set-bundle-id.sh 会一起改），不一致 R11 会红——这是故意的。
3. **R6 把 release.yml 与 archive.sh 绑在一起**：release.yml 里必须逐字含 archive.sh 那条 `sed -n '…PRODUCT_NAME…' project.yml`（`grep -F`）。改 archive.sh 的读法要在同一个提交里改 release.yml 的 ver 这步，否则 R6 红。
   R6 用一个按行的小解析器（本机没有 PyYAML）从 YAML 里抠 `id: ver` 那步的 `run: |` 块：`id:` 要在 `run:` 之前、`run` 保持 `|` 块写法。
4. **干净机器验证要带隔离属性的 DMG**：本机 hdiutil 出的 DMG 没有 `com.apple.quarantine`，直接拷到另一个账户 Gatekeeper 根本不查，等于没验。
   从 Release 草稿下载或 AirDrop；或 `xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" PlusMix-<版本>.dmg` 再挂载。探针：挂载后镜像里的文件本身不显示这个属性，拷出来的 App 会带上 `0081;00000000;;`。
5. **`make release-test` 的 R1 很重**：会 `make gen` + `xcodebuild archive`（本次整条 R1 102 s），还会把 PlusMix.app 起 4 秒。
   别和显示类用例、gate4 / perf 计时并行跑；跑之前 `pgrep -fl xcodebuild` 看一眼（pgrep 也会匹配到命令行里带 "xcodebuild" 字样的包装脚本，要看清是不是真进程）。
6. **macOS 27 上 `open` 会把 shell 环境变量传给新起的 App**（探针：`PROBE_VAR=x open -a Probe.app` 里读得到；`open --env` 也行），所以 sparkle.md 的 `SWITCHER_APPCAST_URL=… open -a PlusMix` 是对的。
   App 已经在跑时 `open` 只是把它调到前台，变量不生效（按 open 的行为推断，没测）。
7. **check-links 挂进 make lint 之后**：任何文档改坏相对链接或锚点，本地 `make lint` 与 CI 的 lint 都会红。锚点按 GitHub 规则（全角标点丢掉、空格变 `-`），例如 `signing.md#gatekeeper-与干净机器验证人工`。
   只查一部分可以 `scripts/check-links.sh docs/user`。
8. **docs/user 里 FaceTime 摄像头名 4 行**等 W4-C / 检查点（问题单 W4B2-w4-docs-virtual-camera-device-name）。
