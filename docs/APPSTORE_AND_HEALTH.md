# Sublight — App Store Viability & Health/Safety Analysis

*Prepared 2026-07-19. This is general information for a personal/open-source
project, **not legal, regulatory, or medical advice.** If you intend to
distribute commercially, make any health claim, or are unsure, consult a
qualified attorney and/or the relevant regulator.*

---

## Part 1 — Can Sublight go on the Mac App Store?

**Verdict: No.** Two independent blockers, either of which is fatal on its own.

### Blocker 1 — Private API use (decisive)

App Store Review Guideline **2.5.1** states apps "may only use public APIs and
must run on the currently shipping OS." App Review runs automated static
analysis that scans submitted binaries for private-framework linkage and
private selector names, and flags them for rejection. This is strict in
practice, not theoretical: developers get rejected even when a private symbol
appears only because a *third-party library* or the *compiler* introduced it,
and even when the private name is merely *referenced* as a string in the
binary.

Sublight's entire mechanism is a textbook violation:
- it `dlopen`s the private `CoreBrightness.framework`;
- it resolves the private class `KeyboardBrightnessClient` by name;
- it calls private selectors (`setBrightness:forKeyboard:`, etc.) by string.

Those private selector strings live in the compiled binary. Apple's scanner
would flag them, and even if a particular build slipped through, it remains a
violation that can trigger later removal.

**There is no public-API workaround, because there is no public API at all.**
Apple exposes *no* third-party control of the keyboard backlight — not
sub-floor, not even at normal levels. The only reason Sublight works is that it
reaches into a private framework. So there is no compliant way to rebuild the
core function; it isn't a matter of "using the right API instead."

### Blocker 2 — The App Sandbox (independent of the above)

Every Mac App Store app **must** run in the App Sandbox. A sandboxed process is
restricted from loading arbitrary private system frameworks and from the kind
of private inter-process communication Sublight uses to talk to `backlightd`.
So even in a hypothetical world where 2.5.1 didn't exist, the sandbox would
very likely break the mechanism. Direct-distribution (notarized) apps are *not*
required to be sandboxed — which is one more reason that path works and the
App Store path doesn't.

### Even hypothetically past those, the pulse feature adds friction

If, counterfactually, the core function were somehow compliant, the *pulse*
feature would still draw scrutiny:
- **Guideline 1.4.1 (Physical Harm):** "If your app behaves in a way that
  risks physical harm, we may reject it." Deliberately flickering light in the
  seizure-trigger band is exactly the kind of thing this is meant to catch.
- **Health-claim scrutiny:** if the app were marketed with any mood/focus/
  "brainwave" benefit, Apple reviews health claims and has historically
  required such apps to drop unsubstantiated claims or rejected them.

**None of that changes the bottom line — the private API alone ends the App
Store conversation — but it's worth knowing the feature carries its own baggage
beyond the API issue.**

---

## Part 2 — What distribution *is* allowed

Crucial distinction: **"can't be on the Mac App Store" ≠ "Apple won't let it
run."** Sublight can be freely and legitimately distributed outside the store.

### Notarized Developer ID distribution (the recommended path)

- Sign with a **Developer ID Application** certificate, enable the **Hardened
  Runtime**, **notarize** (`xcrun notarytool submit --wait`), and **staple**
  (`xcrun stapler`). Distribute as a DMG / zip / GitHub release.
- **Notarization is an automated malware & security scan, not a guideline
  review.** It checks code signing, the hardened runtime, and for known
  malware — it does **not** enforce Guideline 2.5.1. **Private-API use does not
  block notarization.** This is the key fact that makes the whole thing viable.
- Result: users download it and get the normal "downloaded from the internet"
  Gatekeeper prompt, then it opens — no scary block, no "unidentified
  developer" dead-end.
- Cost: a paid Apple Developer account ($99/yr). A *free* account can sign for
  local use but cannot notarize (so binaries won't open cleanly on other
  Macs).

### Pure source distribution (zero cost)

