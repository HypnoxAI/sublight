# Changelog

All notable changes to Sublight are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [semantic](https://semver.org/), and Sublight stays in **0.x**
deliberately: it depends on an undocumented Apple framework that can change in
any macOS release, so the public surface is not yet something to promise
stability on.

## [Unreleased]

### Added
- **Command-truth instrumentation.** Every backlight-mutating daemon call is
  now timed at the bridge seam and logged at debug level in category `engine`
  with its monotonic timestamp, requested value, `fadeSpeed`, `commit`, the
  daemon's answer, and the round-trip latency in ms; an `XPC` signpost interval
  wraps each one. The engine counts each edge four ways — `scheduled`
  (deadlines that came due), `fired` (handler runs; the difference is what a
  repeating `DispatchSourceTimer` coalesced away), `executed` (commands issued)
  and `skipped` (the err-dark rule declining to command) — and records the
  lateness, threshold and *run length* of every skip, so a burst of skipped
  cycles is distinguishable from scattered ones. New signposts `EDGE_HIGH`,
  `EDGE_LOW` and `SKIP_HIGH` separate a scheduled edge from a command that was
  actually sent; `ON`/`OFF` keep their meaning as issued commands.
  `sublight-cli status` prints the counters and the last recorded run,
  `hold --seconds n` runs the engine path for a fixed time and prints them,
  and `pair-sweep --on-ms X` drives raw ON/OFF pairs straight at the bridge
  with the engine bypassed. Diagnostics only — no engine behavior changed.
- **VoiceOver support.** Accessibility labels, hints, and values across the
  popover, Settings, calibration, and onboarding: the menu-bar icon reports
  dimming/idle, sliders speak their value in hertz or percent, and the
  hidden-label pickers and terse buttons are properly named. Annotations only —
  nothing about the UI's behavior changed.
- The CLI's `set` command now warns on stderr when keyboard auto-brightness is
  on: the ambient light sensor can override a commanded value within
  milliseconds, silently invalidating a visual measurement. Run `auto off`
  first for visual tests.
- **GitHub scaffolding**: CI workflow (builds both products and runs the test
  suite on every push and PR), issue forms for bugs (requiring the Diagnostics
  block) and **hardware reports** (feeding the README compatibility table), a
  PR template with the DCO checklist, and a security policy.

### Fixed
- The app bundle shipped with a `com.example` placeholder bundle identifier;
  it is now `com.hypnox.sublight`.

### Changed
- **v1 brand mark on every surface.** The app icon (Finder, Get Info,
  Spotlight) is now the amber-ringed keyboard tile with hollow/filled keys;
  the README carries the animated logo (2.8 s cycle, ~0.36 Hz — far below the
  photosensitivity band) and an off/on pair. The **menu bar glyph is drawn in
  code** (`StatusGlyph.swift`) and reflects state: keys hollow while idle,
  filling from the right as dimming engages, with the fill level mapped to
  the frequency bucket (0 / 0.3 / 0.5 / 0.8 for off / ≈3 Hz / ≈6 Hz / ≈9 Hz).
  Still a monochrome template image, as macOS requires.
- **librsvg icon pipeline retired.** `make_icons.sh` and the old SVG sources
  are gone; `make_app.sh` builds the `.icns` from the committed 1024px PNG
  master at bundle time with `sips` + `iconutil`, which ship with macOS.
- **Calibration's floor step now asks "does it flicker?" instead of "was that
  brighter?"** The two levels alternate at ~1 Hz rather than being shown once
  each. The original phrasing required remembering a brightness across a
  two-second gap and produced results that contradicted each other between
  sessions — on the reference machine it settled on a floor roughly twice the
  real one. Flicker detection is far more sensitive and immediate.

### Added
- **Solar scheduling.** The schedule can now run from sunset to sunrise instead
  of fixed times. Location is chosen from a bundled list of ~110 cities, and is
  pre-filled on first run by matching the Mac's own time zone — so in most cases
  it needs no input at all. Manual coordinates remain available. Sunrise/sunset are computed **locally** from a
  manually-entered latitude/longitude using the standard sunrise equation — no
  CoreLocation, no permission prompt, no network call, no dependency. Polar day
  and polar night are handled explicitly rather than producing nonsense times.
- **Diagnostics tab** in Settings — engine status, resolved keyboard ID,
  measured floor, effective frequency, calibration state, schedule and hardware,
  with a one-click copy for pasting into bug reports. Coordinates are
  deliberately excluded: the chosen city is reported instead, since this text is
  meant to be pasted into public issue trackers.
- **Unit tests** for the solar maths, validated against published sunrise/sunset
  times for four cities, both solstices, and the polar cases — plus the schedule
  window arithmetic, including the overnight-wrapping case and a partition
  property that catches boundary off-by-ones.
- `ScheduleWindow` extracted into SublightKit so the time-of-day logic is pure
  and testable rather than buried in the app layer.

### Planned
- Developer ID signing, notarization, and a DMG.

## [0.3.0] — 2026-07-24

First public release.

### Added
- **Hybrid UI.** Simple mode is a switch and a brightness slider; Advanced mode
  adds 3 / 6 / 9 Hz presets, a 2–12 Hz custom frequency slider, and a separate
  brightness slider.
- **Guided calibration.** Three steps — a bisection A/B for the hardware
  brightness floor, a bisection A/B for the individual's flicker-fusion
  threshold, and a live slider for preferred level. Results are stored per
  hardware model, so a different Mac re-prompts rather than inheriting numbers
  measured elsewhere.
- **Time-of-day scheduling.** Transition-based, so manual overrides between
  transitions stick. Handles windows that wrap past midnight. In Advanced mode
  the schedule can run at its own frequency.
- **First-run onboarding.** Three pages: what the app does, the photosensitivity
  warning behind a real acknowledgment gate, and an offer to calibrate.
- **Settings window** (⌘,) with General, Safety and About tabs. Safety keeps the
  warning permanently readable rather than showing it once and hiding it.
- **Global shortcut** to toggle dimming, built directly on Carbon
  `RegisterEventHotKey` — no third-party dependency, and no Accessibility
  permission required.
- **Launch at login** via `SMAppService`.
- **Hardware detection** — model identifier and chip, used to gate to Apple
  Silicon, key calibration data, and populate About.
- **Crash-safe restore.** A marker is written while dimming and cleared on every
  clean restore; if it survives to the next launch, the backlight is rescued.
- **Structured logging** through `os.Logger` (local only — Sublight makes no
  network calls).
- **Reset to defaults**, an app icon and menu-bar glyph, a menu-bar icon that
  reflects active/idle state, fades on enable/disable, and slider debouncing.

### Changed
- Licensed under **Apache 2.0** (from MIT), with a DCO for contributions, a
  NOTICE file, a standalone DISCLAIMER, and SPDX headers on every source file.
- Preset frequencies are now **3 / 6 / 9 Hz** (previously 5 / 6 / 10). 5 and 6
  were perceptually indistinguishable; 3 / 6 / 9 gives three genuinely different
  characters and a cleaner spread.
- The menu-bar glyph was rebuilt to read as a keyboard at 18 pt and measured
  against system icons — it had been roughly 50% wider and three times the ink
  of a typical status item.

### Fixed
- Invisible menu-bar icon, which had **two** independent causes: a conditional
  view in the `MenuBarExtra` label (which yields an item that occupies space but
  draws nothing), and rasterising the glyph to PDF, whose soft-masks `NSImage`
  does not reliably render.
- Settings window opening *behind* the frontmost app — an accessory app needs an
  explicit activate plus `orderFrontRegardless()`, after the window exists.
- Acknowledging the safety warning now always lands in Simple mode.
- Icon assets are generated automatically by `make_app.sh` when missing, instead
  of silently falling back to a system symbol.

### Known limitations
- Control Center's keyboard slider visibly jitters while Sublight is active and
  Control Center is open. Cosmetic, and inherent to dithering.
- Above roughly 10 Hz macOS coalesces the commands, so the light can read as
  steady because it has stopped dithering — which also means it stops going
  below the floor. Calibration flags this if a result lands at the ceiling.
- Sunset/sunrise scheduling is not implemented; only fixed times.
- Yield-to-manual-control is parked: the reference machine has no
  keyboard-brightness keys, so there is nothing to yield to.

## [0.2.0] — internal

Mechanism fully characterised on the reference machine: the hardware clamp, the
absence of a software fade ramp, command coalescing above ~10 Hz, and the
finding that API read-backs are daemon bookkeeping rather than LED truth.
Menu-bar app with three fixed pulse presets.

## [0.1.0] — internal

Private-API bridge, dither engine, and the CLI probe harness.
