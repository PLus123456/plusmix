# Settings

All settings live in one "Settings" window. Every way in opens that same window:

- ⌘,, PlusMix › Settings…, and the main Settings button in the toolbar: back to the page you looked at last ("General" the first time).
- Settings▾ in the toolbar and PlusMix › All Settings Pages ▸: straight to a page; PlusMix › Shortcuts… / MIDI Mapping… go straight to those two.
- The settings pages listed in the Output menu and the ⚙ of Stream / Multiview in the bottom bar: straight to that output page; the ⚙ of Record / External Display first opens a small menu (Recording Settings… / ISO Recording…; External Display Settings… / NDI® Output Settings…).

## Two groups of pages

The sidebar has two groups; each page's header says where it is stored:

| Group | Stored where | Pages |
|---|---|---|
| **This Show** | Saved in the show file: travels with the show when you save as or switch shows | Show Format, Overview, Recording, ISO, Streaming, External Display, NDI® Output, Virtual Camera, Multiview Layout, Show Audio |
| **This Mac** | Stored on this Mac, shared by every show | General, Audio Devices, Remote Control, Tally, Shortcuts, MIDI, Performance & Power, Updates & Diagnostics, Advanced |

## When changes take effect

- **Most changes apply immediately**: changes on the output pages go to the engine right away (a stream destination that is live locks its URL and encoding, see [Outputs › Streaming](outputs.md#2-streaming)); changes on the This Mac pages are stored right away.
- **Settings that only take effect with a new engine** (show format, show audio, audio device, local API, compatibility layer, preview all overlays in PVW) are tagged "Restarts engine". A change is kept as **pending**; the bottom of the window says "n pending: …".
  "Apply and Restart Engine" at the bottom applies them all at once (while recording / streaming runs it first asks "… will stop n recording(s), m stream(s)"; Cancel changes nothing). Changing a value back removes it from the pending list.
  The window stays open on the same page after the restart. If you don't click it: the This-Mac items (audio device, local API, compatibility layer, preview all overlays in PVW) are already stored and apply the next time the engine starts (New, Open, reopening the app);
  **pending Show Format and Show Audio changes are lost unless applied** — closing the Settings window or creating / opening a show re-reads those two pages from the show.
- **The Shortcuts and MIDI pages need Save**: the table is checked as a whole (conflicts, unrecognised keys) before saving. With unsaved changes, closing the window or switching pages asks "Save / Cancel / Discard Changes"; if it can't be saved (a conflict) the window stays and the error is shown under the table.

Three buttons at the bottom left:

| Button | What it does |
|---|---|
| Export Settings… | Writes this Mac's settings, the shortcut table and the MIDI mapping into one JSON file (`PlusMix Settings.json`) to take to another machine. **The access token is not exported**; neither are Reminders, Performance & Power, Tally and the compatibility layer's HTTP port |
| Import Settings… | Pick an exported file; it first lists "This replaces on this Mac: n Mac settings, the shortcut table (m), the MIDI mapping (k)" and asks; shows are not touched, settings that need an engine restart become pending |
| Restore Defaults | This Mac's settings, the shortcut table and the MIDI mapping go back to defaults and the access token is cleared (asks first); shows are not touched and the engine is not restarted. Reminders, Performance & Power, Tally and the compatibility layer's HTTP port are left as they are |

## This Show

| Page | Contents |
|---|---|
| Show Format | Resolution (presets 1920×1080, 1280×720, 2560×1440, 3840×2160; "Custom…" takes width × height, rounded down to even numbers, 320×240 … 7680×4320), frame rate (24 / 25 / 29.97 / 30 / 50 / 59.94 / 60). Restarts engine |
| Overview, Recording, ISO, Streaming, External Display, NDI® Output, Virtual Camera, Multiview Layout | See [Outputs](outputs.md) |
| Show Audio | Alignment delay (how much later the program audio is than capture; default 2048 frames = 42.7 ms; lower it for low-latency monitoring, raise it for producers with large blocks), headphone monitor point (before the delay line = low latency, default; after the delay line = aligned with the picture). Restarts engine |

## This Mac

### General

| Section | Contents |
|---|---|
| Reminders | Remind me when neither recording nor streaming is on (after the engine has run n minutes; off by default, n = 5); when FTB has been on for 10 seconds; after 30 seconds of the Master level below −50 dBFS. Applies immediately. Reminders appear at the right of the bottom row of the main window (amber), see [Concepts › Reminders, statistics window, interface lock](concepts.md#reminders-statistics-window-interface-lock) |
| Confirmations | "Confirm before stopping recording / streaming (bottom bar buttons)", on by default. Only stopping asks (starting doesn't); hotkeys, MIDI and the API never ask; New / Open / format changes / Quit always ask while recording or streaming, and that question can't be turned off |
| Language | Interface language: System / Simplified Chinese / English. Takes effect after you reopen PlusMix |
| Preview (PVW) | "Preview all overlays in PVW": PVW draws every visible overlay (OR-ed with each channel's "Preview in PVW" in the Overlay Settings window). Restarts engine |
| External displays | "Keep external displays on the main display behind the interface": external display windows on the main display (the one with the menu bar) stay below the interface, even when clicked; on other displays they stay full screen in front. Applies immediately |

### Audio Devices

- **Device**: System default (follows changes) / Null device (silent) / the listed output devices. With the null device picture, recording and streaming carry on with sound; only local playback is silent.
- **Which two channels each bus goes to**: Master, Bus A, Bus B and Headphones each pick a channel pair (1/2, 3/4, …) or "Off". Two buses can't share a pair: picking a pair another bus uses switches that bus to "Off" and says so.
  Changing the device only drops the pairs the new device doesn't have; "Restore device defaults" goes back to the device's default assignment. Recording / streaming / NDI® use Master itself and are not affected by this.
- **2-channel devices** (built-in speakers, plain USB headsets): both channels go to Master, so this page and the mixer header say "This device has no headphone channels" — solo / PFL / AFL live on the headphone bus and can't be heard then.
  "Use the Master channels while monitoring" is **not in effect yet** in this version (the choice is saved and works once the audio engine supports it); to hear the headphone bus today, use a device with more channels.
- A device change needs "Apply and Restart Engine". **Changing only channel pairs does not enable that button** (this version doesn't count it as pending): the change is stored and applies the next time the engine starts (New / Open, reopening the app).

### Remote Control

Two sections: the **local API** (HTTP / WebSocket, [docs/api](../../api/README.md)) and the **third-party API compatibility layer** (lets existing control-panel configurations work, off by default; its legal notice and coverage table are linked from the [local API docs](../../api/README.md); Chinese).

| Item | Local API | Compatibility layer |
|---|---|---|
| Switch | "Enable HTTP / WebSocket API" (on by default) | "Enable compatibility layer (off by default)" |
| Who can connect | This Mac only (127.0.0.1) / Allow local network (0.0.0.0) | Same |
| Ports | 8765 by default | TCP 8099 and HTTP 8088 by default |
| Authentication | Token (empty = no auth) | None (the protocol has none) |
| Connect to | Read-only address for other machines (`http://<this Mac's LAN IP>:8765`) with "Copy"; with several network interfaces the others are listed too; if no LAN address is found it says so | HTTP address (`…/api`) and TCP address, with "Copy" |

When the local network is allowed without a token, or the compatibility layer allows the local network, a yellow warning says anyone on the same network can switch the program or stop recordings. Changes need "Apply and Restart Engine".
"Change Listen Addresses… (Advanced)" at the bottom jumps to the [Advanced](#advanced) page, where a specific host:port can be typed.
**The first time PlusMix listens on the local network** (Allow local network, or the tally stream), macOS asks "Allow incoming connections" if the firewall is on; click Allow.

### Tally

"Provide the read-only tally stream" (off by default): for tally lights / prompter displays on the local network; a frame on every PGM / PVW change, and nothing a client sends is treated as a command.

- Port: unless set separately = the local API port + 1 (8766). When on it listens on the local network (0.0.0.0).
- Two read-only addresses with "Copy": WebSocket `ws://<this Mac's LAN IP>:8766/tally` and HTTP polling `http://<this Mac's LAN IP>:8766/tally`; below them the current number of connections.
- The switch and port apply immediately, no engine restart; if it can't start (port in use) the status line says so. Protocol in [docs/integrations/tally.md](../../integrations/tally.md) (Chinese).

### Shortcuts, MIDI

See [Shortcuts](shortcuts.md).

### Performance & Power

- "Prevent system sleep and App Nap while the engine runs" and "Prevent display sleep while the engine runs": both on by default, apply immediately. While the engine runs PlusMix holds these two power assertions itself and releases them when the engine stops (quitting, between shows); a line on the page shows the current state.
  They can't prevent sleep when the lid is closed or the screen is locked manually: for **unattended runs with the lid closed or the screen locked**, still run `caffeinate -u -i -d -s` as well (see [Troubleshooting › Picture and sound](troubleshooting.md#6-picture-and-sound)).
- Read-only information about this machine: model, chip, memory, GPU, system.

### Updates & Diagnostics

- Updates: signed and notarised release builds check once a day ("Check for updates automatically" can be turned off) and "Check for Updates…" checks now; development / unsigned builds have no update feed and this section is greyed out.
- Export Diagnostics…: same as Help › Export Diagnostics…; attach it when reporting a problem ([Troubleshooting › Logs and diagnostics](troubleshooting.md#9-logs-and-diagnostics)).

### Advanced

| Section | Contents |
|---|---|
| Recording | **Free space minimum (MB)**: when the recording volume drops below this, that recording stops (default 200); applies from the next recording start. **Fallback folder**: when the target disk is full or below the minimum, recording continues in this folder from the next tick (best on another disk); "Choose… / Clear", applies immediately |
| Listen addresses | Local API (host:port), compatibility layer (host:TCP port): type a specific address here if you need one. Invalid entries are not saved and are explained in red. Restarts engine |

## Launch arguments

When starting the app from a terminal (`open PlusMix.app --args …`, or running `PlusMix.app/Contents/MacOS/PlusMix …` directly). Launch arguments only apply to that run;
**but if you change anything on the General, Audio Devices, Remote Control or Advanced pages during that run, this Mac's settings are written back as a whole and the launch-argument values (`--no-api`, `--api-listen`, `--api-token`, `--audio-device`, `--record-*`) are stored too** — don't edit those pages while running with launch arguments:

| Argument | Effect |
|---|---|
| `--show <file>` | Open this show file (instead of restoring the last one) |
| `--stats <file>` | Write one statistics line per second to this file (stats.jsonl) |
| `--audio-device <name / default / null>` | Audio output device; `null` = the null device |
| `--api-listen <host:port>`, `--api-token <token>`, `--no-api` | Local API address, token, or turn it off |
| `--record-min-free-mb <MB>`, `--record-fallback <folder>` | Recording free-space minimum, fallback folder |
| `--tally-port <port>` | Turn on the read-only tally stream on this port (same name as in the headless engine) |
