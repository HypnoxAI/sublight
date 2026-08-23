# Security Policy

Sublight makes no network calls, collects nothing, and runs entirely locally —
so its security surface is small, but not zero: it loads a private Apple
framework at runtime and ships a CLI that drives keyboard hardware.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** on this repository
(Security tab → "Report a vulnerability") rather than a public issue. Reports
are read by the maintainers at Hypnox Technologies. If you would rather not use
GitHub, open a public issue containing only "requesting a private channel" and
nothing else, and you will be given one.

Please include the macOS build, the Mac model identifier, and — for anything
touching the backlight path — `sublight-cli dump` output.

## What "supported" means here

Sublight talks to an interface Apple does not document and owes no stability.
Every signature it depends on was verified empirically, on a specific machine
and a specific OS build, on a specific date. **The supported configuration is
the API compatibility matrix in the [README](README.md#api-compatibility)** —
today, one row: macOS 26.6.1 (build 25G76) on `Mac16,12`.

- **Only the latest release is supported.** There is no backport branch.
- **Other macOS builds are untested, not unsupported.** They may work
  identically. Sublight does not guess: a launch-time probe compares every
  selector it needs against the exact Objective-C type encoding it was verified
  against, and on any mismatch the app **disables itself and says so** while the
  CLI exits 3 without touching the backlight. Refusing to run is the designed
  behaviour, not a failure.
- Reports that extend the matrix are welcome — see the hardware report template.

## In scope

- Anything that lets a process abuse the bridge beyond backlight control.
- Injection into the build or packaging scripts (`scripts/`).
- Any path by which the app could be made to touch the network, write outside
  its own Application Support directory, or read user data it has no business
  reading.
- A way to defeat the safety gate — anything that dims the keyboard without the
  recorded consent described in [SAFETY.md](SAFETY.md).

## Out of scope

- **The private-API dependency itself.** It is documented, deliberate, and the
  entire reason the project exists; see [docs/COREBRIGHTNESS.md](docs/COREBRIGHTNESS.md).
- **Apple changing or removing the interface in a macOS update.** Expected, and
  handled by the launch probe above.
- Ad-hoc code signing. Self-built copies are ad-hoc signed; that is a
  distribution limitation, stated plainly in the README, not a vulnerability.
- The backlight being left dark after a hard kill during a dither's off phase.
  Documented, recoverable with the brightness keys or a relaunch, and covered
  in [SAFETY.md](SAFETY.md).
