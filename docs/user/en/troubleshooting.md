# Troubleshooting

Look in three places first: the one-line message on an input cell (that input's own state, [Inputs › Input states](inputs.md#input-states)), the tooltip of the Record / Stream buttons in the bottom bar (every route's state and why it couldn't start) together with the [Stream / Recording Status window](outputs.md#stream--recording-status-window) (each route's last error and its drops and reconnects),
and the notices / reminders at the right of the status line (outputs and system-level events). Cells in error and outputs that couldn't start name the cause and the next step; a "No signal" cell shows the reason the input itself reports on a second line (cut short if long; the tooltip has it all) — compare with [§2](#2-no-signal). This page groups them by symptom.
Input messages come from the engine and are **in Chinese in this version**; below they are quoted in Chinese with an English gloss.

## 1. Permissions

| Symptom | Cause | Fix |
|---|---|---|
| Camera cell: "摄像头权限被拒。打开 系统设置 › 隐私与安全性 › 摄像头，允许本程序后会自动恢复，不用重启。" (camera access denied; allow it in System Settings › Privacy & Security › Camera and it recovers without a restart) | "Don't allow" was clicked, or the prompt never appeared | Enable PlusMix there; recovers within about 2 s. The banner in the Add Input panel has "Open System Settings…" |
| Camera has picture but no sound; audio-only cell says "麦克风权限被拒…" (microphone access denied) | A device's microphone / an audio input needs separate microphone access | System Settings › Privacy & Security › Microphone |
| Screen input stays "No signal" or says "屏幕录制权限被拒…" (screen recording denied), and **no prompt ever appeared** | Screen recording has no system prompt by design | System Settings › Privacy & Security › Screen & System Audio Recording, add PlusMix.app with +; recovers automatically (macOS may ask you to reopen PlusMix) |
| Access granted, asked again after rebuilding / updating | Ad-hoc signatures without a Team ID change on every build; macOS treats it as a new app | `DEVELOPMENT_TEAM=<TeamID> make gen` for a stable identity, or grant again each time |
| "…权限被系统策略限制（家长控制 / MDM）…" (restricted by system policy) | Device management forbids it | Ask the administrator; the app cannot lift it |
| PlusMix started from a terminal / script gets no camera | TCC grants belong to the launching process (Terminal, IDE) | Grant to Terminal.app, or launch from Finder / Dock |
| "Allow incoming connections" appears the first time you allow the local network or turn on the tally stream | The macOS firewall is on | Click Allow; otherwise other machines can't connect |

## 2. No signal

A noSignal cell says "No signal" (audio-only inputs: "Waiting for the audio device…") with the input's own reason on a second line (in Chinese); the table lists the usual ones per input type. A cell in error shows the reason itself.

| Input | Cell message | Usual causes / what to do |
|---|---|---|
| Camera / capture | "No signal" + "摄像头 … 已断开，等待重新连接" (camera disconnected, waiting) / "找不到摄像头 …（未连接）" (camera not found) | Unplugged; the same device plugged back recovers automatically (≤ 3 s) |
| DeckLink | "No signal" (with "没有找到 DeckLink 驱动：安装 Blackmagic Desktop Video……", driver not found, below it when the driver is missing) | Driver missing (install Blackmagic Desktop Video and connect the card; recovers by itself, no restart), or cable / card absent (recovers when the signal / card returns) |
| DeckLink | "DeckLink SDK 未编译进来：…后重新编译" (DeckLink SDK not compiled in … rebuild) | Error: this copy of the app was built without the DeckLink SDK; use a build with it |
| NDI® | "No signal" + "网络上找不到 NDI 源 …（发送端没开、不在同一网段，或名字不对）" (NDI source not found on the network) | Source not online yet, sender not running, different subnet, or wrong name: the name must match the sender's `MACHINE (source)`; the NDI® page of the Add Input panel searches again every 4 s; connects when the source appears |
| NDI® | "NDI SDK 未编译进来：…后重新编译" (NDI SDK not compiled in … rebuild) | Error: this copy of the app was built without the NDI SDK; install the NDI SDK for Apple to `/Library/NDI SDK for Apple` (or set `NDI_SDK_DIR`) and rebuild. The NDI® page of the Add Input panel then says "Cannot look for NDI sources: …" |
| Video file | "文件里没有视频轨：…" (no video track) | An audio-only file (mp3 / wav / m4a / aac) was chosen: in this version the file input still needs a video track |
| Video file | "文件不存在：…" (file not found) | Wrong path; relative paths are relative to the show file's directory ([Samples › relative paths](../../../Samples/README.md#2-相对路径), Chinese). Once the file is in place, remove the input and add it again, or reopen the show |
| Image | "图片不存在：…" (image not found) | As above; once the file is in place it is picked up by itself (checked every 0.25 s), no need to re-add |
| Audio-only device | "Waiting for the audio device…" + "音频输入设备「…」已断开，等待重新连接" (audio input device disconnected, waiting) and the like | Unplugged; recovers when plugged back; "System default input" inputs rebuild when the default changes |
| Any | Picture present but looks like 30 fps in a 60 fps show | The camera negotiated 30 fps (no 60 fps mode; that line is yellow in the Add Input panel): frames repeat by design; not a drop |

