# Troubleshooting

Look in three places first: the one-line message on an input cell (that input's own state, [Inputs › Input states](inputs.md#input-states)), the tooltip of the Record / Stream buttons in the bottom bar (every route's state and why it couldn't start),
and the notices / reminders at the right of the status line (outputs and system-level events). They name the cause and the next step; this page groups them by symptom.

## 1. Permissions

| Symptom | Cause | Fix |
|---|---|---|
| Camera cell: "camera access denied. Open System Settings › Privacy & Security › Camera; allowing this app recovers automatically, no restart" | "Don't allow" was clicked, or the prompt never appeared | Enable PlusMix there; recovers within about 2 s. The banner in the Add Input panel has "Open System Settings…" |
| Camera has picture but no sound; audio-only cell mentions microphone access | A device's microphone / an audio input needs separate microphone access | System Settings › Privacy & Security › Microphone |
| Screen input stays "no signal" or says screen recording denied, and **no prompt ever appeared** | Screen recording has no system prompt by design | System Settings › Privacy & Security › Screen & System Audio Recording, add PlusMix.app with +; recovers automatically (macOS may ask you to reopen PlusMix) |
| Access granted, asked again after rebuilding / updating | Ad-hoc signatures without a Team ID change on every build; macOS treats it as a new app | `DEVELOPMENT_TEAM=<TeamID> make gen` for a stable identity, or grant again each time |
| "restricted by system policy (parental controls / MDM)" | Device management forbids it | Ask the administrator; the app cannot lift it |
| PlusMix started from a terminal / script gets no camera | TCC grants belong to the launching process (Terminal, IDE) | Grant to Terminal.app, or launch from Finder / Dock |
| "Allow incoming connections" appears the first time you allow the local network or turn on the tally stream | The macOS firewall is on | Click Allow; otherwise other machines can't connect |

## 2. No signal

| Input | Cell message | Meaning |
|---|---|---|
| Camera / capture | "device disconnected, waiting to reconnect" | Unplugged; the same device plugged back recovers automatically (≤ 3 s) |
| DeckLink | "DeckLink driver not found: install Blackmagic Desktop Video (/Library/Frameworks/DeckLinkAPI.framework) and retry, no restart needed" | Driver missing; recovers once installed |
| DeckLink | "no signal" / list of connected devices | Cable or card absent; recovers when the signal / card returns |
| DeckLink | "DeckLink SDK not compiled in" | An error: the build machine had no SDK; rebuild |
| NDI® | "no NDI source found on the network … (sender not running, different subnet, or wrong name)" | Waits for the source; the name must match the sender's `MACHINE (source)`; the NDI® page of the Add Input panel searches again every 4 s |
| NDI® | "cannot search for NDI sources: …" | Error: SDK missing; install the NDI SDK for Apple to `/Library/NDI SDK for Apple` and rebuild |
| Video file | "no video track" | An audio-only file (mp3 / wav / m4a / aac) was chosen: in this version the file input still needs a video track |
| Video file / image | "image not found: …" / file cannot be opened | Wrong path; relative paths are relative to the show file's directory ([Samples › relative paths](../../../Samples/README.md#2-相对路径), Chinese). If the file only arrived later, click "Apply Source" in Input Settings › Source |
| Audio-only device | "disconnected, waiting to reconnect" | Recovers when plugged back; "System default input" inputs rebuild when the default changes |
| Any | Picture present but looks like 30 fps in a 60 fps show | The camera negotiated 30 fps (no 60 fps mode; that line is yellow in the Add Input panel): frames repeat by design; not a drop |

## 3. Disk

| Status line | Behaviour |
|---|---|
| "recording n: x MB free" | Warning below 1 GB; still recording |
| "recording n: x MB free, below the minimum 200 MB" | Only that recording stops; streaming and rendering continue. Change the minimum in Settings › Advanced › Free space minimum (or with the launch argument `--record-min-free-mb`) |
| "recording n: disk full (…)" / "recording n: disk full, switched to fallback folder: …" | Full: written fragments are kept; with a fallback folder (Settings › Advanced, or `--record-fallback`) recording continues there |
| "recording n failed to start: …" | Folder not writable / missing, or that ISO input's branches are used up (4 per input); fixing the folder retries automatically |
| "recording n failed to finalise: …" | Writing the index at stop failed; the fragmented `.mov` stays playable |
| Record in the bottom bar records nothing; notice "No route takes part in recording" | Every recording's "Take part in recording" is off, or the PGM row on the ISO page is unchecked and no input is checked: turn on the routes you want |

Free space is measured on the recording's own volume. A killed process recovers the `.mov` up to the last 1 s fragment (E6 allows at most 2 s loss).

## 4. Streaming

| Bottom bar / Streaming page / API state | Meaning |
|---|---|
| "Stream · Connecting", "Connecting (attempt n)" / `connecting` | Never connected yet: server unreachable, wrong address or path. A local MediaMTX only accepts the paths in its configuration (the repository's `scripts/mediamtx.yml` has s1 / s2 / s3 / srt1, with an empty key); any other path stays connecting |
| "Stream · Reconnecting (attempt n)" / `backoff` | Was live, then dropped: exponential back-off, retrying forever; the wait between attempts is capped by "Max retry interval n s" (30 s by default); resumes with a keyframe |
| "Stream · 1 in trouble" (dark red), tooltip "stream n failed to start: …" / `failed` | Couldn't start: unknown scheme (only rtmp / rtmps / srt), malformed address, no server. The destination's section on the Streaming page shows the reason: fix the URL (Return or leave the field) and it retries automatically, or "Turn Off This Destination"; healthy destinations are not affected, and the main Stream button only retries the ones that couldn't start |
| "stream n has no URL" | Empty address in the output settings |
| Stays "Connecting (attempt n)"; the system log says "鉴权失败（用户名或密码不对）…" (authentication failed) | The user name / password in "Authentication…" on the Streaming page is wrong (Adobe authentication); it keeps retrying with back-off; fix it |
| "Authentication…" filled in, connects, rejected as soon as it starts publishing (log: `NetStream.Publish.Unauthorized`) | The server (MediaMTX, SRS, nginx-rtmp and the like) wants a query string after the URL, not Adobe authentication: put `?user=…&pass=…` in the URL ([Outputs › Stream authentication](outputs.md#stream-authentication)) |
| The system log says "鉴权方式不支持：…" (method not supported) | The server wants an authentication method this version doesn't support |
| SRT with a passphrase doesn't connect | The passphrase may only use letters, digits and `- . _ ~`, 10–79 characters |
| Frames increase but the player shows nothing | Check `stats.encoder[].dropped` (network drops): non-keyframes are dropped first when bandwidth is short; lower the bitrate (a lower "Quality" on the Streaming page); keep "Total upload" at the bottom of the page under half your upload bandwidth |
| Local MediaMTX receives no SRT | Its SRT port must bind IPv4 (`srtAddress: 0.0.0.0:8890`; the repository's `scripts/mediamtx.yml` already does); RTMP is unaffected |

## 5. NDI® output, DeckLink, virtual camera not set up

| Symptom | Meaning |
|---|---|
| NDI® Output page "Unavailable: no NDI SDK", `state = unavailable` | No SDK at build time: nothing is sent. Install the SDK, then `make clean && make build` (Xcode caches the manifest's detection) |
| `state = failed` with a reason in the status line | SDK present but initialise / create failed (usually another process holding the NDI® runtime or a name clash); retried after a settings change |
| Add Input banner "NDI® runtime not available" / "This build has no DeckLink support" / "DeckLink driver not installed" | You can still add the input; it recovers once installed; "Read the guide" opens the matching section of this manual |
| Virtual camera: "failed: macOS refused the install: it needs a signed release build run from the Applications folder" | Development builds cannot activate system extensions: follow the three steps in [Outputs › Virtual camera](outputs.md#5-virtual-camera) |
| Virtual camera: "waiting for approval in System Settings › Privacy & Security" | macOS showed the approval prompt; on macOS 15+ it is under General › Login Items & Extensions |
| Virtual camera: "Virtual camera device not found (extension not installed / not activated); n frames dropped" | Output on, extension not connected; retried every second, starts automatically after activation |
| Extension not listed in System Settings / no "PlusMix" camera in FaceTime after activation | The extension must be embedded in an App inside /Applications; after changing bundle id / Team ID uninstall the extension first |

## 6. Picture and sound

| Symptom | What to check |
|---|---|
| Status line "Dropped" (missed_render) increasing | Rendering missed ticks. Usual causes: another app saturating the GPU, thermal throttling, a covered multiview window lowering the refresh. On an idle machine it stays 0 |
| Frames start dropping after nobody touched the Mac for a while | When the user is "idle" macOS delays real-time thread wake-ups. While the engine runs PlusMix itself prevents system sleep, App Nap and display sleep (Settings › Performance & Power, both on by default), so normally nothing else is needed. **Unattended runs with the lid closed or the screen locked** should still run `caffeinate -u -i -d -s` as well: the app can't prevent sleep on lid-close or a manual lock, and can't declare "user is active" the way `-u` does |
| Audio and video out of sync | Input Settings › Audio › Audio delay compensation (0–500 ms) for the capture device's own offset; the engine's alignment delay (default 2048 frames = 42.7 ms) is in Settings › Show Audio |
| With a compressor / limiter on a bus, headphones / speakers are slightly behind the picture | Expected: compression / limiting adds 5–35 ms; recording / streaming / NDI® are compensated, only live local monitoring is late |
| Changing an input's audio effects makes no audible difference | Per-input effect chains don't affect the sound yet in this version (the page says "Effects don't affect the sound yet (this version)"); bus effect chains do |
| Sound stays after cutting away / no sound after cutting in | That input's "Follow video": off = always audible, on = only on PGM. The global switch is in the mixer header |
| Headphones ahead of the picture | The monitor point defaults to before the alignment delay (low latency); to align with the picture choose "After the delay line" in Settings › Show Audio › Headphone monitor point |
| Solo / PFL / AFL silent, the mixer header says "This device has no headphone channels" | The output device has only 2 channels and Master uses them: pick a multichannel device in Settings › Audio Devices and give the headphones a channel pair |
| No sound from Bus A / B | Give Bus A / B a channel pair in Settings › Audio Devices (needs a multichannel device), then Apply and Restart Engine |
| Reminder "For 30 seconds the Master level has stayed below −50 dBFS (is the mic on?)" | Check whether the microphone input is muted, its fader, whether it feeds Master, and whether "Follow video" keeps it out |
| "audio device … cannot be created (…), falling back to the null device" | Device unplugged or held exclusively by another app: reselect in Settings › Audio Devices; with the null device picture, recording and streaming keep their audio, only local playback is silent |

## 7. Interface

| Symptom | Meaning |
|---|---|
| Nothing in the main window reacts to clicks; the status line says "Interface locked" | The interface lock is on: click the lock at the far right of the bottom bar, or Window › Lock Interface. Hotkeys and the menu bar keep working |
| Transition / Cut on a cell are grey and clicking a thumbnail does nothing | A transition is running (a half-pulled T-bar counts): wait for it to finish; or that input is already on PGM |
| Closing the main window asks "Save…" or "Quitting will stop…" | Closing the main window quits PlusMix, so it asks first, like ⌘Q |
| Help › PlusMix User Guide is greyed out as "(not bundled yet)" | This build has no bundled guide (`App/Resources/Help/` was not generated); the source of this manual is `docs/user/` in the repository |

## 8. API and control panels

| Symptom | Meaning |
|---|---|
| "API failed to start (127.0.0.1:8765): …" | Port in use (a previous PlusMix / headless still running): `lsof -i :8765`; change the port in Settings › Remote Control |
| curl returns 401 | A token is set in Settings › Remote Control: send `Authorization: Bearer <token>` (WebSocket may use `?token=`) |
| 200 with `applied = false` | The state machine ignored the command by rule (a transition while one runs, **changing PVW / PGM during a transition**, already at target); not an error |
| 400 | Malformed command / unknown input or output number; the body says why |
| A control panel / Companion on another machine can't connect | By default only this Mac can connect: set the local API or the compatibility layer to "Allow local network" in Settings › Remote Control, Apply and Restart Engine, and use the address shown there; click Allow when the firewall asks about incoming connections |
| Tally lights can't connect | Turn on the read-only tally stream in Settings › Tally (off by default) and use the address shown there; "tally stream failed to start" usually means the port is in use — pick another |
| Stream Deck buttons gray "not connected" | API off, wrong address / port / token; plugin logs in `~/Library/Logs/ElgatoStreamDeck/` |

## 9. Logs and diagnostics

- Help › Export Diagnostics…: settings (without the API token), the last second of statistics, the show file with stream keys removed, the shortcut / MIDI tables and system information; with your consent also crash diagnostics and the last two hours of logs. You can open and check it before sending it. Help › Show Diagnostics Folder shows the bundles already exported.
- Status-line notices also go to the system log. The last 10 minutes (the full path `/usr/bin/log` works everywhere: a plain `log` is fine in Terminal, but in scripts or non-interactive zsh it hits zsh's own built-in of the same name and fails with "too many arguments"):

```bash
/usr/bin/log show --predicate 'process == "PlusMix"' --last 10m --style compact
```

- One statistics line per second (`stats.jsonl`, fields in [test standard §7](../../testing/测试标准.md#71-统计字段-statsjsonl), Chinese): launch with `--stats <file>`,
  or read `stats` from `GET /api/v1/state`; the statistics window shows the same data. Attach it when reporting a problem.
- Reproducing with the headless engine is often easier: `switcher-headless run --show <show> --duration 60 --stats /tmp/stats.jsonl` ([Samples](../../../Samples/README.md#1-打开), Chinese).
