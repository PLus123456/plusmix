# 底栏推流按钮的悬停提示把推流地址原样显示（含 user:pass@ 与 SRT passphrase）

归属会话 / 分支：W5-F 底栏三段式（w5-app-bottom-bar，prompt 92）；若 92 之前要止血，归 W5-B（w5-app-safety）
发现于：W5-D（w5-stream-auth），读 App 里用到推流地址的地方，main 25af61f
现象：`App/Sources/UI/BottomBarView.swift:159` `streamButton.toolTip = streams.map { $0.settings.stream?.url ?? "" }`——鼠标停在底栏推流按钮上，
      每个目的地的完整地址原样显示。W5-D 之后 rtmp://user:pass@host/app 里的账号密码会生效，提示里就是明文密码；
      SRT 的 `?passphrase=` / `streamid=publish:路径:用户:密码` 一直如此。直播时共享屏幕 / 投屏 / 录屏教程都会带出去。
复现步骤：推流页地址填 rtmp://u:secret@127.0.0.1/live → 底栏点推流 → 鼠标停在推流按钮上。
严重级：S2（凭据外泄；不影响推流本身）
建议改法：提示里用打过码的地址——SwitcherStreaming 已经有公开的 `StreamURLRedaction.redact(url:)`（userinfo 整段、passphrase / streamid / key / token / user / pass 等参数值换成 `<redacted>`，主机端口路径保留），诊断包也用它；
      或者只显示 `StreamDestination.description`（`rtmp://host:port/…`）。推流页地址框是编辑处，显示原文可以，但 95（W5-I）做"鉴权…"时建议地址框里的密码段打码显示（见 reports/w5-stream-auth.md §5）。
