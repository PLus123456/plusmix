# Concepts

One vocabulary is used everywhere: interface, show files, API and this manual ([design spec §1.1](../../spec/导播台设计方案.md#11-统一用词)).

| Term | Meaning |
|---|---|
| **Input** | A numbered signal source: camera / capture device, DeckLink, screen, video file, image, NDI, audio-only device, synthetic test source. Numbers start at 1; 0 means "black" |
| **Program / PGM** | What the audience sees (the large monitor with the red border) |
| **Preview / PVW** | What goes on air next (the other large monitor, green border) |
| **Transition** | How PVW becomes PGM: Cut, Fade, Wipe, Zoom, Stinger |
| **T-bar** | Manual transition lever; pushing it to the end commits and it snaps back |
| **FTB** | Fade to black; while on, PGM outputs black and audio fades to silence |
| **Overlay 1–4** | Four independently switchable layers on top of PGM: lower thirds, picture-in-picture, logos |
| **Bus** | The four audio buses: Master, Bus A, Bus B, Headphones |
| **Output** | Recording, streaming, NDI output, external display, virtual camera, multiview |
| **Tally** | Per input: on PGM / on PVW / neither. Thumbnail borders, multiview borders, Stream Deck colours and external tally lights all read it |
| **Show** | A JSON file (`*.switcher.json`) holding inputs, switching, audio, outputs and window layout |
| **Tick** | One beat of the program clock = one frame; 30 ticks at 1080p60 is 0.5 s |

## The main window

```
┌──────────────────────┬─────────────────────┬──────────────────────┐ ┌──────────┐
│  PVW (green)         │ Transition: Cut     │  PGM (red)           │ │ Mixer     │
│                      │ Fade Wipe Zoom      │                      │ │ per-input │
│                      │ Stinger  Duration   │                      │ │ faders,   │
│                      │ Params…  FTB        │                      │ │ buses,    │
│                      │ T-bar ▮▮▮▮▮▮▮▮▮▮▮▮  │                      │ │ AFV,      │
├──────────────────────┴─────────────────────┴──────────────────────┤ │ meters    │
│  1 Cam 1   2 Cam 2   3 Screen   4 Titles   …  (input strip)       │ │           │
├───────────────────────────────────────────────────────────────────┤ │           │
│  Add Input…  Record  ISO…  Stream  External  Multiview  Overlay… status│ │           │
└───────────────────────────────────────────────────────────────────┘ └──────────┘
```

- Click a thumbnail to put it on PVW; Shift-click cuts it straight to PGM. Right-click › Settings… opens that input's settings.
- The status line updates once a second: fps, render time, GPU / CPU, missed frames, encoder skips, bitrate, free disk. These numbers are
  **the same data** the API and `stats.jsonl` report ([test standard §7](../../testing/测试标准.md#71-统计字段-statsjsonl)); the UI does not compute its own.
- The mixer sits on the right (Window › Audio Mixer hides it); the multiview is its own window (Window › Multiview Window) and can go on a second screen.

## How a switch happens

Every control — button, shortcut, MIDI, API, script — only **sends a command** to the state machine. The state machine applies it,
publishes a new immutable snapshot, and the render thread reads the latest snapshot once per tick. Consequences:

- Switches always land on a tick boundary; a Cut has no intermediate frame (a hard requirement of the [test standard](../../testing/en/README.md), V6).
- The UI and the API always see one state; two operators cannot overwrite each other, commands queue in arrival order.
- A command the state machine ignores by rule (Fade while a transition is running, FTB already at the target) is not an error; the receipt says `applied = false`.

The full command list is the [API reference](../../api.md) (Chinese); the shortcut table binds the same commands.

## Transitions

| Type | Effect | Parameters |
|---|---|---|
| Cut | Atomic swap of PGM and PVW | none |
| Fade | Cross-fade | duration (ticks) |
| Wipe | New picture wipes in | direction (left→right, right→left, top→bottom, bottom→top, diagonal), soft edge width (0–1) |
| Zoom | New picture grows from the centre | duration |
| Stinger | An image / file with alpha on top; the picture underneath swaps at tick n | stinger input number, cut tick |

The Fade / Wipe / Zoom / Stinger buttons select the type and immediately run an auto transition (duration = the preset on the panel).
"Params…" edits Wipe / Stinger parameters for the next transition. The T-bar uses the selected type: 25 % is a 25 % mix or wipe position;
pushing to the top commits and returns to 0; releasing midway holds. Cut during a running transition completes it immediately.

FTB has its own duration (defaults to the transition duration, both 30 ticks); tally does not change while black. In 0.1.0 the FTB duration cannot be changed from the UI, only in the show file; a right-click menu on FTB comes with proposal 020.

## Overlay channels

Each channel has one input, a rectangle in 0–1 program coordinates, an in / out animation (cut / fade / slide / zoom with duration),
an optional border (for picture-in-picture) and an anchor (zoom animates around it). The Overlay… panel edits them; presets include
"lower third" and "PiP bottom right".

- Transparent parts of an image / video show PGM through. A full 1920×1080 PNG with alpha plus the "whole picture" rectangle is the
  simplest way to do titles (the [sample shows](../../../Samples/README.md) do exactly that).
- While a channel is visible (including its out animation) its input counts as on PGM: red tally.
- PVW does not draw overlays by default; tick "Preview on PVW" per channel, or turn all on in Preferences › PVW preview.
- Channels stack 1 to 4; 4 is on top.

## Audio

- Per input: gain (−96…+24 dB), mute, solo, pan, delay compensation (0–500 ms, for a capture device's own A/V offset), bus routing, audio-follows-video.
- Four buses with gain / mute. The effect chain (parametric EQ, dynamics, peak limiter) can be edited in 0.1.0 but **does not yet affect the audio** (the engine does not read it; see [known issues](../../KNOWN_ISSUES.md); wiring is prompt 88). Master feeds recording / streaming / NDI®;
  Bus A / B are secondary mixes (foldback etc.) — in 0.1.0 they have no route to a device channel yet and are only visible as meters in the API / stats.jsonl; Headphones is the monitor bus and is only audible on output devices with ≥ 4 channels (on the built-in output or a plain USB headset, solo / PFL / AFL are silent).
- **AFV (audio follows video)**: with the global switch on, inputs marked "follows video" are only audible on PGM and cross-fade with
  the transition (same start tick, same length). For a presenter microphone or a mixer feed that must always be heard, turn that input's
  "follows video" off.
- Headphone monitoring: AFL (after fader) / PFL (pre fader); the monitor point can sit before the alignment delay (low latency) or after it (aligned with picture).
- Meters: peak / RMS / true peak / loudness (EBU R128 momentary / short-term / integrated / LRA).

## Show files

Show › New / Open / Save / Save As / Open Recent. The file is readable JSON with the same fields as the API's `state`
([CONTRACTS.md §2.8](../../CONTRACTS.md), Chinese) and can be generated by scripts ([example](../../../Samples/tools/make-shows.py)).

- An input's **runtime state** (signal or not) and an output's **runtime numbers** (frames, bitrate) are not in the file; only configuration is.
- Recording / streaming outputs are always stopped when a file is opened; only a button, shortcut or API call starts them.
- On quit, an unsaved show is autosaved to `~/Library/Application Support/PlusMix/LastSession.switcher.json` and restored on the next launch.
- Actual 0.1.0 behaviour: on quit, if the current show was opened from a file, the current state is **written back to that file** without asking; before New / Open nothing is saved or autosaved and unsaved changes are lost. The next version asks "Save / Don't Save / Cancel" in all three places (prompt 87).
- The shortcut table and MIDI map are **not** in the show file; they live next to it as `hotkeys.json` / `midi.json` ([Shortcuts](shortcuts.md)).
