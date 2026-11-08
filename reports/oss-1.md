# OSS-1 开源发布（2026-11-08）

分支 `oss-1`（worktree `.claude/worktrees/g14-checkpoint-merge-release-64b9e9`，从 main 6b504ea 开；G14 会话续做）。用户 2026-11-08 直接指定：把当前版本推到 GitHub 开源，最好带上之前每一次提交；README 补上 Codex 做的图标与演示动画，改成英文主版 + 中文版，做得好看一些；Codex 那边已按用户要求提交（c70d6c4）。

## 1. 做了什么

- **合入 Codex VIS-1**：`codex/readme-visuals` = c70d6c4（30 个文件：AppIcon 十张 PNG + Contents.json、docs/media 的图标 SVG / PNG、两段演示 GIF、静态界面图、image2 原图与提示词、六个生成脚本、README +18 行、project.yml 一行、OWNERSHIP 一行、reports/codex-readme-visuals.md）→ 合并提交 3ceac72。只在 docs/OWNERSHIP.md 冲突（Codex 基于 1886bde，VIS-1 行与 G14 / G15 行同位置）：保留 g14 的行、只接 VIS-1 一行、行尾记去向。合并结果与主检出里 Codex 同步过来的未提交副本逐字节相同（29 / 30，OWNERSHIP 只差那句去向）。
- **开源前审查**（范围 = main + c70d6c4 能到达的全部 977 个提交、4895 个文件版本，未压缩 132 MB、打包 35 MB）：
  - 大文件：最大 8.8 MB（libsamplerate 的系数表），没有接近 GitHub 50 / 100 MB 限制的。
  - 密钥与令牌：私钥块、GitHub / OpenAI / Anthropic / AWS / Slack / Google 令牌、JWT、Bearer、Twitch 推流密钥、序列号 / UDID，文件内容与提交信息里都是 0 处。推流平台地址只有公开入口（不带密钥）；邮箱只有 git 署名、上游库作者与 example.com 测试值。
  - 敏感文件类型：没有 .p12 / .pem / .mobileprovision / .env 一类；只有一个 zip，见下一条。
  - **竞品素材**：`docs/spec/ui-mock/` 与内容相同的 `docs/spec/Vmix macOS风格界面设计.zip` 是早期界面稿：一个标题用竞品品牌的 HTML 界面稿，加 `uploads/` 下三张竞品软件的真实截图（主窗口、输入选择、录制设置）。输入选择那张露出个人文件路径（微信 wxid 目录、课程资料目录、以人名命名的视频文件），录制设置那张露出 Windows 用户名。这些字只在图片像素里，文本历史里搜不到。它们从第一个提交 89b7ca3（2026-09-12）起就在库里；设计方案 §0 与 .gitignore 早就写了"竞品截图是作品，只留在本机"，这两处是漏网。
  - 自家截图：docs/ui-study/img（48 张）、App/Resources/Help/img、App/Tests/Artifacts 里挑最可能露信息的 7 张看过（添加输入三页、远程控制、音频设备、推流、录制）：只有通用设备名、机型、回环地址与临时目录，没有个人信息。
- **当前版本移出那两处**（f56763f）：`git rm`，.gitignore 加 `docs/spec/ui-mock/`、`docs/spec/*.zip`（顺带 `vmix-28-guide.zip`），让它们以后只留在本机。没有 Markdown 链接指向它们。
- **README**（0a15820）：README.md 改成英文主版，新加中文版 README.zh-CN.md，两份结构一一对应：居中图标、徽章、语言切换、页首切换演示 GIF、导航；功能分输入 / 切换与转场 / 叠加与多画面 / 音频 / 输出 / 控制 / 可量化验证七节，逐条对过代码与英文手册；项目状态改到 G14（原 README 停在 G8：861 / 244 个用例、"8 小时已复验"都过时了）；架构用 mermaid 画依赖方向；英文版里只有中文的文档都标了 (Chinese)；README 里不写竞品名（prompt 72 第 6 条）。docs/tools/check-links.py 的默认范围加上 README.zh-CN.md。
- **推送（用户 2026-11-08 选"去掉截图推全历史"）**：在临时副本里用 `git filter-branch --index-filter` 把那两处从 982 个提交里全部去掉（49 s），逐个核对后加一个 docs/history 提交（README + 982 行新旧提交号对照表 commit-map.tsv），本地 `main-pre-oss` 备份旧 main（918f397）、本地 main `reset --keep` 到重写版 0a8783a，新建公开仓库 https://github.com/PLus123456/plusmix 并 `push -u origin main`（凭据只在那一条命令里临时用 `gh auth git-credential`，没改 git 配置；提交信息带 `[skip ci]`，见 §5）。
- 推送后的收尾：scripts/gen-prompt-page.py 的合入判定加认 `main-pre-oss`（不然老分支全显示"等合 main"）；README 架构图改竖排；OWNERSHIP OSS-1 行、prompt 143（G15）、落地方案 §8.8 各记一段。

## 2. 检查

