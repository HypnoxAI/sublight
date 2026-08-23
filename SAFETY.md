# Safety

Read this before you turn Sublight on, and before you let it run where anyone
else can see your keyboard.

Sublight asks you to confirm you have read this the first time you enable
dimming. That prompt is not a formality — the thing this app does is flicker.

---

## What Sublight actually does

macOS will not set the keyboard backlight below its lowest step. There is no
software path to the brightness hardware underneath it. So Sublight does the
only thing left: it **switches the backlight fully on and fully off, several
times a second**, and the average of that is dimmer than the lowest step the
system will hold.

That is the whole mechanism. There is no filter, no analogue level, no trick
that makes the light steady. The light really is going on and off.

- **Every mode runs between 3 and 8 Hz.** Low is 3 Hz, Medium is 6 Hz, High is
  8 Hz. There is nothing outside that range, because 8 Hz is the fastest the
  macOS backlight daemon will honour — above it the daemon stops cooperating
  and the keys fall dark for seconds at a time.
- **No mode is flicker-free, and this is a measurement, not an estimate.** We
  looked. Fusing flicker into a steady glow needs a faster cycle than the
  daemon will accept, so it is not achievable at any setting Sublight can
  offer. At the highest, steadiest setting the app has, a person watching the
  keys still reports clear, visible flicker. Anything that claims otherwise
  about this hardware is describing the daemon giving up on the dither, not
  your eye fusing it.

The 3–30 Hz band is the range most associated with photosensitive seizure
response. Sublight operates inside it by design, because that is the only band
this hardware can be dimmed in.

## Who should not use it

**Do not use Sublight if you have photosensitive epilepsy, any history of
seizures triggered by flashing light, or known sensitivity to flicker.**

This applies to **anyone who can see your keyboard**, not just you. A laptop on
a desk in a shared room, a screen share, a keyboard visible to someone sitting
beside you on a plane — a person who did not install this app and was never
asked can still be looking at it. If you are not certain about the people
around you, do not run it in front of them.

If you are unsure whether this applies to you, treat that as a no, and ask a
doctor rather than this file.

## Stop immediately if

Stop using Sublight and turn the backlight back to a normal level if you notice
any of these while it is running:

- discomfort
- dizziness
- nausea
- eye strain
- any unusual visual sensation

These are the standard warning signs for photosensitive response. Do not wait
to see whether it passes.

## If the backlight gets stuck

Sublight commands the system back into control on every exit path — quitting,
being killed, going to sleep, crashing. But a hard crash at exactly the wrong
moment can leave the backlight held where Sublight put it.

Two ways out, either is fine:

1. **Press your keyboard brightness keys.** This hands control straight back to
   macOS. Works whether or not Sublight is still running.
2. **Relaunch Sublight** (or run `sublight-cli restore`). Sublight writes a
   marker file before its first backlight command and removes it after a
   successful restore. If the next launch finds that marker, it knows the
   previous run died mid-hold, and it restores the backlight and clears the
   marker automatically.

If neither works, log out and back in.

## Trust your eyes, not the read-back

macOS exposes two functions that claim to report the current keyboard backlight
level. **Neither of them can see what the LED is actually doing.**

We tested this directly: 601 samples taken while the keys were visibly going
fully dark ten to thirty times over thirty seconds. Neither reading changed in
any way that reflected it. One of them also periodically returns a level that
was never commanded at all.

The practical consequence: **if what you see and what a diagnostic says
disagree, your eyes are right.** Sublight's own diagnostics are built on what
was *commanded*, never on what the API claims is displayed, for exactly this
reason.

If you see the backlight doing something Sublight does not explain — dropping
out, sticking, refusing to dim, behaving differently after a macOS update —
that is worth reporting. Please
[open an issue](https://github.com/HypnoxAI/sublight/issues) and say what your
eyes saw, along with your macOS build and Mac model. A visual report is
evidence here; a read-back value is not.

---

Sublight is not a medical device and makes no health claims. See
[`DISCLAIMER`](DISCLAIMER) and [`LICENSE`](LICENSE).
