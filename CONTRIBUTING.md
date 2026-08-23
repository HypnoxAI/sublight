# Contributing to Sublight

Thanks for your interest in contributing! Sublight is licensed under the
**Apache License 2.0**, and contributions are accepted under the same license.

## Developer Certificate of Origin (DCO)

This project uses a **DCO** rather than a CLA — there is nothing to sign and no
agreement to email. You simply certify, per commit, that you have the right to
submit your contribution under the project's license. You do this by adding a
`Signed-off-by` line to your commit message:

```
git commit -s -m "Your commit message"
```

`-s` automatically appends:

```
Signed-off-by: Your Name <your.email@example.com>
```

(Configure `git config user.name` and `git config user.email` first, using your
real name and a real email.) By signing off, you agree to the Developer
Certificate of Origin 1.1, reproduced below.

## How to contribute

1. Open an issue to discuss substantial changes before starting.
2. Fork, branch, and make your change. Note that Sublight uses **undocumented
   private Apple APIs** and behaves differently across Macs and macOS versions —
   validate on real hardware (see the runbook in `README.md`).
3. If you modify a file, keep its SPDX header and add a prominent note that you
   changed it (Apache 2.0 §4(b)).
4. Sign off every commit (`-s`) and open a pull request.

## Observing the engine

Everything the engine does is in the unified log under the app's bundle
identifier — start/stop/restore, the dirty flag, suspend/resume, the launch
probe (category `probe`), and signposts per dither edge (category `engine`):

```bash
log stream --predicate 'subsystem == "com.hypnox.sublight"' --info
log show --signpost --predicate 'subsystem == "com.hypnox.sublight" AND category == "engine"' --last 2m
```

The signpost timestamps are how timing regressions are measured: ON-to-ON
spacing is the period, OFF offset from its ON edge is the duty.

### Command truth

A scheduled edge, an edge whose handler actually ran, and a command that
actually reached the daemon are three different things, and conflating them is
how a timing bug hides. The signposts keep them apart:

| signpost              | meaning                                              |
| --------------------- | ---------------------------------------------------- |
| `EDGE_HIGH`/`EDGE_LOW`| the edge timer's handler ran                          |
| `ON` / `OFF`          | a `setBrightness` command was issued to the daemon    |
| `SKIP_HIGH`           | the edge ran and the err-dark rule refused to command |
| `XPC` (interval)      | one daemon call, begin to return — its round trip     |

Per-command detail — monotonic timestamp, requested value, `fadeSpeed`,
`commit`, whether the daemon accepted it, and the round-trip latency — is
logged at **debug** level, which the unified log does not persist by default:

```bash
log stream --level debug --predicate \
  'subsystem == "com.hypnox.sublight" AND category == "engine"'
```

The same facts are summed into counters (`scheduled` / `fired` / `executed` /
`skipped` per edge, plus latency percentiles, the longest gap between executed
ON commands, and the longest run of consecutive err-dark skips). Read them with:

```bash
sublight-cli status                       # this process, plus the last recorded run
sublight-cli hold --freq 9 --duty 0.15 --seconds 30            # engine path, timed
sublight-cli hold --freq 9 --duty 0.15 --seconds 30 --sample-hz 20   # + read-back poll
sublight-cli pair-sweep --on-ms 16        # raw ON/OFF pairs, engine bypassed
sublight-cli hold --freq 6 --duty 0.15 --seconds 30 --pad-writes   # 2x write rate, same period
```

Neither read-back is an output oracle — see the measured notes on
`brightness(_:)` and `backlightLevel(_:)` in `KeyboardBrightnessBridge.swift`.
`--sample-hz` exists to characterise them, not to trust them, and it polls on
the engine queue where it can stall an edge; do not leave it on.

`scheduled - fired` is the number of deadlines a repeating `DispatchSourceTimer`
coalesced away while its queue was blocked; `fired - executed` is what engine
policy declined to send. Both read as darkness on the keys and neither is
visible from the LED alone.

### The menu bar glyph

The status item is drawn in code (`Sources/SublightKit/StatusGlyph.swift`), never
bundled as an image. **Any change to it must regenerate the legend** so the docs
cannot drift from the geometry:

```bash
swift build -c release --product sublight-cli
.build/release/sublight-cli glyph render --out /tmp/glyph
cp /tmp/glyph/sublight-menubar-states.png assets/icons/
```

The render is deterministic — an unchanged glyph produces byte-identical output,
so a diff there means the drawing really did change.

## Scope reminders

Sublight is intentionally narrow: Apple Silicon MacBooks with a backlit
keyboard, zero third-party runtime dependencies, no network calls, no analytics,
and **no health claims** for the pulse feature. Please keep contributions within
these bounds (see `docs/ROADMAP.md` for permanent non-goals).

---

## Developer Certificate of Origin 1.1

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```
