// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  main.swift
//  sublight-cli
//
//  Command-line surface over SublightKit. This is ALSO the project's
//  validation harness: `dump` verifies the private-API selector table on
//  your machine, `probe` maps the clamp behavior, and `hold` is the live
//  dither test. Run these three before trusting anything else — the whole
//  engine rests on empirical facts about YOUR hardware + macOS build.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import SublightKit

// MARK: - Helpers

func printUsage() {
    print("""
    sublight-cli — sub-minimum keyboard backlight control (Apple Silicon)

    USAGE:
      sublight-cli status                     Show keyboard ID, brightness, auto-brightness
      sublight-cli ids                        List keyboard backlight IDs
      sublight-cli dump                       Print KeyboardBrightnessClient's REAL runtime
                                              selectors (verify the bridge's table)
      sublight-cli sig                        Run the private-API capability probe and print the
                                              TRUE type encodings of the key selectors
      sublight-cli get                        Print reported brightness (0..1)
      sublight-cli set <0..1>                 Direct set (subject to the system clamp)
      sublight-cli auto <on|off>              Toggle keyboard auto-brightness
      sublight-cli probe                      Full guided probe: signatures, dual read-back,
                                              clamp sweep, FADE-hold test, ramp (interactive)
      sublight-cli probe --fade               Just the fade-controlled sub-floor experiment
      sublight-cli probe --ramp               Just the fade-ramp measurement
      sublight-cli dither-test [--duty d]      Spike: find the toggle-rate ceiling, then
                                              flicker-test a frequency ladder (WATCH THE KEYS)
      sublight-cli dither-test --slow          Slow 2–40 Hz fade-riding sweep (WATCH; flickers
                                              in the photosensitive-seizure range)
      sublight-cli dither-test --fine [--duty d]  Fine 6–15 Hz sweep with a floor A/B at each
                                              step, to judge dimness (WATCH THE KEYS)
      sublight-cli hold <0..1> [options]      Dither-hold a sub-minimum level (Ctrl-C restores)
      sublight-cli pair-sweep --on-ms <X>     DIAGNOSTIC: raw ON/OFF pairs straight at the
                                              bridge (engine bypassed) — one ON-window per run
      sublight-cli pulse <low|medium|high>     Continuous pulse preset (~5/6/10 Hz). Experimental;
                                              flickers in the photosensitive range. Ctrl-C stops.
      sublight-cli restore [<0..1>]           Panic restore (default lands at 0.30)
      sublight-cli notify-probe               Spike: can the change-notification tell your
                                              keypress from our writes? (interactive)

    HOLD OPTIONS:
      --floor <f>     Assumed system clamp floor        (default 0.0625)
      --period <s>    Dither period in seconds          (default 0.25)
      --seconds <n>   Run for n seconds, then restore and print the command-truth
                      counters (omit to hold until Ctrl-C)

    PAIR-SWEEP OPTIONS (diagnostic; bypasses the engine):
      --on-ms <X>     ON window in milliseconds         (required)
      --off-ms <Y>    OFF gap in milliseconds           (default 400)
      --seconds <n>   Duration                          (default 4)
      --fade <int>    Use setBrightness:fadeSpeed:commit: with this fadeSpeed.
                      Omit to use the plain setter the ENGINE uses (daemon default fade).
      --floor <f>     Level commanded for ON            (default 0.0625)

    COMMAND-TRUTH COUNTERS:
      `status`, `hold --seconds` and `pair-sweep` print scheduled / fired / executed /
      skipped edge counts and daemon round-trip latency. Per-command detail is in the
      unified log at debug level:
        log stream --level debug --predicate \
          'subsystem == "com.hypnox.sublight" AND category == "engine"'

    EXIT CODES:
      0   success
      1   usage error
      2   backlight unavailable (no Apple Silicon backlit keyboard, bridge failed)
      3   private-API probe failed: the CoreBrightness surface on this macOS build
          does not match what Sublight was verified against; nothing was touched.
          Only `help`, `sig`, and `dump` run without the probe, so the drift can
          be inspected.

    All numbers are normalized 0..1. Start with `dump`, then `sig`, then `probe`.
    Every long-running command restores the backlight on Ctrl-C, SIGTERM, and SIGHUP;
    a crash leaves a dirty flag that the next launch of the app or CLI heals.
    """)
}

func parseFloat(_ s: String?) -> Float? {
    guard let s, let v = Float(s), v.isFinite else { return nil }
    return v
}

func flagValue(_ args: [String], _ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}

/// Install a forced restore-on-signal for a long-running command that has
/// engaged the engine or disabled auto-brightness with direct writes (hold,
/// pulse, probe, dither-test, notify-probe). Quick commands skip this so a
/// Ctrl-C during e.g. `set` does not turn auto-brightness on behind the user.
func installRestoreOnSignal(_ c: BacklightController, level: Float = 0.3) {
    signalRestore = SignalRestore { [weak c] in
        c?.panicRestore(to: level)
    }
}

/// nil = present but invalid; .some(nil) = absent; .some(.some) = a finite value.
func optionalPeriod(_ args: [String]) -> Double?? {
    guard let raw = flagValue(args, "--period") else { return .some(nil) }
    guard let v = Double(raw), v.isFinite, v > 0 else { return nil }
    return .some(v)
}
/// nil = present but invalid; .some(nil) = absent; .some(.some) = a finite value.
func optionalSeconds(_ args: [String]) -> Double?? {
    guard let raw = flagValue(args, "--seconds") else { return .some(nil) }
    guard let v = Double(raw), v.isFinite, v > 0 else { return nil }
    return .some(v)
}

