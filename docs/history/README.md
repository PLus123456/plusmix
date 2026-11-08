# 提交历史说明 · About the commit history

**中文**　2026-11-08 开源前（OSS-1，见 [reports/oss-1.md](../../reports/oss-1.md)），用 `git filter-branch` 把早期界面稿 `docs/spec/ui-mock/` 与同内容的 zip 从全部提交里去掉：里面是第三方软件的截图，截图里还有个人信息。其余文件、提交信息、作者与时间都没动，98 个合并保持原样，但每个提交的哈希都变了。

`reports/`、`docs/plan/`、`docs/OWNERSHIP.md`、`docs/KNOWN_ISSUES.md` 等文件和提交信息里引用的提交号（例如"合并提交 2ab726f"）是重写前的。用 [commit-map.tsv](commit-map.tsv) 查对应的新提交（第一列旧、第二列新）：

```bash
grep '^2ab726f' docs/history/commit-map.tsv
```

**English**　Before the code was published on 2026-11-08, `git filter-branch` removed an early UI mock-up (`docs/spec/ui-mock/` and a zip with the same content) from every commit, because it held third-party screenshots with personal information in them. All other files, commit messages, authors and dates are unchanged, and the 98 merges keep their shape, but every commit id changed. Commit ids quoted in reports, plans and commit messages written before that day refer to the old history; look them up in [commit-map.tsv](commit-map.tsv) (old id first, new id second).
