// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DitherEngine.swift
//  SublightKit
//
//  Engine B: temporal dithering.
//
//  macOS clamps commanded keyboard brightness to a floor (lowest legal
//  non-zero step). There is no userspace write path to the PWM hardware.
//  What we DO have is a daemon-managed fade: every setBrightness command is
//  applied as a ramp toward the target, not a step.
//
//  The trick: alternate between two LEGAL targets — the floor and off — at a
//  period shorter than the fade ramp. The LED never completes either
//  transition; its instantaneous output hovers in a narrow band whose
//  time-average sits BELOW the floor. The OS's own fade ramp acts as our
//  low-pass filter. The duty fraction (time spent commanding the floor) sets
//  the perceived level — brightness IS duty.
//
//  TIMING. Two ONE-SHOT DispatchSourceTimers ([.strict], 1 ms leeway) on the
//  engine queue, both derived from one anchor (see DitherSchedule):
//
//      HIGH edge n  at  anchor + n * period          → setBrightness(floor)
//      LOW  edge n  at  anchor + (n + duty) * period → setBrightness(0)
//
//  Handlers DO re-arm — that changed — but only ever from an absolute schedule
//  deadline, and always BEFORE the XPC call. The HIGH handler arms this cycle's
//  LOW, then the next cycle's HIGH, and only then speaks to the daemon; the LOW
//  handler arms nothing. Nothing is ever scheduled at "now + interval" except
//  the keeper, which is not an edge timer and has no phase to keep. So the
//  daemon's latency can stretch a handler but can never move a deadline, which
//  is the property the previous one-shot engine lacked when it re-armed at
//  "now + period" AFTER each synchronous XPC call.
//
//  WHY NOT TWO REPEATING TIMERS, which is what this was until 0.5.0. Two
//  repeating sources are two independent clocks. Each is separately liable to
//  be coalesced, deferred or re-based by the scheduler, and once separated
//  nothing pulls them back together: HIGH can slip while LOW does not, and a
//  HIGH that lands past its own cycle's OFF point is dropped by the err-dark
//  rule below. Consecutive drops are a dark ENVELOPE — which is the defect this
//  structure exists to remove. Re-deriving BOTH edges from the one anchor on
//  every HIGH edge bounds their separation at a single cycle by construction.
//
//  A next deadline that is somehow already IN THE PAST is never armed: an
//  absolute past deadline fires on the very next turn of the queue, so arming
//  one turns a re-arm into a spin. The engine takes a fresh anchor instead. Two
//  consecutive err-dark skips do the same, on the reasoning that the phase has
//  stopped being trustworthy rather than that one edge happened to run late.
//
//  IDLE RESILIENCE. The envelopes this structure was built for were observed at
//  Low, Medium AND High — frequency-INDEPENDENT, with an onset around twenty
//  minutes, after the machine had been left alone. Phase drift between
//  independent timers is frequency-DEPENDENT and does not explain that on its
//  own, so the engine also defends the two things a long idle attacks:
//
//    • the ProcessInfo activity assertion (`.latencyCritical` is what holds
//      timer coalescing and App Nap off these timers) is torn down and retaken
//      with the SAME options every 10 minutes, because nothing can be asked
//      whether an assertion is still being honoured;
//    • the suppression keeper drops from 60 s to 2 s after any skip, so the
//      flag reading attached to the next skip is seconds old, not a minute.
//
//  Neither is a fix for a known cause. They are what makes the soak conclusive:
//  see SkipDiagnostic, which records, for every skip, which of the two clocks
//  slipped and how stale the flag reading was when it did.
//
//  Duty changes are phase-continuous: same anchor, same period, only the LOW
//  timer moves, to the smallest anchor + (n + duty) * period strictly in the
//  future. Frequency changes take a new anchor (a phase reset is acceptable).
//
//  Cosmetic enable/disable fades are duty ramps stepped on HIGH edges — no
//  extra timers, no extra XPC. A ramp-down always ends by commanding restore.
//
//  RESTORE RULE: every path that stops ticking ends by COMMANDING the system
//  back into control (auto-brightness on, idle dim released, a visible level),
//  never by merely cancelling a timer. The dirty flag brackets the engagement
//  so a crash in between self-heals on the next launch.
//
//  ERR-DARK, AND WHY IT IS COUNTED. `highEdge` refuses to command ON when this
//  cycle's OFF deadline has already passed — see the comment at the check. The
//  threshold is not a constant: it IS the ON window, duty × period, so it
//  shrinks as the slider goes down (18.75 ms at 8 Hz / duty 0.15). A skip makes
//  a whole cycle dark, and consecutive skips make a dark ENVELOPE. Every skip
//  is therefore counted, timed against its own threshold, and its run length
//  tracked, so "the light went out for half a second" can be attributed to
//  engine policy or ruled out (EngineCounters).
//
//  SIGNPOSTS distinguish the three things that are easy to conflate:
//      EDGE_HIGH / EDGE_LOW   the timer handler ran (a scheduled edge)
//      ON / OFF               a command was issued to the daemon
//      SKIP_HIGH              the edge ran and was deliberately not commanded
//  The bridge adds an XPC interval around the command itself, so edge-to-
//  command and command duration are separable in one Instruments trace.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import os

public enum EngineState: Equatable, Sendable {
    case stopped
    case running(frequencyHz: Double, duty: Double)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// `@unchecked Sendable`, and this is the load-bearing declaration of the
/// engine's central invariant rather than a way around the checker.
///
/// EVERY stored property below is confined to `EngineQueue`. The public API is
/// a set of thin wrappers that hop onto that queue and mutate nothing
/// themselves; the timer handlers already run on it; and the bridge underneath
/// hops onto the same queue, so the daemon only ever sees one caller at a time.
/// That confinement is what makes this type safe to hand between the app's main
/// actor and the queue, and it is checked at run time where it actually
/// matters — see the `dispatchPrecondition` at the bridge's dynamic-dispatch
/// site, through which every CoreBrightness call passes.
public final class DitherEngine: @unchecked Sendable {