/// Wall-clock epoch plus the monotonic clock, on one line. Printed at the start
/// and end of every measured run so an external recording (a 240 fps phone
/// video, say) can be aligned frame-for-frame against the command log.
func marker(_ label: String, extra: String = "") -> String {
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return String(format: "%@  epoch=%.3f  wall=%@  uptime_ms=%.3f%@",
                  label, now.timeIntervalSince1970, iso.string(from: now),
                  Double(DispatchTime.now().uptimeNanoseconds) / 1e6,
                  extra.isEmpty ? "" : "  " + extra)
}

func optionalFloor(_ args: [String]) -> Float? {
    guard let raw = flagValue(args, "--floor") else { return 0.0625 }
    guard let v = Float(raw), v.isFinite, v > 0 else { return nil }
    return v
}

/// Retained for the process lifetime: the restore-on-signal sources.
var signalRestore: SignalRestore?
/// Set once the launch probe gate has passed. Recovery commands the backlight,
/// so it must not run for probe-exempt commands (help/sig/dump) on an
/// unverified API surface.
var apiVerified = false

func makeController(args: [String]) -> BacklightController? {
    do {
        guard let period = optionalPeriod(args) else {
            fputs("error: --period must be a finite number\n", stderr)
            return nil
        }
        guard let floor = optionalFloor(args) else {
            fputs("error: --floor must be a finite number\n", stderr)
            return nil
        }
        let controller = try BacklightController(floor: floor)
        if let period { controller.period = period }

        // Crash recovery commands the backlight, so only after the API surface
        // was verified (never for the exempt read-only commands).
        if apiVerified {
            let recovery = controller.recoverFromCrashIfNeeded()
            if recovery != .clean {
                fputs("note: previous run did not restore cleanly (\(recovery)) — backlight restored\n", stderr)
            }
        }
        return controller
    } catch {
        fputs("error: \(error)\n", stderr)
        fputs("hint: this tool requires an Apple Silicon MacBook with a backlit keyboard.\n", stderr)
        return nil
    }
}

// MARK: - Probe phases (reused by `probe`, `probe --fade`, `probe --ramp`)

func fmt(_ f: Float?) -> String { f.map { String(format: "%.4f", $0) } ?? "  ?   " }

func banner(_ s: String) { print("\n\(s)\n" + String(repeating: "-", count: s.count)) }

/// Read both oracles at once: (brightnessForKeyboard:, backlightLevelForKeyboard:).
func bothReadbacks(_ c: BacklightController) -> (Float?, Float?) {
    (c.bridge.brightness(c.keyboardID), c.bridge.backlightLevel(c.keyboardID))
}

func phaseSignatures(_ c: BacklightController) {
    banner("Phase 0 — signatures (verify types before believing fade results)")
    let sel = APISurface.expectedEncodings[0].selector   // the fade setter
    let report = validateAPISurface()
    if let enc = report.observed[sel] ?? nil {
        print("  \(sel)")
        print("      raw : \(enc)")
        print("      read: \(c.bridge.decodeSignature(enc))")
        print("  The bridge is built for: fadeSpeed=int (enum), commit=BOOL.")
        if let failure = report.failures.first(where: { $0.selector == sel }) {
            print("  ⚠️  \(failure) — re-check types before the fade phase.")
        }
    } else {
        print("  \(sel)\n      (absent — fade experiment will be skipped)")
    }
    if c.bridge.backlightLevel(c.keyboardID) == nil {
        print("  note: backlightLevelForKeyboard: returned nil — only one read-back available.")
    }
}

func phaseDualReadback(_ c: BacklightController) {
    banner("Phase 1 — do the two read-backs agree? (target vs actual LED oracle)")
    print("  Setting 0.50 …")
    c.bridge.setBrightness(0.5, c.keyboardID)
    Thread.sleep(forTimeInterval: 1.0)
    var (b, bl) = bothReadbacks(c)
    print("    brightness=\(fmt(b))   backlightLevel=\(fmt(bl))")
    print("  Setting floor \(fmt(c.floor)) …")
    c.bridge.setBrightness(c.floor, c.keyboardID)
    Thread.sleep(forTimeInterval: 1.0)
    (b, bl) = bothReadbacks(c)
    print("    brightness=\(fmt(b))   backlightLevel=\(fmt(bl))")
    print("  If the two columns ever differ, one is the commanded target and the")
    print("  other is closer to real output — note which is which.")
}

func phaseClampSweep(_ c: BacklightController) {
    banner("Phase 2 — plain-set clamp sweep (find the REAL floor)")
    print("  WATCH THE KEYS each row. Looking for the lowest visibly-distinct value,")
    print("  and whether anything below \(fmt(c.floor)) is honored at all.\n")
    let sweep: [Float] = [0.0, 0.005, 0.01, 0.02, 0.03, 0.04, 0.05, c.floor, 0.08, 0.10, 0.12, 0.25]
    print("  commanded   ok    brightness  backlightLevel")
    for v in sweep {
        let ok = c.bridge.setBrightness(v, c.keyboardID)
        Thread.sleep(forTimeInterval: 1.0)
        let (b, bl) = bothReadbacks(c)
        print(String(format: "    %.4f    %@   %@    %@", v, ok ? "y" : "N", fmt(b), fmt(bl)))
    }
}

