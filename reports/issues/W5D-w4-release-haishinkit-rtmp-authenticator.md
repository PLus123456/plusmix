# HaishinKit 2.2.5 的 RTMP 鉴权（RTMPAuthenticator）四个毛病：W5-D 绕开了，但根上要在依赖里修

归属会话 / 分支：W4-B 发布工程（依赖升级 / 是否给上游提补丁归这条线）；W5-D 只在 Packages/SwitcherOutputs/Sources/Streaming/ 里绕开
发现于：W5-D（w5-stream-auth）铁律 10 探针，HaishinKit 2.2.5（dc880cb）、macOS 27，报告 reports/w5-stream-auth.md §1
现象（connect 的地址带 user:pass@ 时它自动走 Adobe 鉴权）：
1. `RTMPAuthenticator.swift:20` 用 `url.password` 算 MD5——Foundation 的这个属性不解码（`url.user` 解码），密码里有 @ : / % 空格 中文等就算错；
2. 服务器回 reason=authfailed / nosuchuser（描述里也带 authmod=adobe）时 `makeCommand` 又走 "authmod=adobe" 分支，`RTMPConnection.connect` 递归重连、地址越拼越长、不看 Task 取消：
   测试网关回话前等 20 ms 时 13 s 连了 430 次，100 ms 时 43 s 380 次；
3. 被拒之后 `await socket.close()` 再递归 connect，旧连接的收包循环随后调 `close()`，会关掉新 socket（约一成以 socketErrorOccurred(nil) 失败，第 2 条的循环也是靠它才停）；
   理论上还能落在"readyState 已是 versionSent、continuation 还没登记"的窗口里，connect 永远不返回；
4. 描述里有 reason=needauth 时 `url.user!` / `url.password!` / `dictionary["salt"]!` / `URL(string:)!` 强制解包：地址没写 user:pass@、或服务器回的 needauth 缺 salt 就崩。
W5-D 的处理：交给 HaishinKit 的地址永远不带 userinfo，Adobe 前两轮由 `RTMPAdobeAuth` 自己做（第 1–3 条不再触发）。剩下第 4 条：第三轮服务器回 needauth（挑战过期才会）仍会崩。
严重级：S3（已绕开；第 4 条是残留的崩溃口子，概率低）
建议改法：给上游提补丁——`password(percentEncoded: false)`；authfailed / nosuchuser 直接失败不重连；needauth 分支去掉强制解包；
      递归前先把旧 socket 的收包 Task 收干净（或换成循环而不是递归）。上游修了之后可以考虑删掉 RTMPAdobeAuth，但测试（StreamAuthTests、AdobeAuthGateway）留着。
