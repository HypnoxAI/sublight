# CoreBrightness: the research record

What is actually known about Apple's private keyboard-backlight interface on
Apple Silicon, how each thing came to be known, and what the evidence was.

Everything here was measured on **macOS 26.6.1 (build 25G76), `Mac16,12`
(MacBook Air 13", M4)**, between 2026-07-19 and 2026-08-23. None of it is
documented by Apple. None of it is guaranteed to survive an update. Where a
finding rests on one machine and one OS build — which is most of them — this
document says so rather than generalising.

For the design that follows from these findings, see [`SPEC.md`](SPEC.md). For
what any of it means if you are going to point it at your own eyes, see
[`../SAFETY.md`](../SAFETY.md).

---

## Methodology

Four instruments, in the order they became necessary.

### 1. Runtime lookup, never linking

`CoreBrightness.framework` is `dlopen`ed at run time and
`KeyboardBrightnessClient` resolved by name. Nothing is linked at build time, so
a renamed or removed class produces a clear error instead of a process that
will not launch. Every selector is checked with `responds(to:)` before use.

### 2. The `dump` / `sig` harness

Guessing a private signature from a class dump is how you get a crash or, far
worse, a call that *succeeds* with silently wrong arguments. So the CLI
introspects the live class instead:

- `sublight-cli dump` — the real instance-method list from the Objective-C
  runtime on *this* machine.
- `sublight-cli sig` — the true type encoding of each selector we depend on.

The encodings are then pinned in `APISurface.expectedEncodings` and re-checked
at every launch. On any mismatch the app disables itself and the CLI exits 3.
The rule is: never drive an interface whose shape you have not confirmed today.

### 3. Command-truth instrumentation

Watching the keys tells you what the LED did. It does not tell you what was
*asked* of the daemon, what the daemon *accepted*, or what our own engine
*declined to ask*. Those three are different, and a fault in the middle of a
working dither cannot be attributed without separating them. So every edge is
counted four ways (`EngineCounters`):

| counter | meaning |
|---|---|
| `scheduled` | a deadline came due, by anchor arithmetic |
| `fired` | the timer handler actually ran — the difference is what a repeating `DispatchSourceTimer` coalesced away while its queue was blocked |
| `executed` | a command was issued to the daemon |
| `skipped` | the handler ran and engine policy declined to command |

plus the round-trip latency of every mutating call, timed at the bridge seam
where it actually leaves the process, and signposts (`EDGE_HIGH`, `ON`,
`SKIP_HIGH`, …) that keep scheduling and commanding distinguishable in a trace.

### 4. Human-in-the-loop visual protocol

**Because the read-backs are blind** (finding 3), a person watching the keys is
the only oracle for what the LED is doing. That is a measurement instrument and
it is treated like one:

- One condition per run. Runs are announced with explicit `STEP <id> START` /
  `STOP` markers and a wall-clock epoch, so an external recording could be
  aligned against the command log.
- The observer reports from a fixed verdict menu — *dark envelope (with rough
  duration) / steady flicker / steady dim glow / other* — never a free-form
  impression, and never one that names the expected answer.
- Five-minute soaks use a glance protocol (roughly 0:30 / 2:30 / 4:30). The
  failure mode recurs every one to three seconds, so a glance is sufficient and
  does not require anyone to stare at a keyboard for five minutes.
- **Twenty-five-minute soaks** (glances at 0:30 / 10:00 / 18:00 / 22:00 / 25:00)
  exist because a defect with a ~20 minute onset was invisible to every shorter
  run — see finding 8. Two extra preconditions apply and both were learned the
  hard way: the machine must be left completely alone, because idle is the
  condition under test and the agent's own builds count as load; and there must
  be exactly ONE live engine, verified before starting and re-checked each
  keeper tick, because two engines on one daemon cannot be told apart afterwards
  from either one's counters.
- Verdicts from a run are collected AFTER it ends. Typing one mid-run is itself
  input on the machine under test.
- The agent never operates the camera and never simulates input.

---

## Findings

### 1. `fadeSpeed` is a 32-bit int, and mistyping it would have been silent

`setBrightness:fadeSpeed:commit:forKeyboard:` exists on macOS 26. Its true type
encoding, read from the runtime:

```
B36@0:8f16i20B24Q28
```

Read left to right: returns `BOOL`; `self` at 0, `_cmd` at 8; `float` brightness
at 16; **`int` fadeSpeed at 20**; `BOOL` commit at 24; `unsigned long long`
keyboard ID at 28. So `fadeSpeed` is a 32-bit integer — almost certainly an
enumerated speed selector, not a duration.

**Why this mattered more than it looks.** The first guess was that a "fade
speed" would be a floating-point number of seconds. On arm64 that guess does not
fail loudly, it fails *silently*: the calling convention passes floating-point
arguments in `v` registers and integers in `x` registers. Declaring `fadeSpeed`
as `Double` would place it in `v1` while the callee reads `w2`, and every
argument after it shifts into the wrong register — `commit` and the keyboard ID
would both be garbage. The call still returns `BOOL`. It might even return
`true`.

This is the reason the launch probe checks *type encodings* and not merely
selector existence. A selector that still exists with a changed argument type is
the dangerous case, not the reassuring one.

### 2. Sub-floor commands are clamped in hardware

The system will not display a keyboard backlight level below its lowest non-zero
step (≈0.0625 = 1/16 on this machine). A command below it is **accepted** —
returns `true`, and the read-back will happily echo it — while the light
displayed remains at the floor.

*Evidence:* the guided clamp sweep, `sublight-cli probe` Phase 2, which walks
0.0 → 0.25 and asks a human which rows are visibly distinct. This is the
founding observation of the project and predates the command-truth
instrumentation below; it rests on the guided probe rather than on one of the
instrumented runs, and it is the reason "the API reported success" is treated
here as worth nothing on its own.

The entire duty-cycle approach exists because of this finding: if a static
sub-floor level could be held, none of the rest of this document would need to.

### 3. Both read-back getters are blind to the LED

Two functions claim to report the current level:

- `brightnessForKeyboard:` → `float`
- `backlightLevelForKeyboard:` → `float`

The hypothesis the second one was probed for was that one reports the *commanded
target* and the other the *actual LED output* — which would have given us an
in-code oracle and removed the need for a human observer. **That hypothesis is
refuted. Neither reports output.**

*Evidence — 601 samples at 20 Hz during a 30 s dither at 9 Hz / duty 0.15, a
configuration in which the keys visibly went fully dark ten to thirty times:*

- The longest run of continuous zero read-back was **300 ms**. Runs of 400 ms or
  longer: **zero**.
- The per-second fraction of zero readings was **flat at 0.70–0.75 across all
  thirty seconds**. Not one second registers a dark episode.
- Nothing in the series has a 1–3 s cadence: 0 of 91 inter-arrival gaps for the
  anomalous value fell in that band.

**The phantom 0.1248.** `brightnessForKeyboard:` matched the last commanded
level in only **84.7 %** of samples. Every one of the 92 mismatches returned the
*same* value — **0.124844**, which is step 2 of the 16-step ladder, a value the
engine never commands. It was also observed at t = 4.8 ms of a *different* run,
before that run's first command. The getter therefore appears to serve a
persistent system-side setting intermittently, rather than the live level.

**`backlightLevelForKeyboard:` is not normalised to [0, 1].** It reports on a
~16× scale consistent with the step ladder:

| commanded | `brightnessForKeyboard:` | `backlightLevelForKeyboard:` | ratio |
|---|---|---|---|
| 0.0625 | 0.062500 | 1.010000 | 16.16 |
| — | 0.124844 | 1.917725 | 15.36 |
| 0 | 0.000000 | 0.000000 | — |

It moves in lockstep with the first getter, disagreeing only on samples that
straddle a transition in the ~0.5 ms between the two calls. It is a second view
of the same bookkeeping, not a second source of truth.

**They are also expensive.** `brightnessForKeyboard:` costs a p50 of **0.615 ms**
against **0.148 ms** for a *setter*, with a **21.1 ms outlier** — longer than the
entire 16.7 ms ON window at 9 Hz / duty 0.15. `backlightLevelForKeyboard:` costs
p50 0.242 ms, max 7.15 ms. Polling either one on the engine queue can therefore
stall an edge, which is why the sampler that measured this is a diagnostic flag
and not something left switched on.

**Consequence for everything else in this document:** the only instrument that
can see the LED is a person. That is why the visual protocol exists.

### 4. THE PERIOD LIMIT

**The backlight daemon will not honour a dither cycle shorter than ~125 ms.**
Above roughly 8.5 Hz the keys fall to complete darkness for a second or more at
a time, recurring every one to three seconds, indefinitely.

This is the central finding, it is the reason `DitherEngine.maxStableFrequencyHz`
exists, and it took three directives to isolate because three plausible causes
were collinear.

#### The full boundary table

Every run, in order of write rate. Every dither cycle is exactly two writes, so
writes/s = 2 × frequency except where padding was applied.

| freq | duty | period | ON ms | OFF ms | writes/s | duration | verdict |
|---|---|---|---|---|---|---|---|
| 3.0 | 0.15 | 333.3 | 50.0 | 283.3 | 6 | 30 s | steady |
| 4.5 | 0.70 | 222.2 | 155.6 | 66.7 | 9 | 30 s | steady |
| 6.0 | 0.15 | 166.7 | 25.0 | 141.7 | 12 | 30 s | steady |
| 6.0 | 0.50 | 166.7 | 83.3 | 83.3 | 12 | 30 s | steady |
| 7.0 | 0.15 | 142.9 | 21.4 | 121.4 | 14 | **300 s** | **steady** |
| 7.0 | 0.50 | 142.9 | 71.4 | 71.4 | 14 | 30 s | steady |
| 7.5 | 0.15 | 133.3 | 20.0 | 113.3 | 15 | 30 s | steady |
| 7.5 | 0.15 | 133.3 | 20.0 | 113.3 | 15 | **300 s** | **steady** (5 skips, §6) |
| 8.0 | 0.15 | 125.0 | 18.8 | 106.3 | 16 | 30 s | steady |
| 8.0 | 0.15 | 125.0 | 18.8 | 106.3 | 16 | **300 s** | **steady** |
| — | | | | | | | ← **boundary** |
| 8.5 | 0.15 | 117.6 | 17.6 | 100.0 | 17 | 30 s | **dark, 0.5–1 s** |
| 9.0 | 0.15 | 111.1 | 16.7 | 94.4 | 18 | 30 s | **dark, >1 s** |
| 9.0 | 0.50 | 111.1 | 55.6 | 55.6 | 18 | 30 s | **dark, >1 s** |
| 9.0 | 0.15 | 111.1 | 16.7 | 94.4 | 18 | 30 s | **dark, every 1–3 s** (read-back sampled) |
| 6.0 | 0.15 | 166.7 | 25.0 | 141.7 | **24** (padded, same step) | 30 s | steady |
| 6.0 | 0.15 | 166.7 | 25.0 | 141.7 | **24** (padded, cross-step) | 30 s | steady |

**What the table rules out.** Sorting by ON window gives no separation (16.7
dark, 20.0 steady, 55.6 dark, 83.3 steady). Sorting by OFF window gives none
either (66.7 steady sits between 55.6 dark and 83.3 steady; 100.0 dark sits
between 94.4 dark and 113.3 steady). Duty appears on both sides — 0.15, 0.50 and
0.70 all steady; 0.15 and 0.50 both dark. Only the **period** separates every
row cleanly, at **125.0 ms holds / 117.6 ms fails**.

#### Period, not command rate — and not de-duplication

Period and write rate are rigidly reciprocal for a two-writes-per-cycle engine,
so the table alone cannot separate "cycles too short" from "too many commands
per second". The `--pad-writes` diagnostic breaks that tie by sending each edge
command twice, doubling the rate while the period is untouched:

- **24.1 writes/s through an unchanged 166.7 ms period: steady.** So it is the
  period, not the rate.

That result had one hole. If the daemon de-duplicated writes, the padding would
be discarded and the rate would not really have doubled — and the first padded
run used an offset of 0.002, so both writes of each pair landed inside the same
1/16 output step. A dedupe keyed on the *step* rather than the exact value would
have produced exactly the observed result for entirely the wrong reason. So it
was re-run with the offset raised to a full step, HIGH sending 0.1250 → 0.0625
and LOW sending 0.0625 → 0.0000, so that **every consecutive pair lands in a
different output step and nothing can collapse them**:

- **24.1 writes/s, cross-step, unchanged period: still steady.** Dedupe is
  excluded. **The cycle period is the causal variable.**

#### What failure looks like

At 9.0 Hz / duty 0.15, over 30 s: complete darkness for **more than a second**
at a time, recurring **every one to three seconds** — on the order of ten to
thirty episodes per 30 s run. At 8.5 Hz the episodes are shorter, 0.5–1 s. Duty
does not change it. Neither read-back API registers any of it (finding 3).

#### The engine is not involved

Across **9,270 HIGH edges** in the fifteen instrumented runs:

| | |
|---|---|
| scheduled | 9,270 |
| executed | 9,265 |
| skipped (err-dark) | 5 — see §6 |
| coalesced by the timer | **0** |
| commands the daemon rejected | **0** |
| longest gap between executed ON commands | nominal period + ≤ 7.6 ms |
| daemon round-trip latency | p50 0.15 ms, p95 ≈ 0.21 ms |

The dark envelopes happened while commands were arriving on schedule, in order,
and being accepted. Whatever the daemon is doing with them, it is doing after
`setBrightness:forKeyboard:` returns `true`.

### 5. The suppression flags flip back on their own, mid-run

Sublight turns keyboard auto-brightness **off** and suspends idle dimming
before it starts dithering, because either one would otherwise move the
backlight out from under the hold. Those are not fire-and-forget: **something
in the system turns auto-brightness back on while the dither is running.**

*Evidence:* the engine re-reads both flags every 60 seconds and logs a warning
when it finds one flipped. Across a full day of use (2026-08-23) the unified
log contains **33 such warnings**, in three separate app sessions. In every one,
`autoBrightnessOn` had returned to `true`. Nine were caught by the very next
tick after a re-assertion, so the flip can recur within a minute of being
corrected.

The read is sighted rather than blind — both
`isAutoBrightnessEnabledForKeyboard:` and `isIdleDimmingSuspendedOnKeyboard:`
exist on this machine — so these are observed states, not defensive
re-asserts.

What triggers the re-enable is not established. It is not correlated with
Sublight's own writes (the engine never touches auto-brightness except at
start, resume, and this keeper). The practical consequence is settled either
way: **a one-shot assertion at start is not sufficient**, and the periodic
re-assertion is load-bearing rather than belt-and-braces.

