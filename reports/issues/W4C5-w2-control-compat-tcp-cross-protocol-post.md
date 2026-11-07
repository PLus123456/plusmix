# 兼容层 TCP 入口（默认 8099）疑似能被网页用跨协议 POST 打到：HTTP 头逐行当"不认识的命令"放过，正文里的 `FUNCTION Cut` 照样执行

归属会话 / 分支：下一个动 `Packages/SwitcherControl/Sources/VMixCompat/` 的控制层会话（W2-C 续做）
发现于：W4-C5（prompt 135，分支 `w4-docs-5`）写 docs/integrations/vmix-compat.md"TCP 入口不查来源"那一句、对 `CompatTCPServer.handle(line:)` 核对时
严重级：**疑似**，建议按 NS02 / NS05 同类定（S2：兼容层默认关、默认只听 127.0.0.1；打开时能被操作员正在看的任意网页切画面 / 停录制）——**浏览器侧没有验证**，见"没验证的部分"

## 现象（静态确认的部分）

131 W2-C5 给主 API 与兼容层 **HTTP** 入口装了浏览器来源拦截（`BrowserRequestGuard`，403），报告写"TCP 8099 不涉及"。
但 TCP 入口的读循环（`CompatTCPServer.readLoop` → `handle(line:)`，Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:115–225）是按行切、每行按第一个空格拆出命令：

- 认不出的命令只回一行 `<命令> ER UnknownCommand: <命令>`、**`return .continue`，连接不关**（同文件 :221–224）；空行跳过（:154）。
- 所以一条打到 8099 的 HTTP 请求——`POST / HTTP/1.1`、`Host: 127.0.0.1:8099`、`Origin: …`、`Content-Type: text/plain`……——每个头都只换来一行 UnknownCommand，
  空行之后的**正文**照样逐行当命令执行。

浏览器能发出这种正文：`<form method="POST" action="http://127.0.0.1:8099/" enctype="text/plain">` 里放 `<input name="FUNCTION Cut&#13;&#10;x" value="">`，
text/plain 编码的正文就是 `FUNCTION Cut\r\nx=\r\n`（"名字=值\r\n"，名字里的换行原样保留）——第一行就是一条完整的兼容层命令。不需要读应答，副作用在服务端已经发生。
更省事的是脚本：`fetch("http://127.0.0.1:8099/", {method: "POST", mode: "no-cors", body: "FUNCTION Cut\r\n"})`（no-cors 下 text/plain 正文是"简单请求"，不预检；W4-C5 的核对 agent 独立读代码时也指出了这条）。

## 没验证的部分

- 没在真浏览器里打过：8099 不在 Chrome / Safari / Firefox 的"不安全端口"名单里（名单里是 25、110、6000、6665–6669 这类），但近两年 Chrome 的"本地网络访问"（Private / Local Network Access）
  会对公网页面访问 127.0.0.1 加预检 / 弹权限，Safari 的行为我没查到——**能不能发出去要真浏览器验**。
- 主 API（8765）不受影响：它是 HTTP 服务器，`BrowserRequestGuard` 先拦。tally 流只读。

## 建议

1. 先复现：开兼容层（设置 › 远程控制，或 `SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter testC5_manual`），
   本机 `printf 'POST / HTTP/1.1\r\nHost: 127.0.0.1:8099\r\nContent-Type: text/plain\r\n\r\nFUNCTION Cut\r\n' | nc 127.0.0.1 8099` 看 PGM 换没换（证明解析器不因 HTTP 头断开）；
   再用一个 file:// 或 localhost 页面上的上面那个表单在 Safari / Chrome 各点一次。
2. 改法（和 Redis 防跨协议同一个思路，几行）：一条连接的**第一行**像 HTTP 请求行（`^[A-Z]+ \S+ HTTP/\d\.\d$`），或任何一行以 `Host:` / `Origin:` / `Sec-Fetch-` 开头，
   就记一行日志、**不执行任何东西、直接关连接**。真协议里不会出现这些行（Companion 只发 FUNCTION / TALLY / XML / ACTS / SUBSCRIBE / PING / VERSION / QUIT），C5 的六项不受影响。
3. 用例：上面那段 HTTP 字节流 → 连接被关、`core.noteConnectionClosed` 计数、状态机没收到 Cut；正常 Companion 序列（`scripts/apitest/c5-companion.py`）照旧过。
4. 修了告诉文档会话：docs/integrations/vmix-compat.md §8 那句"TCP 入口不查来源（它不是 HTTP，没有这两个头可查）"补一句"看到 HTTP 请求直接断开"。