## 3. Disk

| Status line | Behaviour |
|---|---|
| "Recording n: x MB free on disk" | Warning below 1 GB; still recording |
| "Recording n: x MB free on disk, below the 200 MB minimum" | Without a fallback folder: only that recording stops; streaming and rendering continue. Change the minimum in Settings › Advanced › Free space minimum (or with the launch argument `--record-min-free-mb`) |
| "Recording n: disk full (…)" | Full: written fragments are kept, that recording stops |
| "Recording n: disk full, switched to the fallback directory: <file name>" | The disk ran full; with a fallback folder (Settings › Advanced, or `--record-fallback`) recording continues there |
| "Recording n: x MB free on disk, below the y MB minimum; switched to the fallback directory: <file name>" | Below the minimum (the disk isn't full yet); with a fallback folder recording continues there too |
| "Recording n failed to start: …" | Folder not writable / missing; fixing the folder retries automatically |
| "ISO input n does not exist or has no free branch (at most 4 ISO / Aux per input)" | The input being ISO-recorded is gone, or it already feeds 4 ISO recordings / Aux uses (external displays and NDI® outputs showing that input): remove some and record again |
| "Recording n failed to finalize: …" | Writing the index at stop failed; the fragmented `.mov` stays playable |
| Record in the bottom bar records nothing; notice "No route takes part in recording" | Every recording's "Take part in recording" is off, or the PGM row on the ISO page is unchecked and no input is checked: turn on the routes you want |

Free space is measured on the recording's own volume. A killed process recovers the `.mov` up to the last 1 s fragment (E6 allows at most 2 s loss).

## 4. Streaming

| Bottom bar / Streaming page / API state | Meaning |
|---|---|
| "Stream · Connecting", "Connecting (attempt n)" (the API's `state` alternates between `connecting` and `backoff`; it is `backoff` while waiting for the next attempt) | Never connected yet: server unreachable, wrong address or path. A local MediaMTX only accepts the paths in its configuration (the repository's `scripts/mediamtx.yml` has s1 / s2 / s3 / srt1, with an empty key); any other path stays connecting. Servers such as SRS and nginx-rtmp that reject the authentication through a callback simply drop the connection without saying why, which looks the same: check the server's log, and whether "Authentication…" uses the query-string method with the right parameter names and credentials ([Outputs › Stream authentication](outputs.md#stream-authentication)). The destination is locked while its switch is on: turn it off before fixing the URL |
| "Stream · Reconnecting (attempt n)" (`state` alternates between `connecting` / `backoff` too) | Was live, then dropped: exponential back-off, retrying forever; the wait between attempts is capped by "Max retry interval n s" (30 s by default); resumes with a keyframe. If the server rejects the authentication on a reconnect, it stops (see below) |
| "Stream · 1 in trouble" (dark red), tooltip "Stream n failed to start: …" / `failed` | Couldn't start: unknown scheme (only rtmp / rtmps / srt), malformed address, no server. The destination's section on the Streaming page shows the reason: fix the URL (Return or leave the field) and it retries automatically, or "Turn Off This Destination"; healthy destinations are not affected, and the main Stream button only retries the ones that couldn't start |
| "Stream n has no URL" | Empty address in the output settings |
| Dark red "Stream · Couldn't start" in the bottom bar ("Stream · k in trouble" with several switched on), status line "Stream n authentication failed (wrong user name or password) and stopped: …"; in the status window the destination is "Failed" and its last error starts with "鉴权失败（用户名或密码不对）" (authentication failed (wrong user name or password)) | The server rejected the credentials: a wrong user name / password with the Adobe method; a wrong user name / password / parameter name with the query-string method on MediaMTX; or the wrong method — MediaMTX wants a query string after the URL but got the Adobe method (the last error shows `NetStream.Publish.Unauthorized`). It stops on that attempt and doesn't retry (SRS and nginx-rtmp rejecting through a callback don't end up here; see the first row). The destination's section on the Streaming page is not locked then: correct it in "Authentication…" (methods: [Outputs › Stream authentication](outputs.md#stream-authentication)), then click the section's "Retry" or the Stream button in the bottom bar — fixing it doesn't retry by itself |
| The last error starts with "鉴权失败（服务器要用户名和密码，地址里没写）" (the server wants a user name and password and the URL has none; the status line still says "wrong user name or password") | The server wants Adobe authentication and the URL has no Adobe-method credentials (none entered, or entered with the query-string method): enter them in "Authentication…" with the Adobe method, then retry |
| The status line / last error contains "鉴权失败（服务器要的鉴权方式不支持）" (method not supported) | The server wants Limelight (llnw) authentication, which this version doesn't support; it stops without retrying too |
| You want to know how often and when a stream dropped, and why | The [Stream / Recording Status window](outputs.md#stream--recording-status-window): the Disconnects / Reconnects columns count them, and the events list "Disconnected: reason → Reconnecting (attempt n) → Reconnected" with times |
| SRT with a passphrase doesn't connect | The passphrase may only use letters, digits and `- . _ ~`, 10–79 characters; one that doesn't match the server's stays "Connecting (attempt n)" (it isn't recognised as a wrong passphrase) |
| Frames increase but the player shows nothing | Check `stats.encoder[].dropped` (network drops): non-keyframes are dropped first when bandwidth is short; lower the bitrate (a lower "Quality" on the Streaming page); keep "Total upload" at the bottom of the page under half your upload bandwidth |
| Local MediaMTX receives no SRT | Its SRT port must bind IPv4 (`srtAddress: 0.0.0.0:8890`; the repository's `scripts/mediamtx.yml` already does); RTMP is unaffected |

## 5. NDI® output, DeckLink, virtual camera not set up

| Symptom | Meaning |
|---|---|
| NDI® Output page "Unavailable: no NDI SDK", `state = unavailable` | No SDK at build time: nothing is sent. Install the SDK, then `make clean && make build` (Xcode caches the manifest's detection) |
| `state = failed` with a reason in the status line | SDK present but initialise / create failed (usually another process holding the NDI® runtime or a name clash); retried after a settings change |
| Add Input banner "This build has no NDI® support" / "This build has no DeckLink support" | This copy of the app was built without that SDK: you can still add the input, but it stays in error until you use a build with the SDK; "Read the guide" opens the matching section of this manual |
| Add Input banner "DeckLink driver not installed" | You can still add the input; it recovers once the driver is installed and the card connected, no restart needed |
| Virtual camera: "failed: macOS refused the install: it needs a signed release build run from the Applications folder" | Development builds cannot activate system extensions: follow the three steps in [Outputs › Virtual camera](outputs.md#5-virtual-camera) |
| Virtual camera: "waiting for approval in System Settings › Privacy & Security" | macOS showed the approval prompt; on macOS 15+ it is under General › Login Items & Extensions |
| Virtual camera: "Virtual camera device not found (extension not installed / not activated); n frames dropped" | Output on, extension not connected; retried every second, starts automatically after activation |
| Extension not listed in System Settings / no "PlusMix" camera in FaceTime after activation | The extension must be embedded in an App inside /Applications; after changing bundle id / Team ID uninstall the extension first |

## 6. Picture and sound

| Symptom | What to check |
|---|---|
| Status line "Dropped" (missed_render) increasing | Rendering missed ticks. Usual causes: another app saturating the GPU, thermal throttling, a covered multiview window lowering the refresh. On an idle machine it stays 0 |
| Frames start dropping after nobody touched the Mac for a while | When the user is "idle" macOS delays real-time thread wake-ups. While the engine runs PlusMix itself prevents system sleep, App Nap and display sleep (Settings › Performance & Power, both on by default), so normally nothing else is needed. **Unattended runs with the lid closed or the screen locked** should still run `caffeinate -u -i -d -s` as well: the app can't prevent sleep on lid-close or a manual lock, and can't declare "user is active" the way `-u` does |
| Audio and video out of sync | Input Settings › Audio › Audio delay compensation (0–500 ms) for the capture device's own offset; the engine's alignment delay (default 2048 frames = 42.7 ms) is in Settings › Show Audio and takes effect only after "Apply and Restart Engine" (which stops recording / streaming; it asks first) |
| With a compressor / limiter on Master, the whole picture (monitors, external displays, multiview) runs a few tens of milliseconds late | Expected (monitor sync): the picture is delayed by Master's effect latency (up to about 35 ms), so speakers / headphones match it; recording / streaming / NDI® follow the same timeline. The status window shows "Video delayed n ms" at the bottom |
| With a compressor / limiter on Bus A / B, the channels they feed are slightly behind the picture | The picture follows Master's delay only; the extra delay of Bus A / B is not compensated (this only affects what those two buses send to device channels) |
| Changing an input's audio effects makes no audible difference | Per-input effects do work: check whether "Enabled" is off (= bypassed); **an input's Limiter has no effect** (only buses get a limiter); a second compressor in the same chain is not installed; EQ bands beyond 16 written through the API are not installed |
| Sound stays after cutting away / no sound after cutting in | First the AFV master switch in the mixer header: **off by default in a new show**, and while it is off no input's "Follow video" has any effect. With it on, check that input's "Follow video": off = always audible, on = only on PGM |
| The headphones play Master; inputs sent to H can't be heard | The headphone output carries the "monitor source", Master in a new show: pick "Headphone bus" in the Listen menu (headphones icon on the Master strip) to hear what the inputs send to H; while something is soloed it always carries the soloed inputs |
| While soloing, headphones are ahead of the picture | The solo monitor point defaults to before the alignment delay (low latency); to align with the picture choose "After the delay line" in Settings › Show Audio › Headphone monitor point, then "Apply and Restart Engine". With a compressor / limiter on Master the picture is delayed again by that much, and the soloed inputs, which skip Master's effects, stay early by that amount |
| Solo / PFL / AFL silent, the mixer header says "This device has no headphone channels" | The output device has only 2 channels and Master uses them: turn on "Use the Master channels while monitoring" in Settings › Audio Devices (while soloing, the speakers / headphones play the soloed inputs; applies immediately), or pick a multichannel device and give the headphones a channel pair |
| No sound from Bus A / B | Give Bus A / B a channel pair in Settings › Audio Devices (needs a multichannel device), then Apply and Restart Engine |
| Reminder "For 30 seconds the Master level has stayed below −50 dBFS (is the mic on?)" | Check whether the microphone input is muted, its fader, whether it feeds Master, and whether "Follow video" keeps it out |
| "Audio device "…" unavailable (…); using the null device" | Device unplugged or held exclusively by another app: reselect in Settings › Audio Devices; with the null device picture, recording and streaming keep their audio, only local playback is silent |

## 7. Interface

| Symptom | Meaning |
|---|---|
| Nothing in the main window reacts to clicks; the status line says "Interface locked" | The interface lock is on: click the lock at the far right of the bottom bar, or Window › Lock Interface. Hotkeys and the menu bar keep working |
| Transition / Cut on a cell are grey and clicking a thumbnail does nothing | A transition is running (a half-pulled T-bar counts): wait for it to finish; or that input is already on PGM |
| Hotkeys do nothing | Hotkeys are not handled while the Statistics window, the Stream / Recording Status window or the multiview window is in front: click the main window first (Settings and the Input / Overlay / Audio Settings windows pass them on) |
| ⌥4 / Return doesn't switch and the status line says "Transition 4 is a Stinger with no input yet — pick one from ▾ in the transition column" | That slot is a Stinger with no input, so it isn't run: pick an input under "Stinger (choose input…)" ▸ in the ▾ of "Transition 4" (or click its button and pick from the list), then run it |
| Clicking "Transition 4" doesn't switch but shows a list of inputs | That slot is a Stinger with no input yet: pick an input from the list (it only changes the slot), then click again to run it ([Concepts › The transition column](concepts.md#the-transition-column)) |
| The T-bar snaps back after I release it at the end | Expected: releasing past 97 % commits (PGM and PVW swap) and the T-bar returns to the left for the next one; it only stays put when released before 97 % |
| ⌥1–⌥4 all just run the current transition instead of separate slots | This Mac has an old saved shortcut table: Settings › Shortcuts › Reset to Defaults |
| Closing the main window asks "Save…" or "Quitting will stop…" | Closing the main window quits PlusMix, so it asks first, like ⌘Q |
| Help › PlusMix User Guide is greyed out as "(not bundled yet)" | The app bundle has no `Resources/Help/`: most likely the Xcode project was generated before the bundled guide was added — run `make gen` and rebuild; the source of this manual is `docs/user/` in the repository |

## 8. API and control panels

| Symptom | Meaning |
|---|---|
| "API failed to start (127.0.0.1:8765): …" | Port in use (a previous PlusMix / headless still running): `lsof -i :8765`; change the port in Settings › Remote Control |
| curl returns 401 | A token is set in Settings › Remote Control: send `Authorization: Bearer <token>` (WebSocket may use `?token=`) |
| 200 with `applied = false` | The state machine ignored the command by rule (a transition while one runs, **changing PVW / PGM during a transition**, already at target); not an error |
| 400 | Malformed command / unknown input or output number; the body says why |
| A control panel / Companion on another machine can't connect | By default only this Mac can connect: set the local API or the compatibility layer to "Allow local network" in Settings › Remote Control, Apply and Restart Engine, and use the address shown there; click Allow when the firewall asks about incoming connections |
| Tally lights can't connect | Turn on the read-only tally stream in Settings › Tally (off by default) and use the address shown there; "The tally stream could not start" usually means the port is in use — pick another |
| Status line "MIDI mapping table … is unreadable; using an empty table: …" | `~/Library/Application Support/PlusMix/midi.json` has a JSON error or a conflict: MIDI runs with the empty map for now; fix the file and reopen PlusMix, or save the map again in Settings › MIDI |
| Stream Deck buttons gray "未连接" (not connected; the plugin's label is in Chinese) | API off, wrong address / port / token; plugin logs in `~/Library/Logs/ElgatoStreamDeck/` |

## 9. Logs and diagnostics

- Help › Export Diagnostics…: settings (without the API token), the last second of statistics, the show file with stream keys removed, the shortcut / MIDI tables and system information; with your consent also crash diagnostics and the last two hours of logs. It is saved where you choose in the save panel and selected in Finder afterwards; you can open and check it before sending it. Help › Show Diagnostics Folder selects `~/Library/Application Support/PlusMix/Diagnostics` in Finder, which holds the crash / hang and other diagnostic records macOS hands over (`crash-….json`, `hang-….json` and so on; the latest 100 are kept), not the exported bundles; "Show Logs…" in the Stream / Recording Status window opens the same folder (the streaming / recording logs are not in it — see the system log below).
- Notices from the engine (recording, streaming, NDI® output, external displays, virtual camera and the like) also go to the system log; notices raised by the bottom bar itself (e.g. "No route takes part in recording…", "Transition in progress…") don't. The last 10 minutes (the full path `/usr/bin/log` works everywhere: a plain `log` is fine in Terminal, but in scripts or non-interactive zsh it hits zsh's own built-in of the same name and fails with "too many arguments"):

```bash
/usr/bin/log show --predicate 'process == "PlusMix"' --last 10m --style compact
```

- One statistics line per second (`stats.jsonl`, fields in [test standard §7](../../testing/测试标准.md#71-统计字段-statsjsonl), Chinese): launch with `--stats <file>`,
  or read `stats` from `GET /api/v1/state`; the statistics window shows the same data. Attach it when reporting a problem.
- Reproducing with the headless engine is often easier: `switcher-headless run --show <show> --duration 60 --stats /tmp/stats.jsonl` ([Samples](../../../Samples/README.md#1-打开), Chinese).