### 6. `fadeSpeed` is visually inert at these timescales

Every value tested — **0, 1, 4, 16, 100** — was accepted (`ok=true`). At a fixed
16 ms ON window with 400 ms of settle between pairs, the three variants
*default* (the plain two-argument setter the engine uses), *fadeSpeed 0*, and
*fadeSpeed 100*, run back to back, were **visually indistinguishable**.

So `fadeSpeed` is not a lever for this problem. It cannot be used to sharpen the
dither's edges, and it is not the cause of the period limit. The engine uses the
plain setter.

### 7. Err-dark skips: 5 in 9,270, and invisible

The engine refuses to command ON at an edge that has run later than its own ON
window (`duty × period`), because lighting the keys past the point they should
already have gone dark is worse than skipping the cycle. That rule fired **5
times in 9,270 edges (0.054 %)**, all within a single five-minute soak at 7.5 Hz.

Each was an **isolated single dropped cycle** — burst length 1, longest gap
between executed ON commands 266.7 ms (exactly two periods), maximum lateness
≈133 ms (about one period). The observer reported the run as clean at all three
glances: one extra dark cycle roughly per minute is not perceptible against a
dither that is already dark for 113 ms of every 133 ms.

> **RETRACTED 2026-08-23.** This section previously concluded, from normal
> daemon latency, that *"the engine queue stalled, not the daemon"*, and put the
> cause down to ambient system activity. **That was wrong.** The queue never
> stalled. Reproducing the soak and reading the per-edge timestamps against the
> anchor showed the three skips were punctual edges that fired **8–24
> microseconds EARLY**, and `DitherSchedule.cycle(at:)` floored them into the
> previous cycle — so the engine measured a lateness of very nearly one whole
> period and dropped them. The "≈133 ms lateness" that looked like evidence of a
> stall was the artefact itself. See below.

