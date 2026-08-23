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

## Building and testing

```bash
swift build                                    # both products, debug
swift build -c release --product sublight-cli  # the CLI + probe harness
swift build -c release --product SublightApp   # the app binary
./scripts/make_app.sh                          # assemble + ad-hoc sign build/Sublight.app
swift test                                     # the pure-logic suite
```

Requires Xcode Command Line Tools and a Swift 6 toolchain. There is nothing to
install beyond that — the package has no dependencies and will never acquire
any.

### What CI proves, and what it cannot

CI runs `swift build` and `swift test` on a pinned macOS runner. That covers
everything deterministic: the anchor arithmetic, schedule windows, solar maths,
the dirty flag and consent markers, the command-truth counters, glyph geometry,
and the API-surface decision logic.

**It cannot tell you whether the keyboard actually dimmed.** No CI runner has a
backlit keyboard, the bridge resolves its class at runtime so nothing links
against CoreBrightness at build time, and the two read-back APIs are blind to
real LED output (see [docs/COREBRIGHTNESS.md](docs/COREBRIGHTNESS.md)). A green
check means the logic is sound, never that the light behaved.

### Hardware runbook

Anything touching the engine, the bridge, or the frequency band has to be
checked by eye, on a real machine, in a dim room:

```bash
sublight-cli dump            # the real method table on YOUR machine
sublight-cli sig             # true type encodings; must match, or the app self-disables
sublight-cli probe           # guided: clamp sweep, fade experiment, ramp shape
sublight-cli hold --freq 8 --duty 0.15 --seconds 30    # one engine run, with counters
sublight-cli status          # counters from the last recorded run
```

Read the counters, not your impression of them: `scheduled` / `fired` /
`executed` / `skipped` separate "the engine did not send it" from "the daemon
did not act on it", which is the distinction almost every backlight bug turns
on. Per-command detail is in the unified log at debug level (below).

If you changed the frequency band or the ceiling, re-run the five-minute soak
in the README's "Re-qualifying after a macOS update" and watch the keys at
roughly 0:30, 2:30 and 4:30.

## Formatting and style

No formatter is enforced; match the file you are editing. Four-space indent,
roughly 80–90 columns, and `// MARK:` sections in longer types.

Comments here carry more weight than usual. The codebase documents *why* —
which alternative was tried, what the hardware actually did, why an obvious
simplification is wrong — because most of its constraints are empirical and
invisible from the code. A comment that restates the line below it is noise; a
comment recording a measurement or a rejected approach is the point. If you
remove a constraint, remove the comment explaining it in the same change.

Commit messages are a plain subject and body. No generated or boilerplate
trailers; the DCO `Signed-off-by` line is the one exception, and it is
required.

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
