# Testing (English summary)

Live-production software has exactly three qualities that matter: **no dropped frames, no A/V drift, no crashes**. PlusMix turns them into
metrics that can be measured, run automatically and compared across versions. The full standard (definitions, test methods, thresholds,
report template and the `stats.jsonl` fields) is published in Chinese: [测试标准.md](../测试标准.md). This page is the map.

## Metric families

| Family | Examples | Hard limits (release gate) |
|---|---|---|
| V — video | V1 render time, V2 missed renders, V3 jitter, V4 duplicate / dropped input frames, V5 frame count, V6 switch accuracy, V7 transition curve, V8 picture correctness, V9 colour levels | V6: the new input appears exactly on tick n and a Cut has no mixed frame; V2 ≤ 0.02 %; V8 PSNR ≥ 40 dB |
| A — audio | A1 dropouts, A2 A/V offset, A3 drift, A4 multi-file (ISO) alignment, A5 monitoring latency, A6 meter accuracy, A7 real-time thread violations | A1 = 0 over 8 h; A2 ≤ 1 frame (16.7 ms at 60 fps); A7 = 0 |
| E — encoding / recording / streaming | E1 encoder skips, E2 bitrate compliance, E3 keyframe interval, E4 quality (VMAF), E5 file integrity, E6 crash recovery, E7 multi-destination independence, E8 reconnect, E9 network-drop accounting | E1 = 0 under standard load; E7 = 0 frames lost on other destinations; E8 10 / 10 within 15 s |
| L — latency | L1 internal (input ingress → encoder), L2 glass-to-glass, L3 stream egress | L1 ≤ 3 frames; L2 UVC ≤ 150 ms, SDI ≤ 100 ms, NDI ≤ 160 ms, screen ≤ 80 ms |
| S — stability / resources | S1 8 h / 24 h soak, S2 memory growth, S3 CPU / GPU, S4 thermal throttling, S5 hot-plug, S6 denied permissions, S7 slow / full disk | S1 8 h pass; S2 ≤ 10 MB/h; S7 only recording stops |
| C — control interface | C1 command latency, C2 push latency, C3 state consistency, C4 concurrency, C5 compatibility layer | C1 ≤ 1 tick + RTT; C3 0 mismatches; C4 0 lost / reordered |

## Test signals and tooling

The engine ships its own instruments: a **synthetic video source** (frame number, input ID, timestamp and a once-per-second flash burnt
into every frame; configurable frame rate, jitter, drops, clock drift), a **synthetic audio source** (1 kHz tone with a click at every flash),
`frameprobe` (decodes recordings and stream captures to count drops / duplicates, locate switches, measure fade curves and A/V offset),
a **headless engine** (`switcher-headless`) that runs scripted scenarios and writes one statistics line per second, plus MediaMTX and
`dnctl`-based network impairment for the streaming metrics.

## Run it yourself

```bash
make test
```

```bash
make gate4
```

The first runs unit / component tests of the six packages, the two tools and the App; the second runs the 10-minute integration scenario
(V1–V7, A1–A4, E1–E3, E5, C1–C4) and writes `reports/G4-run-10min.md`. Use an idle machine on mains power.

