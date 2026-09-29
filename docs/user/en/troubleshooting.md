# Troubleshooting

Look in two places first: the one-line message on an input cell (that input's own state, [Inputs › Input states](inputs.md#input-states))
and the notice in the bottom status line (outputs and system-level events). Both name the cause and the next step; this page groups them by symptom.

## 1. Permissions

| Symptom | Cause | Fix |
|---|---|---|
| Camera cell: "camera access denied. Open System Settings › Privacy & Security › Camera; allowing this app recovers automatically, no restart" | "Don't allow" was clicked, or the prompt never appeared | Enable PlusMix there; recovers within about 2 s |
| Camera has picture but no sound; audio-only cell mentions microphone access | A device's microphone / an audio input needs separate microphone access | System Settings › Privacy & Security › Microphone |
| Screen input stays "no signal" or says screen recording denied, and **no prompt ever appeared** | Screen recording has no system prompt by design | System Settings › Privacy & Security › Screen & System Audio Recording, add PlusMix.app with +; recovers automatically |
| Access granted, asked again after rebuilding / updating | Ad-hoc signatures without a Team ID change on every build; macOS treats it as a new app | `DEVELOPMENT_TEAM=<TeamID> make gen` for a stable identity, or grant again each time |
| "restricted by system policy (parental controls / MDM)" | Device management forbids it | Ask the administrator; the app cannot lift it |
| PlusMix started from a terminal / script gets no camera | TCC grants belong to the launching process (Terminal, IDE) | Grant to Terminal.app, or launch from Finder / Dock |

## 2. No signal

| Input | Cell message | Meaning |
|---|---|---|
| Camera / capture | "device disconnected, waiting to reconnect" | Unplugged; the same device plugged back recovers automatically (≤ 3 s) |
| DeckLink | "DeckLink driver not found: install Blackmagic Desktop Video (/Library/Frameworks/DeckLinkAPI.framework) and retry, no restart needed" | Driver missing; recovers once installed |
| DeckLink | "no signal" / list of connected devices | Cable or card absent; recovers when the signal / card returns |
| DeckLink | "DeckLink SDK not compiled in" | An error: the build machine had no SDK; rebuild |
| NDI | "no NDI source found on the network … (sender not running, different subnet, or wrong name)" | Waits for the source; the name must match the sender's `MACHINE (source)`; "Refresh" in the add panel lists current sources |
| NDI | "cannot search for NDI sources: …" | Error: SDK missing; install the NDI SDK for Apple to `/Library/NDI SDK for Apple` and rebuild |
| Video file / image | "image not found: …" / file cannot be opened | Wrong path; relative paths are relative to the show file's directory ([Samples › relative paths](../../../Samples/README.md#2-相对路径)) |
| Audio-only device | "disconnected, waiting to reconnect" | Recovers when plugged back; "follow system default" inputs rebuild when the default changes |
| Any | Picture present but looks like 30 fps in a 60 fps show | The camera negotiated 30 fps (no 60 fps mode): frames repeat by design; not a drop |

## 3. Disk

| Status line | Behaviour |
|---|---|
| "recording n: x MB free" | Warning below 1 GB; still recording |
| "recording n: x MB free, below the minimum 200 MB" | Only that recording stops; streaming and rendering continue. Change the minimum with `--record-min-free-mb` or the `recordMinimumFreeMB` defaults key (no Preferences item in 0.1.0) |
| "recording n: disk full (…)" / "switched to fallback directory: …" | Full: written fragments are kept; with a fallback directory (`--record-fallback`) recording continues there |
| "recording n failed to start: …" | Directory not writable / missing, or that ISO input's branches are used up (4 per input) |
| "recording n failed to finalise: …" | Writing the index at stop failed; the fragmented `.mov` stays playable |

Free space is measured on the recording's own volume (a bug that reported 0 on non-boot volumes was fixed in 0.1.0). A killed process recovers
the `.mov` up to the last 1 s fragment (E6 allows at most 2 s loss).

## 4. Streaming

| Status line / API state | Meaning |
|---|---|
| "Stream · reconnecting (attempt n)" / `backoff` | Connection lost; exponential back-off (capped at 30 s); resumes automatically with a keyframe |
| "stream n failed to start: …" / `failed` | Unknown scheme (only rtmp / rtmps / srt), server refused, wrong key |
| "stream n has no URL" | Empty address in the output settings |
| Frames increase but the player shows nothing | Check `stats.encoder[].dropped` (network drops): non-keyframes are dropped first when bandwidth is short; lower the bitrate |
| Local MediaMTX receives no SRT | Its SRT port must bind IPv4 (`srtAddress: 0.0.0.0:8890`; the repository's `scripts/mediamtx.yml` already does); RTMP is unaffected |

## 5. NDI output, DeckLink, virtual camera not set up

| Symptom | Meaning |
|---|---|
| NDI page "unavailable (no NDI SDK / initialisation failed)", `state = unavailable` | No SDK at build time: nothing is sent. Install the SDK, then `make clean && make build` (Xcode caches the manifest's detection) |
| `state = failed` with a reason in the status line | SDK present but initialise / create failed (usually another process holding the NDI runtime or a name clash); retried after a settings change |
| Virtual camera: signing / entitlement / location requirements not met (BLOCKED-signing) | Development builds cannot activate system extensions: follow the three steps in [Outputs › Virtual camera](outputs.md#5-virtual-camera) |
| Virtual camera: "waiting for approval in System Settings" | macOS showed the approval prompt; on macOS 15+ it is under General › Login Items & Extensions |
| Virtual camera: "device not found (extension not installed / not activated); n frames dropped" | Output on, extension not connected; retried every second, starts automatically after activation |
| Extension not listed in System Settings / no "Switcher" camera in FaceTime after activation (in 0.1.0 the virtual camera device is still named after the code name, Switcher) | The extension must be embedded in an App inside /Applications; after changing bundle id / Team ID uninstall the extension first |

## 6. Picture and sound

| Symptom | What to check |
|---|---|
| Status line "missed" (missed_render) increasing | Rendering missed ticks. Usual causes: another app saturating the GPU, thermal throttling, a covered multiview window lowering the refresh. On an idle machine it stays 0; for long runs use `caffeinate -u -i -d -s` (`-i` alone is not enough: when the user is "idle" macOS delays real-time thread wake-ups by 10–18 ms; the app does not yet prevent sleep / App Nap itself, prompt 98) |
| Audio and video out of sync | Input Settings › Audio › Delay compensation (0–500 ms) for the capture device's own offset; the engine's alignment delay (default 2048 frames = 42.7 ms) is in Preferences › Show audio |
| Sound stays after cutting away / no sound after cutting in | That input's "follows video": off = always audible, on = only on PGM. The global switch is in the mixer |
| Headphones ahead of the picture | The monitor point defaults to before the alignment delay (low latency); choose "after delay line" to align with the picture |
| "audio device … cannot be created (…), falling back to the null device" | Device unplugged or held exclusively by another app: reselect in Preferences › Audio output; with the null device picture, recording and streaming keep their audio, only local playback is silent |

## 7. API and control panels

| Symptom | Meaning |
|---|---|
| "API failed to start (127.0.0.1:8765): …" | Port in use (a previous PlusMix / headless still running): `lsof -i :8765`; change the port in Preferences |
| curl returns 401 | A token is set: send `Authorization: Bearer <token>` (WebSocket may use `?token=`) |
| 200 with `applied = false` | The state machine ignored the command by rule (transition running, already at target); not an error |
| 400 | Malformed command / unknown input or output number; the body says why |
| Stream Deck buttons gray "not connected" | API off, wrong address / port / token; plugin logs in `~/Library/Logs/ElgatoStreamDeck/` |

## 8. Logs and diagnostics

- Status-line notices also go to the system log. The last 10 minutes:

```bash
log show --predicate 'process == "PlusMix"' --last 10m --style compact
```

- One statistics line per second (`stats.jsonl`, fields in [test standard §7](../../testing/测试标准.md#71-统计字段-statsjsonl), Chinese): launch with `--stats <file>`,
  or read `stats` from `GET /api/v1/state`. Attach it when reporting a problem.
- Reproducing with the headless engine is often easier: `switcher-headless run --show <show> --duration 60 --stats /tmp/stats.jsonl` ([Samples](../../../Samples/README.md#1-打开)).
