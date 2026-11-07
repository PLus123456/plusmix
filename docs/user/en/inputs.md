# Inputs

## Adding an input

Ways in: Input › Add Input… (⌘I), "Add Input…" in the bottom bar (the button opens the panel; ▴ jumps to a type or re-adds a recently added source in one click), the "＋ Add Input" cell at the end of the input strip, or simply [drop video / image files on the input strip](#dropping-files).

The panel's left column is grouped by purpose; the first line of every page says what it connects and what it needs:

| Group | Types |
|---|---|
| Devices | Camera / capture card, DeckLink, Audio device |
| Network | NDI® |
| Screen | Screen / window |
| Media | Video file, Image |
| Test | Synthetic test source |

- The first time it opens on "Camera / capture card"; after that on the type you added last, with **the last source of every type** filled in (camera, file, NDI® source and bandwidth, audio device and channels, which display…). A remembered camera or display that is gone falls back to the first one in the list (an audio device that is gone shows "(missing)").
- The number defaults to the lowest free one (you can change it; only free numbers are listed, existing inputs are never renumbered). A show holds at most 16 inputs; when it is full, "Add" is greyed out with "This show already has the maximum of 16 inputs".
- The panel can be resized and reopens at that size.
- Any input can later be pointed at a different device in Input Settings › Source; number, name, settings and PGM / PVW / overlay references are kept.
  At the moment of the change PGM / PVW keep showing the old source's last frame until the new source's first frame arrives (no black flash); if the new source can't start (file missing, can't be created) or is an audio-only device, the input goes black; if it starts but never produces a picture (a camera that isn't plugged in, an NDI® source that isn't on the network and the like), the old source's last frame stays until the new source's first frame arrives. An ISO recording in progress and an Aux external display showing this input carry on with the new source ([Outputs › ISO recording](outputs.md#iso-recording)).
- Two kinds (DeckLink, NDI®) need optional third-party SDKs at build time — without the SDK the input can be added but never produces a picture (the cell says so).

**Banners**: when access is denied or a runtime is missing, the page shows a banner at the top; you can still add the input ("It shows an error until access is granted, then recovers on its own" next to Add):

| Situation | Banner button |
|---|---|
| Camera / microphone / screen recording access denied | "Open System Settings…": straight to the right page of System Settings › Privacy & Security |
| This build has no NDI® support, this build has no DeckLink support, DeckLink driver not installed | "Read the guide": opens the matching section of this manual |

Access that has never been asked for shows no banner — macOS asks when you add the first one. After granting or installing, the banner updates when you come back to the panel.
Note: "This build has no NDI® support" and "This build has no DeckLink support" mean **this copy of the app was built without that SDK**: an input added anyway stays in error (the note next to Add says "It keeps showing an error (this build doesn't support it)") until you use an app built with the SDK. "DeckLink driver not installed" really does recover once the driver is installed and the card connected (the note says "It shows an error until that is installed, then recovers on its own").

## Input states

Each input cell shows one of three states. The dividing line is "will it recover by itself" ([design spec §6](../../spec/导播台设计方案.md)):

| State | Meaning | Examples |
|---|---|---|
| **live** | Producing frames (or audio, for audio-only inputs) | — |
| **noSignal (waiting)** | Nothing right now, **will recover by itself**. The cell says "No signal" (audio-only inputs: "Waiting for the audio device…"), with the reason the input itself reports on a second line (cut short if long; the tooltip has it all — the engine writes it in Chinese, e.g. "摄像头 … 已断开，等待重新连接", camera disconnected, waiting for it to come back); see [Troubleshooting › No signal](troubleshooting.md#2-no-signal) | Device unplugged, DeckLink driver missing, NDI® source not yet online, external display unplugged, file still opening |
| **error** | **Will not recover by itself**; you need to act. The cell shows the reason, in Chinese in this version (e.g. a camera permission message telling you to allow access in System Settings) | Permission denied (System Settings), SDK not compiled in (rebuild), file / image not found (fix the path), stream failed to start (change configuration) |

In noSignal the frame slot keeps the last frame (PGM does not flash black). Plugging the device back, installing the driver or the source
coming online restores the input automatically — no need to delete and re-add; number and settings are unchanged. Permission denied is
an error, but granting it also recovers automatically (polled once a second), no restart needed.

## Camera / capture device

AVFoundation: built-in camera, USB / UVC cameras and capture devices (HDMI / SDI to USB), and iPhone Continuity Camera all appear in the same list.

- The first use prompts for camera access.
- Format negotiation: frame rate matching the program first, then resolution (equal > smallest that is at least the program size > largest),
  then native NV12; the frame rate is locked. The panel states the result, e.g. "Captures at 1920×1080 · 60 fps (matches the program frame rate)"; when it doesn't match the line turns yellow and says what happens:
  "slower than the program, so frames repeat" or "faster than the program, so frames drop", plus "(scaled to …)" when the size differs.
  A 30 fps camera in a 60 fps program repeats every frame by design; that is not a drop (the MacBook Pro built-in camera tops out at 30 fps, so it is yellow in a 60p show — as it should be).
- The device's own microphone (same USB device) is captured too and **needs microphone access**; without it you get picture only.
- Hot-plug: unplug → noSignal; the same device plugged back → rebuilt automatically, back to live within 3 s.
- A camera's fixed pipeline latency (about 55 ms for the built-in camera) is not jitter; the engine picks frames by arrival time, so no manual
  compensation is needed. If audio and video disagree, use Input Settings › Audio › Audio delay compensation (0–500 ms).

## DeckLink

SDI / HDMI inputs on Blackmagic DeckLink / UltraStudio cards. Requires the Blackmagic Desktop Video driver (`/Library/Frameworks/DeckLinkAPI.framework`); building PlusMix needs the DeckLink SDK
(`DECKLINK_SDK_DIR` or `~/SDKs/DeckLink`), otherwise this kind is an empty implementation (error with a message).

- The panel lists cards and input connections (SDI / HDMI / optical SDI / component / composite / S-Video); "Keep" uses what Desktop Video
  Setup selected. Device ID `peid:<persistent id>` (`model:<model>#<index>` for old cards); empty = first card with an input.
- Automatic format detection where the card supports it: a signal changing from 1080p59.94 to 720p60 reopens automatically. No-signal
  frames are not shown (the cell keeps the last frame and says "no signal"); the input recovers when the signal returns.
- Embedded audio: the card provides 2–16 channels; the "Channels" field picks which two ([channel mapping](#channel-mapping)); the SDK only
  accepts 2 / 8 / 16, so asking for channel 6 opens 8.
- Driver missing: the cell says "No signal" (noSignal) with "没有找到 DeckLink 驱动：安装 Blackmagic Desktop Video……" (DeckLink driver not found: install Blackmagic Desktop Video…) below it; install Blackmagic Desktop Video and connect the card and it recovers by itself, no restart needed. In an app built without the DeckLink SDK the cell shows "DeckLink SDK 未编译进来：…后重新编译" ("DeckLink SDK not compiled in … rebuild", error).
- Status: capture from real hardware **has not been verified on this project's machines** (no DeckLink hardware on the development Mac);
  the bridge was tested against the SDK's simulated device. If you have a card, please report through the [device compatibility table](../../testing/设备兼容性.md) (Chinese).

## Screen / window / application

ScreenCaptureKit: a whole display, a single window, or all windows of one application (slides, a browser, a remote-call window).

- **Screen recording has no system prompt.** Add PlusMix yourself in System Settings › Privacy & Security › Screen & System Audio Recording
  ([Troubleshooting](troubleshooting.md#1-permissions)); the banner on the panel has "Open System Settings…".
- The panel shows a grid of thumbnails: displays are always listed; the window / application list and their thumbnails need screen recording access (without it only icons are drawn).
- Frame rate defaults to the program's and can be lowered (30 fps is plenty for documents and saves GPU). "Capture system audio" brings
  that display's / application's sound in (PlusMix's own audio excluded).
- Frames enter the compositor as BGRA (text is not chroma-subsampled); sources larger than the program are scaled to fit. A static
  picture is re-pushed as the last frame and does not fall to noSignal.

## Video file

Anything AVFoundation decodes (H.264 / HEVC / ProRes in .mov / .mp4 …).

- Frames follow the **program clock** (clock slave); at the end: hold last frame / loop / black. Pause, back to start and restart-when-taken-to-PGM are under [Playback](#playback) below.
- **Playback rate 0.1–8×**: the rate fields in the Add Input panel and in Input Settings › Source are clamped to that range (10 is stored as 8, 0.05 as 0.1, and 0 or a negative number counts as empty = 1×; text that isn't a number is not taken and the field goes back to its previous value). Out-of-range rates sent through the API get a 400; a show file holding an out-of-range rate (older versions could save one) doesn't open at all (see [Troubleshooting › Interface](troubleshooting.md#7-interface)).
- The panel keeps "Recent" files (up to 10, newest first; click to fill in, double-click to add; a file that is gone is greyed out as "(missing)"); once a file is chosen its information is shown, e.g. "H.264 · 1920×1080 · 60 fps · 0:10" (no audio and alpha are mentioned too).
  For a clip shot in portrait on a phone it shows the upright size first (what the input produces) and the encoded size in parentheses, e.g. "H.264 · 1080×1920 (encoded 1920×1080) · 30 fps · 0:12".
- **Portrait and rotated clips are turned upright**: a file that records its orientation (an orientation matrix) is rotated by 90 / 180 / 270° (mirroring included) before its frames go out, so it looks the way a player shows it; rotation / flip in Input Settings › Crop & position apply on top of that.
  An orientation matrix that isn't a multiple of 90° (rare) is not applied — the frames come out as encoded; while it plays, a line of small text along the bottom of the cell's thumbnail says so (hover for the full text), and Input Settings › Source shows "This input reports: …" (other things the input reports about itself — a failed upright turn, a rate / seek outside the range being clamped — show up in the same two places).
- The audio track goes through this input's fader / buses / AFV like any other input.
- **Audio-only files** (mp3 / wav / m4a / aac): the open panel accepts them, the information reads "Audio only · …" and the cell is drawn as audio-only; but **in this version the file input still needs a video track**, so the input then shows "没有视频轨" ("no video track").
- **Changing only "At end" or "Playback rate" applies at once without rebuilding**: the cell's 🔁 button or these two fields in Input Settings › Source keep playback going (no restart, no drop-out) and don't need "Apply Source"; only a new file or type needs "Apply Source" (the input is rebuilt from the new source and plays from the start; PGM / PVW hold the old picture until the new source's first frame arrives).
- If the file is missing when the input is added (the cell shows "文件不存在：…", "file not found"): once the file is in place, remove the input and add it again, or reopen the show — unlike images, video files are not picked up by themselves.
- The path is stored in the show file; relative paths are relative to the show file's directory (for a show that has never been saved, `~/Movies/PlusMix`; [Samples › relative paths](../../../Samples/README.md#2-相对路径), Chinese).

### Playback

The last three buttons in the first row of a video-file cell, its right-click menu and the "Playback" section under Input Settings › Source are one set of actions and behave the same (on other inputs the three buttons are greyed out with the tooltip "Video / audio file inputs only").

| Button | What it does |
|---|---|
| ⏮ Back to start | Plays from the start if playing; holds the first frame if paused (still paused) |
| ⏸ / ▶ | While playing it shows ⏸: click = **pause**, the picture holds this frame (frames keep coming every tick, the cell doesn't say "no signal"); while paused it shows ▶, highlighted: click = carry on from where it stopped; when it has finished (loop off) it shows ▶: click = play from the start. A finished file holding its last frame (or gone to black) shows "No signal" on the cell; a paused one doesn't |
| 🔁 Loop | On = loop (highlighted); **off = hold the last frame at the end**. For black at the end, set "At end" to "Black" in Input Settings › Source (applies at once). Turning loop on just before the end goes on into the next round (it doesn't stop on the last frame); turning it on after the file has finished and is holding its last frame = it starts over and keeps looping right away |

- **Restart When Taken to PGM** (ticked in the right-click menu, or Input Settings › Source › Playback): the input plays from the start on the tick it goes to PGM (Cut, transition done, T-bar at the end, API `setProgram`); previewing it on PVW doesn't restart it.
  The first frame lands about 3 ticks after the switch (50 ms at 60p) — during those ticks PGM holds the input's last frame from before the switch; taken to PGM while paused = back to the first frame, still paused. The setting is saved with the show (changing it counts as unsaved).
- Pausing and going back to the start are live operation and do not count as unsaved changes; a new file or "Apply Source" rebuilds the input and plays from the start.
- A pause takes effect once the input's pacing thread applies it (about a tick): clicking ▶ again before that (a quick double click) cancels the pause and playback carries on where it was — it doesn't jump back to the start, and the sound doesn't break.
- The commands are `setPlayback` and `seekPlayback` ([API reference](../../api.md), Chinese); hotkeys / MIDI can bind them ("File play / pause" and "Seek file / restart" in the Inputs group of the action picker).
  Seek takes 0–604,800 seconds (one week), anything else gets a 400; seeking to the clip's length or beyond = play from the start.

## Image

PNG (with alpha) / JPEG / HEIC … Large images are pre-scaled to the program size.

- A PNG with alpha on an overlay channel is a title or a logo; a full 1920×1080 image with transparent areas is the simplest form
  (the [samples](../../../Samples/README.md#5-重新生成) ship three).
- **Several at once**: select several files in the open panel; each becomes one input named after its file (the first takes the number chosen in the panel, the rest the next free numbers; if there aren't enough free numbers nothing is added and the panel says why).
- **Edits to the file show up automatically**: change the image in your image editor and save (overwrite or replace); PGM switches to the new picture on the next tick, without a black frame and without rebuilding the input.
  The file doesn't have to exist when the input is added: the cell first shows "图片不存在：…" ("image not found") and switches to the picture by itself once the file appears (checked every 0.25 s).
- It can also be the Stinger layer: point the Stinger input at it in the transition parameters.
- Images have no audio (the cell's Mute button is greyed out).

## NDI® receive

NDI® video (with sound) from other computers or devices on the same network. Requires the NDI SDK for Apple (default `/Library/NDI SDK for Apple`) at build time; in an app built without it the cell shows "NDI SDK 未编译进来：…后重新编译"
("NDI SDK not compiled in … rebuild", error), and the NDI® page of the Add Input panel says "Cannot look for NDI sources: …". (NDI® is a registered trademark of Vizrt NDI AB.)

- While this page of the panel is open it searches again every 4 s (a spinner shows while it searches) and lists the sources on the network (names look like `MACHINE (source)`); **double-click to add**; you can also type one.
  A missing source is noSignal: the cell says "No signal" with "网络上找不到 NDI 源 …（发送端没开、不在同一网段，或名字不对）" (NDI source not found on the network: sender not running, different subnet, or wrong name) below it, and it connects when the source appears.
- Bandwidth: Highest (full resolution) / Lowest (preview stream) / Audio only; sources used only for thumbnails can use "Lowest" to save more than half the bandwidth and decoding.
- Jitter buffer 0–2 frames directly sets this input's latency (each frame adds about one frame); default 1.
- Loopback on one machine (PlusMix sending and receiving) measured 1–2 frames behind PGM.

## Audio-only device

Core Audio input devices: built-in microphone, USB interfaces, aggregate devices, iPhone microphone (Continuity), a mixing desk's USB output. This input **has no picture**.

- Devices are listed like "MacBook Pro Microphone (1 ch · Built-in)" (channels · connection); "System default input" rebuilds automatically when the default changes in System Settings; on multi-channel interfaces pick which channels.
  The first use prompts for microphone access.
- The cell shows a microphone glyph, the name and a level meter; it can be put on PGM / PVW / overlays (picture is black, audio follows AFV as usual);
  the multiview cell shows name + meter too.
- The device is set to 48 kHz; if it cannot, audio is converted (the panel says "no 48 kHz, will convert"). Unplug → noSignal (the cell says
  "Waiting for the audio device…", with "音频输入设备「…」已断开，等待重新连接" — audio input device disconnected, waiting — below it); plugged back → live within 3 s.

## Synthetic test source

Built into the engine: every frame carries a frame number, timestamp, input ID and a once-per-second flash block, optionally with synthetic
audio (1 kHz at −20 dBFS plus a click at the flash). Parameters: frame rate (30 / 59.94 / 60), background (flat gray / gradient / gray with
noise), artificial jitter, artificial drops, clock drift, audio drift. Use it to build a show without devices (the [samples](../../../Samples/README.md)
use it exclusively), to verify A/V alignment, or to give encoders a realistic load (noise background). Full definition in
[test standard §2.1](../../testing/测试标准.md#21-合成视频源) (Chinese).

## Input strip and cells

The strip across the middle of the main window. Its header, left to right:

- **Category tags**: "All" + six colours (red, orange, yellow, green, blue, purple). Click a colour to show only that category, click it again for all; it combines with the search. Right-click a colour for Rename… / Clear Name (a named tag shows its name).
  To categorise an input: right-click its cell › Category ▸. The colour is stored in that input's configuration (`inputs[].color` in the API's full state, command `setInputColor`; a colour changed through the API / a script shows on the cell too); changing it counts as unsaved, and removing the input removes its colour.
  The names given to the tags are stored in the show file's interface layout and exist only in the app. The multiview label dots and Stream Deck buttons don't show category colours yet. Older shows (colours still kept in the layout) are converted once when opened, which doesn't count as unsaved.
- **Search field**: filter by number or name; ⌘F (Input › Find Input) puts the cursor in it; Return gives focus back to the main window (the filter stays), Esc gives focus back and clears the filter — hotkeys then work as usual.
- "**Audio Mixer**" at the right end: show / hide the mixer (the same switch as Window › Audio Mixer; highlighted while shown).

### Cells

One cell per input: a title bar (number, name, category dot; red background on PGM, green on PVW), the thumbnail (all cells are the same height, taken from the multiview cell's aspect ratio and never taller than 16:9; no black bars) and two rows of buttons.
First row × | Transition | Cut | ⏮ | ▶⏸ | 🔁, second row 1 2 3 4 | Mute | ⚙:

| Button | What it does |
|---|---|
| × | Remove this input. If it is on PGM / PVW / a visible overlay channel / the Stinger / an ISO recording in progress, it asks first and lists what happens ("It's on PGM: PGM will go black"…); otherwise it is removed at once. This can't be undone |
| Transition | Takes this input to PGM with the **current transition slot** (it is put on PVW first if it isn't there) — the same slot Return, the T-bar and Run Current Transition use ([Concepts › Transition slots](concepts.md#transition-slots)). The tooltip names it, e.g. "Take to PGM with the current transition (Transition 1 · Fade 0.5 s)". While the current slot is a Stinger with no input yet, clicking it pops up that slot's input list first and sends no command (PVW stays as it is; [Concepts › The transition column](concepts.md#the-transition-column)) |
| Cut | Cut straight to PGM (skips PVW) |
| ⏮ ▶⏸ 🔁 | Back to start / pause·play / loop, lit only for video files (greyed out on other inputs); see [Video file › Playback](#playback) |
| 1 2 3 4 | Put this input on overlay channel n and show it; if it is already showing there = hide. Right-click = Overlay Settings… |
| Mute | Mute / unmute this input; greyed out for inputs without sound (images, screen capture without audio, a synthetic source without audio), the tooltip says why |
| ⚙ | This input's settings (also right-click › Settings…) |

- **Click a thumbnail** = put it on PVW; **Shift-click** = cut it straight to PGM.
- **During a transition** (a half-pulled T-bar counts) Transition and Cut are greyed out and clicking or Shift-clicking a thumbnail does nothing; the status line says "Transition in progress: PVW / PGM can change after it finishes" —
  the state machine refuses PVW / PGM changes during a transition (see [Concepts › How a switch happens](concepts.md#how-a-switch-happens)). Transition / Cut are also greyed out on the input that is already on PGM.
- The six buttons fit even in the smallest cell (160 pt wide): ⏮ ▶⏸ 🔁 are 20 pt icons and Transition / Cut share the rest in proportion to their titles. In the English UI "Transition" can still be cut short in the smallest cells; the tooltip has the full text.
- **Right-click menu**: Send to PVW / Cut to PGM / Take to PGM with the current transition (Transition 1 · Fade 0.5 s) / Overlay ▸ 1–4 / Category ▸ / Mute — [video file inputs add four items: Play (or Pause) / Back to Start / Loop (ticked) / Restart When Taken to PGM (ticked) —] Settings… / Change Source… (opens the Source section of the input settings) / Rename… — Remove Input n.

### Dropping files

Drag video / image files from Finder onto the input strip or the "＋ Add Input" cell: each file becomes one input straight away, without the panel. Numbers are the next free ones, names are the file names; a video becomes a file input (loop, 1× speed), an image an image input.
The strip is outlined in blue while you drag; files that are neither video nor image are skipped and the status line says "Skipped 1 file(s) that are not video / image: …"; when the numbers run out it stops and says so. Dropped files also go into "Recently Added".

### The "＋ Add Input" cell and thumbnail size

- The input strip always ends with a dashed "＋ Add Input" cell; click it for the Add Input panel (same as "Add Input…" in the bottom bar). In an empty show it is the only cell and also says "You can also drop video / image files here".
- Three thumbnail sizes: Small / Medium / Large (cells 160 / 200 / 256 wide). Right-click an empty part of the strip › Thumbnail Size ▸, or Window › Input Thumbnails ▸. Stored on this Mac; after a change the strip snaps back to the cell height.

## Per-input settings

The "Input n Settings — name" window: the ⚙ on a cell or right-click › Settings…, the gear on a monitor's title bar (the input on PVW / PGM), or Input › Input N "name" Settings… (⇧⌘I, the input on PVW).
One window per input, several can be open; hotkeys keep switching the program while it is in front. The header line shows the number, the name and the tally ("On PVW / On PGM"); at the bottom right is this input's live picture (its cell of the multiview, thumbnail quality); audio-only inputs say "Audio-only input, no picture".

| Section (sidebar order) | Contents |
|---|---|
| General | Name (it changes when you leave the field, press Return or close the window), number, type |
| Keyer | Enable keyer, key colour, "Pick from picture" (click the picture at the bottom right; the average of the 3×3 pixels around that point becomes the key colour), tolerance, edge softness, spill suppression, Restore defaults; applies wherever the input appears (PGM, transitions, overlays, PVW, multiview) |
| Crop & position | Crop on four edges (%), scale, horizontal / vertical offset, rotation, flip horizontally / vertically; numbers can be typed next to the sliders, every item has a reset (↺), and each group can be reset; "Copy position / Paste position" copies crop and position between inputs |
| Audio | Bus sends, gain, mute, solo (to headphones), pan, audio delay compensation (ms, 0–500, sound only), **Follow video (AFV)** (the same switch as on the mixer strip; has no effect while AFV is off in the mixer header), Reset gain / pan / delay |
| Audio effects | Parametric EQ (up to 3 bands), compressor ("Use compressor", then one of two under "Type": Compressor (threshold + ratio) — threshold / ratio / knee / attack / release / makeup; Dynamics processor (threshold + amount) — threshold / Headroom / expansion ratio / attack / release / output gain); changes **affect this input's sound immediately** (the same settings as this input's audio settings window). Processing order is always EQ, then compressor; **there is no limiter** (inputs get no limiter, only buses do). Effects this page doesn't know (a second compressor written through the API, a limiter cell in the chain) are listed under "Other effects (kept as is)" — shown, not editable; editing the other cells doesn't move them. See [Concepts › Audio](concepts.md#audio) |
| Source | Change type / device / file / source name / end action / rate (0.1–8; values outside are clamped, 0 and negative numbers mean 1×, see [Video file](#video-file)); "Apply Source" rebuilds the input from the new source (the old picture holds until the new source's first frame, files restart), "Revert" discards changes not yet applied; "Apply Source" is greyed out while nothing has changed. For a video file, **changing only "At end" or "Playback rate" applies at once without rebuilding** (playback continues) — no need for "Apply Source". Video files also get a "Playback" section below: ▶ Play / ⏸ Pause, ⏮ Back to Start, Restart when taken to PGM (the same as the cell buttons and right-click menu, see [Playback](#playback)) |

"**Copy from another input…**" at the bottom of the sidebar: pick an input and the groups to copy (Crop & position / Keyer / Audio / Audio effects); they replace this input's settings in one step.

Out-of-range values are clamped (gain −96…+24 dB, delay 0–500 ms, opposite crops summing to at most 1).

### Channel mapping

For DeckLink embedded audio and audio-only devices the "Channels" field decides which source channels feed left / right:

- First two (default): left = channel 1, right = channel 2; a mono source feeds both.
- Mono: one channel to both sides (a mono microphone on channel 5 → pick channel 5).
- Pick two: choose left and right separately.

Out-of-range indices are clamped to the source's channel count. Changing the mapping rebuilds the input, like changing the device.

## Known devices

Tested on this project's development machines (model, macOS, result). More devices come from the community; template and how to submit in
[device compatibility](../../testing/设备兼容性.md) (Chinese).

| Category | Device | Result |
|---|---|---|
| Camera | MacBook Pro built-in camera (M5 Max, macOS 26.6 / 27.0) | 1080p negotiated to the program rate, internal latency within limits; denied / granted permission paths pass |
| Camera | iPhone Continuity Camera (`.external`, 1080p60) | Enumeration, picture, disconnect / reconnect pass |
| Camera | Desk View | Enumerated; no latency measurement |
| Audio-only | MacBook Pro microphone, iPhone microphone (Continuity), HP Thunderbolt Dock headset, NDI® virtual audio device (44.1 kHz, converted) | Pass |
| NDI® | NDI SDK for Apple 6.3.2, local loopback + Studio Monitor | Receive / send pass |
| Screen | Built-in display, LG ULTRAGEAR external display | Screen input and external display pass |
| DeckLink | No hardware | **Unverified** (simulated device only) |
| UVC capture card | No hardware | **Unverified** (same AVFoundation path as cameras) |