func phaseFade(_ c: BacklightController) {
    banner("Phase 3 — THE fade experiment: can we hold sub-floor statically?")
    guard c.bridge.supportsFadeControl else {
        print("  setBrightness:fadeSpeed:commit: is absent — skipping.")
        return
    }
    print("  For each row: fade-set a SUB-FLOOR value, wait 2.5 s, WATCH THE KEYS.")
    print("  Question: does the LED sit visibly BELOW the system minimum and stay there,")
    print("  with no flicker? If yes for any row, the dither engine may be unnecessary.")
    print("  fadeSpeed is an int enum (verified via sig); 0 is likely 'instant/no fade'.\n")
    let target: Float = 0.03
    // (fadeSpeed enum candidate, commit). We don't know the enum's meaning yet,
    // so we sweep the low integers; 0 with commit=true is the prime suspect for
    // a clean static hold.
    let combos: [(Int32, Bool)] = [(0, true), (1, true), (2, true), (0, false)]
    print("  target  fadeSpeed  commit   ok    brightness  backlightLevel")
    for (fs, cm) in combos {
        // Reset to a known state between trials so each starts from the floor.
        c.bridge.setBrightness(c.floor, c.keyboardID)
        Thread.sleep(forTimeInterval: 0.6)
        let ok = c.bridge.setBrightness(target, fadeSpeed: fs, commit: cm, c.keyboardID)
        Thread.sleep(forTimeInterval: 2.5)
        let (b, bl) = bothReadbacks(c)
        print(String(format: "    %.3f    %5d      %@      %@    %@    %@",
                     target, fs, cm ? "yes" : "no ", ok ? "y" : "N", fmt(b), fmt(bl)))
    }
    // One deeper probe with the prime-suspect combo.
    print("  … deeper: target 0.015, fadeSpeed 0, commit yes")
    c.bridge.setBrightness(c.floor, c.keyboardID)
    Thread.sleep(forTimeInterval: 0.6)
    _ = c.bridge.setBrightness(0.015, fadeSpeed: 0, commit: true, c.keyboardID)
    Thread.sleep(forTimeInterval: 2.5)
    let (b2, bl2) = bothReadbacks(c)
    print(String(format: "    0.015       0      yes    -   %@    %@", fmt(b2), fmt(bl2)))
}

func phaseRamp(_ c: BacklightController) {
    banner("Phase 4 — ramp shape (characterize the default fade)")
    print("  floor → 0, sampling BOTH read-backs every 50 ms for 2 s.")
    print("  WATCH THE KEYS: time how long the light physically takes to die.\n")
    c.bridge.setBrightness(c.floor, c.keyboardID)
    Thread.sleep(forTimeInterval: 1.0)
    let start = Date()
    c.bridge.setBrightness(0, c.keyboardID)
    print("     t(ms)  brightness  backlightLevel")
    while Date().timeIntervalSince(start) < 2.0 {
        let t = Date().timeIntervalSince(start)
        let (b, bl) = bothReadbacks(c)
        print(String(format: "    %5.0f   %@    %@", t * 1000, fmt(b), fmt(bl)))
        Thread.sleep(forTimeInterval: 0.05)
    }
    print("  If a column jumped straight to 0 while the LED faded, that column reports")
    print("  TARGETS; a column that ramped down tracks real output.")
}

// MARK: - Fast-dither spike helpers
//
// JUDGMENT CALL: these loops are deliberately NOT the DitherEngine. They are
// the instruments of `dither-test` — a raw, unpaced hammer to find the API's
// call-rate ceiling, a spin-paced ladder far above the engine's band, and a
// sleep-paced slow sweep that measures the daemon's own fade response with
// nothing in the way. Routing them through the engine would measure the
// engine instead of the API. The dither paths that are a product feature —
// `hold` and `pulse` — run on DitherEngine. Every call here still goes
// through the queue-confined bridge.

/// Busy-wait until `nanos` have elapsed. Spins a core — fine for a short spike;
/// it is the most reliable way to hit sub-millisecond phase timing.
func spinWait(_ nanos: UInt64) {
    if nanos == 0 { return }
    let deadline = DispatchTime.now().uptimeNanoseconds &+ nanos
    while DispatchTime.now().uptimeNanoseconds < deadline { }
}

/// Hammer floor↔0 with NO pacing to find the raw ceiling the API+daemon allow.
/// Returns achieved full cycles per second (one cycle = one floor + one off).
func rawCeiling(_ c: BacklightController, floor: Float, seconds: Double) -> Double {
    let id = c.keyboardID
    let end = Date().addingTimeInterval(seconds)
    var n = 0
    while Date() < end {
        c.bridge.setBrightness(floor, id)
        c.bridge.setBrightness(0, id)
        n += 1
    }
    return Double(n) / seconds
}

/// Paced toggle at a target cycle frequency and duty. Returns achieved cycles/sec
/// (if far below the request, the setBrightness call latency is the bottleneck).
func runPaced(_ c: BacklightController, freq: Double, duty: Double, seconds: Double, floor: Float) -> Double {
    let id = c.keyboardID
    let highNs = UInt64(max(0.0, duty) / freq * 1e9)
    let lowNs = UInt64(max(0.0, 1.0 - duty) / freq * 1e9)
    let end = Date().addingTimeInterval(seconds)
    var cycles = 0
    while Date() < end {
        c.bridge.setBrightness(floor, id)
        spinWait(highNs)
        c.bridge.setBrightness(0, id)
        spinWait(lowNs)
        cycles += 1
    }
    return Double(cycles) / seconds
}

/// Slow-band toggle using Thread.sleep (no CPU spin — phases are 12–250 ms, so
/// millisecond sleep accuracy is plenty). This is the fade-riding regime: slow
/// enough that the daemon acts on every command, so any hardware fade shows up.
func runSlow(_ c: BacklightController, freq: Double, duty: Double, seconds: Double, floor: Float) -> Double {
    let id = c.keyboardID
    let highS = max(0.0, duty) / freq
    let lowS = max(0.0, 1.0 - duty) / freq
    let end = Date().addingTimeInterval(seconds)
    var cycles = 0
    while Date() < end {
        c.bridge.setBrightness(floor, id)
        Thread.sleep(forTimeInterval: highS)
        c.bridge.setBrightness(0, id)
        Thread.sleep(forTimeInterval: lowS)
        cycles += 1
    }
    return Double(cycles) / seconds
}