    /// THE STABILITY CEILING. Above this the daemon stops honouring the
    /// dither and the keys fall into multi-second dark envelopes.
    ///
    /// PROVENANCE — measured, not guessed (directives #3, #3-B, #4-MEASURE):
    ///   • Boundary: 8.5 Hz goes dark within 30 s; 8.0 Hz held a five-minute
    ///     soak clean (2401/2401 edges, zero skips). In period terms 117.6 ms
    ///     fails and 125.0 ms holds.
    ///   • Causal variable is the CYCLE PERIOD, not the command rate: doubling
    ///     the writes per cycle at a fixed period (24/s through a 166.7 ms
    ///     period) stayed steady. Confirmed with padding that CROSSES a 1/16
    ///     output step, so no dedupe — by exact value or by step — can be
    ///     swallowing the extra writes and faking the result.
    ///   • NOT the engine. Across 9,270 HIGH edges the engine executed 9,265,
    ///     skipped 5 benign isolated cycles, coalesced none, and the daemon
    ///     rejected nothing. The failure is entirely daemon-side.
    ///   • Measured on Mac16,12 (M4) / macOS 26.6.1, 2026-08-23.
    ///   • Margin 0.5 Hz below the 8.5 Hz first failure, per user policy.
    ///
    /// RE-QUALIFY AFTER ANY macOS UPDATE via the soak ritual:
    ///     sublight-cli hold --freq 8 --duty 0.15 --seconds 300
    /// watching the keys, with glances at ~0:30 / ~2:30 / ~4:30. Any dark
    /// envelope at any glance means the boundary moved: the new first-failure
    /// frequency minus 0.5 Hz becomes this constant.
    public static let maxStableFrequencyHz: Double = 8.0

    /// What the app and the CLI will run. The upper bound IS the ceiling.
    public static let frequencyRange: ClosedRange<Double> = 1.0...maxStableFrequencyHz

    /// Research only, reachable from the CLI's `--allow-unstable` and from
    /// nowhere in the app. Everything above `maxStableFrequencyHz` in here is
    /// known-broken on the reference machine; it exists so the boundary can be
    /// re-measured without editing the source.
    public static let unstableFrequencyRange: ClosedRange<Double> = 1.0...40.0
    /// The duty a fade starts from on enable and ramps to on disable: the
    /// brightest point of the hold, so the transition reads as a fade from
    /// and to "just dim" rather than a snap.
    public static let rampEndpointDuty = DitherSchedule.dutyRange.upperBound

    /// Consecutive err-dark skips that force a fresh anchor. One late edge is
    /// a late edge; two in a row means the phase itself is no longer trusted.
    static let skipBurstReanchor: UInt64 = 2

    /// Keeper cadence, in seconds: slow while the dither behaves, fast right
    /// after a skip so the flag states quoted by the NEXT skip record are
    /// fresh. See `SkipDiagnostic`.
    static let keeperIdleSeconds = 60
    static let keeperAlertSeconds = 2

    /// How often the activity assertion is torn down and retaken while running.
    static let activityRefreshSeconds: Double = 600

    public let queue = EngineQueue.queue

    private let commander: BacklightCommanding
    private let dirtyFlag: DirtyFlag
    /// Command-truth tally. Process-wide in production (the bridge feeds the
    /// same one with command latencies); tests inject their own.
    private let diag: EngineDiagnostics
    private static let signposter = OSSignposter(
        subsystem: Log.subsystem, category: "engine")

    // MARK: State — every field below is confined to `queue`.

    private var schedule: DitherSchedule?
    private var highTimer: DispatchSourceTimer?
    private var lowTimer: DispatchSourceTimer?
    private var keeper: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    /// Index of the most recent HIGH edge, derived from the clock.
    private var cycle: UInt64 = 0
    /// The cycle whose LOW edge has already been commanded, if any.
    private var lowFiredInCycle: UInt64?
    private var ramp: Ramp?
    /// True once a backlight command has been issued and until a restore
    /// succeeds. Terminate/signal paths only command a restore when this is
    /// set (or a dirty flag demands it), so quitting an app that never dimmed
    /// does not touch the user's backlight. Explicit `panicRestore` forces it.
    private var engaged = false
    private var _highLevel: Float
    private var _restoreLevel: Float = 0.4
    private var _state: EngineState = .stopped
    private var _allowsUnstable = false

    // Long-run diagnosis state. All of it exists to make one question
    // answerable after the fact: when the keys went dark, WHICH clock slipped?

    /// Uptime at which the current run started. Onset is the measurement that
    /// matters here — every soak in this project's history was five minutes or
    /// less, which is why a twenty-minute-onset defect went unseen — so it is
    /// recorded as a number rather than reconstructed from log timestamps.
    private var runStartNanos: UInt64?
    /// Consecutive err-dark skips. `skipBurstReanchor` of them re-anchor.
    private var skipRun: UInt64 = 0
    /// The most recent LOW edge and how late it ran, so a skip record can say
    /// whether BOTH timers slipped or only the HIGH one.
    private var lastLowCycle: UInt64?
    private var lastLowLatenessMs: Double = 0
    /// Keeper cadence and last tick. The keeper is timer-driven and reads no
    /// user input, so the age of its last tick is an input-independent measure
    /// of whether the whole queue was being starved.
    private var keeperIntervalSeconds = DitherEngine.keeperIdleSeconds
    private var lastKeeperTickNanos: UInt64?
    private var skippedSinceKeeperTick = false
    /// Suppression flag states as READ at the last keeper tick.
    private var lastAutoBrightnessOn: Bool?
    private var lastIdleDimSuspended: Bool?
    /// When the activity assertion was last taken, for the 10 min refresh.
    private var activityBegunNanos: UInt64?

