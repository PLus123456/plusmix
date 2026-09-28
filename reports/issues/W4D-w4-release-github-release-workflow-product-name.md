# W4D → W4-B / W4-B2（.github/ 的归属）：release.yml 写死了 Switcher-<版本>.dmg / Switcher-<版本>.md / "Switcher <版本>"，改名后发布工作流会在"收集产物"一步失败

发现于：W4-D（prompt 75，分支 w4-rename，2026-09-28），把 `scripts/release/archive.sh` 的产物名改成读 project.yml 的 PRODUCT_NAME（PlusMix）时；本会话只准动
App / CameraExtension / docs / scripts/release / Tools/streamdeck-plugin，`.github/` 不在范围内（W4-B 的行），prompt 83（W4-B2）的范围也没有它。
严重级：S2（只影响 CI 的发布工作流；现在没有 GitHub 远程、没有 runner、没有账号，本来就是 BLOCKED-账号，不影响本机 `make archive-adhoc` / `make release-test`）。

## 现象

`.github/workflows/release.yml`（W4-B 写的）有四处按旧产物名写死：

| 行 | 内容 | 改名后会怎样 |
|---|---|---|
| 80 | `scripts/release/changelog.sh "$VERSION" > "$dir/Switcher-$VERSION.md"`（两处） | 更新说明写成 `Switcher-0.1.0.md`，而 DMG 叫 `PlusMix-0.1.0.dmg`；`generate_appcast` 只认与 DMG 同名的 .md → appcast 没有更新说明（不报错，静默少东西） |
| 96–97 | `upload-artifact` 的 `path` 列 `Switcher-*.dmg`、`Switcher-*.dmg.sha256` | 一个都匹配不到，`if-no-files-found: error` → job 失败 |
| 112–113 | `gh release create … --title "Switcher $VERSION" --notes-file "$dir/Switcher-$VERSION.md" "$dir/Switcher-$VERSION.dmg" "$dir/Switcher-$VERSION.dmg.sha256"` | 文件不存在 → `gh` 报错；标题也该是产品名 |

## 建议的修法（任选，都不用改 archive.sh）

1. 与 `scripts/release/archive.sh` 同一套读法：`product=$(sed -n 's/^[[:space:]]*PRODUCT_NAME:[[:space:]]*"\{0,1\}\([A-Za-z0-9][A-Za-z0-9._-]*\)"\{0,1\}.*/\1/p' project.yml | head -1)`
   放进 `steps.ver` 一起输出（`echo "product=$product" >> "$GITHUB_OUTPUT"`），后面四处用 `${{ steps.ver.outputs.product }}` / `$PRODUCT`。
2. 或者产物一律按通配找：`*.dmg` / `*.dmg.sha256`，更新说明按 DMG 的 basename 命名（`dmg=$(ls "$dir"/*.dmg | head -1); base=${dmg%.dmg}; changelog.sh > "$base.md"`）。

`scripts/release/tests/test-r6-workflows.sh`（R6）现在只查 actionlint 与几个关键字，没查产物名——修的时候加一条"release.yml 里没有写死 `Switcher-`"的断言，或者断言它引用了 `PRODUCT_NAME` / 通配。

## 归属

`.github/` 在 docs/OWNERSHIP.md 里只有 W4-B 的行有；W4-B2（prompt 83，`w4-release-2`）的"只准动"是 scripts/release/、scripts/check-links.sh、docs/release/。
要么给 W4-B2 的行加 `.github/workflows/release.yml`，要么由检查点走胶水额度改这四行（十行以内）。