Publishing the repo for people to `git clone && swift build` themselves needs
nothing — no account, no notarization. This is the natural home for an
open-source project like this. Anyone who builds it locally runs their own
ad-hoc-signed copy.

**Summary:** App Store — no. Notarized direct download — yes, and it's the
standard path for exactly this class of "power-user utility that uses private
APIs" (many popular Mac menu-bar tools live here). Source on GitHub — yes,
freely.

---

## Part 3 — Health & medical effects

Two separate dimensions: a genuine *physical safety* issue (seizures) and a
*claims* issue (does it do anything).

### A. The real safety issue — photosensitive seizures

Flickering light in roughly the **3–30 Hz** range (peak sensitivity ~15–20 Hz)
can trigger seizures in people with **photosensitive epilepsy**. Rough
epidemiology: on the order of 1 in 4,000 people in the general population are
photosensitive; it's more common among people with epilepsy; and — importantly
— many people don't know they're photosensitive until a first event.

**Every Sublight mode sits squarely in this band** — Low 3 Hz, Medium 6 Hz,
High 8 Hz — and **none of them is flicker-free**. That is measured, not
estimated: the backlight daemon will not honour a dither cycle shorter than
~125 ms, so fusing the flicker is unreachable at any setting the app can offer,
and an observer watching the highest, steadiest mode still reports clear
flicker. Earlier drafts of this document described High as "fusing perceptually
into a steadier glow"; that claim is retracted — see
[`COREBRIGHTNESS.md`](COREBRIGHTNESS.md).

**Why the real-world risk here is low (but not zero):** seizure risk scales
strongly with how much of the visual field the stimulus fills, its luminance,
its contrast, and how central it is. Sublight is about as benign as a flicker
source gets — a **small, dim light in your lower peripheral vision**, modulating
between the floor and off (a small absolute luminance range). This is nothing
like a full-screen strobe. As a rough external yardstick, the WCAG accessibility
"three flashes per second" guideline would classify anything above 3 Hz as
potentially problematic *unless* it's small and low-contrast enough to fall
under the small-area / low-luminance exemption — which a dim keyboard backlight
plausibly does. That's a reasoned judgment, not a guarantee.

**The honest conclusion:** low personal risk for a non-photosensitive user, but
a real, non-zero risk that becomes meaningful if you distribute it to others,
since some fraction of any user base will be photosensitive. This is why the
warning and the "keep it dim" defaults matter, and why they must travel with
the software.

### B. The claims issue — does the pulse actually do anything?

- **What's real:** flickering light produces a measurable, frequency-locked
  response in the visual cortex (steady-state visual evoked potentials / photic
  driving). This is well established.
- **What's oversold:** the leap from that to "entrains your brain state →
  drowsiness / relaxation / focus / mood benefits." The evidence is weak —
  small studies, high individual variability, frequent commercial funding,
  publication bias. The tidy theta/alpha/beta → mental-state mapping is the
  framing of the brainwave-entrainment *industry*, not settled science.
- **Compounding it on this hardware:** only 3–8 Hz flicker is even producible
  here (above 8 Hz the backlight daemon stops honouring the dither and the keys
  fall dark for seconds at a time), so the "alpha/beta" bands people associate
  with alertness aren't reachable at all. The feature is, physically, a
  low-band novelty.

**The safe and honest position is to make no efficacy claim.** The app already
says "effects unproven," which is correct and should stay.

### C. Regulatory framing (general information only)

Relevant **only if you market the product or make claims** — for a free,
no-claims, open-source tool these are largely moot, but worth understanding:

- **FDA.** Products promoting general wellness with no disease claim, at low
  risk, generally fall under FDA enforcement discretion (the "General Wellness"
  policy). But (a) a device that flickers light carries a small safety risk,
  which weakens the "low-risk" footing, and (b) any **disease claim** — "treats
  insomnia / anxiety / ADHD / migraines" — could push it into regulated
  **medical-device** territory. Safe path: **no medical or wellness claims at
  all.**