    private struct Ramp {
        let startCycle: UInt64
        let cycles: UInt64
        let from: Double
        let to: Double
        let thenRestore: Bool
    }

    /// Mirror of the engine state for the UI. Always invoked asynchronously
    /// on the main queue; the engine queue never calls out synchronously.
    ///
    /// `@Sendable` because it is handed from whatever set it (the app's main
    /// actor) to the engine queue and invoked from there.
    public var onStateChange: (@Sendable (EngineState) -> Void)?

    // MARK: Init

    /// - Parameters:
    ///   - commander: the hardware seam (BridgeCommander in production).
    ///   - highLevel: the system floor — the HIGH target of the dither.
    ///   - dirtyFlag: crash marker; tests inject one in a temp directory.
    ///   - diagnostics: command-truth tally; defaults to the process-wide one
    ///     the bridge also feeds, so engine edges and daemon latencies land in
    ///     a single report.
    public init(
        commander: BacklightCommanding, highLevel: Float,
        dirtyFlag: DirtyFlag = DirtyFlag(),
        diagnostics: EngineDiagnostics = .shared
    ) {
        self.commander = commander
        self._highLevel = highLevel
        self.dirtyFlag = dirtyFlag
        self.diag = diagnostics
    }

    deinit {
        highTimer?.cancel()
        lowTimer?.cancel()
        keeper?.cancel()
    }

    // MARK: Properties (any thread)

    /// The HIGH target (the floor). Takes effect on the next HIGH edge.
    public var highLevel: Float {
        get { EngineQueue.run { _highLevel } }
        set { EngineQueue.run { _highLevel = min(max(newValue, 0.005), 0.5) } }
    }

    /// The visible level commanded on restore.
    public var restoreLevel: Float {
        get { EngineQueue.run { _restoreLevel } }
        set { EngineQueue.run { _restoreLevel = min(max(newValue, 0), 1) } }
    }

    public var state: EngineState { EngineQueue.run { _state } }
    public var isRunning: Bool { state.isRunning }

    /// Lift the stability ceiling (see `maxStableFrequencyHz`). Research
    /// escape hatch: the CLI's `--allow-unstable` sets it, the app never does.
    /// Takes effect on the next clamp — set it before requesting a frequency.
    public var allowsUnstableFrequency: Bool {
        get { EngineQueue.run { _allowsUnstable } }
        set { EngineQueue.run { _allowsUnstable = newValue } }
    }

    /// The frequency this engine would actually run for `hz`, after clamping.
    /// Callers that display a frequency use this so the UI never shows a value
    /// the engine is not honouring.
    public func clampedFrequency(_ hz: Double) -> Double {
        EngineQueue.run { clampFrequencyLocked(hz) }
    }

    /// Scheduled / fired / executed / skipped edge counts and daemon command
    /// latency for this process. Safe from any thread. Exposed by
    /// `sublight-cli status`, `hold` and `pair-sweep`.
    public var counters: EngineCounters { diag.snapshot() }

    /// Zero the tally — used to bracket one measurement run.
    public func resetCounters() { diag.reset() }

    // MARK: API (any thread; all hop to the queue)

    /// Start dithering, or retune in place if already running. `rampFrom`
    /// fades the duty in from that value over `rampDuration` (enable fade).
    public func start(
        frequencyHz: Double, duty: Double,
        rampFrom: Double? = nil, rampDuration: TimeInterval = 0.35
    ) {
        queue.async {
            self.startLocked(
                frequencyHz: frequencyHz, duty: duty,
                rampFrom: rampFrom, rampDuration: rampDuration)
        }
    }

    /// Change frequency. Takes a fresh anchor (phase reset). No-op if equal
    /// to the current frequency or if not running.
    public func setFrequency(_ hz: Double) {
        queue.async { self.setFrequencyLocked(hz) }
    }

    /// Change duty phase-continuously. No XPC unless the change moves this
    /// cycle's OFF edge into the past (see `applyDuty`). No-op if not running.
    public func setDuty(_ duty: Double) {
        queue.async { self.setDutyLocked(duty) }
    }

    /// Stop and hand control back. With `ramp` > 0 the duty fades up to the
    /// bright end first (disable fade); either way the last command issued is
    /// the restore.
    public func stopAndRestore(ramp: TimeInterval) {
        queue.async { self.stopLocked(ramp: ramp) }
    }

    /// Synchronous restore for terminate and signal paths. Safe from any
    /// thread, including the engine queue itself (runs inline there).
    /// `force` commands the restore even if the engine never engaged — the
    /// panic button and the CLI `restore` command.
    @discardableResult
    public func restoreNow(force: Bool = false) -> Bool {
        EngineQueue.run { restoreLocked(force: force) }
    }

    /// EXIT-TIME restore, for terminate and signal handlers.
    ///
    /// Unlike `panicRestore`/`restoreNow(force:)` this is a NO-OP when the
    /// process has never mutated the backlight. Forcing unconditionally was
    /// wrong in a way that only shows up in the quiet case: launching the app,
    /// never turning dimming on, and quitting would still command
    /// auto-brightness ON and a level of 0.4, overwriting whatever the user
    /// had set by hand. `force` is still right once we HAVE touched the
    /// hardware — calibration suppresses the ALS with direct bridge writes
    /// that never engage the engine, so `engaged` alone would leave it off —
    /// which is exactly what `hardwareTouched` captures and `engaged` does not.
    @discardableResult
    public func restoreOnExit(level: Float? = nil) -> Bool {
        EngineQueue.run {
            if let level { _restoreLevel = min(max(level, 0), 1) }
            guard diag.hardwareTouched else {
                Log.lifecycle.info(
                    "exit: backlight was never commanded this session — leaving system state untouched"
                )
                return true
            }
            return restoreLocked(force: true)
        }
    }

