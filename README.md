<p align="center">
  <img src="assets/icons/sublight-logo-animated.svg" width="200" alt="Sublight">
</p>

<div align="center">

# Sublight

**Dim your MacBook's keyboard backlight below the macOS minimum.**

Free and open source · Apache 2.0 · zero dependencies · zero network calls

</div>

---

macOS clamps the keyboard backlight to a lowest step that is still too bright in
a genuinely dark room. Sublight goes *below* it.

It cannot do that with a static setting — the hardware refuses — so it dithers
the backlight faster than the eye resolves. At the right speed this fuses into a
**steady, dim, flicker-free glow**. Lower speeds read as a gentle visible pulse
and are offered as an experimental extra.

<!-- SCREENSHOTS: replace these placeholders before publishing.
     1. menu bar + popover in Simple mode
     2. Advanced mode showing the frequency controls
     3. Settings → General
     4. the calibration sheet mid-flow
-->
<div align="center">
<em>(screenshots go here)</em>
</div>

## ⚠️ Read this first

- **Photosensitivity.** Sublight dims by flickering the backlight, in the
  2–8 Hz range — which can trigger seizures in people with photosensitive
  epilepsy. The light is small, dim, and in peripheral vision, so the risk is
  low, but **if you have any history of photosensitivity or epilepsy, do not use
  this app.** See [`DISCLAIMER`](DISCLAIMER).
- **Effects are unproven.** Flickering light produces a measurable response in
  the visual cortex, but there is no reliable evidence it improves mood, focus,
  or sleep, and Sublight claims none. It is not a medical device.
- **Private API.** Sublight drives the backlight through Apple's private
  `CoreBrightness` framework. Apple can change or remove it in any update. Calls
  are guarded and fail gracefully, but expect to re-verify after macOS updates.
- **No warranty** (Apache 2.0, see [`LICENSE`](LICENSE)). This cannot ship on the
  Mac App Store — private API plus the required sandbox — see
  [`docs/APPSTORE_AND_HEALTH.md`](docs/APPSTORE_AND_HEALTH.md).

## Requirements

- **Apple Silicon MacBook with a backlit keyboard.** Intel Macs and external
  keyboards are not supported and never will be.
- **macOS 14 or later.** Honest caveat: development and testing have happened
  **only on macOS 26** on a MacBook Air (M4). Earlier versions should work — the
  APIs used are available — but are untested. Reports welcome.
- Xcode Command Line Tools (`xcode-select --install`)

## Install

No signed release yet, so build from source:

```bash
git clone https://github.com/<you>/sublight.git && cd sublight
swift build -c release --product SublightApp
./scripts/make_app.sh
open build/Sublight.app
```

To keep it, drag `build/Sublight.app` to `/Applications` — the login item only
persists from a stable location.

The CLI (also the reverse-engineering and validation harness) builds separately:

```bash
swift build -c release --product sublight-cli
.build/release/sublight-cli help
```

## Using it

Sublight lives in the menu bar — no Dock icon, no window. The glyph's keys are
hollow while the backlight is under system control and fill from the right as
Sublight takes over.

**First launch** walks through a short onboarding: what the app does, the safety
warning (with an acknowledgment you have to tick), and an offer to calibrate.

**Simple mode** is one switch and a brightness slider. It runs at a fixed
flicker-free frequency and never mentions Hz. This is the right mode if you just
want dim keys.

**Advanced mode** exposes the second axis: preset frequencies at **3 / 6 / 8 Hz**,
a **2–8 Hz** custom slider, and a separate brightness slider. Frequency and
brightness are inversely coupled on this hardware — higher frequencies are
dimmer *and* steadier — so they're presented as two independent knobs.

| Off — system control | On — Sublight active |
|---|---|
| ![off](assets/icons/sublight-icon-off-1024.png) | ![on](assets/icons/sublight-icon-1024.png) |

**Schedule** dims automatically, either between two fixed times or from
**sunset to sunrise**. It acts on transitions, so you can still override it by
hand in between. In Advanced mode the schedule can run at its own frequency.

Solar scheduling needs to know roughly where you are. Pick your city from the
list in Settings — it's usually already selected, because Sublight matches your
Mac's time zone on first run — or enter coordinates by hand.
Sublight deliberately does *not* use CoreLocation: that would spend a permission
prompt, and macOS location services commonly resolve position over the network —
which would quietly break this app's no-network promise. The sunrise/sunset maths
runs locally, and your coordinates never leave the machine.

**Global shortcut** (Settings → General) toggles dimming from anywhere. Four
presets; no Accessibility permission needed.

