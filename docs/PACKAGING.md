# Packaging Sublight — ad-hoc, Developer ID, notarize, DMG

Sublight ships as source first. A shareable `.app` / `.dmg` is an extra, and
it needs a **paid Apple Developer account** plus a Mac. This document is the
operator recipe. Nothing here invents credentials, and nothing in the repo
holds a certificate, password, or notary API key.

The Cursor cloud environment is Linux. It can edit these scripts; it cannot
run them. Codesign, `hdiutil`, `notarytool` and `stapler` are macOS-only.

## Two paths

| Path | Who it is for | Command | Gatekeeper on another Mac |
|---|---|---|---|
| **Ad-hoc** (local) | The machine you built on | `./scripts/make_app.sh` | Blocked / "unidentified developer" |
| **Developer ID + notarize** (shareable) | Anyone else's Mac | `./scripts/make_app.sh` then `./scripts/make_dmg.sh --sign --notarize` | Normal "downloaded from the internet" prompt, then opens |

Ad-hoc is the default and stays the default. `make_app.sh` always ad-hoc
signs. Developer ID **replaces** that signature on the way into the DMG; it
does not change the local path.

Mac App Store distribution is a permanent non-goal (private `CoreBrightness`
API). Notarization is a malware scan, not an API review — private-API use
does not block it. See [`APPSTORE_AND_HEALTH.md`](APPSTORE_AND_HEALTH.md).

## Local: ad-hoc `.app`

```bash
./scripts/make_app.sh
open build/Sublight.app
```

`make_app.sh` also stamps `CFBundleShortVersionString`, `CFBundleVersion`,
and `SublightGitRevision` (from `git rev-parse HEAD`, with a `-dirty` suffix
if the tree is dirty) into `build/Sublight.app/Contents/Info.plist`. The SHA
is never committed in source. Settings → Diagnostics and About read it from
the live bundle so a rebuilt app is distinguishable from `0.5.0 (5)`.

## Shareable: Developer ID, notarize, DMG

Requires a Mac, Xcode Command Line Tools, and a paid Apple Developer
account ($99/yr). A *free* team can ad-hoc sign but cannot notarize.

### 1. Identity

Install a **Developer ID Application** certificate in the login keychain
(Apple Developer → Certificates). Then either:

```bash
export SUBLIGHT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

or let the script pick it when exactly one such identity is present:

```bash
security find-identity -v -p codesigning
```

Do not put that string, the cert, or any password in the repository.

### 2. Notary credentials (once per Mac)

`notarytool` stores an app-specific password (or API key) in the keychain
under a profile name. The packaging script never sees the secret.

```bash
# App-specific password: appleid.apple.com → Sign-In and Security
# → App-Specific Passwords. Team ID is on developer.apple.com → Membership.
xcrun notarytool store-credentials sublight-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Override the profile name with `SUBLIGHT_NOTARY_PROFILE` if you already have
one.

### 3. Build, sign, wrap, notarize

```bash
./scripts/make_app.sh
./scripts/make_dmg.sh --sign --notarize
```

`--sign` without `--notarize` produces a Developer ID-signed DMG that has
**not** been notarized — Gatekeeper on another Mac will still object until
you notarize and staple. `--notarize` implies `--sign`.

Output: `build/Sublight-<marketing>-<build>.dmg`, plus a stapled
`build/Sublight.app`.

Hardened Runtime (`codesign --options runtime`) is applied on the Developer
ID path only. The ad-hoc local path does not enable it, matching
`make_app.sh` today.

### 4. What this repo will not do

- Embed an Apple certificate, private key, or notary password
- Call the network to open a GitHub issue or upload a binary
- Run these steps on Linux

If `make_dmg.sh` is invoked off macOS it exits 1 and points here.

## Verify a stamped build

On the Mac that built the app:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Sublight.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/Sublight.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SublightGitRevision' build/Sublight.app/Contents/Info.plist
codesign -dv --verbose=2 build/Sublight.app
```

In the running menu-bar app: Settings → About (version + build, and a short
SHA when stamped) and Settings → Diagnostics → Copy (full SHA, engine age,
live skip counters, last skip or `none`).