    /// Arm crash recovery for an EXTERNAL suppression the engine itself is not
    /// driving — calibration disables auto-brightness with direct bridge writes
    /// that never engage the engine, so without this a hard crash mid-calibration
    /// would leave the ALS off with no marker to heal it. Paired with a
    /// panicRestore (which clears the flag) on every normal calibration exit.
    public func armCrashRecovery() {
        EngineQueue.run { if !engaged { dirtyFlag.set() } }
    }

    /// Launch-time crash recovery: if a previous process left the dirty flag
    /// (or the legacy UserDefaults marker), command a restore and clear it.
    @discardableResult
    public func recoverFromCrashIfNeeded() -> DirtyFlag.Recovery {
        EngineQueue.run {
            dirtyFlag.recoverIfNeeded {
                diag.noteHardwareTouched()
                return commander.restoreSystemControl(level: _restoreLevel)
            }
        }
    }

    // MARK: - Locked implementation (on `queue`)

    /// Clamp to the range in force and SAY SO when the request was refused.
    /// Silently running at a different frequency than asked for is how a
    /// ceiling becomes invisible and someone spends a week re-diagnosing it.
    private func clampFrequencyLocked(_ hz: Double) -> Double {
        let range = _allowsUnstable ? Self.unstableFrequencyRange : Self.frequencyRange
        guard hz.isFinite else { return range.upperBound }
        let f = min(max(hz, range.lowerBound), range.upperBound)
        if abs(f - hz) > 0.001 {
            Log.engine.notice(
                """
                frequency \(hz, format: .fixed(precision: 2), privacy: .public) Hz clamped to \
                \(f, format: .fixed(precision: 2), privacy: .public) Hz \
                (measured stability ceiling \(Self.maxStableFrequencyHz, format: .fixed(precision: 2), privacy: .public) Hz\
                \(self._allowsUnstable ? ", ceiling LIFTED" : "", privacy: .public))
                """)
        }
        return f
    }

    private func startLocked(
        frequencyHz hz: Double, duty: Double,
        rampFrom: Double?, rampDuration rampDurationRaw: TimeInterval
    ) {
        let f = clampFrequencyLocked(hz)
        let target = DitherSchedule.clampDuty(duty)
        let rampDuration = rampDurationRaw.isFinite ? max(rampDurationRaw, 0) : 0

        if let s = schedule {
            // Already running (possibly mid ramp-down): retune in place and
            // cancel any ramp so the new intent wins.
            ramp = nil
            if abs(s.frequencyHz - f) > 0.001 { setFrequencyLocked(f) }
            applyDuty(target)
            setState(.running(frequencyHz: f, duty: target))
            return
        }

        // Bracket the engagement BEFORE the first backlight command.
        dirtyFlag.set()
        engaged = true
        // The run clock starts here and NOT in `installTimers`, which is also
        // reached by a frequency change and by a skip-burst re-anchor. Onset is
        // measured from when the user started dithering, not from the most
        // recent anchor, or a re-anchor would reset the very number that makes
        // a twenty-minute-onset defect visible.
        runStartNanos = DispatchTime.now().uptimeNanoseconds
        beginActivity()

        diag.noteHardwareTouched()
        let flips = commander.assertSuppression()
        if flips.any {
            Log.engine.notice(
                "start: suppression flags were off — autoBrightnessOn=\(String(describing: flips.autoBrightnessWasOn), privacy: .public) idleDimActive=\(String(describing: flips.idleDimWasActive), privacy: .public); asserted"
            )
        }

        let initial = rampFrom.map(DitherSchedule.clampDuty) ?? target
        let anchor = DispatchTime.now().uptimeNanoseconds
        installTimers(DitherSchedule(anchorNanos: anchor, frequencyHz: f, duty: initial))

        if let from = rampFrom.map(DitherSchedule.clampDuty), abs(from - target) > 0.001 {
            ramp = Ramp(
                startCycle: 0, cycles: max(1, UInt64((rampDuration * f).rounded())),
                from: from, to: target, thenRestore: false)
        }
        startKeeper()
        setState(.running(frequencyHz: f, duty: target))
        Log.engine.info(
            "start: \(f, format: .fixed(precision: 2), privacy: .public) Hz, duty \(target, format: .fixed(precision: 2), privacy: .public)"
        )
    }

    private func setFrequencyLocked(_ hz: Double) {
        guard let s = schedule else { return }
        let f = clampFrequencyLocked(hz)
        guard abs(s.frequencyHz - f) > 0.001 else { return }
        ramp = nil
        let anchor = DispatchTime.now().uptimeNanoseconds
        installTimers(DitherSchedule(anchorNanos: anchor, frequencyHz: f, duty: s.duty))
        setState(.running(frequencyHz: f, duty: s.duty))
        Log.engine.info(
            "frequency: \(f, format: .fixed(precision: 2), privacy: .public) Hz (new anchor)"
        )
    }

    private func setDutyLocked(_ duty: Double) {
        guard let s = schedule else { return }
        ramp = nil
        let d = DitherSchedule.clampDuty(duty)
        applyDuty(d)
        setState(.running(frequencyHz: s.frequencyHz, duty: d))
    }

    private func stopLocked(ramp durationRaw: TimeInterval) {
        guard let s = schedule else {
            restoreLocked(force: false)
            return
        }
        let duration = durationRaw.isFinite ? max(durationRaw, 0) : 0
        let cycles = UInt64((duration * s.frequencyHz).rounded())
        if duration > 0, cycles >= 1 {
            ramp = Ramp(
                startCycle: cycle, cycles: cycles, from: s.duty,
                to: Self.rampEndpointDuty, thenRestore: true)
            Log.engine.info(
                "stop: ramping down over \(cycles, privacy: .public) cycles, then restore"
            )
        } else {
            restoreLocked(force: false)
        }
    }

