# Inputs

Input › Add Input… (⌘I): choose a kind on the left, fill in the parameters, the number defaults to the next free one. Any input can later
be pointed at a different device in Input Settings › Source; number, name, settings and PGM / PVW / overlay references are kept.
Eight kinds; two of them (DeckLink, NDI) need optional third-party SDKs at build time — without the SDK the input can be added but
never produces a picture (the cell says so).

## Input states

Each input cell shows one of three states. The dividing line is "will it recover by itself" ([design spec §6](../../spec/导播台设计方案.md)):

| State | Meaning | Examples |
|---|---|---|
| **live** | Producing frames (or audio, for audio-only inputs) | — |
| **noSignal (waiting)** | Nothing right now, **will recover by itself**; the cell says what it is waiting for | Device unplugged, DeckLink driver missing, NDI source not yet online, external display unplugged, file still opening |
| **error** | **Will not recover by itself**; you need to act | Permission denied (System Settings), SDK not compiled in (rebuild), image not found (fix the path), stream failed to start (change configuration) |

In noSignal the frame slot keeps the last frame (PGM does not flash black). Plugging the device back, installing the driver or the source
coming online restores the input automatically — no need to delete and re-add; number and settings are unchanged. Permission denied is
an error, but granting it also recovers automatically (polled once a second), no restart needed.

## Camera / capture device

AVFoundation: built-in camera, USB / UVC cameras and capture cards, and iPhone Continuity Camera all appear in the same list.

- The list is what the system sees; the first use prompts for camera access.
- Format negotiation: frame rate matching the program first, then resolution (equal > smallest that is at least the program size > largest),
  then native NV12; the frame rate is locked. A 30 fps camera in a 60 fps program repeats every frame by design; that is not a drop.
- The device's own microphone (same USB device) is captured too and **needs microphone access**; without it you get picture only.
- Hot-plug: unplug → noSignal; the same device plugged back → rebuilt automatically, back to live within 3 s.
- A camera's fixed pipeline latency (about 55 ms for the built-in camera) is not jitter; the engine picks frames by arrival time, so no manual
  compensation is needed. If audio and video disagree, use Input Settings › Audio › Delay compensation (0–500 ms).

## DeckLink (SDI / HDMI)

Requires the Blackmagic Desktop Video driver (`/Library/Frameworks/DeckLinkAPI.framework`); building PlusMix needs the DeckLink SDK
(`DECKLINK_SDK_DIR` or `~/SDKs/DeckLink`), otherwise this kind is an empty implementation (error with a message).

- The panel lists cards and input connections (SDI / HDMI / optical SDI / component / composite / S-Video); "keep" uses what Desktop Video
  Setup selected. Device ID `peid:<persistent id>` (`model:<model>#<index>` for old cards); empty = first card with an input.
- Automatic format detection where the card supports it: a signal changing from 1080p59.94 to 720p60 reopens automatically. No-signal
  frames are not shown (the cell keeps the last frame and says "no signal"); the input recovers when the signal returns.
