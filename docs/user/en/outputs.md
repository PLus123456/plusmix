# Outputs

The Output menu has six settings pages, one per output kind; the bottom-bar buttons (Record / Stream / Multiview / External / ISO…) are
shortcuts into them. Every output has a number, a name, a "should be running" switch and its own settings. Runtime numbers
(frames / bitrate / drops) live only in the status line and the API's `stats`, never in the show file.

| Kind | Sends | How it starts |
|---|---|---|
| Recording | PGM, or one input (ISO) | Record button starts / stops all recordings together; shortcut / API `startRecord` |
| Streaming | PGM | Stream button; `startStream` |
| NDI output | PGM / PVW / multiview / one input | the "Send" switch on the NDI page; `setOutputEnabled` |
| External display | PGM / PVW / multiview / one input (Aux) | External output menu / page; `setOutputEnabled` |
| Virtual camera | **PGM** | Output › Virtual Camera › Enable; `setOutputEnabled` |
| Multiview | the multiview picture (for downstream use) | Multiview page / `setOutputEnabled`; the layout is independent of the switch |

## 1. Recording

Output › Recording Settings…. Default directory `~/Movies/PlusMix`; a relative directory in the show file lives under it.

| Item | Notes |
|---|---|
| Directory, file name template | `{show}` `{date}` `{time}` `{output}`; default `{show}-{date}-{time}` |
| File format | Always written as `.mov` first (1 s fragments: a killed process recovers up to the last fragment); for .mp4 enable "remux to MP4 after stop" (the .mov is kept if it fails). The "container .mp4" option on the recording page has no effect in 0.1.0 (the file is still .mov); the next version merges both into one "file format" choice (prompt 87) |
| Video | H.264 / HEVC / ProRes 422 / 422 HQ / 4444 (hardware), bitrate, keyframe interval, size (default = program) |
| Audio | AAC (160 kbps default) or PCM; audio = Master bus |

- Encoder PTS is the tick time, so the file duration equals ticks × frame duration ([test standard](../../testing/en/README.md) E5); 20 normal stops
  and 10 kills during recording are covered by automated tests.
- A show can hold several recording outputs (e.g. PGM as H.264 and as ProRes); the button starts them together on the same tick.

### ISO recording

Output › ISO Recording… (or the ISO… button): each ticked input records its own file (source = that input's raw picture; encoding and
directory copied from the PGM recording; the file name template gets `{output}` appended).

- Started and stopped on the same tick as PGM, sharing the start tick: measured 0.0–0.2 ms between files for the same event (A4 requires ≤ 1 frame).
- The ISO audio track is that input after its fader and before AFV (recorded even when off air).
- A 30 fps input recorded into a 60 fps program repeats each frame, on the same grid as PGM.
- Each input has at most 4 branches (ISO / Aux windows / NDI input sources share them); the UI warns when they run out.
- The page shows the directory, free space and an estimate of remaining time (sum of all recording bitrates).

### Disk protection

Every second the free space of each recording's volume is checked (external drives and disk images included):

| Situation | Behaviour |
|---|---|
| Free space below 1 GB | Status line warns "recording n: x MB free" |
| Below the minimum (200 MB by default; `--record-min-free-mb` or the `recordMinimumFreeMB` defaults key — 0.1.0 has no Preferences item for it) | **Only that recording stops**; streaming, rendering and other recordings continue |
| Volume full / write error | That recording stops and keeps what was written; with a fallback directory (`--record-fallback`) it continues there from the next tick |

Tested with a 50 MB disk image and two 40 Mbps recordings filling it ([test standard](../../testing/en/README.md) S7).

## 2. Streaming

Output › Streaming Settings…: one output per destination, each with its own encoder and reconnect logic.

| Item | Notes |
|---|---|
| URL | `rtmp://host/app`, `rtmps://host/app`, `srt://host:port?streamid=…&passphrase=…&latency=…`; the scheme selects the protocol |
| Key | RTMP: appended as the stream name; SRT: becomes `streamid=<key>` when the URL has none |
| Video / audio | As for recording (platforms usually want H.264 + AAC with a 2 s keyframe interval: 60 frames at 30 fps, 120 at 60 fps) |
| Reconnect | Exponential back-off after a drop, retrying forever; the wait between attempts is capped at 30 s by default (the "reconnect limit" on the streaming page is that cap); the first frame after reconnecting is a keyframe |

- Destinations are independent: when one loses the network the others drop 0 frames (E7); after a 30 s outage 10 out of 10 reconnects
  succeed within 15 s (E8); the reported "network drops" match real drops within 5 % under bandwidth limits (E9). All of this runs
  automatically against a local MediaMTX with network impairment.