    /// Cancel everything and command system control back. The ONLY place the
    /// timers are cancelled, so cancelling without restoring is impossible.
    @discardableResult
    private func restoreLocked(force: Bool) -> Bool {
        let wasRunning = schedule != nil
        var restoreOK = true
        highTimer?.cancel(); highTimer = nil
        lowTimer?.cancel(); lowTimer = nil
        schedule = nil
        ramp = nil
        lowFiredInCycle = nil
        runStartNanos = nil
        skipRun = 0
        lastLowCycle = nil
        lastLowLatenessMs = 0
        lastKeeperTickNanos = nil
        lastAutoBrightnessOn = nil
        lastIdleDimSuspended = nil
        stopKeeper()
        endActivity()

        // NOT `|| dirtyFlag.isSet`: the flag is shared with the CLI, and another
        // live process's flag must not make us restore its hold. Our own
        // engagement is tracked by `engaged`; explicit restores pass `force`.
        if engaged || force {
            let level = _restoreLevel
            diag.noteHardwareTouched()
            if commander.restoreSystemControl(level: level) {
                engaged = false
                dirtyFlag.clear()
                Log.engine.info(
                    "restored system control (level \(level, format: .fixed(precision: 2), privacy: .public))"
                )
            } else {
                restoreOK = false
                Log.engine.error(
                    "restore command rejected by the daemon; dirty flag kept")
            }
        }
        if wasRunning { setState(.stopped) }
        return restoreOK
    }

    // MARK: Timers

    /// Install a fresh schedule and arm cycle 0's two edges. Every later edge
    /// is armed by `highEdge` from this same anchor — see the TIMING note.
    private func installTimers(_ s: DitherSchedule) {
        highTimer?.cancel()
        lowTimer?.cancel()
        schedule = s
        cycle = 0
        lowFiredInCycle = nil
        skipRun = 0
        lastLowCycle = nil
        lastLowLatenessMs = 0

        diag.noteAnchorReset(periodNanos: s.periodNanos, onWindowNanos: s.lowOffsetNanos)

        // Cycle 0's edges are armed unconditionally: the anchor was taken from
        // the clock a moment ago, so neither deadline can already be in the
        // past and the re-anchor guard has nothing to catch here. Armed before
        // `resume()`, so a source is never live without a deadline on it.
        let high = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        high.setEventHandler { [weak self] in self?.highEdge() }
        high.schedule(
            deadline: DispatchTime(uptimeNanoseconds: s.highDeadline(cycle: 0)),
            repeating: .never, leeway: .milliseconds(1))

        let low = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        low.setEventHandler { [weak self] in self?.lowEdge() }
        low.schedule(
            deadline: DispatchTime(uptimeNanoseconds: s.lowDeadline(cycle: 0)),
            repeating: .never, leeway: .milliseconds(1))

        highTimer = high
        lowTimer = low
        high.resume()
        low.resume()
    }

    /// THE ARM DECISION, kept pure so the guard itself is testable without
    /// having to manufacture a stalled queue. An absolute deadline that is
    /// already in the past fires on the very next turn of the queue, so arming
    /// one converts a re-arm into a spin: such a deadline is never armed, and
    /// the engine takes a fresh anchor instead.
    static func shouldReanchor(deadline: UInt64, now: UInt64) -> Bool {
        deadline <= now
    }

    /// Arm the HIGH one-shot for `cycle` from its absolute schedule deadline.
    /// Returns false when the caller must re-anchor rather than arm.
    private func armHigh(cycle n: UInt64) -> Bool {
        guard let s = schedule, let t = highTimer else { return true }
        let due = s.highDeadline(cycle: n)
        guard
            !Self.shouldReanchor(
                deadline: due, now: DispatchTime.now().uptimeNanoseconds)
        else { return false }
        t.schedule(
            deadline: DispatchTime(uptimeNanoseconds: due),
            repeating: .never, leeway: .milliseconds(1))
        return true
    }

    /// Arm the LOW one-shot for `cycle`. Same rule as `armHigh`.
    private func armLow(cycle n: UInt64) -> Bool {
        guard let s = schedule, let t = lowTimer else { return true }
        let due = s.lowDeadline(cycle: n)
        guard
            !Self.shouldReanchor(
                deadline: due, now: DispatchTime.now().uptimeNanoseconds)
        else { return false }
        t.schedule(
            deadline: DispatchTime(uptimeNanoseconds: due),
            repeating: .never, leeway: .milliseconds(1))
        return true
    }

    /// Take a fresh anchor at now, keeping frequency and duty. A phase reset is
    /// visible only as one irregular cycle, which is a far smaller artefact
    /// than the dark envelope it is being used to break out of.
    private func reanchorLocked(reason: String) {
        guard let s = schedule else { return }
        Log.engine.notice(
            """
            re-anchor (\(reason, privacy: .public)): \
            \(s.frequencyHz, format: .fixed(precision: 2), privacy: .public) Hz \
            duty \(s.duty, format: .fixed(precision: 2), privacy: .public)
            """)
        installTimers(
            DitherSchedule(
                anchorNanos: DispatchTime.now().uptimeNanoseconds,
                frequencyHz: s.frequencyHz, duty: s.duty))
    }