#### What it actually was

`cycle(at:)` was plain integer division. A `.strict` `DispatchSourceTimer` may
fire marginally before its deadline; when it did, the floor landed on the
previous cycle index, the computed lateness came out at very nearly a full
period, and the err-dark rule discarded a perfectly on-time edge. The log made
it visible in hindsight: the same cycle index appears twice in a row, once
executed and once skipped — `cycle 2118 ok`, then `cycle 2118 SKIPPED`.

The evidence is unambiguous. Normal edges land with a fractional cycle position
of 0.0003–0.0006 (40–80 µs *after* the deadline); all three skips sat at
0.9998–0.9999, i.e. 8–24 µs *before* the next one. The cadence through each skip
was exactly nominal — 21 ms ON, 112–113 ms OFF — and LOW edges never exceeded
2.33 ms late anywhere in the run. Nothing stalled.

This was the **sole source of every err-dark skip ever recorded**: 5 in the
original soak, 3 in its reproduction, and none from any other cause.

#### Fixed

`cycle(at:)` now bins a firing forward when it lands within an early-fire guard
of the next boundary, and floors otherwise. The guard is 2 ms — twice the
scheduled timer leeway, about a hundred times the largest early-fire observed —
clamped to a quarter of the period so it stays a small, unambiguous fraction of
a cycle even at the top of the research range.

