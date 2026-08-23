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
//  TIMING. Two repeating DispatchSourceTimers ([.strict], 1 ms leeway) on the
//  engine queue, both derived from one anchor (see DitherSchedule):
//
//      HIGH edge n  at  anchor + n * period          → setBrightness(floor)
//      LOW  edge n  at  anchor + (n + duty) * period → setBrightness(0)
//
//  Every deadline is anchor arithmetic; nothing is ever scheduled at
//  "now + interval" and no handler re-arms its own timer. The XPC call inside
//  a handler happens after the schedule is already fixed, so the daemon's
//  latency can stretch a handler but never a period. The previous engine
//  re-armed one-shot after each synchronous XPC call, which let that latency
//  accumulate into every half-phase.
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
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import os

public enum EngineState: Equatable {
    case stopped
    case running(frequencyHz: Double, duty: Double)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public final class DitherEngine {

    public static let frequencyRange: ClosedRange<Double> = 1.0...40.0
    /// The duty a fade starts from on enable and ramps to on disable: the
    /// brightest point of the hold, so the transition reads as a fade from
    /// and to "just dim" rather than a snap.
    public static let rampEndpointDuty = DitherSchedule.dutyRange.upperBound

    public let queue = EngineQueue.queue

    private let commander: BacklightCommanding
    private let dirtyFlag: DirtyFlag
    private static let signposter = OSSignposter(subsystem: Log.subsystem, category: "engine")

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

    private struct Ramp {
        let startCycle: UInt64
        let cycles: UInt64
        let from: Double
        let to: Double
        let thenRestore: Bool
    }

    /// Mirror of the engine state for the UI. Always invoked asynchronously
    /// on the main queue; the engine queue never calls out synchronously.
    public var onStateChange: ((EngineState) -> Void)?

    // MARK: Init

    /// - Parameters:
    ///   - commander: the hardware seam (BridgeCommander in production).
    ///   - highLevel: the system floor — the HIGH target of the dither.
    ///   - dirtyFlag: crash marker; tests inject one in a temp directory.
    public init(commander: BacklightCommanding, highLevel: Float, dirtyFlag: DirtyFlag = DirtyFlag()) {
        self.commander = commander
        self._highLevel = highLevel
        self.dirtyFlag = dirtyFlag
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

    // MARK: API (any thread; all hop to the queue)

    /// Start dithering, or retune in place if already running. `rampFrom`
    /// fades the duty in from that value over `rampDuration` (enable fade).
    public func start(frequencyHz: Double, duty: Double,
                      rampFrom: Double? = nil, rampDuration: TimeInterval = 0.35) {
        queue.async { self.startLocked(frequencyHz: frequencyHz, duty: duty,
                                       rampFrom: rampFrom, rampDuration: rampDuration) }
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
                commander.restoreSystemControl(level: _restoreLevel)
            }
        }
    }

    // MARK: - Locked implementation (on `queue`)

    private static func clampFrequency(_ hz: Double) -> Double {
        guard hz.isFinite else { return 9.0 }
        return min(max(hz, frequencyRange.lowerBound), frequencyRange.upperBound)
    }

    private func startLocked(frequencyHz hz: Double, duty: Double,
                             rampFrom: Double?, rampDuration rampDurationRaw: TimeInterval) {
        let f = Self.clampFrequency(hz)
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
        beginActivity()

        let flips = commander.assertSuppression()
        if flips.any {
            Log.engine.notice("start: suppression flags were off — autoBrightnessOn=\(String(describing: flips.autoBrightnessWasOn), privacy: .public) idleDimActive=\(String(describing: flips.idleDimWasActive), privacy: .public); asserted")
        }

        let initial = rampFrom.map(DitherSchedule.clampDuty) ?? target
        let anchor = DispatchTime.now().uptimeNanoseconds
        installTimers(DitherSchedule(anchorNanos: anchor, frequencyHz: f, duty: initial))

        if let from = rampFrom.map(DitherSchedule.clampDuty), abs(from - target) > 0.001 {
            ramp = Ramp(startCycle: 0, cycles: max(1, UInt64((rampDuration * f).rounded())),
                        from: from, to: target, thenRestore: false)
        }
        startKeeper()
        setState(.running(frequencyHz: f, duty: target))
        Log.engine.info("start: \(f, format: .fixed(precision: 2), privacy: .public) Hz, duty \(target, format: .fixed(precision: 2), privacy: .public)")
    }

    private func setFrequencyLocked(_ hz: Double) {
        guard let s = schedule else { return }
        let f = Self.clampFrequency(hz)
        guard abs(s.frequencyHz - f) > 0.001 else { return }
        ramp = nil
        let anchor = DispatchTime.now().uptimeNanoseconds
        installTimers(DitherSchedule(anchorNanos: anchor, frequencyHz: f, duty: s.duty))
        setState(.running(frequencyHz: f, duty: s.duty))
        Log.engine.info("frequency: \(f, format: .fixed(precision: 2), privacy: .public) Hz (new anchor)")
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
            ramp = Ramp(startCycle: cycle, cycles: cycles, from: s.duty,
                        to: Self.rampEndpointDuty, thenRestore: true)
            Log.engine.info("stop: ramping down over \(cycles, privacy: .public) cycles, then restore")
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
        stopKeeper()
        endActivity()

        // NOT `|| dirtyFlag.isSet`: the flag is shared with the CLI, and another
        // live process's flag must not make us restore its hold. Our own
        // engagement is tracked by `engaged`; explicit restores pass `force`.
        if engaged || force {
            let level = _restoreLevel
            if commander.restoreSystemControl(level: level) {
                engaged = false
                dirtyFlag.clear()
                Log.engine.info("restored system control (level \(level, format: .fixed(precision: 2), privacy: .public))")
            } else {
                restoreOK = false
                Log.engine.error("restore command rejected by the daemon; dirty flag kept")
            }
        }
        if wasRunning { setState(.stopped) }
        return restoreOK
    }