    /// Assemble the one-line discrimination record for a skip.
    ///
    /// The suppression flags are the LAST KEEPER READING, not a fresh one:
    /// reading them is a daemon round trip and this is the timing-critical
    /// path. `secondsSinceKeeperTick` is what makes them interpretable, and is
    /// -1 when the keeper has not ticked yet (a run shorter than its cadence).
    private func skipDiagnostic(
        cycle n: UInt64, highLatenessMs: Double, at now: UInt64,
        schedule s: DitherSchedule
    ) -> SkipDiagnostic {
        var d = SkipDiagnostic()
        d.cycle = n
        d.highLatenessMs = highLatenessMs
        d.lowLatenessMs = lastLowLatenessMs
        d.lowWasSameCycle = lastLowCycle == n
        d.lowAlsoLate = lastLowLatenessMs > Double(s.earlyFireGuard) / 1e6
        d.elapsedRunSeconds =
            runStartNanos.map { Double(now > $0 ? now - $0 : 0) / 1e9 } ?? 0
        d.secondsSinceKeeperTick =
            lastKeeperTickNanos.map { Double(now > $0 ? now - $0 : 0) / 1e9 } ?? -1
        d.autoBrightnessOn = lastAutoBrightnessOn
        d.idleDimSuspended = lastIdleDimSuspended
        return d
    }

    private func highEdge() {
        guard let s0 = schedule else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        cycle = s0.cycle(at: now)
        Self.signposter.emitEvent("EDGE_HIGH")
        diag.noteHighEdge(cycle: cycle)

        // Ramps step here, BEFORE this edge's XPC: the duty for the upcoming
        // LOW edge is fixed first, then the daemon is spoken to. The ramp step
        // must NOT command an immediate OFF (allowImmediateLow: false) — that
        // is the slider's behaviour, not a ramp's, and firing it here would
        // send OFF then ON back-to-back in one handler.
        if let r = ramp {
            let progress =
                r.cycles == 0 ? 1 : Double(cycle &- r.startCycle) / Double(r.cycles)
            if progress >= 1 {
                ramp = nil
                if r.thenRestore {
                    restoreLocked(force: false)  // the last command is the restore
                    return
                }
                applyDuty(r.to, allowImmediateLow: false)
            } else {
                applyDuty(r.from + (r.to - r.from) * progress, allowImmediateLow: false)
            }
        }

        guard let s = schedule else { return }
        // Err DARK, never bright: if this cycle's OFF deadline is already in the
        // past (a HIGH edge that ran late), skip the ON. Commanding the floor
        // now would leave the cycle bright past its OFF point — the exact
        // brightening the immediate-OFF rule in applyDuty exists to avoid. This
        // must NOT also require `lowFiredInCycle != cycle`: when applyDuty has
        // already commanded this cycle's OFF, a late HIGH would otherwise fall
        // through and relight the keys. Only a duty RAISE moves the deadline
        // back into the future, and that case correctly does not skip.
        if s.lowDeadline(cycle: cycle) <= now {
            let due = s.highDeadline(cycle: cycle)
            let latenessMs = Double(now > due ? now - due : 0) / 1e6
            let thresholdMs = Double(s.lowOffsetNanos) / 1e6
            let record = skipDiagnostic(
                cycle: cycle, highLatenessMs: latenessMs, at: now, schedule: s)
            Self.signposter.emitEvent("SKIP_HIGH")
            diag.noteHighSkipped(
                latenessMs: latenessMs, thresholdMs: thresholdMs, diagnostic: record)
            // NOTICE, not debug: this is the event the long-run investigation
            // is built on, and a level the unified log discards by default
            // would make every soak unadjudicable after the fact.
            Log.engine.notice(
                """
                edge HIGH SKIPPED (err-dark) \
                threshold=\(thresholdMs, format: .fixed(precision: 3), privacy: .public)ms \
                (= ON window, duty x period) \(record.line, privacy: .public)
                """)

            skipRun &+= 1
            skippedSinceKeeperTick = true
            escalateKeeper()

            // A SKIPPED HIGH DOES NOT ARM ITS LOW. The cycle is being kept dark
            // deliberately; an OFF edge for a cycle that was never lit is a
            // command with nothing to undo, and arming it would put a second
            // XPC into an already-late cycle for no visible effect.
            if skipRun >= Self.skipBurstReanchor {
                reanchorLocked(
                    reason: "\(skipRun) consecutive err-dark skips")
            } else if !armHigh(cycle: cycle &+ 1) {
                reanchorLocked(reason: "next HIGH deadline already in the past")
            }
            return
        }

        skipRun = 0

        // SCHEDULE FIRST, XPC SECOND — and in this order: this cycle's OFF edge,
        // then the next cycle's ON edge, both re-derived from the one anchor.
        // By the time the daemon is spoken to below, the next two deadlines are
        // already fixed, so however long the call takes it cannot move them.
        guard armLow(cycle: cycle) else {
            reanchorLocked(reason: "LOW deadline for this cycle already in the past")
            return
        }
        guard armHigh(cycle: cycle &+ 1) else {
            reanchorLocked(reason: "next HIGH deadline already in the past")
            return
        }

        let issuedAt = DispatchTime.now().uptimeNanoseconds
        let due = s.highDeadline(cycle: cycle)
        Log.engine.debug(
            """
            edge HIGH cycle \(self.cycle, privacy: .public) EXECUTE \
            t=\(Double(issuedAt) / 1e6, format: .fixed(precision: 3), privacy: .public)ms \
            late=\(Double(issuedAt > due ? issuedAt - due : 0) / 1e6, format: .fixed(precision: 3), privacy: .public)ms \
            value=\(self._highLevel, format: .fixed(precision: 4), privacy: .public)
            """)
        Self.signposter.emitEvent("ON")
        diag.noteHighExecuted(atNanos: issuedAt)
        diag.noteHardwareTouched()
        commander.setBrightness(_highLevel)
    }