Verification, 7.5 Hz / duty 0.15 / 300 s: **2251 of 2251 HIGH edges executed,
zero skipped, zero coalesced**, longest gap between executed ON commands 135.7 ms
against a 133.3 ms nominal (it was 266.7 ms — a whole dropped cycle — before).
The steady-state err-dark skip rate is now expected to be **zero**.

The rule itself still works, and still matters: a 40 Hz research run — far above
the product ceiling, with a 3.75 ms ON window — skipped two edges that were
genuinely 12.6 ms and 4.1 ms late. Those are real stalls and err-dark is right
to drop them. What has been retired is the class of skip that was never late at
all.

The keeper was **correctly acquitted** as the cause, though for the wrong
reason: it fired exactly five times in each of three five-minute soaks and only
one of them skipped. It is unrelated to this defect — and, as finding 5 records,
it turned out to be load-bearing for an entirely different reason.

---

### 8. The ceiling holds over the long run — and the ON-window hypothesis is refuted

**Measured 2026-08-26 on Mac16,12 (M4) / macOS 26.6.1 (25G76).**

Every soak in this project's history before this date was **five minutes or
shorter**. When dark envelopes were reported at Low, Medium *and* High with an
onset around twenty minutes, no prior "steady" verdict covered the timescale —
so the ceiling was re-qualified at 25 minutes, at the tightest configuration the
product ships: `--freq 8 --duty 0.15`, an **18.75 ms ON window**.

