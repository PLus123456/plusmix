# Shortcuts, MIDI and control panels

Every control path sends the same commands ([Concepts › How a switch happens](concepts.md#how-a-switch-happens)), so keyboard, MIDI,
Stream Deck, Companion and scripts can be mixed freely and always agree on the state.

## Default shortcut table

Active while the main window is in front (not while typing in a text field); also while the Settings, Input Settings, Overlay Settings, Audio Settings, Statistics, Stream / Recording Status or multiview windows are in front (while Settings › Shortcuts is recording a key, the key goes into that row and switches nothing).

| Key | Action |
|---|---|
| `1` … `9`, `0` | Put input 1–10 on PVW (`0` = input 10) |
| `⇧1` … `⇧0` | Cut input 1–10 straight to PGM (PVW unchanged) |
| `Space` | Cut |
| `Return` | Run the current transition slot (the T-bar uses it too; Transition 1 · Fade 0.5 s in a new show) |
| `F` | FTB on / off |
| `⌥1` … `⌥4` | Run Transition 1–4 (selects that slot and starts it at once; Return and the T-bar use it afterwards; [Concepts › Transition slots](concepts.md#transition-slots)). A slot that is a Stinger with no input yet doesn't run; the status line says so |
| `⌃1` … `⌃4` | Overlay 1–4 on / off (a channel without an input uses the input on PVW; if PVW is black too it doesn't turn on and the status line says so — the same as the Overlay buttons in the transition column) |

- **⇧ with a digit / symbol key goes by the key position**: whatever ⇧1 types under your layout or input source (`!`, or a full-width `！` with Pinyin), it counts as `shift+1` (the same for ⇧ with `- = [ ] \ ; ' , . /` and `` ` ``), so these rows work from a US keyboard and with Pinyin alike.
  Rows you re-recorded earlier with "Record" to make ⇧1–⇧0 work (stored as `shift+!` and the like) are read as `shift+1`, keep working and are written the new way the next time you save; if one collides with the table's own `shift+1` row, your recorded row wins and the other one is disabled (it stays in the table); if two old-style rows land on the same key (e.g. `shift+!` and a hand-written `shift+！`), it doesn't pick for you and treats it as a conflict: the table isn't loaded, the default table is used and the status line says so.
- **With the Pinyin input source the punctuation keys `, . ; [ ] \` and `` ` `` (without ⇧, also with ⌃ / ⌥ / ⌘) can't be pressed**: the Pinyin layout types them as `， 。 ； 【 】 、 ·`, which don't match the key names in the table. Letters, digits, named keys, `' / - =` and punctuation with ⇧ are fine; the default table has no such keys. To use these keys, switch to a US input source while you press them, or pick another key.
- **Recording and streaming have no default keys**: stopping them from a hotkey never asks, so one stray key would stop the show. Add them yourself if you want ([Editing the table](#editing-the-table)), e.g. with "All recordings on / off".
- **The interface lock has no default shortcut**: use the lock at the far right of the bottom bar, or Window › Lock Interface.
- On a Mac that saved a shortcut table before (`hotkeys.json`), ⌥1–⌥4 are still "Run Current Transition" from the old table (that is how the old default table was saved; it isn't upgraded automatically): click "Reset to Defaults" in Settings › Shortcuts for the new table (re-add your own rows afterwards).
- `⌃1`–`⌃4` are also the system's "Switch to Desktop 1–4": if those are turned on in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, the system takes these keys first. `⌥1`–`⌥4` are not used by the system.
- Help › Keyboard Shortcuts generates a page from the **current** table (key / action / note) and opens it in your browser — handy to print for the desk; after editing the table, click it again for the new version.

Menu shortcuts (standard AppKit): ⌘N new, ⌘O open, ⌘S save, ⇧⌘S save as, ⌘I add input, ⇧⌘I input settings (the input on PVW), ⌘F find input, ⌘, settings, ⌘M minimize, ⌘Q quit (asks first while recording / streaming or with unsaved changes).
The grey keys on the right of the Transition menu come from the shortcut table and are display only — keys are handled by the shortcut table, and the menu follows when you change it.

## Editing the table

Settings › Shortcuts (PlusMix › Shortcuts…): one row per binding — Enabled (checkbox), key combination (type it, or click "Record" and press it), action (a one-line summary; click it for the action picker), note, and "Edit JSON… / Duplicate / Remove" at the end of the row.

- A search field at the top (finds keys, actions and notes); "Add", "Reset to Defaults" and "Save" at the bottom. "Duplicate" inserts a copy of the row below with the key left empty for you to record.
- Binding the same combination twice among enabled rows shows "n conflicts" next to Save and the table can't be saved; disabled rows are not dispatched and don't count as conflicts.
- A new row has no action and must get one before saving ("Row n has no action yet") — it never silently becomes some other command.
- **Click "Save" when done**; with unsaved changes, closing the window or switching pages asks "Save / Cancel / Discard Changes". The page shows where the table file is.
- "Edit JSON…": write one command directly (the top-level key is the command name, the same form as the HTTP API's `command`); it is checked when applied, and a recognised command turns back into the matching action.

### The action picker

Opens from a row's action button:

- A search field at the top (you can type straight away; it searches action names, descriptions and API key names across groups); groups on the left: Switching / Overlays / Audio / Outputs / Inputs / Show / Interface / All / Recent.
- One line per action on the right: our name, a one-line description and the API key name in small print (compound actions list what they send, e.g. "previewAndTransition → setPreview + autoTransition").
- Below it a form built from the action's parameters: an input is a menu ("Input 3 “name”") plus "Current PVW / Current PGM" (whatever is on PVW / PGM at the moment of the press), and the overlay commands (Overlay on / off) have one more item, "(Clear)" (= 0, clears that channel's input; the summary says "Clear"); durations are in seconds (0.5 / 1 / 2 + custom; a custom value above the limit is stored as the limit — for durations stored in frames, 864 000 frames at the current program frame rate (4 hours at 60 fps), for a Fade stored in milliseconds 1 hour, for a file seek one week; negative numbers or non-numbers are stored as 0); overlay channels 1–4; a transition slot is a menu listing the four slots' current effect and duration ("Transition 3 · Zoom 1 s"); outputs only list the kinds that fit; one of the four buses; switches have three segments: on / off / toggle;
  optional switches (solo and "Audio follows video" in "Input solo / AFV / routing") have three segments "Keep / On / Off", "Keep" by default; for bus routing, tick "Change bus routing" first, then the buses it feeds (Master / Bus A / Bus B / Headphones) — unticked = routing unchanged.
- At the bottom "What a press sends now:" — the commands computed from the current show, exactly what goes onto the command bus when the key is pressed.
- By default only operator actions are listed. Whole-replacement commands (show / input settings / output settings) and adding / removing inputs and outputs need "Show whole-replacement commands (advanced)" or "Advanced: Write JSON…" (checked before saving).

Actions worth knowing:

| Action | Notes |
|---|---|
| Run transition / Select transition (don't run) | In the Switching group. Run transition n = select that slot and start it at once (one command; Return and the T-bar use it afterwards, like ⌥n); Select transition n = only make it the current slot, nothing runs (like "Use for T-bar" in the slot's ▾). The summary reads e.g. "Run transition · Transition 3 (Zoom 1 s)". Ignored by the state machine during a transition |
| Input solo / AFV / routing | In the Audio group (`setInputAudio`): changes only the items you set (solo, audio follows video, bus routing); anything left at "Keep" and all other settings stay as they are |
| Preview and transition | Puts the input on PVW, then takes it to PGM with the current transition slot (two commands in order; if the first is refused — say the input has been removed — the second isn't sent; pressed during a transition, both are ignored by the state machine and nothing changes) |
| Fade | In seconds (stored as milliseconds), so the length stays the same when the show's frame rate changes. Old tables with Fade in ticks still load and work; the picker shows them as "Fade (in ticks, old)" |
| All recordings on / off, ISO recordings only, All streams start / stop | PGM and ISO start and stop on the same tick; pressing them **never asks** |
| Output on / off, All outputs of a kind on / off | One NDI® / external display / virtual camera / multiview output, or every output of one kind |
| Input follows video, Bus routing, Solo, Bus mute on / off | Sent only when something actually changes |
| Put input on overlay and show it, All overlays off | |
| Show / hide the audio mixer, Multiview window on / off, Multiview window full screen | Interface actions: done only in the local app, not on the command bus (the API doesn't see them) |

### hotkeys.json

The table is stored outside the show file in `~/Library/Application Support/PlusMix/hotkeys.json` (it doesn't change with the show):

```json
{
  "version": 1,
  "bindings": [
    {"key": "1", "action": {"command": {"setPreview": {"input": 1}}}, "note": "PVW input 1"},
    {"key": "shift+1", "action": {"command": {"setProgram": {"input": 1}}}, "note": "PGM input 1"},
    {"key": "space", "action": {"command": {"cut": {}}}, "note": "Cut"},
    {"key": "return", "action": {"command": {"autoTransition": {}}}},
    {"key": "f", "action": {"toggleFTB": {}}},
    {"key": "alt+2", "action": {"transitionSlot": {"slot": 2}}, "note": "run transition 2"},
    {"key": "ctrl+alt+4", "action": {"selectTransitionSlot": {"slot": 4}}, "note": "select transition 4, don't run"},
    {"key": "ctrl+1", "action": {"toggleOverlay": {"channel": 1}}, "note": "overlay 1 on / off"},
    {"key": "g", "action": {"fadeMs": {"durationMs": 750}}, "note": "0.75 s fade"},
    {"key": "ctrl+alt+3", "action": {"previewAndTransition": {"input": 3}}},
    {"key": "m", "action": {"ui": {"name": "toggleMixer"}}, "note": "show / hide the mixer"},
    {"key": "cmd+alt+r", "action": {"recordAll": {"mode": "toggle"}}, "note": "all recordings (never asks)", "enabled": false}
  ]
}
```

- Combination syntax `ctrl+alt+shift+cmd+<key>` in any order; `⌘⌥⌃⇧` prefixes and the long names `command / option / control` are accepted.
  The key is a single letter / digit / symbol or a named key: `space, return, escape, tab, delete, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1 … f20`.
  With ⇧, always write **the key without ⇧**: `shift+1`, `shift+=`, `shift+/` (⇧ with a letter is written with the letter as usual). The old spellings `shift+!`, `shift+?` and full-width `shift+！` are still accepted and read as `shift+1` and so on (for collisions see the [default shortcut table](#default-shortcut-table) above).
- Actions: `{"command": {<command>}}` (command JSON is the API's, [API reference](../../api.md), Chinese), or the switch / compound actions below. A switch's `mode` is `"on"` / `"off"` / `"toggle"` (missing = toggle);
  an input can be a number or `"preview"` / `"program"` (whatever is on PVW / PGM at the moment of the press).
- `"enabled": false` is written only on disabled rows; no key = enabled. Old files load unchanged.
- An unreadable file (bad JSON, conflicts) falls back to the default table with a notice in the status line.

| Action | JSON |
|---|---|
| FTB / AFV on / off | `{"toggleFTB": {}}`, `{"toggleAFV": {}}` |
| Run transition n / select transition n (don't run) | `{"transitionSlot": {"slot": 2}}`, `{"selectTransitionSlot": {"slot": 4}}` (`slot` 1–4; any other number sends nothing) |
| Overlay on / off / put an input on it / all off | `{"toggleOverlay": {"channel": 1}}`, `{"overlayInput": {"channel": 2, "input": "preview"}}`, `{"overlaysOff": {}}` |
| Mute on / off | `{"toggleMute": {"input": 2}}` |
| Start / stop one recording / stream | `{"toggleRecord": {"output": 1}}`, `{"toggleStream": {"output": 2}}` |
| All recordings / ISO only / all streams | `{"recordAll": {"mode": "toggle"}}`, `{"recordISO": {"mode": "on"}}`, `{"streamAll": {"mode": "off"}}` |
| One output / all of a kind | `{"outputSwitch": {"output": 7, "mode": "toggle"}}`, `{"outputKindSwitch": {"kind": "externalDisplay", "mode": "off"}}` (`kind` ∈ ndi / externalDisplay / virtualCamera / multiview) |
| Fade (ms) / preview and transition | `{"fadeMs": {"durationMs": 500}}`, `{"previewAndTransition": {"input": 3}}` |
| Follow video / bus routing / solo / bus mute | `{"inputAFV": {"input": 4, "mode": "off"}}`, `{"busRoute": {"input": 4, "bus": 1, "mode": "toggle"}}`, `{"solo": {"input": 2}}`, `{"busMuteSwitch": {"bus": 0}}` (`bus`: 0 Master / 1 Bus A / 2 Bus B / 3 Headphones) |
| Interface actions | `{"ui": {"name": "toggleMixer"}}` (also `toggleMultiviewWindow`, `fullscreenMultiview`) |

## MIDI

Settings › MIDI (PlusMix › MIDI Mapping…): CoreMIDI; all online devices are listened to and the page lists the current MIDI sources. One row per mapping: Enabled, trigger (Note / CC / 14-bit CC, channel, number), "Learn" (fills the trigger from the next fader move or key press), action (the same action picker), note.
It also has search, Add, Duplicate, Remove and Edit JSON…; click "Save" when done.

| Trigger | Actions it takes |
|---|---|
| CC (7-bit, channel 1–16, controller 0–127) | Faders only: T-bar (commits at either end and reverses, like a real lever), input gain fader, bus gain fader (0–127 mapped linearly to a dB range) |
| 14-bit CC (controller 0–31 coarse, +32 fine) | Same, with a smoother fader |
| Note (on, velocity > 0) | Button actions: the same as shortcuts (commands, switches, compound and interface actions) |

Saving checks that every action fits its trigger (Notes take button actions, CCs take faders); otherwise it says "Mapping n's action doesn't fit its trigger" and doesn't save. The map is stored in `~/Library/Application Support/PlusMix/midi.json`:

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

Inside a Note's `"action": {"action": …}` goes an action written exactly as in hotkeys.json above. **The default map is empty** (no factory mappings; restoring defaults empties it); an unreadable midi.json (JSON error, conflict) falls back to the empty map and the status line says "MIDI mapping table … is unreadable; using an empty table: …".
Devices unplugged and plugged back are picked up again; devices connected while the app runs are discovered too.

- A Note that runs a Stinger slot with no input yet ("Run transition 4", or "Run current transition" while that is the current slot) doesn't run it, just like a shortcut, and the status line says "Transition 4 is a Stinger with no input yet — pick one from ▾ in the transition column"; turning on an overlay channel with no input while PVW is black gets the same notice as ⌃1–⌃4.
- A CC fader still pushes such a slot: the picture changes once it passes the cut tick and the swap happens at the top — in effect a hard cut. The on-screen T-bar is greyed out in that case ([Concepts › The transition column](concepts.md#the-transition-column)); the MIDI fader doesn't go through it.

## Stream Deck, Companion, tally, scripts

- **Stream Deck**: official-SDK plugin (button = command, button colour = tally; the "Transition 1–4" button runs or just selects a slot and is coloured after the current slot); install and button table in [docs/integrations/stream-deck.md](../../integrations/stream-deck.md) (Chinese).
- **Bitfocus Companion**: via the local API (Generic HTTP / WebSocket modules) in [API examples](../../api/examples.md#3-companion); via the third-party
  compatibility layer with an existing panel configuration in [docs/integrations/companion.md](../../integrations/companion.md).
  When Companion runs on another machine, set the compatibility layer to "Allow local network" in Settings › Remote Control, apply and restart the engine, and enter the address shown on that page in Companion.
- **External tally lights**: a read-only WebSocket / HTTP tally stream, turned on in Settings › Tally (off by default, port 8766 by default), which shows addresses ready to copy; protocol in [docs/integrations/tally.md](../../integrations/tally.md).
  The local API's `GET /api/v1/tally` works too.
- **Scripts / automation**: the local HTTP + WebSocket API, [docs/api/README.md](../../api/README.md). It listens on `127.0.0.1:8765` by default;
  Settings › Remote Control switches between "This Mac only / Allow local network" and sets the port and token.