| 项 | 结果 |
|---|---|
| `make lint BRANCH=oss-1`（C locale） | 过：禁词、版本号 0.1.0、包约束、依赖方向 8 包、归属（12 个改动文件都在范围内，合并冲突解决 OWNERSHIP +1 / −5 单列）、check-help（18 个文件 879.0 KB）、check-links 231 个 Markdown、check-rt-symbols、check-shell-utf8-vars |
| `make lint BRANCH=oss-1`（UTF-8 locale） | 过 |
| README 渲染 | pandoc 本地预览（项目内 .build/ + 本地 http 服务）：图标、徽章、语言切换、两段 GIF、表格正常；mermaid 图与 `> [!NOTE]` 只有 GitHub 渲染，本地没验 |
| 重写核对（982 个提交） | 每个提交的文件清单与内容哈希，去掉那两处后与原提交完全相同（982 / 982）；作者、邮箱、时间、提交者、提交信息逐字相同；合并 98 = 98；最终文件树相同；被删的 7 个文件版本在新历史里不可达 |
| 推送结果 | https://github.com/PLus123456/plusmix 公开，默认分支 main，远端头 = 本地 0a8783a，983 个提交（982 + docs/history），打包 29 MB；GitHub 识别许可证 Apache-2.0；`docs/spec` 下只剩三份规格，碰过 `docs/spec/ui-mock` 的提交 0；没有触发工作流 |
| GitHub 页面 | 内置浏览器看过：README 的图标、徽章、两段 GIF、状态提示框（`[!NOTE]`）、mermaid 架构图、表格都正常渲染 |

## 3. 没做的和原因

1. **推送：用户选了 (A)，已推**（§1、§2）。当时的考虑留作记录：历史里的竞品截图带个人信息，光在当前版本删掉不够——推完整历史就会把它们一起推上去。两种推法：(A) 把这两处从全部提交里去掉、再推完整历史：每个提交换新哈希，文档 / 报告里引用的旧短哈希在 GitHub 上查不到（附 old → new 对照表），本地 main 换成重写后的那份，旧 main 留一个备份分支；(B) 只推当前版本的一个快照提交，没有过程历史。选 (A) 的代价：每个提交换新哈希，旧短哈希查 docs/history/commit-map.tsv；提交署名的 QQ 邮箱照旧公开（用户没要求换成 GitHub noreply）。
2. **英文版动画没做。** Codex 的两段 GIF 是中文界面、中文字幕（`docs/media/tools/encode-demo.py` 与 `make-demo.py` 写死中文），英文 README 里看到的也是中文画面。要英文版得改这两个脚本的文字、用英文界面重录（要屏幕录制权限，录制时不能切走前台），留作后续。
3. `docs/media/README.md` 只有中文。

## 4. 对契约的疑问

无，没碰契约。

## 5. 下一个会话需要知道的坑

1. **开源前审查别只扫文本**：这次的个人信息全在图片像素里，文本搜索一处都找不到，必须把历史里的图片挑着看。
2. **内置浏览器打开项目外的本地文件只给静态快照**（data: URL），相对路径的图片出不来；把预览放进 worktree 的 `.build/`，用 `python3 -m http.server` 起本地服务再看。
3. **主检出带着 Codex 同步过来的未提交副本**：Codex 的"同步回原目录"会把同一份改动拷进 `/Users/plus/plusmix`。快进 main 前先核对这些副本与已提交的版本逐字节相同、拷一份备份，再还原 / 移走，快进后再看 `git status`（reports/G14.md §10 第 13 条）。
4. 如果推送选 (A)：以后所有会话都从重写后的 main 开；Codex 的 worktree（`~/.codex/worktrees/f8f1/plusmix`，`codex/readme-visuals`）和本仓库其他老分支都还在旧历史上，别再拿来合。
5. **历史重写之后**：本地 main 与 GitHub 是重写版，128 之前的所有老分支、各 worktree、Codex 的 `codex/readme-visuals` 都在旧历史上，与新 main 没有共同祖先——别再合，`check-ownership.sh <老分支>` 也找不到 merge-base。旧 main 在本地备份分支 `main-pre-oss`，别删：gen-prompt-page.py 靠它判断老分支已合入。
6. **仓库的 CI 是 self-hosted runner**（`.github/workflows/ci.yml` 推任何分支 / PR 都触发，`nightly.yml` 每天 UTC 19:00），公开仓库里没有 runner，任务会排队到超时；这次两次推送的提交信息都带 `[skip ci]`，定时任务不受它影响。公开仓库不建议把自己的 Mac 挂成 runner（别人的 PR 能在上面跑代码）。
7. **推送凭据**：本机 git 的凭据助手是 osxkeychain，没有 GitHub 令牌；用 `git -c credential.helper= -c 'credential.helper=!/opt/homebrew/bin/gh auth git-credential' push …` 只在这条命令里借 gh 的登录，不改全局配置。
8. **Claude in Chrome 这次连不上**，看 GitHub 页面用的是内置浏览器（锚点跳转用带 `#标题` 的地址，scroll_to 不动）。