**Result: the ceiling holds.** Across **~29.5 minutes and ~14,150 HIGH edges
with a single engine on the hardware**, three err-dark skips:

| Skip | HIGH late | LOW late | LOW/HIGH | Burst |
|---|---|---|---|---|
| 1 | 38.35 ms | 2.30 ms | 0.06 | 1 |
| 2 | 57.85 ms | 2.18 ms | 0.04 | 1 |
| 3 | 44.01 ms | 1.17 ms | 0.03 | 1 |

Every one isolated, every one with the LOW edge punctual, longest gap between
executed HIGH commands 236–247 ms — two periods, i.e. exactly one dropped cycle,
never an envelope. Four glances inside solo windows, all *steady flicker*.

#### The hypothesis this refutes

A contended 25-minute run at the same settings recorded **14 skips, eight of
them 19.3–21.3 ms late** — barely past the 18.75 ms threshold. That clustering
suggested a specific and product-relevant failure: *routine scheduler jitter on
this machine exceeds the ON window at duty 0.15*, which would make the ceiling's
**duty** dimension unsafe regardless of frequency and would call for a minimum
ON-window floor.

The criterion set in advance was: **if HIGH lateness again clusters near 20 ms
with LOW punctual, the ON window is below the jitter floor.** It does not. No
solo skip lands anywhere near 20 ms — the three are 38, 44 and 58 ms, an order
of magnitude above the threshold and consistent with occasional system-level
stalls rather than a floor sitting under the window. **The hypothesis is refuted
by its own criterion, and no minimum-ON-window change is warranted.**

