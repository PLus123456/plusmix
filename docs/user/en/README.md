# PlusMix User Manual

PlusMix (code name Switcher: the modules and command-line tools keep that name) is a multi-camera production switcher that runs natively on Apple Silicon Macs: numbered inputs, Program / Preview monitors,
Cut / Fade / Wipe / Zoom / Stinger transitions, four overlay channels, four audio buses, and outputs to recording, streaming, NDI® (NDI® is a registered trademark of Vizrt NDI AB),
a second display, a virtual camera and a multiview. This manual is for operators. How it works inside is in the
[design spec](../../spec/导播台设计方案.md) (Chinese); how it is verified is in [testing](../../testing/en/README.md).

The interface is described as it looks after the 0.1.x redesign (toolbar, three-part bottom bar, a single Settings window…); for the old 0.1.0 interface see [docs/ui-study/03](../../ui-study/03-目视检查.md) (Chinese).

中文版（以中文为准）：[../README.md](../README.md).

## Contents

| Page | What it covers |
|---|---|
| [Concepts](concepts.md) | PGM / PVW, inputs, transitions, T-bar, FTB, overlay channels, buses, outputs, tally, show files, ticks; the main window (toolbar, monitors, transition column, mixer, input strip, bottom bar, status line), the menu bar, reminders / statistics / interface lock |
| [Inputs](inputs.md) | The Add Input panel; how to connect each of the eight input kinds; the input strip and cells; per-input settings; known devices |
| [Outputs](outputs.md) | Overview, recording (ISO, disk protection), streaming (service presets, quality, authentication), NDI® output, external display, virtual camera, multiview |
| [Shortcuts](shortcuts.md) | Default keyboard table, editing it and the action picker, hotkeys.json, MIDI mapping, Stream Deck / Companion / tally |
| [Settings](settings.md) | The single Settings window: This Show / This Mac pages, when changes apply, export / import / restore defaults, remote control, tally, performance & power, advanced; launch arguments |
| [Troubleshooting](troubleshooting.md) | Permissions, no signal, disk, streaming (connecting / reconnecting / couldn't start / authentication), NDI® / DeckLink / virtual camera, picture and sound, interface, API, logs and diagnostics |

See also: [sample shows](../../../Samples/README.md) (church / classroom / event, run out of the box; Chinese),
[local API](../../api/README.md) (scripting, control panels), [control panels and tally](../../integrations/README.md).

Help › PlusMix User Guide in the app opens this manual (web pages installed with the app, in Chinese or English to match the interface language).

## First run

1. Build and open (Xcode required; see the repository [README](../../../README.md)):

```bash
make gen build-app && open .build/DerivedData/Build/Products/Debug/PlusMix.app
```

2. Show › Open… (or Open in the toolbar) and pick `Samples/event/event.switcher.json`: four synthetic cameras, a multiview and four ISO recordings, all configured.
3. Press `2` to put input 2 on Preview, `Space` to cut, `Return` to run the selected transition (Fade by default), `F` to fade to black; or click Transition or Cut on a cell.
4. Click **Record** in the bottom bar to record into `~/Movies/PlusMix/活动/`; click again to stop (it asks first).
5. Input › Add Input… (⌘I) to connect your camera. macOS asks for camera / microphone access the first time; screen recording access
   must be granted manually in System Settings ([Troubleshooting › Permissions](troubleshooting.md#1-permissions)).

## Version and language

This manual matches PlusMix 0.1.x (see the status in the repository [README](../../../README.md)). The interface is available in Simplified Chinese and English and follows the system language
(Settings › General › Language overrides it after reopening the app). Menu names below use the English interface; the Chinese names are in the Chinese pages.