- The bottom-bar stream button shows e.g. "Stream · reconnecting (attempt n)" (in 0.1.0 it reflects the first destination only and n is successful reconnects + 1, not attempts; a destination that failed to start shows "Stream · idle"); in the API `stats.encoder[].state` is idle / connecting / publishing / backoff / stopping / stopped / failed.
- Try locally first: `mediamtx scripts/mediamtx.yml`, URL `rtmp://127.0.0.1:1935/live`, any key, then `ffplay rtmp://127.0.0.1:1935/live/<key>`
  ([Samples › streaming](../../../Samples/README.md#4-直播先在本机试)). RTMP and SRT are tested end to end in this repository; RTMPS is the same path plus TLS.

## 3. NDI® output

NDI® is a registered trademark of Vizrt NDI AB.

Output › NDI Output…: one output per sender; the source name is the output's name and appears on the network as **`MACHINE (output name)`**.

| Item | Notes |
|---|---|
| Source | PGM / PVW / multiview / one input (Aux, raw picture). PVW / multiview render an extra picture on demand and may miss a frame or two at the start |
| Groups | NDI group names (comma separated); empty = the default group `public`. Receivers filter by group |
| Conversion | NV12 → UYVY on the GPU, the CPU, or automatic (periodically compares both and keeps the cheaper one) |
| Audio | PGM / PVW / multiview send Master; an input source sends that input after its fader |

- Renaming, changing the source or the groups rebuilds the sender (receivers must reselect it); conversion can be switched any time.
- **SDK missing** (not detected at build time): the output can be added and enabled but nothing is sent; the page says "unavailable (no NDI SDK /
  initialisation failed)" and `stats.encoder[].state` is `"unavailable"`.
- SDK present but the sender cannot start (initialise / create failed): `state = "failed"` with the reason in the status line; retried when settings change.
- `stats.encoder[].connections` is the current receiver count; `bitrate` is the raw UYVY rate (about 2 Gb/s at 1080p60 — normal).

## 4. External output (second display)

Output › External Output…, or the External button (a display × source menu). One external output = one borderless full-screen window on one display.

- Source: PGM / PVW / multiview / one input (Aux, full-resolution raw picture).
- Display absent: by default stays black and waits, leaving the main display alone; "fall back to main display when absent" goes full screen
  on the main display (covering the UI) — only enable it deliberately.
- The window takes the latest frame at the display's own refresh; dragging the main window or entering full screen does not touch the render
  thread (missed-frame count stays flat). Esc closes the window.
- The show file stores display ID and source and restores them; display IDs can change across reboots, so reselect if needed.

## 5. Virtual camera

Output › Virtual Camera: lets FaceTime, QuickTime, browser meetings etc. use PlusMix as a camera. **It sends PGM** (no source selection).

Install once:

1. Build with a Team ID (`DEVELOPMENT_TEAM=<TeamID> make gen build-app`), move PlusMix.app to `/Applications` and launch from there —
   system extensions can only be activated from an App in /Applications.
2. Output › Virtual Camera › Install / Activate Extension…, then allow it in System Settings › General › Login Items & Extensions
   (older releases: Privacy & Security). "Check Extension Status" shows the current state.
3. Output › Virtual Camera › Enable / Disable Virtual Camera Output. Pick the "Switcher" camera in FaceTime / QuickTime › New Movie Recording (in 0.1.0 the device is still named after the code name, Switcher).

- Development builds (no Team ID, ad-hoc signature) cannot activate: the status says signing / entitlement / location requirements are not met
  (BLOCKED-signing); the App keeps running.
- Output enabled but the extension not connected: "virtual camera device not found (extension not installed / not activated); n frames dropped",
  retried every second; sending starts automatically once connected. With the output off, the other side sees a placeholder (dark gray with a moving white bar).
- Frame rate follows the program, 1080p NV12; PGM to the receiving process within 3 frames is the design target (verified on signed builds).

## 6. Multiview

Output › Multiview Layout…; Window › Multiview Window (or the Multiview button) opens the separate window, which can be moved to any screen or made full screen.

| Item | Notes |
|---|---|
| Presets | `pgmPvw+grid` (default: PVW / PGM on top, 4×2 / 6×3 / 8×4 below depending on input count), `pgmPvw+4x2`, `pgmPvw+2x2`, `3x3`, `4x4` |
| Custom | one source (PGM / PVW / input n) and rectangle per cell; replaces the preset when non-empty |
| Safe area | EBU R95 action-safe 3.5 % / title-safe 5 % on the PGM / PVW cells |
| Meters | input cells show that input's meter, PGM = Master, PVW = the current PVW input; the readings are the same data as the status line / API |

- Every cell has a tally border (red PGM / green PVW) and a name label; audio-only inputs show name + meter.
- The layout is stored in the show file (settings of the first multiview output) and applies to the multiview window, the thumbnail strip and the
  "multiview" source of external outputs / NDI.
- The multiview output's switch only decides whether the multiview picture is sent downstream (NDI / external); the layout does not depend on it,
  so the output that merely carries the layout can stay off.