#### OPEN: what produced the ~20 ms cluster

Contention with a second engine is the leading explanation and **is not
established**. Against it: the final run's last five minutes were themselves
contended — a second engine dithering at 3 Hz alongside ours at 8 Hz — and
produced **zero** skips, clean by eye at both glances. So contention does not
produce the cluster on its own, and whatever did remains unidentified.

The decisive piece of evidence was never captured: **the other engine's
frequency and duty during the 14-skip run are unknown.** It was a menu-bar app
nobody knew was running, and by the time it was found it had been restarted.
Contention intensity presumably scales with the other engine's command rate, and
that number is simply missing.

**Status: open.** Resolvable by deliberately running two engines at known
settings and sweeping the second one's command rate. Nothing in the product
depends on the answer — the ceiling is set by the solo measurement above — but
the record should not claim contention as the cause when a 3 Hz contended tail
falsified the simple version of that story.

#### Why the measurement took five attempts

Recorded because the failure mode is subtle and will recur otherwise. **Two
engines commanding one daemon is invisible in the counters**: each process's
tally is honest about its own edges and silent about the other's contention.
Three 25-minute soaks were spent before anyone noticed, and the app engages
*silently* when a CLI run has already set the suppression flags — `startLocked`
logs only when it finds a flag needing correction, and there was nothing left to
correct. Enforced since: the CLI refuses to start (exit 3) while another live
engine holds the marker, and a running engine logs an error every keeper tick if
one appears mid-run. See `DirtyFlag.liveOwnerPID`.

---

## HYPOTHESIS — not established

> **The July "10 Hz fuses into a steady, dim, flicker-free glow" result may have
> been the daemon giving up, not an eye fusing flicker.**

Earlier notes in [`SPEC.md`](SPEC.md) record ~10 Hz as the prize: a steady,
flicker-free, sub-floor glow. Everything measured since says 10 Hz is well above
the period limit, where the daemon stops honouring the dither. Two readings fit
the same observation:

1. **Retinal fusion.** The flicker was real and the observer's eye fused it.
2. **Daemon coalescing.** The daemon stopped acting on the individual commands
   and settled the LED at some averaged or clamped level. It would look steady
   because it *was* steady — and it would also mean the dither had stopped
   dimming, since the sub-floor average depends on the LED actually being
   switched off part of the time.

Reading 2 is favoured by the current evidence — a 7.0 Hz and an 8.0 Hz dither
are both reported as *clear flicker* by the same observer, and flicker fusion
does not improve going from 8 Hz to 10 Hz by nearly enough to explain "no
flicker at all". But the failure mode measured above 8.5 Hz is *dark envelopes*,
not a steady glow, which reading 2 does not obviously predict either.

**Status: open.** It is resolvable by characterising behaviour deliberately
above the ceiling (`sublight-cli hold --freq 10 --duty 0.15 --allow-unstable`)
and asking an observer whether the result is dark envelopes, a steady dim glow,
or steady *bright*. Nothing in the product depends on the answer — the ceiling
is set by the measured failure boundary regardless — but the historical record
should not keep asserting a fusion result that may never have been one.
