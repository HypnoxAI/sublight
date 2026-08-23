# Sublight — Roadmap

**Status:** the three-mode dimming/pulse engine works and is stable. This
document captures the agreed product direction and the prioritized build plan
to take it from "works on my M4" to a polished, shareable, open-source tool.

## Product identity

Sublight is a **free, open-source, Apple-Silicon-only** utility that dims a
MacBook's built-in keyboard backlight **below the macOS minimum**. It serves
two audiences from one app via a hybrid UI:

- **Dimming-focused users** get a dead-simple surface: on/off + a brightness
  slider. Under the hood this runs at the calibrated steadiest value, or 8 Hz
  (the dimmest *and* steadiest setting the daemon will hold) until calibrated.
  They never see frequencies or the experimental framing.
- **Experimenters** opt into an **Advanced mode** that exposes the pulse
  frequency (3 / 6 / 8 Hz) as a first-class control, with the entrainment
  associations, alongside an independent brightness slider.

> **Revised 2026-08-23.** This document previously described High as ~10 Hz and
> as fusing into a steady glow. Measurement says otherwise: the backlight
> daemon will not honour a dither cycle shorter than ~125 ms, so 8 Hz is a hard
> ceiling and **no setting is flicker-free**. See
> [`COREBRIGHTNESS.md`](COREBRIGHTNESS.md).

## Locked decisions

- **Scope: Apple Silicon MacBooks with a backlit keyboard only.** No Intel, no
  external keyboards. Stated explicitly in-app and in the README; unsupported
  hardware gets a clear message, not a mysterious failure.
- **Preset frequencies are 3 / 6 / 8 Hz** for Low / Medium / High — plus a
  **2–8 Hz custom slider** in Advanced mode. Low and Medium align with
  frequencies referenced in photic-entrainment studies; **High is not a chosen
  number at all — it IS the measured stability ceiling**
  (`DitherEngine.maxStableFrequencyHz`), 0.5 Hz below the lowest frequency ever
  observed to fail. Simple mode dims at the calibrated value, or 8 Hz until
  calibrated. Nothing in the app can exceed the ceiling.
- **Hybrid UI:** simple dimming surface by default; Advanced/Experimenter mode
  behind a toggle.
- **The two-axis model** (see below) governs how brightness and frequency are
  presented.
- **Sequencing A:** quick wins first, in-app calibration last as its own push.
- **Effects framing:** the pulse's neurological effects are **unproven**;
  described as "associated with X in entrainment research," never as a claim.
- **The Control Center jitter is a documented known limitation, not a bug**
  (see below).
- **No mode is flicker-free, and the docs say so plainly.** Fusing the dither
  would need a shorter cycle than the daemon will accept, so it is not
  achievable at any setting. Consent is taken before the first backlight
  command (see [`../SAFETY.md`](../SAFETY.md)).

## The two-axis design (why the UI splits the way it does)

There are two independent axes — **brightness** (how dim) and **frequency**
(pulse character / claimed feel) — and this hardware couples them *inversely*:
8 Hz is the dimmest and steadiest but the "alert" frequency; 3 Hz is the
brightest and most obtrusive but the "relaxed" one. A single Low/Medium/High scale can't express both without making
"High" ambiguous. The resolution is to give each audience only the axis they
care about:

- **Dimming users:** frequency is hidden entirely. One axis (dimmer↔brighter),
  at the calibrated value or 8 Hz. They optimize the objective thing (dim +
  steadiest available) and never meet the inverse coupling.
- **Experimenters:** frequency is the star and brightness is a *separate*
  slider. Two clean, independent knobs — pick the frequency for the feel, set
  brightness independently. The inverse coupling becomes a starting point they
  adjust, not a confusion.

## Prioritized build plan