    // MARK: Timers

    private func installTimers(_ s: DitherSchedule) {
        highTimer?.cancel()
        lowTimer?.cancel()
        schedule = s
        cycle = 0
        lowFiredInCycle = nil

        let period = DispatchTimeInterval.nanoseconds(Int(s.periodNanos))

        let high = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        high.setEventHandler { [weak self] in self?.highEdge() }
        high.schedule(deadline: DispatchTime(uptimeNanoseconds: s.highDeadline(cycle: 0)),
                      repeating: period, leeway: .milliseconds(1))

        let low = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        low.setEventHandler { [weak self] in self?.lowEdge() }
        low.schedule(deadline: DispatchTime(uptimeNanoseconds: s.lowDeadline(cycle: 0)),
                     repeating: period, leeway: .milliseconds(1))

        highTimer = high
        lowTimer = low
        high.resume()
        low.resume()
    }

    private func highEdge() {
        guard let s0 = schedule else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        cycle = s0.cycle(at: now)

        // Ramps step here, BEFORE this edge's XPC: the duty for the upcoming
        // LOW edge is fixed first, then the daemon is spoken to. The ramp step
        // must NOT command an immediate OFF (allowImmediateLow: false) — that
        // is the slider's behaviour, not a ramp's, and firing it here would
        // send OFF then ON back-to-back in one handler.
        if let r = ramp {
            let progress = r.cycles == 0 ? 1 : Double(cycle &- r.startCycle) / Double(r.cycles)
            if progress >= 1 {
                ramp = nil
                if r.thenRestore {
                    restoreLocked(force: false)   // the last command is the restore
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
        if s.lowDeadline(cycle: cycle) <= now { return }

        Self.signposter.emitEvent("ON")
        commander.setBrightness(_highLevel)
    }

    private func lowEdge() {
        guard let s = schedule else { return }
        // Attribute this OFF to the cycle it was SCHEDULED for, not the cycle
        // the wall clock is in now. A late handler (queue stalled past the next
        // HIGH edge) would otherwise stamp cycle n+1 and cause the next
        // applyDuty to skip cycle n+1's OFF — a dropped edge, i.e. a bright
        // cycle. Subtracting the low offset lands back in the scheduled cycle.
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduledNow = now > s.lowOffsetNanos ? now - s.lowOffsetNanos : 0
        lowFiredInCycle = s.cycle(at: scheduledNow)
        Self.signposter.emitEvent("OFF")
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

        let now = DispatchTime.now().uptimeNanoseconds
        let current = s.cycle(at: now)
        if allowImmediateLow, lowFiredInCycle != current, s.lowDeadline(cycle: current) <= now {
            lowEdge()
        }
        let next = s.nextLowDeadline(after: now, lowAlreadyFiredIn: lowFiredInCycle)
        low.schedule(deadline: DispatchTime(uptimeNanoseconds: next),
                     repeating: .nanoseconds(Int(s.periodNanos)), leeway: .milliseconds(1))
    }

    // MARK: Keeper

    /// Slow re-assertion of the suppression flags while running. This
    /// replaces the old 2 s main-thread watchdog. It is NOT an edge timer,
    /// so it is non-strict with generous leeway and is the one timer allowed
    /// to be scheduled relative to now. Getters exist for both flags on the
    /// reference build, so it reads before writing and logs any flip.
    ///
    /// DELETION CRITERION (Tier-4 pass): if no "flag flipped mid-run" line is
    /// observed over extended use, the keeper is removed — the one-shot
    /// assertion on start/resume is then proven sufficient.
    private func startKeeper() {
        stopKeeper()
        let k = DispatchSource.makeTimerSource(queue: queue)
        k.setEventHandler { [weak self] in self?.keeperFired() }
        k.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60), leeway: .seconds(5))
        k.resume()
        keeper = k
    }

    private func stopKeeper() {
        keeper?.cancel()
        keeper = nil
    }

    private func keeperFired() {
        guard schedule != nil else { return }
        let flips = commander.assertSuppression()
        if flips.any {
            Log.engine.warning("keeper: suppression flag flipped mid-run — autoBrightnessOn=\(String(describing: flips.autoBrightnessWasOn), privacy: .public) idleDimActive=\(String(describing: flips.idleDimWasActive), privacy: .public); re-asserted")
        } else {
            Log.engine.debug("keeper: suppression flags intact")
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
    }

    private func endActivity() {
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: State mirror

    private func setState(_ s: EngineState) {
        guard s != _state else { return }
        _state = s
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(s)
        }
    }
}
