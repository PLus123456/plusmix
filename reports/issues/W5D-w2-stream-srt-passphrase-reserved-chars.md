# SRT 的 passphrase / streamid 里有要转义的字符（空格 & = % + 中文……）就推不上

归属会话 / 分支：推流会话（W2-D 系，Packages/SwitcherOutputs/Sources/Streaming/ 的 SRT 分支）；W5-D 按 prompt "SRT 分支不动"没改
发现于：W5-D（w5-stream-auth）给 RTMP 鉴权做 SRT 对照的探针（reports/w5-stream-auth.md §1.4），HaishinKit 2.2.5 + MediaMTX 1.21
现象：MediaMTX 路径配 `srtPublishPassphrase: "pass word&1=2Z"`，地址写 `srt://127.0.0.1:18891?streamid=publish:srtq&passphrase=pass%20word%261%3D2Z`（按 URL 规矩转义）→
      HaishinKit `failedToConnect(peer)`，MediaMTX 日志 `closed: invalid passphrase`。不转义又会被 & / = 拆错参数、空格被 Foundation 自动编码。
      对照：同一台 MediaMTX，passphrase 只含字母数字时连得上；错的 / 没给的分别是 `invalid passphrase` / `passphrase not provided by client`。
原因：HaishinKit `SRTHaishinKit/Sources/SRT/SRTSocketURL.swift:9-24` 按 `?` `&` `=` 手切查询串、值不做百分号解码就交给 SRTO_PASSPHRASE / SRTO_STREAMID；
      我们这边 `StreamDestination` 的 SRT 分支 `c.queryItems = items` 还会按 URLComponents 的规矩重新编码一遍。
复现步骤：探针在 scratchpad（见报告 §1.4 的命令）；或 StreamingTests 里仿 testSRT_endToEnd 给 MediaMTX 实例加 srtPublishPassphrase。
严重级：S3（绕过办法：passphrase 只用字母数字和 - . _ ~；streamid 同理）
建议改法：SRTTransport 连之前把地址的查询串解码一次、用 SRTSocketOption 自己设（或者把解码后的值按 libsrt 能收的形式重新拼），不靠 HaishinKit 的手切；
      StreamDestination 的 SRT 分支改用 percentEncodedQuery 原样带（W5-D 已对 RTMP 分支这么做）。另：HaishinKit 上游的 SRTSocketURL 也该解码。