| # | Item | Notes | Status |
|---|---|---|---|
| 1 | ~~Yield to manual control~~ | **Parked.** This MacBook Air has no keyboard-brightness keys (F5/F6 are dictation/focus), so there is nothing to yield to. The only manual path is Control Center's slider, which our dither writes drown out in read-back and which would need the notification's key-identifier strings reversed. Low value + high effort → dropped. | parked |
| 2 | **Consent before the first backlight command** | A versioned modal states what the flicker is and asks, before anything is commanded, on the first enable by toggle, preset chip, or hotkey. Declining records and changes nothing; accepting writes a marker shared with the CLI. Superseded the original first-run tick-box, which gated features at launch and meant two prompts for one fact. | **done** |
| 2b | **Deferred consent for scheduled enables** | The schedule fires unattended, so it never raises the modal — it records a pending flag and the popover reports the skipped dim with a "Review and enable" button. | **done** |
| 3 | **Hybrid UI** | Simple (Off + dim slider @ calibrated value, 8 Hz default) vs Advanced (frequency picker + separate brightness + associations). | **done (this build)** |
| 4 | **Apple-Silicon gate** | Clear "requires Apple Silicon MacBook with a backlit keyboard" message on unsupported hardware. | **done (this build)** |
| 4b | **Custom frequency + presets** | Advanced mode: 3/6/8 Hz preset chips + a 2–8 Hz custom slider, capped at the measured ceiling. | **done** |
| 4c | **Launch at login** | `SMAppService` toggle. (App must live in a stable path — e.g. /Applications — to persist across reboots.) | **done** |
| 4d | **Reset to defaults** | Menu action clears saved settings, revokes consent, and re-shows the first-run walkthrough; leaves the system login item alone. | **done** |
| 5 | **In-app calibration** | Guided 3-step flow in Settings: bisection A/B for the hardware floor, bisection A/B for the personal flicker-fusion frequency, live slider for preferred level. Stored per hardware model. | **done** |
| 6a | **Manual time scheduling** | Auto-dim between two times. Transition-based so manual overrides stick; handles windows wrapping past midnight; Advanced mode can set the schedule's own frequency. | **done** |
| 6b | **Solar scheduling** | Sunset → sunrise, computed **locally** from a manually-entered latitude/longitude using the NOAA solar position algorithm. Deliberately NOT CoreLocation: that adds a permission prompt and may resolve position over the network, which would break the no-network rule. No dependency (`ceeK/Solar` considered and rejected for the same reason). Polar day/night handled explicitly. Unit-tested against published times. | **done** |
| 7 | **Global hotkey** | Toggle dimming system-wide. Implemented directly on Carbon `RegisterEventHotKey` rather than taking the `KeyboardShortcuts` dependency — ~100 lines, keeps the zero-dependency rule, and needs no Accessibility permission. Four preset combinations instead of a recorder control. | **done** |
| 8 | **Release polish** | Remaining: Control Center jitter mitigations; Developer ID + notarization + DMG; screenshots. | partial |
| 8d | **State-reflecting menu-bar icon** | Keyboard glyph drawn in code (`StatusGlyph.swift`, in the kit): keys hollow while idle, filling from the right as dimming engages — 0 / 3 / 5 / 8 of 10 keys for Off / Low / Medium / High. Fill, not colour — stays a template image. | **done** |
| 8h | **Menu-bar legend** | `sublight-cli glyph render` draws the four states over dark and light rows straight from `StatusGlyph`, deterministically, so README and SPEC cannot drift from the geometry. | **done** |
| 8i | **Stability ceiling** | Command-truth instrumentation isolated a daemon cycle-period limit; 8.0 Hz is enforced as a hard ceiling (0.5 Hz below the measured failure), `High := the ceiling`, and no app path can exceed it. | **done** |
| 8e | **Fade + slider debounce** | 0.35 s ramp on enable, 0.25 s on disable; slider changes coalesced over 50 ms so dragging doesn't stutter the dither. | **done** |
| 8f | **Crash-safe watchdog + logging** | A marker written while dimming and cleared on every clean restore; if it survives to launch, the backlight is rescued. Structured `os.Logger` categories throughout. | **done** |
| 8g | **First-run onboarding** | Three-page window: what it does, the safety warning, and an offer to calibrate. Informational only — it records nothing; the versioned consent modal (item 2) is the sole recorded acknowledgment. Replaces a seizure warning crammed into the popover as a new user's first sight of the app. | **done** |
| 8a | **App icon & identity** | v1 brand mark: an amber-ringed tile with a keyboard whose keys are hollow (off, system control) or filled (on, Sublight active). SVG + 1024px PNG masters in `assets/icons/`; `.icns` generated at build time by `make_app.sh` (sips + iconutil); animated logo in the README. | **done** |
| 8b | **UI refactor** | Slimmed popover (status line, Simple/Advanced segmented switch, grouped frequency, inline schedule) + Settings window (General / Safety / About). | **done** |
| 8c | **Hardware detection** | `HardwareInfo` — model, chip, Apple-Silicon gate; shown in About, keys calibration. | **done** |

## Known limitations

- **Control Center keyboard-slider jitter.** While a mode is active, Sublight
  writes the backlight value ~10×/second. macOS's own Control Center polls that
  value and redraws its keyboard slider, so the slider knob visibly jitters
  while Control Center is *open*. This is cosmetic and only visible when
  actively watching Control Center or System Settings; during normal use
  nothing observes the value in real time. It is inherent to the dither
  technique (the commercial prior art has the same tension) and cannot be fully
  eliminated at any usable frequency — only reduced. Documented here and in-app
  so it reads as a known quirk rather than a fault.

## Permanent non-goals

No network, no analytics, no telemetry, no health claims — ever. Not Intel. Not
per-key lighting. Not the Mac App Store (private API; see
`APPSTORE_AND_HEALTH.md`).
