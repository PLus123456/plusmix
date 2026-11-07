# Outputs

Each kind of output has a page in the "This Show" group of the [Settings](settings.md) window: Overview, Recording, ISO, Streaming, External Display, NDI® Output, Virtual Camera, Multiview Layout.
The Output menu lists them, the ⚙ buttons in the bottom bar open the right page (Record's ⚙ is a small menu with "Recording Settings… / ISO Recording…", External Display's ⚙ is the routing menu), and the main buttons and ▴ menus in the bottom bar are the shortcuts for live operation ([Concepts › Bottom-bar buttons](concepts.md#bottom-bar-buttons)).

Every output has a number, a name, a "should be running" switch and its own settings. Each section's title line reads "kind k · Output n" with a name field on the right (press Return or leave the field to rename).
Runtime numbers (frames / bitrate / drops) live only in the status line, the statistics window and the API's `stats`, never in the show file.

| Kind | Sends | How it starts |
|---|---|---|
| Recording | PGM, or one input (ISO) | Record in the bottom bar starts / stops them together; ▴ stops a single one; shortcut / API `startRecord` |
| Streaming | PGM | Stream in the bottom bar, ▴ for a single destination, the switch on each destination; `startStream` |
| NDI® output | PGM / PVW / multiview / one input | the "Send" switch on the NDI® Output page; `setOutputEnabled` |
| External display | PGM / PVW / multiview / one input (Aux) | External Display in the bottom bar / toolbar, right-click a monitor › Show Fullscreen On; `setOutputEnabled` |
| Virtual camera | **PGM** | Output › Virtual Camera ▸ › Enable / Disable Virtual Camera Output; `setOutputEnabled` |
| Multiview | sends nothing by itself, **only carries the layout** (see [Multiview](#6-multiview)) | no switch; for a multiview picture, set the source of an NDI® output / external display to "Multiview" |

## 0. Overview

Settings › Overview (Output › Output Overview…): one row per output in the show — kind, name, source, on / off, status, and "Details ›" at the right. Click a row to jump to its settings page and section.
For recordings "On" means recording; for streams it means it should be live (the status says what is actually happening). The status reads the same statistics as the bottom bar and the control API.

## 1. Recording

Settings › Recording (⚙ Record › Recording Settings… in the bottom bar, or Output › Recording Settings…). The top of the page says "The bottom bar's Record button records n route(s) together: Recording, Recording 2, ISO 1…", with "Recording Status…" on the right of that line (the Recording page of the [Stream / Recording Status window](#stream--recording-status-window)); while recording it says "Recording: changes apply from the next recording."

**Files (shared by all recordings)** — this section edits Recording 1 and the other recordings follow it:

| Item | Notes |
|---|---|
| Directory | Default `~/Movies/PlusMix`; a relative directory in the show file lives under it. Long paths are shortened in the middle; hover for the full path |
| File name pattern | `{show}` `{date}` `{time}` `{output}`; default `{show}-{date}-{time}`; an example is shown below. Recordings other than Recording 1 automatically get `-{output}`. **If a file of that name already exists when recording starts** (no time in the pattern, recording again within the same second, stopping and starting right away, an .mp4 of that name for a route converted to .mp4, a file of that name in the fallback folder when switching there), `-2`, `-3`… are appended — **old recordings are never deleted or overwritten**; routes in the same batch whose names collide are kept apart the same way (names are compared case-insensitively) |
| File format | One choice: **".mov (written in fragments while recording; crash-recoverable)"** or **".mov, converted to .mp4 after stopping"**. Always written as .mov first (fragment by fragment: a killed process recovers up to the last fragment); if converting to .mp4 fails, the .mov is kept. A "container .mp4" written in an old show file has no effect (the page says so); this choice is what's used |
| Fragment interval | 1 s by default |

**Recording list**: one section per recording, "Recording k · Output n · name":

| Item | Notes |
|---|---|
| Take part in recording | "Take part in recording (recorded when you press Record in the bottom bar)": off = the settings stay, but the bottom bar's Record button does not start it |
| Source | PGM, or one input (its raw picture). PVW and multiview cannot be recording sources |
| Encoding | Codec (H.264 / HEVC / ProRes 422 / 422 HQ / 4444, hardware), resolution (default = program), bitrate, keyframe interval, audio (AAC or PCM + bitrate); audio = the Master bus |
| Status | The same wording as the bottom bar |
| Remove this recording | Greyed out while recording |

- "Add recording" at the bottom: a new recording records PGM; you can switch it to one input and give it its own format (for example a ProRes master plus a small H.264 file).
- **New recordings get a bitrate based on the program format**: 1080p30 10 Mb/s, 1080p60 18, 1440p60 32, 2160p30 36 (59.94 / 29.97 use the 60 / 30 rows), otherwise about 0.15 bit per pixel per frame rounded (at least 4 Mb/s); audio AAC 256k.
- **Recording 1** = the first recording whose source is PGM; the ISO routes use its format (below).
- The Record button in the bottom bar: nothing recording → every route that takes part starts **on the same tick** (a shared start); something recording → stop all (asks first). With no recording in the show at all, one click adds a default one and starts it. ▴ stops a single route.
- While recording, the bottom bar / toolbar show the running time "● REC 01:02:05" ("● REC 00:14:22 (3)" for three routes together), and ▴ shows each route as "name · Recording · 01:02:05"; the time is how long that route has been recording according to the statistics, the longest route wins.
- Encoder PTS is the tick time, so the file duration equals ticks × frame duration ([test standard](../../testing/en/README.md) E5); 20 normal stops
  and 10 kills during recording are covered by automated tests.

### ISO recording

Settings › ISO (⚙ Record › ISO Recording… in the bottom bar, or Output › ISO Recording…): a separate file per input.

- At the top: "Format H.264 · 18 Mb/s · .mov (same as Recording 1)" with "Change format…", and the folder with "Change folder…" — **the ISO format and folder follow Recording 1**. When Recording 1 changes, ISO routes that are not recording follow right away; ones that are recording follow after they stop (from the next recording).
- The table: rows = "PGM · Recording 1" + every input; columns = Rec (checkbox) / Name / Status / Duration / Dropped / Folder. "Duration" shows hh:mm:ss while recording (the PGM row = Recording 1, an input row = its ISO route) and "—" otherwise.
  Checking an input adds a recording output for it (source = that input's raw picture; the file name pattern includes `{output}`); unchecking removes that ISO route.
  **Unchecking the PGM row = Recording 1 doesn't take part = record ISO only.** Rows that are recording are locked (stop them to change). Audio-only / image inputs are hidden by default; "Show all inputs (n audio-only / image inputs hidden)" shows them.
  An audio-only input's row says "Audio only: the picture is black" under its name: checking it records a black picture plus that input's sound (a .mov like any other ISO file, starting and stopping on the same ticks, so it drops straight into an editor next to the others).
- Started and stopped on the same tick as PGM, sharing the start tick: measured 0.0–0.2 ms between files for the same event (A4 requires ≤ 1 frame).
- The ISO audio track is that input after its fader and before AFV (recorded even when off air).
- A 30 fps input recorded into a 60 fps program repeats each frame, on the same grid as PGM.
- Each input has at most 4 branches (ISO / Aux external displays / NDI® input sources share them); the UI warns when they run out.
- **Changing an input's source while it is being recorded** (Input Settings › Source): the ISO recording carries on with the new source in the same file, ticks continuous; a few frames of the old picture repeat at the change, then the new source's first frame takes over.
  Switching to a source that can't start (file missing, can't be created) or to an audio-only device records black; a new source that starts but has no picture yet (a camera that isn't plugged in, an NDI® source not online yet) records the old source's last frame until its own first frame arrives; once it has produced a picture and then drops out, it holds its own last frame, just like the same source dropping out mid-way.
  **Removing the input** while recording isn't a source change: that ISO recording stops at the tick of the removal (about 3 extra ticks get in), the status line says "ISO recording n stopped: input m was removed (stopped at that tick; adding an input with the same number does not resume it — start recording again if needed)" (as soon as the file is finalised the same line is shown again followed by " — saved: file name, n frames / x s"; both lines are in the log exported by "Show Logs…"), and that ISO route's recording switch turns off ("Off" on the ISO page / in the bottom bar); the newly added input isn't picked up automatically — start recording again if needed.
  The ISO audio track follows the input's number: wherever the new source's sound lands in the mixer after a source change, the track follows it, so it never records another input.
- The bottom of the page shows the folder, free space and an estimate of remaining time (sum of all recording bitrates).

### Disk protection

Every second the free space of each recording's volume is checked (external drives and disk images included):

| Situation | Behaviour |
|---|---|
| Free space below 1 GB | Status line warns "Recording n: x MB free on disk" |
| Below the minimum (200 MB by default; Settings › Advanced › Free space minimum, or the launch argument `--record-min-free-mb`) | **Only that recording stops**, with "Recording n: x MB free on disk, below the y MB minimum"; streaming, rendering and other recordings continue. With a fallback folder it moves there and keeps recording |
| Volume full / write error | That recording stops and keeps what was written, with "Recording n: disk full (…)"; with a fallback folder (Settings › Advanced, or `--record-fallback`) it continues there from the next tick instead, with "Recording n: disk full, switched to the fallback directory: file name" |
| The recorder itself fails (encoder, format and the like — not the disk) | Only that recording stops, with "Recording n failed: reason"; no move to the fallback folder |

- When a stopped recording has been finalised, the status line shows the same line again followed by " — saved: file name, n frames / x s" (e.g. "Recording 2: 150 MB free on disk, below the 200 MB minimum — saved: …").
- **An ISO route needs one more picture branch to move to the fallback folder** (the new file starts at the next tick while the old one records up to that tick before giving its branch back): when all 4 branches of that input (ISO / Aux external displays / NDI® outputs with that input as source) are taken it does **not** move — that recording stops, with "…; fallback folder: this route's picture branches are all taken (input n allows at most 4 ISO / Aux), so it did not switch and this recording stopped"; it never silently records PGM instead. If the fallback folder itself can't be used, that recording stops too ("…; the fallback directory failed too: …").

Tested with a 50 MB disk image and two 40 Mbps recordings filling it ([test standard](../../testing/en/README.md) S7).

## 2. Streaming

Settings › Streaming (⚙ Stream in the bottom bar, or Output › Streaming Settings…): one output per destination, each with its own encoder and reconnect logic. "Start all / Stop all" at the top of the page (stopping asks too), with "Stream Status…" on the right (opens the [Stream / Recording Status window](#stream--recording-status-window)).

Each destination has a section titled "Stream k" with "Output n" and a name field; a "Start / stop" switch at the start of the section (it won't start without a URL; turning it off asks first), and a status line: "Streaming · 5.9 Mb/s · 3 dropped · 1 reconnects".

| Item | Notes |
|---|---|
| Service | Custom (RTMP / RTMPS), Custom (SRT), WeChat Channels, Douyin, Bilibili, Kuaishou, YouTube, Facebook, Twitch. Services with a fixed ingest (YouTube, Facebook, Twitch) fill in the URL; get the stream key from the platform's dashboard. Platforms that hand out an address per session (WeChat Channels, Douyin, Kuaishou, Bilibili) fill nothing in: copy the "stream URL + stream key" from the platform's live dashboard as the hint says. The show file stores only the full URL; when reopened, the service is recognised from the URL only for the fixed-ingest services (YouTube, Facebook, Twitch) and Bilibili — WeChat Channels, Douyin and Kuaishou destinations come back as "Custom (RTMP / RTMPS)" (the URL is unchanged and streaming is not affected) |
| URL | `rtmp://host/app`, `rtmps://host/app`, `srt://host:port?streamid=…&passphrase=…&latency=…`; the scheme selects the protocol. A `user:pass@` part and password-like query parameters (user, pass, key, token…) are masked as •••; while editing, leaving a masked part as it is keeps the original value. With the key field empty and the key written as the last segment of an RTMP URL (a whole stream URL pasted in), this field **still shows that segment in clear** (known issue — mind screen sharing; better put the key in the key field below); the bottom bar's ▴ tooltips, the diagnostics bundle and the API state already mask it |
| Stream key | RTMP: appended as the stream name; SRT: becomes `streamid=<key>` when the URL has none |
| Authentication… | See [Stream authentication](#stream-authentication) below |
| Quality | 1080p (6 Mb/s when the program runs at ≥ 48 fps, otherwise 4.5 Mb/s; audio AAC 160k), 720p (3 Mb/s; AAC 128k), Custom. A new destination defaults to the highest tier not above the program (1080p at most, never upscaled); editing the encoding by hand shows "Custom" |
| Encoding details… | Codec, resolution, bitrate, keyframes (in seconds, 2 s for a new destination, with "= n frames" next to it), audio bitrate, **Max retry interval n s (keeps retrying, except after an authentication failure)** |
| Same as Stream 1 | Checked by default from the second destination on: quality and encoding follow Stream 1 (URL, key and retry interval don't); both are greyed out while checked |
| Remove Destination | Greyed out while its switch is on (connecting / reconnecting included; a destination that couldn't start or failed can be removed with the switch on) |

- "Total upload about n Mb/s (m destinations)" at the bottom of the page: every destination is encoded separately and uses its own share of upload bandwidth, so two destinations need twice as much; leave about twice the total as headroom.
- **A destination whose switch is on is locked** (live, connecting and reconnecting alike; only one that couldn't start or failed is not): service, URL, key, authentication, quality, encoding details and Remove can't be changed; it says "Streaming: URL, key and encoding can be changed after it stops." — if it keeps failing to connect and you need to fix the URL or authentication, turn its switch off first.
- URL / key edits are committed **when you press Return or leave the field**.
- **A destination that couldn't start is not locked**: it says "Couldn't start: reason" (e.g. "Couldn't start: No URL", "Couldn't start: Unsupported address: foo:// (only rtmp://, rtmps://, srt://)"), offers "Retry" and "Turn Off This Destination", and the red hint below reads "Fix the URL / key (Return or leave the field) and it retries automatically; or turn this destination off." The status line says "Stream 3 failed to start: No URL".
- **A destination stopped because the server rejected its authentication** isn't locked either, but says "Failed: 鉴权失败（…）：…" (authentication failed (…): …), and its red hint reads "This destination stopped and won't reconnect on its own (the server rejected the credentials): fix the URL / credentials, then click “Retry” — changing the settings alone doesn't retry; or turn this destination off." — click "Retry" once it's fixed, see [Stream authentication](#stream-authentication).
- The "Add destination" section at the bottom: pick a service (fixed-ingest services fill in the URL, the others say where to get it), enter URL / key and click Add; with no destination in the show yet, the Stream button in the bottom bar opens this section too, with the cursor in the URL field.
- **Reconnecting**: after a drop it reconnects with exponential back-off and never gives up (the same when it can't connect at all); "Max retry interval n s" (30 s by default) caps the wait between attempts — it is not a "give up after" limit. The first frame after reconnecting is a keyframe.
  The one exception is the server rejecting the authentication: it stops on that attempt and doesn't retry (see [Stream authentication](#stream-authentication)).
- Destinations are independent: when one loses the network the others drop 0 frames (E7); after a 30 s outage 10 out of 10 reconnects
  succeed within 15 s (E8); the reported "network drops" match real drops within 5 % under bandwidth limits (E9). All of this runs
  automatically against a local MediaMTX with network impairment.

**The stream status in the bottom bar and toolbar** shows the worst destination and the running time while live: with a single destination in the show it reads "● LIVE 00:10:00"; with several, "● LIVE 00:10:00 (2/3)" (live / all — "1/3" even when only one is live);
the time comes from the statistics (how long that destination has been streaming, counted from its start, reconnects included), the longest one wins. When one is reconnecting, still not connected from the second attempt on, couldn't start or failed, it reads "Stream · 1 in trouble" (orange; dark red when it couldn't start or failed), and with only one destination on it shows that destination's state directly (e.g. "Stream · Reconnecting (attempt 2)", "Stream · Couldn't start", or "Stream · Failed" after the server rejected the authentication).
A first connection reads "Connecting" ("Connecting (attempt n)" from the second try); only after a destination has been live does a drop read "Reconnecting (attempt n)" — n is the real attempt count. The tooltip lists "name: state" per destination, with reasons for those that couldn't start or failed and passwords in URLs masked; when there are such destinations it ends with "Click: retry the destinations that couldn't start; healthy ones keep going" ("…that couldn't start or failed…" when one has failed).
When starting, the status line says "Stream n connecting…", and "Stream n is live" only once it actually is.
▴ has one item per destination (click = start / stop / retry just that one); "Stream Status…" opens the Stream / Recording Status window. Each item's tooltip gives, in order: why it couldn't start ("Can't start: …") or why it stopped after an authentication rejection ("Stopped: 鉴权失败（…）：…"), the destination's URL ("Address: …", with `user:pass@` and password-like parameter values replaced by `<redacted>`; with the key field empty and the key written as the last segment of an RTMP URL, that segment is `<redacted>` too), and what a click does.
In the API's `stats.encoder[]` the stream `state` is idle / connecting / publishing / backoff / stopping / stopped / failed; a destination that couldn't start, or stopped after an authentication rejection, reports `failed`.

### Stream / Recording Status window

A separate window ("Stream / Recording Status") with two pages, Stream and Recording. Open it from "Stream Status…" in the bottom bar's Stream ▴, "Recording Status…" at the end of the Record ▴ (Output › Stream ▸ / Record ▸ in the menu bar are the same two menus), "Stream Status…" at the top of the Streaming page or "Recording Status…" at the top of the Recording page. It opens on the page of the entry you used, or comes to the front if it is already open.

| Page | One row per route, columns |
|---|---|
| Stream | Name / State / Bitrate / Dropped / Reconnects (times it came back after a drop) / Duration / Disconnects (drops after being connected) / Last error |
| Recording | Name / State / Duration / Bitrate / Frames / Dropped / Free space / Last error |

- All numbers come from the statistics (`stats.encoder[]`, the same data as the API and the status line); the window computes nothing of its own. A route that is off shows "Off", with "—" for bitrate and duration; reconnecting is orange; a route that couldn't start shows "Couldn't start" and one that stopped / failed shows "Failed" (the same words as the bottom bar and the Streaming page), both in red.
- **Last error**: the line the streaming / recording code wrote the last time this route failed, word for word (cleared on the next start); passwords in URLs are masked. The streaming engine writes these in Chinese:
  - can't connect: `连接失败：<reason>` (connection failed), the reason being a short Chinese summary, e.g. `连接失败：连接超时（服务器没回）` (connection timed out, the server didn't answer — it accepted the connection but never replied, and the 5 s connection timeout ran out), `连接失败：连接被拒（这个地址和端口上没有服务器在听）` (connection refused: no server listening on that address and port), `连接失败：找不到主机（域名解析失败）` (host not found: DNS lookup failed), `连接失败：SRT 连接超时（服务器没回）` (SRT connection timed out);
    when the server answered with a status it is `连接失败：服务器拒绝连接：<code> <description>` (the server rejected the connection) or `连接失败：发布被拒：<code> <description>` (publish rejected), and a server that doesn't answer the publish step gives `连接失败：发布：服务器没回（请求超时）` (publish: no answer, request timed out); an over-deep / oversized reply during Adobe authentication gives `连接失败：RTMP 协议错误：AMF0 嵌套过深` (`…元素过多`; RTMP protocol error: AMF0 nested too deep / too many elements) and backs off and retries as usual. The underlying library's own wording only goes to the system log (it's in the export from "Show Logs…"); this column only has the summary. When the transport can't be created before an attempt it is `建传输层失败：<reason>` (failed to create the transport; it backs off and retries too);
  - was live, then dropped: `断线：连接断开` (disconnected: connection closed), `断线：发送停滞` (sending stalled: data waiting and not a byte sent for 5 s), `断线：发送失败：<reason>` (send failed);
  - couldn't start (unknown address, no address, the route couldn't be created): the reason itself, e.g. `No URL`, `Unsupported address: foo:// (only rtmp://, rtmps://, srt://)` (the status line puts "Stream n failed to start: " in front);
  - the server rejected the authentication: `鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected … reason=authfailed …` (authentication failed (wrong user name or password), followed by what the server replied; see [Stream authentication](#stream-authentication)).
- **Events** below: timed state changes, newest first, each as "name · event" — Connecting → Streaming → Disconnected: reason → Reconnecting (attempt n) → Reconnected / Stopped / Couldn't start: reason / Failed: reason. They are derived from the once-a-second statistics, so changes that come and go within a second are not shown;
  **they are recorded while the window is closed too**, cleared when you open another show or the engine restarts, and the last 500 are kept.
- At the bottom, an "**Effect chain latency**" line: one item per bus and per input with effects, e.g. "Effect chain latency: Master 12.0 ms · Bus A 0.0 ms (compressor measured 0.00 ms) · Bus B 0.0 ms · Headphones 0.0 ms · Input 3 Mic 0.0 ms" — read from `audio.effects` in the statistics; chains with the self-written compressor also show its measured value.
- Below it, "**Video delayed n ms**" appears only while the picture is delayed for monitor sync (a compressor / limiter on Master, see [Concepts › Audio](concepts.md#audio)); it is `video_delay_ms` from the statistics.
- "**Show Logs…**": exports the last 10 minutes of this app's system log (the virtual camera extension included) to a text file `log-yyyyMMdd-HHmmss.txt` in the diagnostics folder (`~/Library/Application Support/PlusMix/Diagnostics`) and opens it; it takes a few seconds. The streaming / recording logs are in it. You can also query the system log yourself, see [Troubleshooting › Logs and diagnostics](troubleshooting.md#9-logs-and-diagnostics).
- Hotkeys keep working while this window is in front (keep it open to watch during a show and Space still cuts).

### Stream authentication

"Authentication…" opens a small form that depends on the URL's protocol; **it can't be changed while the destination's switch is on** (the section is locked) — turn the switch off first (a destination that couldn't start, or that stopped because the server rejected its authentication, is not locked and can be changed with the switch on):

- **RTMP / RTMPS**: the form "RTMP authentication (user name / password)" starts with "Method", one of two:
  - **Adobe (user:pass@)**: for Wowza, Nimble, FMS and some authenticated CDN ingests (Adobe authentication, FMLE compatible). The user name and password go into the `user:pass@` part of the URL and the connection answers the server's challenge without sending the password in clear;
    the URL field shows `rtmp://•••@host/app`, and next to the button it says "Authentication: user xxx (password set)" ("(no password)" when the password is empty).
  - **Query string (?user=&pass=)**: for self-hosted servers such as MediaMTX, SRS and nginx-rtmp, written after the URL as `?user=…&pass=…`. Two more fields, "User parameter / Password parameter", default to MediaMTX's `user` / `pass`;
    for SRS and nginx-rtmp use the names your server's auth hook expects (letters, digits and `- . _ ~` only; the two must differ). The values are masked in the URL field (`?user=•••&pass=•••`), and next to the button it says "Auth (query string): user xxx".
    If the password parameter's name is not on the masking list (user, pass, password, pwd, key, token, secret, passphrase, streamid, auth, response), the form warns that the password will be shown in the address field and in logs.
    **Parameter names are remembered on this Mac**: the show file stores only the full URL; reading it back recognises `user` / `username` / `usr` and `pass` / `password` / `pwd` / `passwd` plus the parameter names this Mac has saved in the form (the latest 8 pairs) — both for recognising the method and for switching it, and switching to Adobe removes the two parameters by the names it recognised.
    So on **another Mac** a show that uses custom parameter names shows "No authentication" next to the button and the form reopens on Adobe with empty fields (streaming itself is unaffected; the URL is unchanged): choose "Query string" in the form and fill in the original names once, and that Mac remembers them.
  - The two methods are **exclusive**: saving one removes the other's credentials from the URL; saving with an empty user name removes both (no authentication). Other URL parameters are kept.
  - The wrong method doesn't work: with the Adobe method, MediaMTX accepts the connection and then rejects the publish (`NetStream.Publish.Unauthorized`), which stops the destination as an authentication failure (see below); servers such as SRS and nginx-rtmp that reject through an authentication callback simply drop the connection, so it keeps retrying (see below);
    a server that wants Adobe authentication and gets the query-string method stops it as "the server wants a user name and password and the URL has none".
  - "Clear" only empties the user name and password fields; the URL changes when you click "Save". Without authentication it says "No authentication".
- **SRT: passphrase** (encryption), written into the URL's `passphrase=` parameter; only letters, digits and `- . _ ~`, 10–79 characters (other characters don't work yet); anything else is rejected and not written.
- **The server rejects the authentication** (wrong user name / password, the wrong method, the server wants credentials and the URL has none, or a method that isn't supported): the destination stops on that attempt and does **not** retry with back-off (the password won't fix itself) — on the first connection and on a reconnect alike.
  - The status line says "Stream n authentication failed (wrong user name or password) and stopped: fix it on the Streaming page, then click “Stream” in the bottom bar to retry"; when the server wants Limelight (llnw) it says "Stream n stopped retrying: 鉴权失败（服务器要的鉴权方式不支持）：…" (method not supported — not in this version, so changing the password won't help).
  - The bottom bar's Stream button turns dark red "Stream · Failed" ("Stream · k in trouble" with several switched on), its tooltip reads "name: Failed — 鉴权失败（…）：…" plus "Click: retry the destinations that couldn't start or failed; healthy ones keep going", and its item in ▴ reads "Stopped: 鉴权失败（…）：…"; the destination's section on the Streaming page says "Failed: 鉴权失败（…）：…" and is not locked (red hint in the [Streaming](#2-streaming) section above). The status line's stream bitrate leaves this destination out ("—" when it's the only one switched on).
    In the [status window](#stream--recording-status-window) its state is "Failed", the event is "Failed: 鉴权失败（…）：…" and "Last error" is the same line; in the API's `stats.encoder[]` its `state` is `failed`, `attempt` 0 and `last_error` the same line.
  - The start of the line tells you which case it is: `鉴权失败（用户名或密码不对）` (wrong user name or password: the server answered authfailed / nosuchuser to the Adobe method, or rejected the query-string method with `NetStream.Publish.Unauthorized`),
    `鉴权失败（服务器要用户名和密码，地址里没写）` (the server wants a user name and password and the URL has none; the status line still says "wrong user name or password" then), `鉴权失败（服务器要的鉴权方式不支持）` (method not supported); after the colon comes what the server replied, without the password (except when the URL has Adobe credentials and the server wants Limelight: then it is the sentence "服务器要 Limelight（authmod=llnw）", the server wants Limelight).
  - Once it's fixed, click the Stream button in the bottom bar (or "Retry" in the destination's section on the Streaming page): it stops the destination and starts it again with the new settings; the switch can stay on. **Changing the URL / credentials alone does not retry this case.**
  - Query-string method with MediaMTX: with a single path segment in the URL (e.g. `rtmp://127.0.0.1:1935/s1`) and an empty key — the way MediaMTX is usually used — it stops on the first attempt;
    with a key, or with two path segments (e.g. `rtmp://host/live/s1`), every connection first waits about 3 s longer, and MediaMTX deliberately delays the rejection by 0–4 s, which often runs past the 5 s connection timeout: that attempt backs off as "can't connect", and on average it takes about two attempts before the rejection is recognised and it stops.
  - Rejections that can't be recognised keep retrying as before ("Connecting (attempt n)"): a server that simply drops the connection without saying why (e.g. SRS or nginx-rtmp rejecting through an authentication callback), and an SRT passphrase that doesn't match the server's. Look in the server's log for the reason.

### Try it locally first

```bash
mediamtx scripts/mediamtx.yml
```

Start the local server from the repository root (it records what it receives into `mediamtx-recordings/` in the current directory). Use the URL `rtmp://127.0.0.1:1935/s1` with **an empty key** (this configuration only has the paths s1 / s2 / s3 and srt1 for SRT; pushing to any other path stays "Connecting"), then watch:

```bash
ffplay rtmp://127.0.0.1:1935/s1
```

For SRT use `srt://127.0.0.1:8890?streamid=publish:srt1`. RTMP and SRT are tested end to end in this repository; RTMPS is the same path plus TLS ([Samples › streaming](../../../Samples/README.md#4-直播先在本机试), Chinese).

## 3. NDI® output

Settings › NDI® Output (Output › NDI® Output Settings…, or ⚙ External Display › NDI® Output Settings… in the bottom bar): one output per sender; the source name is the output's name and appears on the network as **`MACHINE (output name)`**. (NDI® is a registered trademark of Vizrt NDI AB.)

| Item | Notes |
|---|---|
| Source | PGM / PVW / multiview / one input (Aux, raw picture: keying / crop / transform not applied). PVW / multiview render an extra picture on demand and may miss a frame or two at the start |
| Groups | NDI® group names (comma separated); empty = the default group `public`. Receivers filter by group |
| Conversion | NV12 → UYVY on the GPU, the CPU, or Auto (periodically compares both and keeps the cheaper one); only applies to NV12 pictures (see below) |
| Audio | PGM / PVW / multiview send Master; an input source sends that input after its fader |
| Send | Switch: off = stop sending, settings kept |

- "Add NDI output" at the bottom of the page: enter name, groups, conversion and source and click Add; **a new output is switched on as soon as it is added and starts sending right away**.
- Renaming, changing the source or the groups ("Apply name / groups") rebuilds the sender (receivers must reselect it); conversion can be switched any time.
- **The pixel format sent** follows the source: PGM / PVW / multiview and NV12 inputs (cameras, video files without alpha and the like) are converted to UYVY; **BGRA / UYVY inputs (images, video files with alpha, screen / window capture, NDI® receive, DeckLink) are sent as they are, at their own size, without conversion**.
  BGRA is always sent as **opaque** (BGRX), so receivers get no alpha: transparent parts of an image / video arrive black and semi-transparent edges darker. To key a title, key it in PlusMix and send PGM.
  An NV12 input larger than the program (e.g. a 4K video file in a 1080p show; cameras usually negotiate the program size) only sends the program-sized top-left part (known issue).
- **SDK missing** (not detected at build time): the output can be added and enabled but nothing is sent; the status says "Unavailable: no NDI SDK" and `stats.encoder[].state` is `"unavailable"`.
- SDK present but the sender cannot start (initialise / create failed): `state = "failed"` with the reason in the status line; retried when settings change.
- Sending, but **10 frames in a row couldn't be sent** (conversion failed, a pixel format it can't send and the like) reports `failed` too, with the reason in that entry's `last_error` in the API's `stats.encoder[]` (e.g. "NDI 送不了像素格式 '…'（只认 NV12 / UYVY / BGRA），连续 10 帧没送出" — can't send pixel format '…', NV12 / UYVY / BGRA only, 10 frames in a row not sent); one frame sent and it is back to sending. Then:
  - the NDI® Output page shows "Failed: <reason>" (that same `last_error` line; only without a reason does it say "Failed to start: NDI SDK present, but initialize / send_create failed (see the log)");
  - the status line says "NDI output n error: <reason>" ("NDI output n error (see the NDI page in Output settings)" without a reason), at most once a minute per output, so flipping between failed and sending doesn't flood it;
  - it also goes to the system log at the moment it turns failed (it's in the export from "Show Logs…" in the Stream / Recording Status window).
- `stats.encoder[].connections` is the current receiver count; `bitrate` is the raw rate computed as UYVY at the program size (about 2 Gb/s at 1080p60 — normal; it shows the same figure for directly sent BGRA or smaller inputs).

## 4. External display (second display)

One external display = one borderless full-screen window on one display. Ways in:

- External Display in the bottom bar: ⚙ = the routing menu; the main button = all on / off. External Display▾ in the middle of the toolbar and Output › External Display ▸ / Turn On (Off) All External Displays are the same.
- Right-click the PGM / PVW monitor › Show Fullscreen On ▸: that display now shows this monitor ([Concepts › The main window](concepts.md#the-main-window)).
- Settings › External Display (Output › External Display Settings…).

**The routing menu**: one **single-choice** section per display (PGM / PVW / Multiview / Input n), ticked = what that display shows; once a display has been set up, its first line is "Off" (nothing on that display, settings kept), and an output that is off is marked "(off)".
Choosing a source switches that display's output to it and turns it on (other outputs on the same display are turned off), or adds one if the display has none. Below are "Remove n … (state)" and "Turn Off All External Displays", and the last section is "External Display Settings… / NDI® Output Settings…".

**The main button**: some on → turn all off (settings kept); all off → turn all back on as configured; none configured → show PGM full screen on the first non-main display (the main display = the one with the PlusMix main window); no second display → open the routing menu.

**The settings page** starts with "What each display shows": one single choice per display — the same setting as the routing menu. Below it, each output's details: name, enabled, display, source, fall back to the main display when missing, status, and finally a "Remove This Output" button — it **removes this output and its settings** (like "Remove n …" in the routing menu; nothing is asked); to blank a display only for a while, turn off "Enabled" at the top of that section, or use that display's "Off" in the routing menu or the main button.

- Source: PGM / PVW / multiview / one input (Aux, full-resolution raw picture; it follows that input when its source is changed in Input Settings › Source).
- Display absent: by default stays black and waits, leaving the main display alone; "Fall back to the main display when missing" goes full screen on the main display (covering the UI) — only enable it deliberately. Settings › General › Keep external displays on the main display behind the interface keeps an external display window on the main display below the interface.
- The window takes the latest frame at the display's own refresh; dragging the main window or entering full screen does not touch the render
  thread (missed-frame count stays flat). Pressing Esc in an external display window turns that output off (like "Off" in the routing menu: the window goes away, the display / source settings are kept, and choosing a source again turns it back on as configured).
- The show file stores display ID and source and restores them; display IDs can change across reboots, so reselect if needed.

## 5. Virtual camera

Settings › Virtual Camera, or Output › Virtual Camera ▸: lets FaceTime, QuickTime, browser meetings etc. use PlusMix as a camera. **It sends PGM** (no source selection) — the same program frame recording / streaming / NDI® get.

Install once:

1. Build with a Team ID (`DEVELOPMENT_TEAM=<TeamID> make gen build-app`), move PlusMix.app to `/Applications` and launch from there —
   system extensions can only be activated from an App in /Applications.
2. Settings › Virtual Camera › Install… (or Output › Virtual Camera › Install / Activate Extension…), then allow it in System Settings › General › Login Items & Extensions
   (older releases: Privacy & Security). "Check" (in the menu: "Check Extension Status") shows the current state.
3. Turn on "Enable virtual camera" (or Output › Virtual Camera › Enable / Disable Virtual Camera Output). Pick the **"PlusMix"** camera in FaceTime / QuickTime › New Movie Recording.

- Development builds (no Team ID, ad-hoc signature) cannot activate: the status says "macOS refused the install: it needs a signed release build run from the Applications folder"; the App keeps running.
- Output enabled but the extension not connected: "Virtual camera device not found (extension not installed / not activated); n frames dropped",
  retried every second; sending starts automatically once connected. With the output off, the other side sees a placeholder (dark gray with a moving white bar).
- Frame rate follows the program, 1080p NV12; PGM to the receiving process within 3 frames is the design target (verified on signed builds).

## 6. Multiview

Settings › Multiview Layout (⚙ Multiview in the bottom bar, or Output › Multiview Layout…); the Multiview button in the bottom bar / Window › Multiview Window opens and closes the separate window, which can be moved to any screen or made full screen.

| Item | Notes |
|---|---|
| Preset | PVW / PGM + automatic grid (default: PVW / PGM on top, 4×2 / 6×3 / 8×4 below depending on input count), PVW / PGM + 4×2, PVW / PGM + 2×2, 3×3, 4×4 |
| Cells | With a preset: "Convert preset to custom cells" (copies every cell of the preset) or "Add cell"; with custom cells, edit each one: source (PGM / PVW / input n) + x / y / w / h (fractions of the picture, 0–1, anything outside is clipped) + Remove, then "Add cell / Clear custom cells (use the preset)". While custom cells exist the preset is ignored |
| Safe area | EBU R95 action-safe 3.5 % / title-safe 5 % on the PGM / PVW cells |
| Meters | Input cells show that input's meter, PGM = Master, PVW = the current PVW input; the readings are the same data as the status line / API |

- Every cell has a tally border (red PGM / green PVW) and a name label; audio-only inputs show name + meter.
- The layout is stored in the show file (settings of the first multiview output) and applies to the multiview window, the thumbnail strip and the
  "multiview" source of external displays / NDI®.
- The show's "Multiview" output only carries the layout: the page has no switch, it is created off, and it can stay off. When an NDI® output or external display uses the "Multiview" source,
  the renderer produces the multiview picture by itself regardless of this switch (turning it on with the API's `setOutputEnabled` only makes the renderer convert an extra multiview picture each frame that nothing uses).