/// Thread-safe fire counter for the notification probe. The change-notification
/// block runs on a system thread; increments must be locked.
final class ProbeCounter {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
    func reset() { lock.lock(); n = 0; lock.unlock() }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    printUsage()
    exit(1)
}

// Capability probe gate. `help`, `sig`, and `dump` are exempt: they never
// command the backlight, and they are how a failing probe gets diagnosed.
if !["help", "--help", "-h", "sig", "signatures", "dump"].contains(command) {
    let report = validateAPISurface()
    if !report.passed {
        fputs(report.text + "\n", stderr)
        fputs("Refusing to drive the backlight on an unverified API surface. Please file an issue with the report above.\n", stderr)
        exit(3)
    }
    apiVerified = true
}

switch command {

case "help", "--help", "-h":
    printUsage()
    exit(0)

case "status":
    guard let c = makeController(args: args) else { exit(2) }
    print("keyboard id      : \(c.keyboardID)")
    print("reported level   : \(c.reportedBrightness().map { String(format: "%.4f", $0) } ?? "unavailable")")
    if let auto = c.bridge.isAutoBrightnessEnabled(c.keyboardID) {
        print("auto-brightness  : \(auto ? "on" : "off")")
    } else {
        print("auto-brightness  : selector unavailable")
    }
    if let dimmed = c.bridge.isBacklightDimmed(c.keyboardID) {
        print("idle-dimmed      : \(dimmed)")
    }
    print("assumed floor    : \(String(format: "%.4f", c.floor))  (verify with `probe`)")

    // Command-truth counters. This process has not driven any edges, so the
    // live tally is empty by construction — what is worth reading is the last
    // recorded run, written by `hold --seconds` / `pair-sweep`.
    print("\ncommand-truth counters (this process):")
    print(c.engine.counters.report())
    if let last = DiagnosticsStore.load() {
        let iso = ISO8601DateFormatter()
        print("\nlast recorded run: \(last.label)")
        print("  recorded \(iso.string(from: last.recordedAt))  pid \(last.pid)  (\(DiagnosticsStore.defaultURL.path))")
        print(last.counters.report())
    } else {
        print("\nlast recorded run: none (run `hold --seconds n` or `pair-sweep`)")
    }
    exit(0)

case "ids":
    guard let c = makeController(args: args) else { exit(2) }
    let ids = c.bridge.keyboardIDs()
    if ids.isEmpty {
        print("copyKeyboardBacklightIDs returned nothing — using heuristic ID \(c.keyboardID)")
    } else {
        for id in ids {
            print("id \(id)  builtIn=\(c.bridge.isBuiltIn(id))")
        }
    }
    exit(0)

case "dump":
    guard let c = makeController(args: args) else { exit(2) }
    print("KeyboardBrightnessClient instance methods on THIS machine:")
    print("(reconcile against the table in KeyboardBrightnessBridge.swift)\n")
    for sel in c.bridge.runtimeSelectorDump() {
        print("  \(sel)")
    }
    exit(0)

case "sig", "signatures":
    let report = validateAPISurface()
    print(report.text)
    print("")
    print("True selector type encodings on THIS machine.")
    print("The fade setter is built for: brightness=float, fadeSpeed=int (enum), commit=BOOL,")
    print("keyboardID=unsigned long long. Any mismatch above means the signature changed")
    print("on your build — file an issue with this output before running the fade phase.\n")
    let decoder = try? KeyboardBrightnessBridge()   // decode is a pure string helper
    for s in APISurface.introspectionSelectors {
        if let enc = report.observed[s] ?? nil {
            print("  \(s)")
            print("      raw : \(enc)")
            if let d = decoder { print("      read: \(d.decodeSignature(enc))\n") } else { print("") }
        } else {
            print("  \(s)\n      (absent on this machine)\n")
        }
    }
    exit(report.passed ? 0 : 3)

case "get":
    guard let c = makeController(args: args) else { exit(2) }
    if let b = c.reportedBrightness() {
        print(String(format: "%.4f", b))
        exit(0)
    }
    fputs("error: brightness read-back unavailable\n", stderr)
    exit(2)

case "set":
    guard let value = parseFloat(args.count > 1 ? args[1] : nil), (0...1).contains(value) else {
        fputs("usage: sublight-cli set <0..1>\n", stderr)
        exit(1)
    }
    guard let c = makeController(args: args) else { exit(2) }
    // `set` does not touch auto-brightness, and the ambient light sensor can
    // override a commanded value within milliseconds — silently invalidating
    // a visual measurement.
    if c.bridge.isAutoBrightnessEnabled(c.keyboardID) == true {
        fputs("warning: auto-brightness is ON — the ambient light sensor may override this value within milliseconds; run 'auto off' first for visual tests\n", stderr)
    }
    let ok = c.bridge.setBrightness(value, c.keyboardID)
    Thread.sleep(forTimeInterval: 0.5) // let the fade land
    let after = c.reportedBrightness().map { String(format: "%.4f", $0) } ?? "?"
    print("commanded \(String(format: "%.4f", value))  ok=\(ok)  read-back=\(after)")
    print("(read-back may echo the request even if the hardware clamped — trust your eyes)")
    exit(ok ? 0 : 2)

case "auto":
    guard args.count > 1, ["on", "off"].contains(args[1]) else {
        fputs("usage: sublight-cli auto <on|off>\n", stderr)
        exit(1)
    }
    guard let c = makeController(args: args) else { exit(2) }
    let ok = c.bridge.setAutoBrightness(args[1] == "on", c.keyboardID)
    print("auto-brightness \(args[1])  ok=\(ok)")
    exit(ok ? 0 : 2)

case "probe":
    guard let c = makeController(args: args) else { exit(2) }
    installRestoreOnSignal(c)   // disables auto-brightness below; restore on Ctrl-C
    print("=== Sublight comprehensive probe ===")
    print("Dim room, other keyboard tools quit. Your EYES are the instrument —")
    print("the read-back columns can lie (SPEC §6.4). If the light gets stuck,")
    print("Ctrl-C then run `sublight-cli restore`.")

    // Focused re-runs.
    if args.contains("--ramp") {
        phaseRamp(c)
        c.bridge.setBrightness(0.3, c.keyboardID)
        print("\nRestored 0.30.")
        exit(0)
    }
    if args.contains("--fade") {
        phaseSignatures(c)
        phaseFade(c)
        c.bridge.setBrightness(0.3, c.keyboardID)
        print("\nRestored 0.30.")
        exit(0)
    }

    // Full guided sequence.
    phaseSignatures(c)
    print("\n▶ Bringing keys to a visible baseline before the next phase …")
    c.bridge.setBrightness(0.4, c.keyboardID)
    Thread.sleep(forTimeInterval: 1.2)
    phaseDualReadback(c)
    phaseClampSweep(c)
    phaseFade(c)
    phaseRamp(c)

    c.bridge.setBrightness(0.3, c.keyboardID)
    banner("Done — restored 0.30. Record these for SPEC §12")
    print("  1. Real floor        = lowest visibly-distinct value in Phase 2")
    print("  2. Sub-floor honored by a PLAIN set?           (Phase 2)")
    print("  3. Did any Phase 3 fade row hold BELOW the floor, flicker-free?")
    print("     → if yes, a single fade-set may REPLACE the whole dither engine.")
    print("  4. Which read-back tracks real output vs the target? (Phases 1 & 4)")
    print("  5. Ramp duration                                (Phase 4)")
    exit(0)

case "dither-test":
    guard let c = makeController(args: args) else { exit(2) }
    installRestoreOnSignal(c)   // forces auto-brightness off below; restore on Ctrl-C
    let floor = c.floor
    let duty = parseFloat(flagValue(args, "--duty")).map { Double($0) } ?? 0.5

    print("=== Fast-dither spike ===")
    print("This RAPIDLY FLICKERS the keyboard backlight on purpose, to test whether")
    print("toggling floor<->0 fast enough fuses into a steady, sub-floor glow.")
    print("⚠️  Photosensitivity: if fast flicker bothers you, Ctrl-C now.")
    print("    `sublight-cli restore` fixes the backlight afterward if needed.")
    print("Dim room; watching the keys IS the experiment.\n")

    // Auto-brightness OFF for a clean test — it was the flicker source earlier.
    let savedAuto = c.bridge.isAutoBrightnessEnabled(c.keyboardID)
    if c.bridge.supportsAutoBrightnessControl { c.bridge.setAutoBrightness(false, c.keyboardID) }
    print("auto-brightness: " + (savedAuto.map { $0 ? "was on → forced off" : "already off" } ?? "n/a") + "\n")

    if args.contains("--slow") {
        print("Part S — SLOW band sweep (2–40 Hz), the fade-riding regime.")
        print("  ⚠️  PHOTOSENSITIVITY: this flickers at 2–40 Hz, the range that can trigger")
        print("      photosensitive seizures. Small peripheral light, so risk is low — but if")
        print("      you have ANY photosensitivity, abort now.")
        print("  For EACH frequency, watch the keys and note:")
        print("    • transition — does it SNAP hard between min and off, or FADE softly?")
        print("    • steadiness — obvious pulsing, or fused into a steady glow?")
        print("    • dimness    — on average, clearly dimmer than the floor, or not?\n")
        // Abort countdown.
        for n in stride(from: 5, through: 1, by: -1) {
            print("  starting in \(n) …  (Ctrl-C to abort)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("")
        let slow = [2.0, 5.0, 10.0, 20.0, 30.0, 40.0]
        for f in slow {
            print(String(format: "  → %.0f Hz — 4 s, WATCH THE KEYS…", f))
            let ach = runSlow(c, freq: f, duty: duty, seconds: 4.0, floor: floor)
            print(String(format: "    (achieved ~%.0f Hz)\n", ach))
            c.bridge.setBrightness(floor, c.keyboardID)
            Thread.sleep(forTimeInterval: 0.8)
        }
        if let s = savedAuto, c.bridge.supportsAutoBrightnessControl { c.bridge.setAutoBrightness(s, c.keyboardID) }
        c.bridge.setBrightness(0.3, c.keyboardID)
        print("Restored: auto-brightness reset, brightness 0.30.")
        print("Report — especially for 2–5 Hz: SNAP or FADE on each transition? And did")
        print("any frequency settle into steady dimming below the floor?")
        exit(0)
    }

    if args.contains("--fine") {
        print("Part F — FINE sweep with a FLOOR A/B at each step (the dimness test).")
        print("  ⚠️  Still flickers in the photosensitive range — abort now if sensitive.")
        print("  At each frequency you see the FLOOR, then the dither. The ONLY question")
        print("  that matters: is the dither CLEARLY dimmer than the floor, or the same?")
        print("  (Same brightness but steady = coalescing, not a win. Dimmer = the real thing.)\n")
        for n in stride(from: 5, through: 1, by: -1) {
            print("  starting in \(n) …  (Ctrl-C to abort)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("")
        let fine = [6.0, 8.0, 10.0, 12.0, 15.0]
        for f in fine {
            print(String(format: "  %.0f Hz:", f))
            print("    FLOOR (2.5 s) — fix this brightness in your eye…")
            c.bridge.setBrightness(floor, c.keyboardID)
            Thread.sleep(forTimeInterval: 2.5)
            print("    DITHER (5 s) — dimmer than that floor? and steady or still pulsing?")
            let ach = runSlow(c, freq: f, duty: duty, seconds: 5.0, floor: floor)
            print(String(format: "      (achieved ~%.0f Hz)\n", ach))
            c.bridge.setBrightness(floor, c.keyboardID)
            Thread.sleep(forTimeInterval: 0.8)
        }
        if let s = savedAuto, c.bridge.supportsAutoBrightnessControl { c.bridge.setAutoBrightness(s, c.keyboardID) }
        c.bridge.setBrightness(0.3, c.keyboardID)
        print("Restored: auto-brightness reset, brightness 0.30.")
        print("Report per frequency: DIMMER than floor, or same? And steady or pulsing?")
        print("The winner is any frequency that is BOTH steady AND clearly dimmer than the floor.")
        exit(0)
    }

    // Part A — raw ceiling.
    print("Part A — raw ceiling: hammering floor<->0 as fast as the API allows for 1.5 s.")
    print("  WATCH: a fast shimmer or steady glow = promising; chunky blinking = ceiling too low.")
    let cyc = rawCeiling(c, floor: floor, seconds: 1.5)
    print(String(format: "  → ~%.0f cycles/sec  (%.0f setBrightness calls/sec)\n", cyc, cyc * 2))
    c.bridge.setBrightness(floor, c.keyboardID)
    Thread.sleep(forTimeInterval: 1.0)

    if cyc < 50 {
        print("Ceiling is below ~50 Hz — too slow to fuse. Steady sub-floor light is NOT")
        print("achievable through this API by dithering. That is a definitive negative;")
        print("no amount of tuning fixes a hard rate ceiling this low.")
    } else {
        let candidates = [60.0, 90.0, 120.0, 180.0, 240.0]
        let ladder = candidates.filter { $0 <= cyc * 0.8 }
        let tested = ladder.isEmpty ? [min(cyc * 0.8, 60.0)] : ladder
        print(String(format: "Part B — paced ladder at duty %.2f (target ≈ %.0f%% of floor brightness).", duty, duty * 100))
        print("  Each runs 4 s. For each, judge TWO things:")
        print("    (1) flicker — rock-steady, or visibly strobing/shimmering?")
        print("    (2) dimness — clearly dimmer than the floor, or no different?\n")
        for f in tested {
            print(String(format: "  → %.0f Hz — running 4 s, WATCH THE KEYS…", f))
            let ach = runPaced(c, freq: f, duty: duty, seconds: 4.0, floor: floor)
            print(String(format: "    (achieved ~%.0f Hz)\n", ach))
            c.bridge.setBrightness(floor, c.keyboardID)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    // Restore.
    if let s = savedAuto, c.bridge.supportsAutoBrightnessControl { c.bridge.setAutoBrightness(s, c.keyboardID) }
    c.bridge.setBrightness(0.3, c.keyboardID)
    print("Restored: auto-brightness reset, brightness 0.30.")
    print("Report, per frequency: did it hold STEADY (fused), and was it DIMMER than the floor?")
    exit(0)

case "hold":
    guard let value = parseFloat(args.count > 1 ? args[1] : nil), (0...1).contains(value) else {
        fputs("usage: sublight-cli hold <0..1> [--floor f] [--period s]\n", stderr)
        exit(1)
    }
    guard let c = makeController(args: args) else { exit(2) }

    guard let seconds = optionalSeconds(args) else {
        fputs("error: --seconds must be a finite number > 0\n", stderr)
        exit(1)
    }

    print("Holding level \(String(format: "%.4f", value)) (floor \(String(format: "%.4f", c.floor)), period \(c.period)s).")
    if value < c.floor && value > 0 {
        print("Sub-minimum zone → dither engine active. Watch for flicker; tune --period.")
    } else {
        print("At/above floor (or zero) → plain direct set, no dithering.")
    }
    if seconds == nil { print("Ctrl-C restores auto-brightness and lands at the floor.\n") }

    installRestoreOnSignal(c, level: max(c.floor, 0.2))

    // Bracket the measurement: zero the tally on the engine queue, so it is
    // ordered strictly before the start block setLevel is about to enqueue.
    EngineQueue.run { EngineDiagnostics.shared.reset() }
    let holdStart = Date()
    print(marker("RUN START"))
    c.setLevel(value)

    // A no-op hop drains the queue behind setLevel's async start, so the state
    // read below is the settled one.
    EngineQueue.run { }
    let resolved = c.engine.state
    if case .running(let hz, let duty) = resolved {
        print(String(format: "engine: %.4f Hz  duty %.4f  period %.2f ms  ON window %.2f ms",
                     hz, duty, 1000.0 / hz, duty * 1000.0 / hz))
    } else {
        print("engine: stopped (direct set path)")
    }

    if let seconds {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            // Snapshot BEFORE the restore, so the restore's own three commands
            // do not land in the run's latency distribution — and ON the engine
            // queue, so it cannot land mid-edge and report a HIGH as fired but
            // not yet executed.
            let snap = EngineQueue.run { c.engine.counters }
            c.engine.restoreNow(force: false)
            let elapsed = Date().timeIntervalSince(holdStart)
            print(marker("RUN STOP", extra: String(format: "elapsed=%.3fs", elapsed)))
            print(snap.report())
            var label = String(format: "hold %.4f", value)
            if case .running(let hz, let duty) = resolved {
                label = String(format: "hold %.3f Hz duty %.3f for %.0f s", hz, duty, seconds)
            }
            if DiagnosticsStore.save(DiagnosticsRecord(label: label, counters: snap)) {
                print("saved: \(DiagnosticsStore.defaultURL.path)")
            }
            exit(0)
        }
    }
    dispatchMain()

case "pair-sweep":
    // DIAGNOSTIC INSTRUMENT, not a product path. Same shape as the `dither-test`
    // spike helpers above — a raw, unpaced pair loop straight at the queue-confined
    // bridge, with the engine deliberately out of the picture. One ON-window per
    // invocation, because the verdict on each is a HUMAN visual observation and
    // those cannot be batched.
    guard let c = makeController(args: args) else { exit(2) }
    guard let onMsRaw = flagValue(args, "--on-ms"), let onMs = Double(onMsRaw), onMs.isFinite, onMs > 0 else {
        fputs("usage: sublight-cli pair-sweep --on-ms <X> [--off-ms 400] [--seconds 4] [--fade <int>] [--floor f]\n", stderr)
        exit(1)
    }
    let offMs = flagValue(args, "--off-ms").flatMap { Double($0) } ?? 400
    guard offMs.isFinite, offMs >= 0 else {
        fputs("error: --off-ms must be a finite number >= 0\n", stderr)
        exit(1)
    }
    guard let sweepSecondsOpt = optionalSeconds(args) else {
        fputs("error: --seconds must be a finite number > 0\n", stderr)
        exit(1)
    }
    let sweepSeconds = sweepSecondsOpt ?? 4.0
    var fadeSpeed: Int32?
    if let raw = flagValue(args, "--fade") {
        guard let v = Int32(raw) else {
            fputs("error: --fade must be an integer (the fadeSpeed enum)\n", stderr)
            exit(1)
        }
        if !c.bridge.supportsFadeControl {
            fputs("error: setBrightness:fadeSpeed:commit: is absent on this build\n", stderr)
            exit(2)
        }
        fadeSpeed = v
    }

    installRestoreOnSignal(c, level: max(c.floor, 0.2))
    // Direct writes with no engine engagement: arm crash recovery by hand so a
    // hard kill mid-sweep cannot leave the ALS suppressed with no marker.
    c.armCrashRecovery()

    let setter = fadeSpeed.map { "setBrightness:fadeSpeed:commit: fadeSpeed=\($0) commit=true" }
        ?? "setBrightness:forKeyboard: (the setter the ENGINE uses — daemon default fade)"
    print("=== pair-sweep (engine bypassed) ===")
    print(String(format: "ON window %.1f ms at level %.4f, OFF gap %.1f ms, for %.1f s (~%.0f cycles)",
                 onMs, c.floor, offMs, sweepSeconds, sweepSeconds / ((onMs + offMs) / 1000.0)))
    print("setter: \(setter)")
    print("⚠️  This blinks the keyboard backlight. WATCH THE KEYS — the verdict is visual.\n")

    // Same suppression the engine asserts, so the ALS and the idle dimmer are
    // not competing with the measurement.
    let sweepCommander = BridgeCommander(bridge: c.bridge, keyboardID: c.keyboardID)
    _ = sweepCommander.assertSuppression()
    Thread.sleep(forTimeInterval: 0.3)
    EngineQueue.run { EngineDiagnostics.shared.reset() }

    func sweepSet(_ v: Float) -> UInt64 {
        let t = DispatchTime.now().uptimeNanoseconds
        if let f = fadeSpeed {
            c.bridge.setBrightness(v, fadeSpeed: f, commit: true, c.keyboardID)
        } else {
            c.bridge.setBrightness(v, c.keyboardID)
        }
        return t
    }

    let onNanos = UInt64(onMs * 1e6)
    let sweepEnd = Date().addingTimeInterval(sweepSeconds)
    var spacings: [Double] = []
    var cycles = 0
    print(marker("STEP START", extra: String(format: "on_ms=%.1f fade=%@", onMs, fadeSpeed.map(String.init) ?? "default")))
    while Date() < sweepEnd {
        let tOn = sweepSet(c.floor)
        spinWait(onNanos)
        let tOff = sweepSet(0)
        spacings.append(Double(tOff &- tOn) / 1e6)
        cycles += 1
        if offMs > 0 { Thread.sleep(forTimeInterval: offMs / 1000.0) }
    }
    print(marker("STEP STOP", extra: String(format: "cycles=%d", cycles)))

    let snap = EngineDiagnostics.shared.snapshot()
    let sorted = spacings.sorted()
    if !sorted.isEmpty {
        print(String(format: "\n  achieved ON->OFF command spacing: min %.3f  p50 %.3f  max %.3f ms  (requested %.1f ms, n=%d)",
                     sorted.first!, sorted[sorted.count / 2], sorted.last!, onMs, sorted.count))
    }
    print(snap.report())
    let sweepLabel = String(format: "pair-sweep on=%.1fms off=%.1fms fade=%@",
                            onMs, offMs, fadeSpeed.map(String.init) ?? "default")
    if DiagnosticsStore.save(DiagnosticsRecord(label: sweepLabel, counters: snap)) {
        print("saved: \(DiagnosticsStore.defaultURL.path)")
    }
    c.panicRestore(to: 0.3)
    print("\nrestored: auto-brightness on, level 0.30")
    exit(0)

case "pulse":
    let modeArg = args.count > 1 ? args[1] : ""
    // All three live in the ~5–8 Hz band — the only range this hardware can
    // actually flicker (above ~8 Hz the daemon coalesces it into steady floor).
    // These are NOT the theta/alpha/beta spread; they're a low-band gradient,
    // and any neurological effect is unproven. Named for a subjective low→high feel.
    let presets: [String: Double] = ["low": 5.0, "medium": 6.0, "high": 10.0]
    guard let freq = presets[modeArg.lowercased()] else {
        fputs("usage: sublight-cli pulse <low|medium|high> [--duty d]\n", stderr)
        fputs("  low ≈ 5 Hz,  medium ≈ 6 Hz,  high ≈ 10 Hz — the band this hardware can flicker.\n", stderr)
        exit(1)
    }
    guard let c = makeController(args: args) else { exit(2) }
    let duty = parseFloat(flagValue(args, "--duty")).map { Double($0) } ?? 0.5

    print("=== Pulse: \(modeArg.lowercased()) (~\(freq) Hz) ===")
    print("⚠️  Experimental novelty. This flickers at \(freq) Hz — inside the")
    print("    photosensitive-seizure band. Any mood/focus effect is unproven.")
    print("    Keep it dim; don't run it if you're photosensitive.")
    print(String(format: "duty %.2f → the light spends ~%.0f%% of each cycle at the floor.", duty, duty * 100))
    print("Ctrl-C stops and restores.\n")

    c.period = 1.0 / freq
    // A sub-floor level whose implied duty (level / floor) equals `duty`, so the
    // dither runs at `freq` with the requested on-fraction.
    installRestoreOnSignal(c, level: max(c.floor, 0.2))
    c.setLevel(Float(duty) * c.floor)
    print("pulsing… (Ctrl-C to stop)")
    dispatchMain()

case "notify-probe":
    guard let c = makeController(args: args) else { exit(2) }
    installRestoreOnSignal(c)
    let sel = APISurface.notificationSelector
    print("=== Notification probe (yield-to-manual spike) ===")
    print("Question: can the keyboard change-notification tell YOUR keypress apart")
    print("from Sublight's own backlight writes? That decides how yield-to-manual works.\n")

    // 1. Signature (learn the `keys` arg type; the block's internal sig stays opaque).
    if let enc = c.bridge.methodSignature(sel) {
        print("selector: \(sel)")
        print("  raw : \(enc)")
        print("  read: \(c.bridge.decodeSignature(enc))\n")
    } else {
        print("selector is ABSENT on this build — cannot probe. Stopping.")
        exit(0)
    }

    // 2. Register a ZERO-ARG block (safe against the unknown real signature).
    let counter = ProbeCounter()
    let ok = c.bridge.registerChangeNotification(keys: nil, c.keyboardID) {
        counter.bump()
    }
    print("register (keys=nil): \(ok ? "call made" : "FAILED")")
    if !ok { exit(2) }
    print("(If every phase reports 0, nil keys may be wrong — we'll try other values.)\n")

    // Keep the run loop alive so notifications delivered on it can fire, and so
    // the per-phase RunLoop waits the full duration.
    let keepAlive = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }

    print("Phase A — 8 s, doing NOTHING (baseline: does it fire on its own?)")
    counter.reset()
    RunLoop.current.run(until: Date().addingTimeInterval(8))
    let phaseA = counter.value()
    print("  → \(phaseA) fires\n")

    print("Phase B — 5 write-pairs BY US over ~5 s (do OUR writes fire it?)")
    counter.reset()
    for _ in 0..<5 {
        c.bridge.setBrightness(c.floor, c.keyboardID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        c.bridge.setBrightness(0, c.keyboardID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    let phaseB = counter.value()
    print("  → \(phaseB) fires  (10 writes)\n")

    print("Phase C — 15 s. PRESS THE KEYBOARD BRIGHTNESS KEYS a few times NOW.")
    print("  (does YOUR keypress fire it?)")
    counter.reset()
    c.bridge.setBrightness(0.4, c.keyboardID)
    RunLoop.current.run(until: Date().addingTimeInterval(15))
    let phaseC = counter.value()
    print("  → \(phaseC) fires\n")

    keepAlive.invalidate()
    c.bridge.unregisterChangeNotification()
    c.bridge.setBrightness(0.4, c.keyboardID)

    print("=== Result ===")
    print(String(format: "  idle baseline    : %d", phaseA))
    print(String(format: "  our writes       : %d", phaseB))
    print(String(format: "  your keypresses  : %d", phaseC))
    print("")
    print("How to read it:")
    print("  • our≈0 but keypresses>0  → it distinguishes user input. Yield-to-manual is easy.")
    print("  • our>0 (fires per write) → can't tell us apart by event alone; needs the block's")
    print("    args read (a further spike) or a different detection path.")
    print("  • all≈0                   → nil keys was wrong / wrong mechanism; try other keys.")
    print("Report the three numbers.")
    exit(0)

case "restore":
    guard let c = makeController(args: args) else { exit(2) }
    let level = parseFloat(args.count > 1 ? args[1] : nil) ?? 0.3
    let ok = c.panicRestore(to: min(max(level, 0), 1))
    if ok {
        print("restored: auto-brightness on, level \(String(format: "%.2f", level))")
        exit(0)
    } else {
        fputs("restore command was rejected by the daemon — try the keyboard brightness keys\n", stderr)
        exit(2)
    }

default:
    fputs("unknown command: \(command)\n\n", stderr)
    printUsage()
    exit(1)
}
