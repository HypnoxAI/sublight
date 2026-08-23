# Sublight — Strategy & Technical Specification

**Version:** 0.3 (shipped app) · **Date:** 2026-07-24 · **License:** Apache 2.0
**Validated on:** MacBook Air 13" (M4, Mac16,12), macOS 26, Swift 6.3

> This revision replaces the v0.1 plan, which was built on two assumptions that
> testing on real hardware disproved: that the private API could set a static
> level below the system floor, and that dithering would ride a daemon-side
> *fade ramp*. Neither is true on this machine. What follows is what we
> actually found, and the design that resulted. Where a mechanism is inferred
> rather than measured, it says so.

---

## 1. Purpose and scope

Sublight holds a MacBook's built-in keyboard backlight at a brightness below
the minimum that macOS exposes through any normal control, for use in a
genuinely dark room. It is deliberately narrow: one light (the built-in
keyboard backlight), one platform family (Apple Silicon MacBooks), one
privileged surface (the private CoreBrightness framework), zero third-party
dependencies.

**Outcome, stated up front:** the goal is achievable, but *only* by dithering
(pulsing) the backlight — there is no static sub-floor level on this hardware.
**No setting is flicker-free.** The backlight daemon refuses to act on a dither
cycle shorter than ~125 ms, so 8 Hz is a hard ceiling, and fusing the flicker
would need a faster cycle than that. Every mode Sublight can offer — 3, 6 and
8 Hz — is visible flicker, and it is exposed with the caveats in §7 and in
[`../SAFETY.md`](../SAFETY.md).

> **Revised 2026-08-23.** An earlier version of this document claimed ~10 Hz
> "fuses into a steady, dim, flicker-free glow". That claim did not survive
> instrumented measurement: 10 Hz is well above the daemon's period limit,
> where the dither stops being honoured. The measured account — with the full
> boundary table and the evidence for every finding — is in
> [`COREBRIGHTNESS.md`](COREBRIGHTNESS.md). Passages below that still describe
> the old model are marked.

## 2. Independence and open-source posture

Sublight is an independent, clean-room implementation. A commercial utility
with similar functionality exists; no code, resources, strings, or binaries
from it (or any third party) were examined, decompiled, or copied, and its
name/branding/UI are not imitated. What the project reuses is unprotectable:
functionality, physical principles, and the shape of a private Apple API that
public class-dump repositories already document. The license is Apache 2.0 so the
*knowledge* here — a map of what this hardware's keyboard backlight can and
cannot be made to do — survives macOS churn through forks. The one disclosure
duty that travels with distribution is honesty about fragility (private API)
and about the photosensitivity caveat (§7).

"Sublight" is a working title. Renaming touches `Package.swift`, the
`SublightApp` product name, `scripts/Info.plist`, and `scripts/make_app.sh`.

## 3. System model — what we confirmed

```
App / CLI
   └── SublightKit
         └── CoreBrightness.framework (PRIVATE) — KeyboardBrightnessClient
               └── backlightd (CoreBrightness daemon, over XPC)
                     └── HID / SMC keyboard-backlight driver
                           └── LED driver hardware (PWM)
                                 └── keyboard backlight LEDs
```

Three facts, all now confirmed by eye on the target machine (the important
ones were confirmed *visually*, because the API's own read-backs turned out to
be unreliable — see §6.3):

**A. There is a hard floor on real output, and the API cannot cross it.**
`KeyboardBrightnessClient.setBrightness:forKeyboard:` accepts values below the
floor and returns success. `brightnessForKeyboard:` then echoes the commanded
value exactly (0.03 reads back as 0.03), and the second read-back,
`backlightLevelForKeyboard:`, returns a clean linear rescale of it
(≈ 14.6 × commanded + 0.1). **Both are daemon bookkeeping, not LED state.** The
tell: `backlightLevel` climbs in a dead-straight line straight through the
floor with no plateau or kink — a real sensor would flatten at the clamp; a
computed value sails through it. With auto-brightness off and the room dark,
commanded 0.0625, 0.02, and 0.005 are visually identical. The driver pins the
actual PWM at the floor (~0.0625 normalized, i.e. `backlightLevel ≈ 1.0`) and
files away whatever sub-floor number it is sent.

**B. There is no software fade ramp to exploit.** Setting 0 reads back as an
instant jump to 0; there is no gradual daemon-side fade of the *commanded*
value. (The v0.1 plan assumed one and intended to ride it. That plan was
wrong.) Note this does not mean the *LED* changes instantly — see §5.