Reading `frameprobe` results (details in [测试标准 §2.3](../测试标准.md#23-frameprobe分析工具), Chinese):

- `switches` / `fade` place transitions by program tick computed from the PTS, so frames missing from a file don't shift later transitions; the missing ticks are reported separately (`missingFrames` / `missingFrameCount`, plus `missingBetween` per switch). Their frame rate comes only from `--fps`, otherwise it is estimated from the PTS steps between frames.
- `av` / `wipe` / `zoom` / `stats` fall back to the container's nominal frame rate without `--fps`, which reads low on a file with missing frames: always pass `--fps 60` (or the program rate) for such files.
- Multi-file `av` (A4): if a file lacks the click or the flash of a judged event, `passA4` is false — `maxClickSpreadMs` / `maxFlashSpreadMs` alone don't show it (a missing value doesn't enter the spread).

## Checkpoint reports

| Checkpoint | Date | Scope | Result |
|---|---|---|---|
| G2 | 2026-09-15 | Core loop: 8 synthetic inputs → compositor → H.264 → .mov, 10 min + 60 min | Pass (one item waived by the reference-line rule) — [reports/G2.md](../../../reports/G2.md) |
| G3 | 2026-09-18 | Switching, audio, outputs, control; network impairment E7–E9 | Pass: 18 of 19 automatic items, E2 not applicable to that scene; E7–E9 3 / 3 — [reports/G3.md](../../../reports/G3.md) |
| G4 | 2026-09-20 → 27 | Inputs phase 2, overlays, five transitions, keyer, multiview, external output, virtual camera, ISO | Automatic items pass (latest run 20 / 20) — [reports/G4.md](../../../reports/G4.md); manual and BLOCKED items in the checklist |
| G5 | 2026-09-28 | Release gate: 8 h soak, device matrix, performance regression, known-issues list | **0.1.0 not released**: the 8 h soak failed S2 (file-input leak, fixed, re-run pending), one S1 and half the device matrix missing, notarisation / update feed BLOCKED (account) — [reports/G5.md](../../../reports/G5.md) |
| G6 | 2026-10-02 | Fifth wave, stop-gap fixes (visual, live safety, bus effects, stream authentication, refusing PVW / PGM changes mid-transition) | **0.1.0 still not released**; L2 automatic items 20 / 20 — [reports/G6.md](../../../reports/G6.md) |
| G7 | 2026-10-04 → 10-10 | Fifth wave, interface redesign (bottom bar, toolbar, input strip, output pages, Settings window, panels, sleep / tally / remote control / reminders / statistics / lock) | **0.1.0 not released, 0.1.1 not recommended yet** (MIDIHost.sync crash, 8 h re-run, signing…); six packages 777 tests and App 228 tests with 0 failures, L2 20 / 20 — [reports/G7.md](../../../reports/G7.md) |
| G8 | 2026-10-10 → 10-12 | Contract work (transition slots, file playback, status statistics), the MIDIHost crash fix and monitor sync (G8a); then the transition-slot interface, playback controls and the stream / recording status window, per-input audio effects and the bundled guide (G8b) | **0.1.1 not released yet**: only the L3 manual checklist and signing / notarisation remain; the 8 h soak re-run passed on 10-12 (S2 2.46 MB/h); six packages 861 tests with 0 product failures (one timing test failed on a busy desktop), App 244 tests with 0 failures, gate4 automatic items all pass, no performance regression — [reports/G8.md](../../../reports/G8.md) |
| G9 | 2026-10-17 → 10-18 | Five follow-up branches merged (contracts, app follow-ups, stopping on stream authentication failures, frameprobe A4 half-second events, guide part two); an external debugging review's 22 findings filed as known issues | **0.1.1 not released**: the review found S0 / S1 defects (crashes on bad file-playback parameters and in the compatibility layer, an audio ring overwrite, saving into the wrong file, recordings deleting old files…), so seven stop-gap branches were scheduled; six packages 883 tests with 0 failures, App 263 tests with 0 product failures, gate4 automatic items all pass with A4 no longer waived — [reports/G9.md](../../../reports/G9.md) |
| G10 | 2026-10-19 | The seven stop-gap branches (contracts, file input, control, outputs, core audio, frameprobe ticks, app fixes) plus seven glue fixes merged | **0.1.1 not released**: the only S1 left is "input numbers have no upper limit" (scheduled next), and the L3 manual checklist and the 8 h soak haven't been run; six packages 984 tests with 0 failures, App 296 tests twice with 0 failures, gate4 automatic items all pass, no performance regression — [reports/G10.md](../../../reports/G10.md) |

Reports are in Chinese. The [device compatibility table](../设备兼容性.md) collects community results (model, firmware, macOS, passed items).