    /// - Parameter immediate: true when called by `applyDuty` for an OFF edge
    ///   whose deadline the duty change moved into the past. That is an
    ///   executed command but NOT a timer fire, so it is not counted as one.
    private func lowEdge(immediate: Bool = false) {
        guard let s = schedule else { return }
        // Attribute this OFF to the cycle it was SCHEDULED for, not the cycle
        // the wall clock is in now. A late handler (queue stalled past the next
        // HIGH edge) would otherwise stamp cycle n+1 and cause the next
        // applyDuty to skip cycle n+1's OFF — a dropped edge, i.e. a bright
        // cycle. Subtracting the low offset lands back in the scheduled cycle.
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduledNow = now > s.lowOffsetNanos ? now - s.lowOffsetNanos : 0
        let n = s.cycle(at: scheduledNow)
        lowFiredInCycle = n
        if !immediate {
            Self.signposter.emitEvent("EDGE_LOW")
            diag.noteLowEdge(cycle: n)
        }
        let issuedAt = DispatchTime.now().uptimeNanoseconds
        let due = s.lowDeadline(cycle: n)
        Log.engine.debug(
            """
            edge LOW cycle \(n, privacy: .public) EXECUTE\(immediate ? " (immediate, duty change)" : "", privacy: .public) \
            t=\(Double(issuedAt) / 1e6, format: .fixed(precision: 3), privacy: .public)ms \
            late=\(Double(issuedAt > due ? issuedAt - due : 0) / 1e6, format: .fixed(precision: 3), privacy: .public)ms \
            value=0.0000
            """)
        // Remember how late THIS edge ran, so the next skip record can say
        // whether both clocks slipped together or only the HIGH one. An
        // immediate OFF from a duty change is not a timer fire and says nothing
        // about the scheduler, so it is not recorded.
        if !immediate {
            lastLowCycle = n
            lastLowLatenessMs = Double(issuedAt > due ? issuedAt - due : 0) / 1e6
        }
        Self.signposter.emitEvent("OFF")
        diag.noteLowExecuted()
        diag.noteHardwareTouched()
        commander.setBrightness(0)
    }

    /// Phase-continuous duty change: same anchor and period; only the LOW
    /// timer moves, to the smallest anchor + (n + duty) * period strictly in
    /// the future.
    ///
    /// JUDGMENT CALL, recorded here: if this cycle's OFF edge has not fired
    /// yet and the new duty puts it in the past (the slider being dragged
    /// toward dimmer), the OFF edge is commanded immediately instead of being
    /// dropped. Dropping it would leave one cycle at 100 % duty — a visible
    /// brightening on every such drag event. This is the only XPC a duty
    /// change can produce, and at most one per cycle.
    private func applyDuty(_ duty: Double, allowImmediateLow: Bool = true) {
        guard var s = schedule, let low = lowTimer else { return }
        let d = DitherSchedule.clampDuty(duty)
        guard abs(d - s.duty) > 0.0005 else { return }
        s = s.withDuty(d)
        schedule = s
        diag.noteOnWindow(nanos: s.lowOffsetNanos)

        let now = DispatchTime.now().uptimeNanoseconds
        let current = s.cycle(at: now)
        if lowFiredInCycle != current, s.lowDeadline(cycle: current) <= now {
            if allowImmediateLow {
                lowEdge(immediate: true)
            } else {
                // A ramp step lowered the duty past this cycle's OFF point.
                // The rule says a ramp must not fire OFF here, so this cycle's
                // OFF is genuinely dropped — counted, not silent.
                diag.noteLowSkipped()
                Log.engine.debug(
                    "edge LOW cycle \(current, privacy: .public) DROPPED (ramp step moved the OFF deadline into the past)"
                )
            }
        }
        // One-shot, like every other edge arm: `nextLowDeadline` returns an
        // absolute deadline strictly in the future, and the next HIGH edge
        // re-arms LOW from the same anchor anyway, so there is no repeat to set.
        let next = s.nextLowDeadline(after: now, lowAlreadyFiredIn: lowFiredInCycle)
        low.schedule(
            deadline: DispatchTime(uptimeNanoseconds: next),
            repeating: .never, leeway: .milliseconds(1))
    }

    // MARK: Keeper

    /// Re-assertion of the suppression flags while running. This replaces the
    /// old 2 s main-thread watchdog. It is NOT an edge timer, so it is
    /// non-strict with generous leeway and is the one timer allowed to be
    /// scheduled relative to now. Getters exist for both flags on the reference
    /// build, so it reads before writing and logs any flip, with the elapsed
    /// run time attached — a flag that flips twenty minutes in and a flag that
    /// flips immediately are different faults.
    ///
    /// The cadence is adaptive; see `armKeeper`.
    ///
    /// RETAINED — the deletion criterion was tested and FAILED, decisively.
    ///
    /// The criterion was: if no "flag flipped mid-run" line is ever observed,
    /// delete the keeper, because the one-shot assertion on start and resume
    /// would then be proven sufficient. Checked against the unified log over a
    /// full day of use (2026-08-23): **33 mid-run flip warnings**, across three
    /// separate app sessions. In every one, `autoBrightnessOn` had come back
    /// TRUE — something in the system re-enables keyboard auto-brightness
    /// while the dither is running. Nine of the thirty-three were caught by the
    /// very next 60 s tick after a re-assertion, so the flip can recur within a
    /// minute of being corrected.
    ///
    /// The read-before-write is sighted, not blind: both
    /// `isAutoBrightnessEnabledForKeyboard:` and
    /// `isIdleDimmingSuspendedOnKeyboard:` are present on the reference
    /// machine, so those warnings reflect an actual observed state, not a
    /// blind re-assert.
    ///
    /// Without this timer the ambient light sensor would take the backlight
    /// back mid-hold and the sub-floor dither would be silently stomped —
    /// which is exactly the class of intermittent, hard-to-attribute fault the
    /// rest of this file exists to prevent. It stays.
    private func startKeeper() {
        stopKeeper()
        keeperIntervalSeconds = Self.keeperIdleSeconds
        skippedSinceKeeperTick = false
        lastKeeperTickNanos = nil
        let k = DispatchSource.makeTimerSource(queue: queue)
        k.setEventHandler { [weak self] in self?.keeperFired() }
        keeper = k
        armKeeper()
        k.resume()
    }