**C. There is a cycle-period limit.** Hammering `setBrightness` floor↔0 as
fast as possible, and pacing it at 60–240 Hz, produces *no* LED modulation: the
light holds steady at the floor. This closes the door on classic
high-frequency (flicker-fusion) dithering.

The limit was later measured precisely, and it is **not** a rate limit. It is a
limit on how short a *cycle* the daemon will act on: **125.0 ms holds, 117.6 ms
fails**. Doubling the commands per second while leaving the period alone
changes nothing — verified with padding writes that deliberately cross a 1/16
output step, so no de-duplication can be discarding them. Above the limit the
keys fall to complete darkness for a second or more at a time, recurring every
one to three seconds. See [`COREBRIGHTNESS.md`](COREBRIGHTNESS.md) §4 for the
full boundary table.

The one thing definitively unavailable is direct PWM register access from
userspace, which would need a DriverKit extension with entitlements Apple
grants only to hardware vendors. The design never assumes it.

## 4. The private-API bridge

All private-API risk is concentrated in `KeyboardBrightnessBridge.swift`, whose
design is entirely about containing it: the framework is `dlopen`ed at runtime
(a future removal yields a clean error, not a launch failure); the class is
resolved by name; selectors are declared in a private `@objc` protocol and
every call is guarded by `responds(to:)`, so a missing selector degrades one
feature instead of crashing. Only two selectors are load-bearing —
`setBrightness:forKeyboard:` and `brightnessForKeyboard:` — and their absence
fails init with a targeted error.

**Verified selector surface (macOS 26, this machine).** `dump`
(`class_copyMethodList`) and `sig` (`method_getTypeEncoding`) print the real
runtime surface and the real argument types. The full class includes a
notably richer set than the v0.1 table guessed:

| Selector | Types (verified via `sig`) | Role |
|---|---|---|
| `setBrightness:forKeyboard:` | `(float, u64) → BOOL` | **load-bearing** set |
| `brightnessForKeyboard:` | `(u64) → float` | **load-bearing** read (bookkeeping) |
| `backlightLevelForKeyboard:` | `(u64) → float` | second read-back (also bookkeeping) |
| `setBrightness:fadeSpeed:commit:forKeyboard:` | `(float, **int**, BOOL, u64) → BOOL` | fade-controlled set (see below) |
| `copyKeyboardBacklightIDs` / `isKeyboardBuiltIn:` | — | enumeration |
| `enableAutoBrightness:forKeyboard:` / `isAutoBrightnessEnabledForKeyboard:` | — | ALS control (§6.1) |
| `suspendIdleDimming:forKeyboard:` / `isIdleDimmingSuspendedOnKeyboard:` | — | idle-dim control |
| `registerNotificationForKeys:keyboardID:block:` | — | change notifications (unused; block sig un-reversed) |

**The `fadeSpeed:commit:` lesson.** This selector looked like it might set a
sub-floor value directly (with a fade), potentially retiring the whole dither
approach. It did not — every fade/commit combination clamped at the floor just
like the plain setter. But verifying its *types* before calling it was
essential and nearly non-obvious: `sig` revealed `fadeSpeed` is a 32-bit
**int** (an enumerated speed), not the `Double` we first guessed. On arm64,
floating-point arguments travel in a separate register file (v0–v7) from
integers (x0–x7), so declaring `fadeSpeed` as `Double`/`Float` would have
placed it in a v-register and shifted every subsequent integer argument down
one slot — `commit` would have received the keyboard ID's bits and `keyboardID`
would have been garbage. It would not have crashed; it would have silently
commanded a nonexistent keyboard, and we might have misread the resulting
nothing as "fade doesn't help." **Principle: introspect a private method's
type encoding before calling it; a guessed signature can be ABI-wrong in ways
that fail silently.**

Keyboard identification prefers `copyKeyboardBacklightIDs` filtered by
`isKeyboardBuiltIn:`; both are present here, so the heuristic fallback (ID 1)
is not exercised.

## 5. The dither mechanism — corrected

### 5.1 Why dithering at all, and what actually integrates it

Since a static sub-floor level is impossible (§3-A), the only way under the
floor is to alternate between two *rendered* values — the floor and off (0) —
and rely on something to integrate them into a perceived average below the
floor. The v0.1 plan named the wrong integrator (a daemon fade ramp, which
does not exist). The correct picture:

- The **commanded** value has no fade — it jumps (§3-B). But the **physical
  LED/driver** has its own response time; the light does not snap
  instantaneously. This physical smoothing, *not* any software ramp, is what a
  sub-floor dither actually rides.
- The **eye** provides a second low-pass stage (flicker fusion), which for a
  dim source has a lower fusion threshold than for a bright one
  (Ferry–Porter).

### 5.2 The usable band, and why it is narrow

Two walls squeeze the usable frequency range from both sides:

- **Below ~5 Hz:** the LED fully completes each swing, so you see distinct
  pulses (visible flicker), though the average is dim.
- **Above 8 Hz:** the daemon stops honouring the dither (§3-C). The keys fall
  to complete darkness for a second or more at a time, recurring every one to
  three seconds — not a steady light, and not a dim one.

The usable band sits in between. Measured on this machine (see
[`COREBRIGHTNESS.md`](COREBRIGHTNESS.md) §4 for every run):

| Frequency | Observed result |
|---|---|
| 2–3 Hz | clear, obtrusive pulsing; dim on average |
| ~6 Hz | steady visible flicker, dim; peripherally tolerable |
| 7–8 Hz | steady visible flicker, dimmest; **holds a five-minute soak** |
| ≥ 8.5 Hz | **dark envelopes** — the daemon has stopped honouring the dither |

**There is no flicker-free result.** An observer watching a 7.0 Hz and an
8.0 Hz dither reports clear flicker at both. Fusing it would require a shorter
cycle than the daemon will accept, so it is not reachable at any setting. What
8 Hz buys is *dimmest and steadiest*, not *invisible*. The ceiling ships at
**8.0 Hz**: 0.5 Hz of margin below the lowest frequency ever observed to fail.

### 5.3 Implementation

`DitherEngine` runs one `DispatchSourceTimer` (`.strict`, ~1 ms leeway, on a
dedicated `userInteractive` queue), alternating the two targets. At 3–8 Hz
(100–200 ms periods) a timer is more than accurate enough and does not spin the
CPU. The perceived level is set by the **duty** — the fraction of each period
spent at the floor; the first-order model is `L ≈ duty × floor`. The engine is
idle at or above the floor (a single direct set) and only runs while holding a
sub-floor level.

`BacklightController.setLevel(_:)` is the unified entry point: `~0` → direct
off; `(0, floor)` → dither at `controller.period` with `duty = level/floor`;
`≥ floor` → direct set, idle. The CLI's `dither-test` harness (its `--slow` and
`--fine` sweeps, with an A/B floor comparison) is what mapped §5.2; it doubles
as the per-macOS-release smoke test.

### 5.4 Energy

While holding a sub-floor level the engine issues `2 × frequency`
setBrightness calls per second (≤ 20/s at these frequencies) — small, and only
while active. Above the floor it is fully idle. Auto-brightness is suspended
while dithering (§6.1) and restored on exit.

## 6. System integration

### 6.1 Auto-brightness (ambient light sensor)

macOS keyboard auto-brightness fights a dither by issuing its own targets
between ticks — and in early testing it was **the source of the flicker** we
first saw on static holds. Entering a sub-floor state therefore saves and
disables auto-brightness (`enableAutoBrightness:NO`); leaving restores it.
This is not optional polish; it is required for a clean result.

### 6.2 Sleep, wake, idle dim

`backlightd` restores its own idea of brightness on wake and would stomp a
hold, so the app suspends dithering on `willSleepNotification` and re-applies
the active mode after `didWake`/`screensDidWake` (with a settle delay). Idle
dim: `suspendIdleDimming:forKeyboard:` exists and is the clean lever if a
future version needs to prevent the OS dimming the keys during a hold; v0.2
does not wire a policy around it.

### 6.3 Read-back honesty (the load-bearing principle)

Both `brightnessForKeyboard:` and `backlightLevelForKeyboard:` proved to be
daemon bookkeeping, not LED truth (§3-A). Every consumer of read-back in this
codebase treats it as advisory only, and every real conclusion in this
document was reached by **eye**, not by API return value. This is the same
lesson as the CoreGraphics display-gamma regression, where the API reported a
written table that the display pipeline silently ignored. It bit us twice here
(the clamp, then the coalescing) and is the single most important thing to
carry into any future work on this surface.

## 7. Safety

