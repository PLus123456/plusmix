# 随包手册目录要在 project.yml 里写成 folder reference——103 的目录里没有 project.yml

归属会话 / 分支：W4-C2（prompt 103，`w4-docs-2`）+ 认领 project.yml 的那一行（等用户定：给 103 的归属行加 `project.yml`（只加 `App/Resources/Help/` 那一条 folder reference），或由下一个检查点加）
发现于：G7 检查点读 reports/w5-app-toolbar.md §5 第 10 条（W5-G 在草稿区拷贝里做的探针）
现象：
- App（W5-G）找随包手册的路径是 `Contents/Resources/Help/<lproj 名>/index.html`（`zh-Hans`、`en`），没有就 `Help/index.html`；现在包里没有 Help，帮助菜单"PlusMix 使用手册"灰着、标题写"手册尚未随包"。
- XcodeGen 会把 `App/Resources/Help/` 下的文件当普通资源一个个加进 Copy Bundle Resources：拷进包时目录层级没了，`zh-Hans/index.html` 与 `en/index.html` 撞名（探针：pbxproj 里是两条 "index.html in Resources"）。所以这个目录要在 project.yml 里另写成 folder reference（`type: folder`），整个目录原样进包。
- prompt 103 的"只准动"是 `docs/`（不含 spec / plan）、`Samples/`、`README.md`、`App/Resources/Help/`——没有 project.yml；W5-L 行的 project.yml 授权只限 SwitcherTally 那一条。
复现步骤：在草稿区拷贝的 `App/Resources/Help/zh-Hans/` 与 `en/` 各放一个 index.html → `xcodegen generate` → 看 pbxproj / 编出来的包。
严重级：S3（发布工程；手册随包是 0.1.x 的交付项之一，prompt 103 / Q33）。
建议：用户定归属（最省事：103 的 OWNERSHIP 行加 `project.yml`，并注明只加 Help 的 folder reference 一条）；写法一行 `- path: App/Resources/Help  type: folder`（放 App target 的 sources 下），编完 `ls PlusMix.app/Contents/Resources/Help/` 应有 `zh-Hans/index.html`、`en/index.html`。
