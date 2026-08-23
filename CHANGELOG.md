# Changelog

All notable changes to Sublight are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [semantic](https://semver.org/), and Sublight stays in **0.x**
deliberately: it depends on an undocumented Apple framework that can change in
any macOS release, so the public surface is not yet something to promise
stability on.

## [Unreleased]

### Changed
- **Builds in Swift 6 language mode with complete concurrency checking**, on
  every target. No behaviour changed; the compiler now refuses several things
  that were previously only conventions. `StatusGlyph` is `@MainActor` (it
  vends NSImages for a status item and memoized them in shared mutable state);
  the Carbon hotkey table moved behind a lock, because the two things that
  touch it — `deinit` and a C function pointer — are the two things that can
  never carry actor isolation; and the engine's state mirror now reads its
  callback on the engine queue and sends only that, rather than handing
  `self` to the main queue.

  Strict checking does **not** cover the engine's queue confinement:
  `queue.async { self.something() }` compiles regardless, and the only way to
  make the compiler prove it would be a custom global actor, which would make
  every bridge call `async` and change the engine's timing. So the invariant
  stays held by construction and is now also checked at run time — a
  `dispatchPrecondition` at the single point where CoreBrightness is actually
  reached, which traps loudly if any future edit calls the daemon from off the
  queue.

### Planned

- Developer ID signing, notarization, and a DMG.

## [0.4.0] — 2026-08-23

### Added

- **Informed consent before the first backlight command.** Sublight's only
  mechanism is flicker, every mode it can offer sits in the 3–30 Hz
  photosensitive band, and none of them is flicker-free — so the first time
  anyone enables dimming, the app now says so plainly in a modal and asks,
  *before* a single command reaches the daemon. Declining changes nothing and
  records nothing. Accepting writes a versioned marker beside the dirty flag in
  Application Support; bumping `ConsentMarker.currentVersion` alongside the
  copy re-asks everyone. The schedule deliberately does not raise the prompt —
  automation that fires unattended does not get to be the first thing that
  turns dimming on. The CLI does not block (it is a research harness) but every
  mutating command points at `SAFETY.md` on stderr until the marker exists.
- **A menu bar icon legend that cannot drift.** `StatusGlyph` moved into the
  kit, and `sublight-cli glyph render --out <dir>` draws the four states from
  that same code — per-state PNGs at 1x and 2x plus a composed legend showing
  Off / Low / Medium / High over both a dark and a light menu bar. The render
  is deterministic, so re-running it on an unchanged glyph produces
  byte-identical output and a diff there means the drawing really changed. Only
  the legend is committed; the runtime icon stays code-drawn and no PNG ships as
  an app resource. README and SPEC §8 both embed it.
- **`docs/COREBRIGHTNESS.md`** — the research record. Methodology (runtime
  lookup, the `dump`/`sig` harness, command-truth instrumentation, and the
  human-in-the-loop visual protocol, with the reason it has to exist), then
  every finding with the evidence under it: `fadeSpeed`'s true type and the
  arm64 register-misalignment trap behind it, the hardware clamp, both
  read-backs being blind to the LED, the period limit with its full boundary
  table, `fadeSpeed` being visually inert, and the err-dark skip statistics. It
  also flags one claim as an open hypothesis rather than quietly dropping it.
- **`SAFETY.md`**, linked from the README's warning section and again directly
  above the install instructions: what the flicker mechanically is, who should
  not use it — including anyone who can merely *see* the keyboard — the stop
  conditions, how to recover a stuck backlight, and why a read-back value is
  not evidence and your eyes are.

- **Write padding** (`hold --pad-writes [--pad-offset f]`), a diagnostic that
  sends every edge command twice — first the value offset by ~0.002, then the
  value itself — doubling the command rate at an unchanged cycle period. The
  engine emits exactly two writes per cycle, so its rate and its period are
  rigidly reciprocal and no ordinary run can tell which one the daemon reacts
  to; this breaks that tie. The padded value goes FIRST so an OFF edge never
  parks on a sub-floor value for the whole OFF window. CLI and bridge
  instrumentation only, off by default — no engine behavior changed.
- **Discrimination runs and a read-back sampler.** `hold` gains `--freq`,
  `--duty` (drive the engine at an exact duty instead of deriving it from a
  level), `--sample-hz` and `--sample-csv`. The sampler polls BOTH read-backs on
  the engine queue during a run, timing each getter and stamping it against the
  last commanded level, and writes a CSV. The diagnostics tally now remembers
  the last commanded level so a read-back has something honest to be compared
  against. CLI and instrumentation only — no engine behavior changed.
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

### Changed

- **The docs no longer claim a flicker-free mode, because there isn't one.**
  `SPEC.md`, `ROADMAP.md` and `APPSTORE_AND_HEALTH.md` described ~10 Hz as
  fusing into a steady, dim, flicker-free glow and framed the limit as command
  coalescing. Measurement contradicts both: the limit is on the cycle *period*,
  and 10 Hz is above it. Those documents now carry the measured story and a
  dated note saying what was retracted and why — the old claims are marked, not
  erased. The README's own opening paragraph said the same thing and now says
  the true one. A new "How it works — and what could break" section records
  which macOS build and hardware the private interface was verified against,
  how the launch probe self-disables on drift, the five-minute ritual for
  re-qualifying the ceiling after an update, and what related projects do and
  do not do.

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

### Fixed

- **High mode's long-standing irregularity was never the engine — it was a
  daemon-side cycle-period limit, and the presets sat on the wrong side of
  it.** Above roughly 8.5 Hz the backlight daemon stops honouring the dither
  and the keys fall completely dark for a second or more at a time, repeating
  every one to three seconds. This is not command coalescing (the old
  explanation) and not flicker fusion: it is a hard limit on how short a
  dither cycle the daemon will act on — 117.6 ms fails, 125.0 ms holds. Duty
  makes no difference, the ON window makes no difference, and neither
  read-back API can see it. It is the period specifically and not the
  command rate: pushing 24 writes/s through an unchanged 166.7 ms period
  stays perfectly steady, including when the extra writes deliberately
  cross a 1/16 output step so that no form of daemon-side de-duplication
  can be quietly discarding them. The old re-armed-after-each-XPC engine drifted
  slower than requested and so spent much of its time *below* the limit,
  which is why this read as intermittent "jitter" for so long; the anchored
  rewrite hits the requested period exactly and put High mode squarely on the
  wrong side of it every time.
- **The engine is exonerated, with numbers.** Command-truth instrumentation
  put 9,270 dither edges through scheduled/fired/executed/skipped counters
  across fifteen runs: 9,265 executed, 5 benign isolated skips, zero timer
  coalescing, zero rejected commands, and daemon round trips with a p50 of
  0.15 ms. The dark envelopes happened while commands were arriving on
  schedule and being accepted.
- **Presets re-homed to 3 / 6 / 8 Hz behind an enforced 8.0 Hz ceiling.** High
  was 9 Hz — above the boundary. It is now defined AS
  `DitherEngine.maxStableFrequencyHz`, which is the lowest frequency ever
  observed to fail (8.5 Hz) less a 0.5 Hz margin, verified by a five-minute
  soak at 8.0 Hz with 2,401 of 2,401 edges executed and no envelope. The
  engine clamps any higher request and logs the clamp; the Advanced slider,
  Simple mode, the schedule, `pulse high`, and calibration's search ladder all
  stop at the ceiling, and a stored calibration above it is clamped down on
  load. `sublight-cli --allow-unstable` lifts it for re-measurement; the app
  has no path past it. Measured on Mac16,12 / macOS 26.6.1 — re-qualify after
  a macOS update with the soak ritual in `README.md`.
- **Quitting without ever dimming no longer touches your backlight.** The exit
  restore forced auto-brightness on and a level of 0.4 unconditionally, so
  simply launching Sublight and quitting overwrote whatever you had set by
  hand. It is now gated on whether the process ever issued a backlight
  command; once it has, the forced restore behaves exactly as before, so
  calibration's ambient-sensor suppression is still always undone.

- The app bundle shipped with a `com.example` placeholder bundle identifier;
  it is now `com.hypnox.sublight`.

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
