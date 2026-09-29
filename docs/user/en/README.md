# PlusMix User Manual

PlusMix (code name Switcher: the modules and command-line tools keep that name) is a multi-camera production switcher that runs natively on Apple Silicon Macs: numbered inputs, Program / Preview monitors,
Cut / Fade / Wipe / Zoom / Stinger transitions, four overlay channels, four audio buses, and outputs to recording, streaming, NDI® (NDI® is a registered trademark of Vizrt NDI AB),
a second display, a virtual camera and a multiview. This manual is for operators. How it works inside is in the
[design spec](../../spec/导播台设计方案.md) (Chinese); how it is verified is in [testing](../../testing/en/README.md).

中文版（以中文为准）：[../README.md](../README.md).

## Contents

| Page | What it covers |
|---|---|
| [Concepts](concepts.md) | PGM / PVW, inputs, transitions, T-bar, FTB, overlay channels, buses, outputs, tally, show files, ticks; the main window |
| [Inputs](inputs.md) | How to connect each of the eight input kinds; input states; known devices |
| [Outputs](outputs.md) | Recording (ISO, disk protection), streaming, NDI output, external display, virtual camera, multiview |
| [Shortcuts](shortcuts.md) | Default keyboard table, editing it, MIDI mapping, Stream Deck / Companion |
| [Troubleshooting](troubleshooting.md) | Permissions, no signal, disk, stream reconnects, missing NDI / DeckLink, virtual camera activation, logs |

See also: [sample shows](../../../Samples/README.md) (church / classroom / event, run out of the box; Chinese),
[local API](../../api/README.md) (scripting, control panels), [control panels and tally](../../integrations/README.md).

## First run

1. Build and open (Xcode required; see the repository [README](../../../README.md)):

```bash
make gen build-app && open .build/DerivedData/Build/Products/Debug/PlusMix.app
```

2. Show › Open… and pick `Samples/event/event.switcher.json`: four synthetic cameras, a multiview and four ISO recordings, all configured.
3. Press `2` to put input 2 on Preview, `Space` to cut, `Return` to run the selected transition (Fade by default), `F` to fade to black.
4. Click **Record** in the bottom bar to record into `~/Movies/PlusMix/活动/`; click again to stop.
5. Input › Add Input… (⌘I) to connect your camera. macOS asks for camera / microphone access the first time; screen recording access
   must be granted manually in System Settings ([Troubleshooting › Permissions](troubleshooting.md#1-permissions)).

## Version and language

This manual matches PlusMix 0.1.0. The interface is available in Simplified Chinese and English and follows the system language
(Preferences › Language overrides it). Menu names below use the English interface; the Chinese names are in the Chinese pages.
