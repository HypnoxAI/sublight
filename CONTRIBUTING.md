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
probe (category `probe`), and one signpost per dither edge (`ON` / `OFF`,
category `engine`):

```bash
log stream --predicate 'subsystem == "com.hypnox.sublight"' --info
log show --signpost --predicate 'subsystem == "com.hypnox.sublight" AND category == "engine"' --last 2m
```

The signpost timestamps are how timing regressions are measured: ON-to-ON
spacing is the period, OFF offset from its ON edge is the duty.

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