- Embedded audio: the card provides 2–16 channels; the "channels" field picks which two ([channel mapping](#channel-mapping)); the SDK only
  accepts 2 / 8 / 16, so asking for channel 6 opens 8.
- Driver missing: the cell says to install Blackmagic Desktop Video and that no restart is needed (noSignal; recovers when installed).
- Status: capture from real hardware **has not been verified on this project's machines** (no DeckLink hardware on the development Mac);
  the bridge was tested against the SDK's simulated device. If you have a card, please report through the [device compatibility table](../../testing/设备兼容性.md).

## Screen / window / application

ScreenCaptureKit: a whole display, a single window, or all windows of one application.

- **Screen recording has no system prompt.** Add PlusMix yourself in System Settings › Privacy & Security › Screen & System Audio Recording
  ([Troubleshooting](troubleshooting.md#1-permissions)).
- Frame rate defaults to the program's and can be lowered (30 fps is plenty for documents and saves GPU). "Capture system audio" brings
  that display's / application's sound in (PlusMix's own audio excluded).
- Frames enter the compositor as BGRA (text is not chroma-subsampled); sources larger than the program are scaled to fit. A static
  picture is re-pushed as the last frame and does not fall to noSignal.

## Video file

Anything AVFoundation decodes (H.264 / HEVC / ProRes in .mov / .mp4 …).

- Frames follow the **program clock** (clock slave); playback rate is adjustable; at the end: hold last frame / loop / black.
- The audio track goes through this input's fader / buses / AFV like any other input.
- The path is stored in the show file; relative paths are relative to the show file's directory (current App behaviour: see
  [Samples › relative paths](../../../Samples/README.md#2-相对路径)).

## Image

PNG (with alpha) / JPEG / HEIC … Large images are pre-scaled to the program size.

- A PNG with alpha on an overlay channel is a title or a logo; a full 1920×1080 image with transparent areas is the simplest form
  (the [samples](../../../Samples/README.md#5-重新生成) ship three).
- It can also be the Stinger layer: point the stinger input at it in the transition parameters.
- Images have no audio.

## NDI receive

Requires the NDI SDK for Apple (default `/Library/NDI SDK for Apple`) at build time; at run time without the SDK the input is an error
("cannot search for NDI sources").

- The panel lists sources on the network (names look like `MACHINE (source)`); you can also type one. A missing source is noSignal
  ("no NDI source found on the network … sender not running, different subnet, or wrong name") and connects when it appears.
- Bandwidth: highest / lowest / audio only; sources used only for thumbnails can use "lowest" to save more than half the bandwidth and decoding.
- Jitter buffer 0–2 frames directly sets this input's latency (each frame adds about one frame); default 1.
- Loopback on one machine (PlusMix sending and receiving) measured 1–2 frames behind PGM.

## Audio-only device

Core Audio input devices: built-in microphone, USB interfaces, aggregate devices, iPhone microphone (Continuity). This input **has no picture**.

- Pick a device ("follow system default input" rebuilds automatically when the default changes) and, on multi-channel interfaces, which channels.
  The first use prompts for microphone access.
- The cell shows a microphone glyph, the name and a level meter; it can be put on PGM / PVW / overlays (picture is black, audio follows AFV as usual);
  the multiview cell shows name + meter too.
- The device is set to 48 kHz; if it cannot, audio is converted (the panel says "no 48 kHz, will convert"). Unplug → noSignal "disconnected,
  waiting"; plugged back → live within 3 s.

## Synthetic test source

Built into the engine: every frame carries a frame number, timestamp, input ID and a once-per-second flash block, optionally with synthetic
audio (1 kHz at −20 dBFS plus a click at the flash). Parameters: frame rate (30 / 59.94 / 60), background (flat gray / gradient / gray with
noise), artificial jitter, artificial drops, clock drift, audio drift. Use it to build a show without devices (the [samples](../../../Samples/README.md)
use it exclusively), to verify A/V alignment, or to give encoders a realistic load (noise background). Full definition in
[test standard §2.1](../../testing/测试标准.md#21-合成视频源) (Chinese).

## Per-input settings

Right-click a thumbnail › Settings…, or Input › Input Settings…:

| Section | Contents |
|---|---|
| General | name, number |
| Source | change device / file / source name; "Apply source" rebuilds the input |
| Crop / transform | four-edge crop (fractions), scale, offset, rotation, flip |
| Audio | bus routing, gain, mute, solo, pan, delay compensation 0–500 ms (the "follows video (AFV)" switch is not here but on the input's mixer strip) |
| Effects | per-input audio effect slots (order = processing order); editable in 0.1.0 but not applied to the audio yet (prompt 102) |
| Keyer | key colour, tolerance, softness, spill suppression; applies wherever the input appears (PGM, transitions, overlays, PVW, multiview) |

Out-of-range values are clamped (gain −96…+24 dB, delay 0–500 ms, opposite crops summing to at most 1).

### Channel mapping

For DeckLink embedded audio and audio-only devices the "channels" field decides which source channels feed left / right:

- First two (default): left = channel 1, right = channel 2; a mono source feeds both.
- Mono: one channel to both sides (a mono microphone on channel 5 → pick channel 5).
- Pair: choose left and right separately.

Out-of-range indices are clamped to the source's channel count. Changing the mapping rebuilds the input, like changing the device.

## Known devices

Tested on this project's development machines (model, macOS, result). More devices come from the community; template and how to submit in
[device compatibility](../../testing/设备兼容性.md) (Chinese).

| Category | Device | Result |
|---|---|---|
| Camera | MacBook Pro built-in camera (M5 Max, macOS 26.6 / 27.0) | 1080p negotiated to the program rate, internal latency within limits; denied / granted permission paths pass |
| Camera | iPhone Continuity Camera (`.external`, 1080p60) | Enumeration, picture, disconnect / reconnect pass |
| Camera | Desk View | Enumerated; no latency measurement |
| Audio-only | MacBook Pro microphone, iPhone microphone (Continuity), HP Thunderbolt Dock headset, NDI virtual audio device (44.1 kHz, converted) | Pass |
| NDI | NDI SDK for Apple 6.3.2, local loopback + Studio Monitor | Receive / send pass |
| Screen | Built-in display, LG ULTRAGEAR external display | Screen input and external output pass |
| DeckLink | No hardware | **Unverified** (simulated device only) |
| UVC capture card | No hardware | **Unverified** (same AVFoundation path as cameras) |