- **FTC.** Health/efficacy claims in advertising must be backed by "competent
  and reliable scientific evidence"; unsubstantiated ones are deceptive
  advertising. This bites *marketing*. A free tool that claims nothing has no
  exposure. Make claims → take on risk.

Net: the regulatory picture is clean **as long as you claim nothing and frame
it as an experimental novelty.** The moment you advertise a benefit, you invite
both agencies' attention and should get professional advice first.

---

## Part 4 — Ready-to-use disclaimer text

Drop these into the README, a first-run dialog, and/or an "About" panel. Written
to be honest and protective, not to launder a claim.

**Photosensitive-seizure warning (the important one):**
> ⚠️ **Photosensitive Seizure Warning.** The pulse modes deliberately flicker
> the keyboard backlight at 5–6 Hz — within the range of frequencies that can
> trigger seizures in people with photosensitive epilepsy. A small number of
> people may have seizures when exposed to flickering light, even with no prior
> history. **If you or anyone using this software has epilepsy or any history
> of photosensitivity, do not use the pulse modes.** Stop immediately and see a
> doctor if you experience dizziness, altered or blurred vision, disorientation,
> eye or muscle twitching, or any involuntary movement. Use in a well-lit room,
> keep brightness low, sit back from the keyboard, and take regular breaks.

**No-claims / effects-unproven:**
> Sublight's pulse modes are an **experimental novelty**. Flickering light
> produces a measurable electrical response in the visual cortex, but there is
> **no reliable evidence** that it improves mood, focus, relaxation, sleep, or
> any other outcome, and **Sublight makes no such claim**. Any effect you
> perceive may be placebo.

**Not a medical device:**
> Sublight is **not a medical device**. It is not regulated or approved by the
> FDA or any other authority and must not be used for any therapeutic or
> diagnostic purpose. It is not intended to diagnose, treat, cure, or prevent
> any condition.

**Use-at-your-own-risk:**
> Provided "as is," without warranty of any kind (see LICENSE). You use it at
> your own risk. It relies on undocumented Apple interfaces that can change or
> break at any time.

---

## Part 5 — Recommended safety mitigations (good-citizen design)

If you distribute the pulse feature to anyone but yourself, these lower risk
and demonstrate reasonable care:

1. **First-run acknowledgment.** *(Done.)* A modal states what the flicker is
   and asks for confirmation **before any backlight command is issued**, the
   first time dimming is enabled by any route. Declining records nothing.
   Note the original form of this recommendation — "the steady dimming can be
   available without it" — no longer applies: there is no steady mode, so the
   gate covers all dimming, not only the pulse presets.
2. **Default to the steadiest mode.** Ship defaulting to High (8 Hz, dimmest
   and steadiest available) — never auto-select a lower, more obtrusive
   frequency. Note this is *steadiest*, not *steady*: nothing fuses.
3. **Never auto-start on launch.** *(Already done — the app launches Off and
   touches nothing until the user picks a mode.)*
4. **Keep brightness capped sub-floor and low.** *(Already done — the slider
   maps to a sub-floor duty; there's no "crank it brighter for a stronger
   effect" path.)*
5. **Keep the warning visible in the UI** whenever a pulse mode is active.
   *(Already done for Low/Medium.)*

Several of these already exist in the current build; the first-run
acknowledgment and steady-mode default are the main additions worth making
before any public release.

---

## One-paragraph bottom line

Sublight **cannot** ship on the Mac App Store — its core depends on a private
API (Guideline 2.5.1, automatic rejection) with no public-API substitute, and
the required sandbox would break it regardless. It **can** be distributed freely
as a **notarized Developer ID app** (notarization is a malware scan, not an API
review, so private-API use is fine there) or as **open source** to build
locally. On health: the one genuine issue is **photosensitive-seizure risk**
from the 5–6 Hz pulse — low for a dim, small, peripheral source, but real, so
ship the warning and dim defaults. On effects: the visual-cortex response is
real but the wellness benefits are **unproven**, so **claim nothing** — which
keeps the FDA/FTC picture clean and is what the app already does.