    /// ADAPTIVE CADENCE: `keeperIdleSeconds` while the dither behaves,
    /// `keeperAlertSeconds` once anything has skipped. The fast cadence is not
    /// about correcting the flags sooner — it is about the READING. Every skip
    /// record quotes the flag states from the last keeper tick, so at 60 s that
    /// reading can be most of a minute stale and proves very little about the
    /// moment the keys went dark; at 2 s it is contemporaneous. The engine
    /// falls back to the slow cadence after one clean tick.
    private func armKeeper() {
        guard let k = keeper else { return }
        let seconds = keeperIntervalSeconds
        k.schedule(
            deadline: .now() + .seconds(seconds), repeating: .seconds(seconds),
            leeway: .seconds(seconds >= Self.keeperIdleSeconds ? 5 : 1))
    }

    private func escalateKeeper() {
        guard keeperIntervalSeconds != Self.keeperAlertSeconds else { return }
        keeperIntervalSeconds = Self.keeperAlertSeconds
        armKeeper()
        Log.engine.notice(
            "keeper: cadence -> \(Self.keeperAlertSeconds, privacy: .public) s after a skip"
        )
    }

    private func stopKeeper() {
        keeper?.cancel()
        keeper = nil
    }

    private func keeperFired() {
        guard schedule != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = runStartNanos.map { Double(now > $0 ? now - $0 : 0) / 1e9 } ?? 0
        lastKeeperTickNanos = now

        refreshActivityIfDue(now: now, elapsedRunSeconds: elapsed)

        diag.noteHardwareTouched()
        // READ BOTH FLAGS BEFORE RE-ASSERTING. `assertSuppression` reads each
        // one where a getter exists and reports what it found, so these are
        // observed states rather than assumptions — and they are stamped here
        // because the next skip record quotes them (see `skipDiagnostic`).
        let flips = commander.assertSuppression()
        lastAutoBrightnessOn = flips.autoBrightnessWasOn
        lastIdleDimSuspended = flips.idleDimWasActive.map { !$0 }
        if flips.any {
            Log.engine.warning(
                """
                keeper: suppression flag flipped mid-run at \
                t+\(elapsed, format: .fixed(precision: 1), privacy: .public) s — \
                autoBrightnessOn=\(String(describing: flips.autoBrightnessWasOn), privacy: .public) \
                idleDimActive=\(String(describing: flips.idleDimWasActive), privacy: .public); re-asserted
                """)
        } else {
            Log.engine.debug(
                "keeper: suppression flags intact at t+\(elapsed, format: .fixed(precision: 1), privacy: .public) s"
            )
        }

        let want =
            skippedSinceKeeperTick ? Self.keeperAlertSeconds : Self.keeperIdleSeconds
        skippedSinceKeeperTick = false
        if want != keeperIntervalSeconds {
            keeperIntervalSeconds = want
            armKeeper()
            Log.engine.notice(
                "keeper: cadence -> \(want, privacy: .public) s (a full tick with no skip)"
            )
        }
    }

    // MARK: Activity assertion

    /// Held only while running. `.userInitiatedAllowingIdleSystemSleep`, NOT
    /// `.userInitiated`: the latter disables idle system sleep, and a MacBook
    /// left dimming overnight must still be able to sleep. `.latencyCritical`
    /// keeps timer coalescing and App Nap off the edge timers.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Sublight dithering")
        activityBegunNanos = DispatchTime.now().uptimeNanoseconds
    }

    private func endActivity() {
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        activityBegunNanos = nil
    }

    /// Tear the assertion down and take it again with THE SAME OPTIONS every
    /// `activityRefreshSeconds`.
    ///
    /// Checked on keeper ticks rather than from a third timer, so the cadence
    /// is quantised to the keeper's: the refresh lands in [600 s, 600 s + one
    /// keeper period), and measured runs show both 600.0 s and 660.0 s
    /// intervals. That is deliberate — the alternative is another timer on the
    /// engine queue to save at most a minute of staleness on a ten-minute
    /// refresh, and this queue's timer population is exactly what the rest of
    /// this file is careful about.
    ///
    /// The assertion is what holds timer coalescing and App Nap off the edge
    /// timers, and a dark envelope that only appears after twenty idle minutes
    /// is exactly what a silently weakened assertion would look like. There is
    /// no API that answers "is this assertion still being honoured?", so the
    /// only available move is to retake it on a cadence and log that we did —
    /// which also dates it in the log alongside any skip record. If the
    /// envelopes stop at the refresh boundary, that is the answer; if they do
    /// not, this rules the assertion out, which is worth as much.
    private func refreshActivityIfDue(now: UInt64, elapsedRunSeconds: Double) {
        guard let begun = activityBegunNanos else { return }
        let ageSeconds = Double(now > begun ? now - begun : 0) / 1e9
        guard ageSeconds >= Self.activityRefreshSeconds else { return }
        endActivity()
        beginActivity()
        Log.engine.notice(
            """
            activity assertion refreshed after \
            \(ageSeconds, format: .fixed(precision: 1), privacy: .public) s at \
            t+\(elapsedRunSeconds, format: .fixed(precision: 1), privacy: .public) s \
            (userInitiatedAllowingIdleSystemSleep, latencyCritical)
            """)
    }

    // MARK: State mirror

    private func setState(_ s: EngineState) {
        guard s != _state else { return }
        _state = s
        // Read the callback HERE, on the engine queue, and send only it — not
        // `self`. Capturing `self` would hand a queue-confined object to the
        // main queue, which is exactly the race the confinement exists to
        // prevent, and which Swift 6 refuses to compile.
        let notify = onStateChange
        DispatchQueue.main.async { notify?(s) }
    }
}
