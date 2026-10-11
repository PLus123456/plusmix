# 兼容层：31 个对方真实存在的函数名仍返回 400 UnknownFunction（02 X51），没有任何 prompt 认领

归属会话 / 分支：建议 W5-M（prompt 100，`w5-transition-slots`：`Packages/SwitcherControl/Sources/VMixCompat/` 在它的归属行里、它本来就要改 `FunctionCatalog.knownUnimplemented`）；或由用户另指
发现于：W4-C2（prompt 103，分支 `w4-docs-2`）。prompt 103 交付 3 要"覆盖表按 X51 的 501 口径改"，但实现没改，文档只能照实写
现象：
- docs/ui-study/02-功能缺口.md X51：`NDISelectSourceByName`、`StreamingSetKey`、`AutoPlayOn` 等 31 个对方真实存在的函数名不在 `FunctionCatalog.knownUnimplemented`，也不匹配 `knownUnimplementedPrefixes`，
  所以 `GET /api/?Function=NDISelectSourceByName` 回 400 `UnknownFunction`；按兼容层自己的定义（对方有、这里没做）应回 501 `NotImplemented`。
- 2026-10-10 的 main（93f50d9）上 `Packages/SwitcherControl/Sources/VMixCompat/FunctionCatalog.swift:91-134` 仍是这样；prompt 99–107 的交付里都没有 X51（prompt 100 只把 Transition2–4 / SetTransitionEffect2–4 / SetTransitionDuration2–4 从 knownUnimplemented 里拿掉）。
- 文档：`docs/integrations/vmix-compat.md` §6 末尾那句"另有 31 个……现在也被当成'不认识'返回 400，按上面的定义应返回 501"保留着（照实）。
复现步骤：起兼容层（App：设置 › 远程控制 › 第三方 API 兼容层，或 `switcher-headless run … --compat`），`curl 'http://127.0.0.1:8088/api/?Function=NDISelectSourceByName'`。
严重级：S3（错误码不对，客户端日志里看到的是"不认识"而不是"没做"）
建议：照 X51 / V14 的建议把这 31 个精确名字补进 `knownUnimplemented`（不加前缀族），C5 用例里加一条 501 的断言；改完告诉文档会话删掉 vmix-compat.md §6 那句。
