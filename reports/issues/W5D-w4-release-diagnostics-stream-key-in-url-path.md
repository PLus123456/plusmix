# 诊断包：推流密钥写在地址路径里（rtmp://host/app/密钥）时原样进 zip

归属会话 / 分支：W4-B 发布工程（App/Sources/Release/ShowRedaction.swift 的设计）；W5-D 只按 prompt 加了 userinfo 打码，没改路径的规矩
发现于：W5-D（w5-stream-auth）改 ShowRedaction 时，main 25af61f
现象：`StreamDestination` 支持"密钥栏空着、地址最后一段就是发布名（密钥）"（rtmp://a.rtmp.youtube.com/live2/xxxx-xxxx-xxxx 这种整条粘贴），
      而 `ShowRedaction` 的口径是"主机、端口、路径保留"，所以这种写法的推流密钥会原样出现在诊断包的 show.switcher.json 里（R7 的"密钥一个字都不出现"只测了密钥栏）。
复现步骤：推流输出密钥栏留空、地址填 rtmp://h/live/SECRET-KEY-123 → 帮助 → 导出诊断包 → 解包 grep SECRET。
严重级：S2（密钥外泄；这种写法很常见）
建议改法：redact(json:) 处理 stream 字典时看同一层的 streamKey：为空且 RTMP 地址路径 ≥ 2 段，就把最后一段换成标记（与 StreamDestination 的拆法一致）；
      或者在 StreamURLRedaction 里加一个"路径末段是发布名"的选项给诊断包用（日志用的地址本来就不带发布名）。R7 补一条整条地址的用例。
