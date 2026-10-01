# 控制 API 的全量状态里带推流密钥和地址里的账号密码

归属会话 / 分支：控制会话（W2-C / W3-D 系，Packages/SwitcherControl/Sources/SwitcherControl/API/）；要不要改字段归契约（MixerState 原样嵌入是 W2-C 的设计）
发现于：W5-D（w5-stream-auth）排查推流凭据会出现在哪里，main 25af61f
现象：`GET /api/v1/state` 和 WebSocket 的状态推送原样嵌入 `MixerState`（APIServer.swift:12、:112，APIModels.swift:33），
      outputs[].settings.stream 里的 `streamKey` 和 `url` 都是原文；W5-D 之后 url 里的 user:pass@ 会生效，也就是密码。
      API 没设 token、又监听在局域网时，同网段任何人都能读到推流密钥 / 密码（设了 token 的话，拿到 token 的控制面板 / 脚本也都能读到）。
复现步骤：开 API（不设 token）→ 加一路推流填 rtmp://u:secret@h/app、密钥 k → curl http://<本机>:<端口>/api/v1/state | grep -E 'secret|"k"'。
严重级：S2（看部署：只开本机且有 token 时 S3）
建议改法：API 输出的状态里把 streamKey 换成"有 / 没有"、url 过 SwitcherStreaming 的 `StreamURLRedaction.redact(url:)`（与诊断包同一份名单）；
      要读原文的场景（远程改推流设置）单独给一个要 token 的接口。字段形态变了要走 docs/contract-changes/ 提案。