**Restore discipline.** The backlight must always be one obvious action from
normal. Four independent restore paths: the app's "Restore system control"
button and "Quit" (both call `panicRestore`), `willTerminateNotification`
(Cmd-Q / system termination), and the CLI's `restore` command, which builds a
fresh bridge and works even after a `kill -9`. `panicRestore` is unconditional
— stop the dither, force auto-brightness on, set a visible level — so it is
safe from any state. Residual risk: a hard kill during the *off* phase of a
dither leaves the backlight off until `restore` is run or a brightness key is
pressed; documented, and harmless.

**Photosensitivity (central for the pulse feature).** The usable dither band
(§5.2) is 3–8 Hz, and the sub-floor *pulse* modes (5–6 Hz) sit squarely in the
3–30 Hz photosensitive-epilepsy trigger range (peak risk ~15–20 Hz). What
keeps real risk low here is that the stimulus is a small, dim light in lower
peripheral vision — seizure risk scales hard with visual-field coverage,
luminance, and contrast, and a dim keyboard is a sliver of the field at low
brightness. Two rules follow and are enforced in the UI/CLI: keep it dim
(brightness is capped sub-floor; don't crank it for a "stronger" effect), and
the photosensitivity warning travels with the feature. The 8 Hz mode reads
as steady and is the recommended everyday mode; 5–6 Hz pulse is opt-in novelty.

**Efficacy honesty.** The "pulse mode" is framed as experimental with no health
claims. Flicker at a frequency does produce a real frequency-locked cortical
response (SSVEP / photic driving), but the popular mapping of theta/alpha/beta
flicker to drowsiness/relaxation/cognition is weakly evidenced — small,
often commercially-funded studies with high individual variability. The UI
says "effects unproven" and means it. (It also cannot reach the alpha/beta
bands anyway: >8 Hz stops being honoured, so only theta/low-alpha flicker is even
producible here.)

## 8. Architecture

```
sublight/
├── Package.swift              SwiftPM — 3 targets, 0 dependencies
├── Sources/
│   ├── SublightKit/           the engine (UI-free, auditable, reusable)
│   │   ├── KeyboardBrightnessBridge.swift   §4  private-API bridge + sig/dump
│   │   ├── DitherEngine.swift               §5  timer-based dither
│   │   ├── BacklightController.swift        §5.3 unified setLevel routing
│   │   ├── HardwareInfo.swift               model/chip detection, Apple-Silicon gate
│   │   ├── HotKey.swift                     Carbon RegisterEventHotKey wrapper
│   │   ├── Log.swift                        os.Logger categories
│   │   └── SystemEvents.swift               §6.2 sleep/wake
│   ├── sublight-cli/main.swift              CLI + the whole probe harness
│   └── SublightApp/                         menu-bar app
│       ├── SublightApp.swift                MenuBarExtra + Settings scenes
│       ├── AppState.swift                   state, schedule, fade, crash marker
│       ├── MenuView.swift                   popover: Simple / Advanced
│       ├── SettingsView.swift               General / Safety / About
│       ├── CalibrationController.swift      §9.1 guided A/B calibration
│       ├── CalibrationView.swift            calibration sheet
│       ├── OnboardingView.swift             first-run window
│       └── HotKeyChoice.swift               preset shortcut table
├── assets/icons/                            brand masters: SVG + 1024px PNG (on/off), animated README logo;
│                                            .icns is built at bundle time by make_app.sh (sips + iconutil → build/,
│                                            gitignored); menu bar glyph is code-drawn in StatusGlyph.swift
├── scripts/  (Info.plist, make_app.sh)      bundle + ad-hoc sign
└── docs/  (SPEC, ROADMAP, APPSTORE_AND_HEALTH)
```

The app presents **two independent axes** — brightness and frequency — and
splits them across two audiences, because the hardware couples them inversely
(higher frequency is dimmer *and* steadier, so the "calm" low frequencies are
also the brightest). A single scale cannot express both without making "High"
ambiguous.

- **Simple** shows one axis: an on/off toggle and a brightness slider, running
  at a fixed frequency (the calibrated steadiest value, or 8 Hz until
  calibration has run). Frequency is never mentioned.
- **Advanced** shows both: preset chips at **3 / 6 / 8 Hz**, a **2–8 Hz**
  custom slider, and a *separate* brightness slider — two independent knobs, so
  the inverse coupling becomes a starting point to adjust rather than a trap.

Brightness maps to dither duty (`0.15…0.85`, always sub-floor). Everything
routes through `BacklightController.setLevel`, the same path the CLI validated.
All mode use sits behind a one-time photosensitivity acknowledgment (§7).

## 9. Validation — the record

Every conclusion here came from an on-device, human-in-the-loop harness, run in
this order (which also serves as the per-macOS-release smoke test):

1. `dump` — confirm the two load-bearing selectors exist on this build.
2. `sig` — confirm argument *types* before any fade call (§4).
3. `probe` — clamp sweep + dual read-back → **direct sub-floor is clamped;
   read-backs are bookkeeping** (§3-A).
4. `probe --ramp` — **no software fade to ride** (§3-B).
5. `dither-test` (fast band) — **60–240 Hz coalesces to nothing** (§3-C).
6. `dither-test --slow` / `--fine` (A/B vs floor) — **map the 3–8 Hz band**
   (§5.2). *(Historical note: this step originally recorded "~10 Hz fuses to
   steady dim". It does not — see [`COREBRIGHTNESS.md`](COREBRIGHTNESS.md).)*
7. `pulse low|medium|high` — the three presets, continuous.
8. The app — the presets as a menu-bar feature.

Re-run 1–6 after any macOS update and diff `dump`/`sig`; the private surface is
undocumented and can change.

### 9.1 In-app calibration

The harness above is how the mechanism was mapped on one machine. Calibration
is that same procedure turned into something a stranger can run on hardware we
have never seen, because **two of the numbers this app depends on are not
universal**:

- the **floor** is a property of the machine (where its driver clamps), and
- the **steadiest usable frequency** is partly a property of the *person* —
  flicker fusion varies between individuals, so 8 Hz reading as tolerable here says nothing about
  anyone else's eyes.

Three steps, in `CalibrationController`:

1. **Floor — bisection on "does it flicker?"** Below the clamp every commanded
   value renders identically, so the test alternates a known sub-floor
   reference with a candidate at ~1 Hz and asks whether the light changes at
   all. Visible flicker means the candidate rendered differently, and therefore
   cleared the clamp; rock steady means it is still clamped. Five rounds bisect
   `0.005…0.30`. These are **direct bridge writes** that deliberately bypass
   `BacklightController.setLevel` — routing through it would engage the dither
   and measure the dither rather than the clamp.

   **This step was redesigned after it produced contradictory results.** The
   original version showed the reference and the candidate once each, in
   sequence, and asked "was the second brighter?" On the reference machine that
   converged on a floor of 0.1248 — roughly double the 0.0625 the probe had
   found. A follow-up check settled it: commanding 0.0625 and 0.1248 in turn
   produced *no visible difference at all*, so both were clamped and the
   calibrated figure was wrong.

   The fault was the question, not the arithmetic. Judging "was that brighter?"
   requires holding a brightness in memory across a two-second gap, which people
   do badly, and the bisection's failure mode is asymmetric: answering "the
   same" when unsure raises the lower bound, so hesitation inflates the result.
   Flicker detection is by contrast one of the most sensitive things the visual
   system does, and alternating the two levels turns an unreliable memory task
   into an immediate perceptual one.

   **Worth noting for anyone tempted to obsess over this number:** on hardware
   where several commanded values land on the same rendered plateau, the exact
   floor matters less than it appears. The dither's contrast comes from
   floor-versus-*off*, so any value that renders at the minimum produces the
   same result. It matters only when an overestimate crosses onto a genuinely
   brighter step, which is what the redesigned test is there to prevent.
2. **Flicker-free frequency — bisection on "steady or pulsing?"** Five rounds
   over `2…11 Hz` at duty 0.5. The ceiling is 11 rather than 12 on purpose:
   past 8 Hz the daemon stops honouring the dither (§3-C) and the light fails *because
   it has stopped dithering*, which is "steady" for the wrong reason and no
   longer sub-floor. A result at the ceiling is flagged in the summary rather
   than silently returned as a good number.
3. **Preferred level — a live slider.** Not a bisection: preference is
   something you set, not something you converge on.

Results are keyed by `HardwareInfo.modelIdentifier`, so moving to a different
Mac falls back to defaults and re-prompts instead of silently applying numbers
measured on someone else's machine.

**The shipped defaults are a guess.** The default floor (0.0625) and frequency
were measured on one MacBook Air. On a machine whose real floor is higher, the
dither's high value sits below the actual clamp and dimming will feel weak or
absent — which reads as "the app is broken" rather than "this machine needs
calibrating". That is the single most likely first-run complaint from other
hardware, and calibration is the answer to it.

## 10. Distribution

Ad-hoc signing (`make_app.sh`) suffices for the build machine. Sharing binaries
needs Developer ID + Hardened Runtime + notarization (a paid $99/yr account; a
free team can sign locally but not notarize). Notarization is a malware scan,
not an API review, so private-API use is not a barrier — but the Mac App Store
is permanently off the table for the same private-API reason. Primary
distribution is source: `git clone && swift build`.

## 11. Roadmap

**Done (v0.3):** the mechanism is characterized; sub-floor dimming works;
hybrid Simple/Advanced UI with 3/6/8 Hz presets and a 2–8 Hz custom slider;
per-machine guided calibration (§9.1); manual time-of-day scheduling;
launch-at-login (`SMAppService`); a dependency-free global hotkey (Carbon
`RegisterEventHotKey`); first-run onboarding with the safety gate; a menu-bar
icon that reflects active/idle; fade on transitions and slider debounce;
crash-safe restore with structured logging; Apache-2.0 licensing with DCO.

Solar (sunset/sunrise) scheduling is also shipped, computed locally from a
manually-entered location — deliberately *not* CoreLocation, which would add a
permission prompt and may resolve position over the network, breaking the
no-network rule below.

**Next:** signing, notarization and a DMG.

**Parked:** yield-to-manual-control. The original design released the hold when
the user pressed a keyboard-brightness key — but the reference machine (M4
MacBook Air) has no such keys (F5/F6 are dictation and Focus), so there is
nothing to yield to. The remaining manual path is Control Center's slider,
which our own writes dominate in read-back, and detecting it would need the
`registerNotificationForKeys:` key identifiers reversed first (its `keys`
argument is an object we never decoded — see §4). Low value, high effort.

**Researched, not promised:** ambient-light-driven auto-enable. Room darkness
is a better trigger than the clock, but reading raw lux is another private-API
expedition and it conflicts with the auto-brightness suppression in §6.1.

**Permanent non-goals:** any network call, analytics, or telemetry — which also
rules out an auto-updater; Intel support; per-key effects; Mac App Store; any
health claim for the pulse feature.

## 12. Findings (was: open questions)

The v0.1 open-questions table is now a findings record.

| # | Question | Finding |
|---|---|---|
| 1 | Exact clamp floor | ~0.0625 (`backlightLevel ≈ 1.0`); sub-floor commands accepted but not rendered |
| 2 | Are sub-floor values honored by a plain set? | **No** — clamped at the floor (confirmed by eye, auto off) |
| 3 | Is there a software fade ramp to ride? | **No** — commanded value jumps; only the *physical* LED response smooths |
| 4 | Read-back: LED truth or bookkeeping? | **Bookkeeping** — both read-backs echo/rescale the command; neither tracks the LED |
| 5 | Does the daemon rate-limit rapid commands? | **No — it limits the CYCLE PERIOD.** 125.0 ms holds, 117.6 ms fails; doubling writes/s at a fixed period changes nothing. 60–240 Hz produces no modulation |
| 6 | Does the `fadeSpeed:commit:` setter reach sub-floor? | **No** — clamps like the plain setter; `fadeSpeed` is an int enum (verified via `sig`) |
| 7 | Is there a usable dither band? | **Yes, 3–8 Hz** — all of it visibly flickering. 8 Hz is dimmest and steadiest; nothing fuses |
| 8 | Selector/type drift risk on future macOS | Standing — `dump`/`sig` are the tripwire; re-run per release |
| 9 | Photosensitivity | Real caveat; low personal risk (small/dim/peripheral); warning + dim caps enforced |
| 10 | Apple removes `KeyboardBrightnessClient` | Standing — bridge fails cleanly; project pauses until a new surface is found |

## 13. References

- Public class-dump repositories documenting CoreBrightness (e.g.
  LeoNatan/Apple-Runtime-Headers; nst/iOS-Runtime-Headers).
- First-hand accounts of driving `KeyboardBrightnessClient` via
  `dlopen`/Objective-C runtime from a notarized app.
- pirate/mac-keyboard-brightness (Intel-era IOKit `AppleLMUController`;
  historical, dead on Apple Silicon).
- The commercial prior art whose FAQ describes a duty-cycle-via-oscillation
  mechanism (acknowledged; no implementation taken).
- CoreGraphics display-gamma regression reports (FB22273730 / FB22273782) —
  the "API success is not hardware truth" precedent behind §6.3.