**Settings** (⌘, or the gear) holds launch-at-login, the shortcut, calibration,
reset, the full safety text, and version info.

### If the backlight gets stuck

Press the keyboard brightness keys — the system takes control back immediately.
Relaunching Sublight (or running `sublight-cli restore`) also auto-restores: a
crash leaves a flag that the next launch heals before doing anything else.

## Calibrate — please actually do this

The shipped defaults were measured on **one** MacBook Air. Two numbers vary:
where *your* keyboard's backlight actually bottoms out, and how fast it has to
flicker before *you* stop seeing it. If dimming feels weak or absent on your
machine, this is almost certainly why.

**Settings → General → Calibrate**, in a dark room, about a minute. Three steps:
a brighter/same comparison to find the hardware floor, a steady/pulsing
comparison to find your personal flicker threshold, then a slider for your
preferred level. Results are stored per Mac model.

## Hardware compatibility

Behaviour varies by machine. If you run Sublight, please add a row — calibrate, then file a
**Hardware report** issue (there's a template) or open a PR.

| Model identifier | Mac | macOS | Measured floor | Stability ceiling | Works |
|---|---|---|---|---|---|
| `Mac16,12` | MacBook Air 13" (M4) | 26 | ~0.0625 | 8 Hz (8.5 Hz fails) | ✅ |

**Stability ceiling** is the highest frequency the backlight daemon will actually
hold. It is a hardware/OS limit, not a claim about your eyes: above it the keys
fall dark for seconds at a time no matter how perfectly the commands are sent.
Flicker *fusion* is a separate, personal thing, and on the reference machine the
dither is still visible as flicker at the ceiling.

## Known limitations

- **Control Center's keyboard slider jitters** while Sublight is active *and*
  Control Center is open. Sublight writes the backlight value many times a
  second; Control Center polls it and redraws. Cosmetic, only visible when
  you're looking at it, and inherent to dithering.
- **Above ~10 Hz macOS starts merging the commands**, so the light can look
  steady because it has stopped flickering — not because your eye fused it. That
  also means it stops going below the floor. Calibration flags this if your
  result lands at the ceiling.
- **Yield-to-manual-control is parked**: the reference machine has no
  keyboard-brightness keys, so there is nothing to yield to. See SPEC §11.

## How it works

The private API cannot set a static level below the floor — it accepts the value,
reports success, and the driver clamps the actual light. The only way under is to
alternate between the floor and off; the LED's physical response and your eye's
flicker fusion average that into a sub-floor brightness. macOS coalesces commands
faster than ~10 Hz, and below ~5 Hz you see distinct pulses, so the usable band is
narrow.

The full account — including the reverse-engineering record, the dead ends, and
why API read-backs turned out to be daemon bookkeeping rather than LED truth — is
in [`docs/SPEC.md`](docs/SPEC.md).

## CLI reference

| Command | Purpose |
|---|---|
| `status` / `ids` | keyboard ID, reported level, auto-brightness state |
| `dump` / `sig` | private class's real selectors and their argument types |
| `get` / `set <0..1>` | read / write brightness (subject to the clamp) |
| `auto on\|off` | toggle keyboard auto-brightness |
| `probe [--fade\|--ramp]` | guided clamp, read-back and fade probes |
| `dither-test [--slow\|--fine]` | map the usable frequency band |
| `hold <0..1> [--period s]` | continuous dither at a level |
| `pulse <low\|medium\|high>` | continuous preset |
| `notify-probe` | change-notification spike |
| `restore [<0..1>]` | panic restore |

`hold` and `pulse` disable auto-brightness and restore it on Ctrl-C.

**If the backlight is ever left in a strange state** (e.g. after `kill -9`),
`sublight-cli restore` fixes it from any state. The app also self-heals on next
launch.

## Uninstall

```bash
rm -rf /Applications/Sublight.app
defaults delete com.hypnox.sublight 2>/dev/null || true
```

If you enabled launch-at-login, remove Sublight in
System Settings → General → Login Items.

## Contributing

Contributions welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). The project
uses a **DCO**, not a CLA: sign off commits with `git commit -s`.

Bug reports about hardware behaviour are far more useful with diagnostics
attached: **Settings → Diagnostics → Copy** gets everything relevant in one
block (and deliberately excludes your coordinates). For anything involving the
private API, add `sublight-cli dump` and `sublight-cli sig` output too.

Deliberate non-goals: any network call, analytics or telemetry (which also rules
out an auto-updater), Intel support, per-key lighting, the Mac App Store, and any
health claim for the pulse feature.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
Copyright 2026 Hypnox Technologies LLC.
