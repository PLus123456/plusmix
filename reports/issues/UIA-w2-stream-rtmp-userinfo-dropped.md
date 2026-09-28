# RTMP 推流地址里的 user:pass@ 被丢掉，需要鉴权的服务器推不上

归属会话 / 分支：推流会话（W2-D 系）；`Packages/SwitcherOutputs/Sources/Streaming/`
发现于：界面对照调研 UIA，提交 c836cce；R7-M10 / G07，核对 VF1 属实
现象：推流页只有地址和密钥两项；即使把用户名密码写进地址（rtmp://user:pass@host/app），连接时也不带：重拼 connectURL 只拷 scheme / host / port / path / query。
复现步骤：自建需要鉴权的 RTMP 服务器，地址写 rtmp://user:pass@host/app，开推流，服务器端拒绝鉴权。
严重级：S2（自建服务器 / 部分 CDN 要鉴权；绕过办法是换不要鉴权的入口）
猜测原因：`Packages/SwitcherOutputs/Sources/Streaming/StreamDestination.swift:54-60` 用新的 URLComponents 重拼，没拷 user / password。
建议改法：先按铁律 10 写探针确认推流库在 connect URL 里带 userinfo 时是否走 RTMP 鉴权；成立则保留 userinfo；推流页"编码详情…"旁加"鉴权…"（写回 url 的 userinfo），诊断包的脱敏同密钥（App/Sources/Release/ShowRedaction.swift）。
