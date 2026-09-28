# Shortcuts, MIDI and control panels

Every control path sends the same commands ([Concepts › How a switch happens](concepts.md#how-a-switch-happens)), so keyboard, MIDI,
Stream Deck, Companion and scripts can be mixed freely and always agree on the state.

## Default shortcut table

Active while the main window has focus (not while typing in a text field).

| Key | Action |
|---|---|
| `1` … `9`, `0` | Put input 1–10 on PVW (`0` = input 10) |
| `Shift` + `1` … `0` | Cut input 1–10 straight to PGM (PVW unchanged) |
| `Space` | Cut |
| `Return` | Run one auto transition with the selected type / duration (Fade 30 ticks by default) |
| `F` | FTB on / off |

Menu shortcuts (standard AppKit): ⌘N new, ⌘O open, ⌘S save, ⇧⌘S save as, ⌘I add input, ⌘, preferences.

## Editing the table

Transition › Shortcuts…: one row per key combination + action + note; "Record key" captures a key; binding the same combination twice is
flagged and cannot be saved; "Reset to defaults" restores the table above.

Bindable actions: any command (preview input / program input / Cut / Fade with ticks / auto transition / other command) and state-aware toggles:
FTB, overlay channel, input mute, record, stream, AFV.

The table is stored outside the show file in `~/Library/Application Support/Switcher/hotkeys.json`:

```json
{
  "version": 1,
  "bindings": [
    {"key": "1", "action": {"command": {"setPreview": {"input": 1}}}, "note": "PVW input 1"},
    {"key": "shift+1", "action": {"command": {"setProgram": {"input": 1}}}, "note": "PGM input 1"},
    {"key": "space", "action": {"command": {"cut": {}}}},
    {"key": "return", "action": {"command": {"autoTransition": {}}}},
    {"key": "f", "action": {"toggleFTB": {}}},
    {"key": "cmd+alt+r", "action": {"toggleRecord": {"output": 1}}},
    {"key": "f5", "action": {"toggleOverlay": {"channel": 1}}}
  ]
}
```

- Combination syntax `ctrl+alt+shift+cmd+<key>` in any order; `⌘⌥⌃⇧` prefixes and the long names `command / option / control` are accepted.
  The key is a single letter / digit / symbol or a named key: `space, return, escape, tab, delete, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1 … f20`.
- Command JSON is the API's ([API reference](../../api.md), Chinese): `{"command": {<command>}}`.
- An unreadable file (bad JSON, conflicts) falls back to the default table with a notice in the status line.

## MIDI

Transition › MIDI Mapping…: CoreMIDI, all online devices are listened to; "Learn" fills the trigger from the next fader move or key press.

| Trigger | Action |
|---|---|
| CC (7-bit, channel 1–16, controller 0–127) | T-bar (commits at either end and reverses, like a real lever), an input's gain, a bus gain (0–127 mapped linearly to a dB range) |
| 14-bit CC (controller 0–31 coarse, +32 fine) | Same, with a smoother fader |
| Note (on, velocity > 0) | The same actions as shortcuts (a command or a toggle) |

Stored in `~/Library/Application Support/Switcher/midi.json`:

```json
{
  "version": 1,
  "mappings": [
    {"trigger": {"cc14": {"channel": 1, "controller": 1}}, "action": {"tbar": {}}, "note": "fader"},
    {"trigger": {"cc": {"channel": 1, "controller": 7}}, "action": {"busGain": {"bus": 0, "minDb": -60, "maxDb": 0}}},
    {"trigger": {"cc": {"channel": 1, "controller": 16}}, "action": {"inputGain": {"input": 1, "minDb": -60, "maxDb": 12}}},
    {"trigger": {"note": {"channel": 1, "note": 60}}, "action": {"action": {"command": {"cut": {}}}}},
    {"trigger": {"note": {"channel": 1, "note": 61}}, "action": {"action": {"toggleFTB": {}}}}
  ]
}
```

Devices unplugged and plugged back are picked up again; devices connected while the App runs are discovered too.

## Stream Deck, Companion, scripts

- **Stream Deck**: official-SDK plugin (button = command, button colour = tally); install and button table in [docs/integrations/stream-deck.md](../../integrations/stream-deck.md) (Chinese).
- **Bitfocus Companion**: via the local API (Generic HTTP / WebSocket modules) in [API examples](../../api/examples.md#3-companion); via the third-party
  compatibility layer with an existing panel configuration in [docs/integrations/companion.md](../../integrations/companion.md).
- **External tally lights**: a read-only WebSocket / HTTP tally stream, [docs/integrations/tally.md](../../integrations/tally.md).
- **Scripts / automation**: the local HTTP + WebSocket API, [docs/api/README.md](../../api/README.md). It listens on `127.0.0.1:8765` by default;
  Preferences › Local API changes the address, port and token.
