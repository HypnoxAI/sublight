// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DitherEngineTests.swift — phase logic and restore guarantees through the
//  BacklightCommanding seam. No hardware: a recorder stands in for the bridge.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest

@testable import SublightKit

/// Records every command with its uptime timestamp. Thread-safe: the engine
/// calls from its own queue.
final class RecordingCommander: BacklightCommanding {
    enum Command: Equatable {
        case set(Float)
        case restore(Float)
        case assertSuppression
    }
    struct Entry { let command: Command; let at: UInt64 }

    private let lock = NSLock()
    private var _entries: [Entry] = []
    var flips = SuppressionFlips()
    /// Simulated daemon round trip, in seconds. Stands in for a slow XPC call
    /// so a test can prove the schedule was already fixed before it was made.
    var commandDelay: TimeInterval = 0
    /// Called on every command, before it is recorded (used to observe the
    /// dirty flag at the moment of the first command).
    var onCommand: ((Command) -> Void)?

    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return _entries }
    var commands: [Command] { entries.map(\.command) }

    private func record(_ c: Command) {
        onCommand?(c)
        lock.lock();
        _entries.append(Entry(command: c, at: DispatchTime.now().uptimeNanoseconds));
        lock.unlock()
    }

    func setBrightness(_ value: Float) -> Bool {
        record(.set(value))
        if commandDelay > 0 { Thread.sleep(forTimeInterval: commandDelay) }
        return true
    }
    func restoreSystemControl(level: Float) -> Bool {
        record(.restore(level)); return true
    }
    func assertSuppression() -> SuppressionFlips {
        record(.assertSuppression); return flips
    }
}

final class DitherEngineTests: XCTestCase {

    private var tempDir: URL!
    private var flag: DirtyFlag!
    private var recorder: RecordingCommander!
    private var engine: DitherEngine!
    /// Private tally per test: the engine defaults to the process-wide one,
    /// which every other test in the run would otherwise pollute.
    private var diag: EngineDiagnostics!

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sublight-engine-\(UUID().uuidString)")
        suiteName = "sublight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        flag = DirtyFlag(directory: tempDir, defaults: defaults)
        recorder = RecordingCommander()
        diag = EngineDiagnostics()
        engine = DitherEngine(
            commander: recorder, highLevel: 0.0625, dirtyFlag: flag, diagnostics: diag)
        // These tests exercise the engine's TIMING logic — alternation, phase
        // continuity, ramps, the err-dark rule — and deliberately run above the
        // product's stability ceiling so a test sees dozens of edges in a
        // fraction of a second instead of waiting out 125 ms periods. The
        // ceiling is a separate concern with its own suite
        // (FrequencyCeilingTests); pretending it doesn't exist here would make
        // every timing assertion in this file a test of the clamp instead.
        engine.allowsUnstableFrequency = true
    }

    override func tearDown() {
        engine.restoreNow()
        engine = nil
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName!).plist")
        try? FileManager.default.removeItem(at: plist)
        super.tearDown()
    }

    func testNonFiniteAndNegativeRampDurationsDoNotTrap() {
        // Public API must not trap on a NaN/negative ramp (Double->UInt64).
        engine.start(frequencyHz: 9, duty: 0.5, rampFrom: 0.2, rampDuration: .nan)
        wait(0.1)
        engine.stopAndRestore(ramp: -1)
        wait(0.1)
        engine.start(frequencyHz: 9, duty: 0.5, rampFrom: 0.2, rampDuration: -5)
        wait(0.1)
        engine.stopAndRestore(ramp: .infinity)
        wait(0.15)
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        XCTAssertFalse(engine.isRunning)
    }

    private func wait(_ seconds: TimeInterval) {
        let e = XCTestExpectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        XCTWaiter().wait(for: [e], timeout: seconds + 2)
    }

    private func sets() -> [Float] {
        recorder.commands.compactMap {
            if case .set(let v) = $0 { return v } else { return nil }
        }
    }

    // MARK: Alternation and restore

    func testTicksAlternateHighLowAndStopEndsWithRestore() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.5)
        engine.stopAndRestore(ramp: 0)
        wait(0.15)

        let cmds = recorder.commands
        XCTAssertEqual(
            cmds.first, .assertSuppression,
            "suppression is asserted before the first edge")
        XCTAssertEqual(cmds.last, .restore(0.4), "the last command is the restore")
        XCTAssertFalse(engine.isRunning)

        let levels = sets()
        XCTAssertGreaterThanOrEqual(
            levels.count, 14, "≈20 edges in 0.5 s at 20 Hz; got \(levels.count)")
        XCTAssertEqual(levels.first, 0.0625, "the first edge is ON")
        for (i, v) in levels.enumerated() {
            XCTAssertEqual(v, i % 2 == 0 ? 0.0625 : 0, "edge \(i) must alternate ON/OFF")
        }
    }

    func testRampDownStillEndsWithRestoreAndStops() {
        engine.start(frequencyHz: 20, duty: 0.3)
        wait(0.3)
        engine.stopAndRestore(ramp: 0.2)  // 4 cycles at 20 Hz
        wait(0.6)
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.state, .stopped)
    }

    func testRestoreNowCutsThroughARampDown() {
        engine.start(frequencyHz: 10, duty: 0.5)
        wait(0.25)
        engine.stopAndRestore(ramp: 5)  // would take 5 s
        wait(0.05)
        engine.restoreNow()
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        XCTAssertFalse(engine.isRunning)
        let count = recorder.commands.count
        wait(0.3)
        XCTAssertEqual(
            recorder.commands.count, count, "no edges after a synchronous restore")
    }

    func testStartRampReachesTargetDutyAndReportsTargetState() {
        engine.start(frequencyHz: 20, duty: 0.3, rampFrom: 0.85, rampDuration: 0.2)
        wait(0.8)
        XCTAssertEqual(engine.state, .running(frequencyHz: 20, duty: 0.3))

        // After the ramp, OFF edges sit ≈ 0.3 × 50 ms = 15 ms after their ON edge.
        let e = recorder.entries.suffix(8)
        var offsets: [Double] = []
        var lastOn: UInt64?
        for entry in e {
            switch entry.command {
            case .set(let v) where v > 0: lastOn = entry.at
            case .set: if let on = lastOn { offsets.append(Double(entry.at - on) / 1e6) }
            default: break
            }
        }
        XCTAssertFalse(offsets.isEmpty)
        // Median again, and for the same reason as in the phase-continuity
        // test: one load-delayed handler must not fail a test about geometry.
        let sorted = offsets.sorted()
        XCTAssertEqual(
            sorted[sorted.count / 2], 15, accuracy: 8,
            "median OFF offset after ramp: \(sorted)")
    }

    // MARK: Dirty flag

    func testDirtyFlagIsSetBeforeFirstCommandAndClearedAfterRestore() {
        var flagAtFirstCommand: Bool?
        recorder.onCommand = { [flag] _ in
            if flagAtFirstCommand == nil { flagAtFirstCommand = flag!.isSet }
        }
        XCTAssertFalse(flag.isSet)
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.2)
        XCTAssertEqual(
            flagAtFirstCommand, true, "flag exists before the first backlight command")
        XCTAssertTrue(flag.isSet)
        engine.stopAndRestore(ramp: 0)
        wait(0.1)
        XCTAssertFalse(flag.isSet, "flag removed after a successful restore")
    }

    // MARK: Restore semantics

    func testRestoreNowIsSilentWhenNeverEngagedButForceCommands() {
        engine.restoreNow()
        XCTAssertTrue(
            recorder.commands.isEmpty,
            "quitting without ever dimming must not touch the backlight")
        engine.restoreLevel = 0.3
        engine.restoreNow(force: true)
        XCTAssertEqual(recorder.commands, [.restore(0.3)])
    }

    func testStopWhenNotRunningStillCommandsRestoreIfEngaged() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.15)
        engine.restoreNow()
        let n = recorder.commands.count
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        // Already stopped and not engaged → nothing to command.
        engine.stopAndRestore(ramp: 0.25)
        wait(0.1)
        XCTAssertEqual(recorder.commands.count, n)
    }

    // MARK: Retunes

    func testDutyIsClampedAndSetDutyIsPhaseContinuous() {
        engine.start(frequencyHz: 20, duty: 0.99)
        wait(0.1)
        XCTAssertEqual(engine.state, .running(frequencyHz: 20, duty: 0.85))
        engine.setDuty(0.01)
        wait(0.05)
        XCTAssertEqual(engine.state, .running(frequencyHz: 20, duty: 0.15))

        // ON cadence is unchanged by duty changes: ON-to-ON spacing stays 50 ms.
        let before = recorder.entries.count
        engine.setDuty(0.5); engine.setDuty(0.7); engine.setDuty(0.3)
        wait(0.3)
        let ons = recorder.entries.dropFirst(before).filter {
            if case .set(let v) = $0.command { return v > 0 }; return false
        }
        XCTAssertGreaterThan(ons.count, 3)

        // MEDIAN, not every sample. What this test is actually asserting is
        // that setDuty leaves the HIGH timer alone — that it is phase
        // continuous. A single handler delayed by machine load produces one
        // long gap and one short one either side of it, which says nothing
        // about the timer and everything about the machine; on a shared CI
        // runner that is routine. The median moves only if the cadence itself
        // moved, which is the regression worth catching, and the total elapsed
        // catches accumulated drift that a median could hide.
        let spacings = zip(ons, ons.dropFirst()).map { Double($1.at - $0.at) / 1e6 }
            .sorted()
        XCTAssertEqual(
            spacings[spacings.count / 2], 50, accuracy: 5, "median ON-to-ON spacing")
        let span = Double(ons.last!.at - ons.first!.at) / 1e6
        XCTAssertEqual(
            span, Double(ons.count - 1) * 50, accuracy: 12,
            "cadence must not drift across the window")
    }

    func testStartWhileRunningRetunesInsteadOfRestarting() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.15)
        let asserts = recorder.commands.filter { $0 == .assertSuppression }.count
        engine.start(frequencyHz: 20, duty: 0.3, rampFrom: 0.85)
        wait(0.15)
        XCTAssertEqual(
            recorder.commands.filter { $0 == .assertSuppression }.count, asserts,
            "a second start while running is a retune, not a re-engagement")
        XCTAssertEqual(engine.state, .running(frequencyHz: 20, duty: 0.3))
    }

    // MARK: Command-truth counters

    func testCountersAccountForEveryEdgeAndMatchTheRecordedCommands() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.5)
        engine.stopAndRestore(ramp: 0)
        wait(0.15)

        let c = engine.counters
        let ons = sets().filter { $0 > 0 }.count
        let offs = sets().filter { $0 == 0 }.count

        XCTAssertEqual(
            Int(c.high.executed), ons,
            "executed HIGH must equal the ON commands the seam saw")
        XCTAssertEqual(
            Int(c.low.executed), offs,
            "executed LOW must equal the OFF commands the seam saw")
        XCTAssertEqual(
            c.high.executed + c.high.skipped, c.high.fired,
            "with no ramp, every fired HIGH either commanded or was skipped")
        XCTAssertGreaterThanOrEqual(
            c.high.scheduled, c.high.fired,
            "a deadline can be coalesced away but never fire twice")
        XCTAssertEqual(c.nominalPeriodMs, 50, accuracy: 0.001)
        XCTAssertEqual(c.nominalOnWindowMs, 25, accuracy: 0.001)
        XCTAssertGreaterThan(c.high.executed, 5)
    }

    func testResetCountersZeroesTheTally() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.2)
        XCTAssertGreaterThan(engine.counters.high.executed, 0)
        engine.resetCounters()
        XCTAssertEqual(engine.counters.high.executed, 0)
        XCTAssertEqual(engine.counters.high.scheduled, 0)
        engine.restoreNow()
    }

    func testAStalledQueueProducesErrDarkSkipsAndTheyAreCounted() {
        // The err-dark rule drops any HIGH edge that runs later than its own ON
        // window (duty x period = 7.5 ms here). Block the engine queue for well
        // over a period and the next HIGH edge must be skipped, not commanded —
        // this is the mechanism that turns a queue stall into a DARK cycle, so
        // it has to be observable in the counters.
        engine.start(frequencyHz: 20, duty: 0.15)
        wait(0.2)
        for _ in 0..<3 {
            engine.queue.async { Thread.sleep(forTimeInterval: 0.06) }
            wait(0.12)
        }
        wait(0.1)
        let c = engine.counters
        engine.restoreNow()

        XCTAssertGreaterThan(
            c.high.skipped, 0, "a stall longer than the ON window must skip a HIGH edge")
        XCTAssertGreaterThan(
            c.skipMaxLatenessMs, c.nominalOnWindowMs,
            "a skip is by definition later than its threshold")
        XCTAssertEqual(
            c.skipLastThresholdMs, 7.5, accuracy: 0.5, "the threshold IS the ON window")
        XCTAssertGreaterThanOrEqual(c.skipMaxRunLength, 1)
        XCTAssertGreaterThan(
            c.longestExecutedHighGapMs, c.nominalPeriodMs,
            "skipped cycles stretch the gap between executed ON commands")
    }

    // MARK: Phase-locked edges (directive #10)

    func testNoSkipBurstInASteadyRun() {
        // The defect these one-shots exist to remove is not a skip, it is a
        // RUN of skips: one dark cycle is a flicker, several in a row is the
        // dark envelope Omar sees. Re-arming both edges from the anchor on
        // every HIGH edge is supposed to make a burst impossible in a steady
        // run, so that is what is asserted — the goal state, not the mechanism.
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.5)
        let c = engine.counters
        engine.restoreNow()

        XCTAssertGreaterThan(c.high.executed, 5, "the run has to have actually run")
        XCTAssertLessThanOrEqual(
            c.skipMaxRunLength, 1,
            "consecutive skips are a dark envelope; a steady run must never produce one")
    }

    func testDaemonLatencyStretchesAHandlerButNotThePeriod() {
        // "Schedule first, XPC second", asserted as EDGE RATE over a fixed
        // wall-clock window — the one consequence a loaded machine cannot fake.
        //
        // Absolute deadlines mean the number of HIGH edges in T seconds is T x f
        // no matter how late any individual edge runs: a delayed handler still
        // runs, and the next one was armed from the anchor before the delay
        // happened. Latency leaking into the schedule instead lengthens every
        // cycle by the command's duration, so the rate itself drops.
        //
        // THREE EARLIER FORMS OF THIS TEST WERE WRONG. Recorded so they are not
        // reinvented. (1) Neighbouring ON-to-ON spacing: a handler that misses
        // its ON window makes the engine correctly err dark, which doubles one
        // spacing and reads as drift. (2) Span against the nearest multiple of
        // the period: aliases to zero once accumulated drift reaches one full
        // period, silently ceasing to detect the defect. (3) Median phase error
        // against the anchor: sound in principle, but CI measured 17.5 ms of
        // median timer jitter on a loaded runner, which swamps the drift being
        // looked for. Rate is immune to all three, because jitter does not
        // change how many deadlines fall inside a window.
        let seconds = 4.0
        let hz = 5.0
        recorder.commandDelay = 0.070
        // Duty 0.85 gives a 170 ms ON window against a 70 ms command, so the
        // err-dark rule stays out of this measurement even under load. Skipped
        // edges would not affect it anyway: `fired` counts handler runs.
        engine.start(frequencyHz: hz, duty: 0.85)
        wait(seconds)
        let c = engine.counters
        engine.restoreNow()

        // A 70 ms command that moved the schedule stretches the cycle from
        // 200 ms to 270 ms, cutting the edge count by a quarter. The allowance
        // below sits well clear of that on both sides: the honest engine can
        // lose three whole edges to load and still pass, and the defect misses
        // by more than two.
        let expected = seconds * hz
        XCTAssertGreaterThanOrEqual(
            Double(c.high.fired), expected * 0.85,
            "HIGH edges must keep the anchor's rate; a command that moved the schedule would slow it to \(seconds / (1 / hz + recorder.commandDelay)) edges"
        )
    }

    func testSetDutyCannotEmitAFullyBrightCycle() {
        // Dropping an OFF edge whose deadline a duty change moved into the past
        // would leave that cycle commanded ON for its whole period — 100 % duty,
        // a visible brightening on every drag of the slider. `applyDuty`
        // commands the OFF immediately instead. Two ON commands with no OFF
        // between them is exactly what that failure looks like at the seam.
        engine.start(frequencyHz: 20, duty: 0.85)
        wait(0.15)
        for d in [0.15, 0.85, 0.2, 0.8, 0.15, 0.5] {
            engine.setDuty(d)
            wait(0.04)
        }
        wait(0.1)
        let levels = sets()
        engine.restoreNow()

        XCTAssertGreaterThan(levels.count, 8)
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertFalse(
                a > 0 && b > 0,
                "two ON commands with no OFF between them is a 100 % bright cycle")
        }
    }

    func testAPastDeadlineIsNeverArmed() {
        // The re-anchor guard itself. An absolute deadline that has already
        // passed fires on the very next turn of the queue, so arming one turns
        // a re-arm into a spin; the engine must re-anchor instead.
        let now: UInt64 = 1_000_000_000
        XCTAssertTrue(DitherEngine.shouldReanchor(deadline: now - 1, now: now))
        XCTAssertTrue(
            DitherEngine.shouldReanchor(deadline: now, now: now),
            "a deadline of exactly now is due now, and re-arming to it would spin")
        XCTAssertFalse(DitherEngine.shouldReanchor(deadline: now + 1, now: now))
    }

    func testAHardStallRecoversOnCadenceInsteadOfSpinning() {
        // The consequence of that guard, end to end: block the queue for five
        // whole cycles, then check the engine comes back on cadence rather than
        // firing a packed burst of caught-up edges (which is what an absolute
        // past deadline, or a coalescing repeating timer, would produce).
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.2)
        engine.queue.async { Thread.sleep(forTimeInterval: 0.25) }
        wait(0.3)

        let after = recorder.entries.count
        wait(0.4)
        let ons = recorder.entries.dropFirst(after).filter {
            if case .set(let v) = $0.command { return v > 0 }
            return false
        }
        let c = engine.counters
        engine.restoreNow()

        XCTAssertTrue(c.high.executed > 0)
        XCTAssertGreaterThan(ons.count, 4, "the engine must still be dithering")
        XCTAssertLessThan(
            ons.count, 20,
            "0.4 s at 20 Hz is ~8 ON commands; a burst means deadlines were replayed")
        let spacings = zip(ons, ons.dropFirst()).map { Double($1.at - $0.at) / 1e6 }
        // Whole periods, not one exact period: a loaded machine may cost a
        // cycle to the err-dark rule here and there, which is a 2-period gap
        // and not a phase error. A gap that is NOT a multiple of the period is
        // the thing that would mean the phase itself moved.
        let deviations =
            spacings
            .map { abs($0 - ($0 / 50).rounded() * 50) }
            .sorted()
        XCTAssertLessThan(
            deviations[deviations.count / 2], 10,
            "median ON-to-ON gap after the stall must be a whole number of periods")
        XCTAssertLessThanOrEqual(
            c.skipMaxRunLength, 1,
            "even a five-cycle stall must not produce consecutive skips")
    }

    func testStateChangeIsDeliveredOnMain() {
        let started = expectation(description: "running")
        let stopped = expectation(description: "stopped")
        engine.onStateChange = { s in
            XCTAssertTrue(Thread.isMainThread)
            if s.isRunning { started.fulfill() } else { stopped.fulfill() }
        }
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(for: [started], timeout: 2)
        engine.stopAndRestore(ramp: 0)
        wait(for: [stopped], timeout: 2)
    }
}

/// The stability ceiling: a request above it must be honoured as the ceiling,
/// never silently run as asked. See DitherEngine.maxStableFrequencyHz for the
/// provenance of the number.
final class FrequencyCeilingTests: XCTestCase {

    private var tempDir: URL!
    private var recorder: RecordingCommander!
    private var engine: DitherEngine!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-ceiling-\(UUID().uuidString)")
        recorder = RecordingCommander()
        engine = DitherEngine(
            commander: recorder, highLevel: 0.0625,
            dirtyFlag: DirtyFlag(
                directory: tempDir,
                defaults: UserDefaults(
                    suiteName: "sublight.ceiling.\(UUID().uuidString)")!),
            diagnostics: EngineDiagnostics())
    }

    override func tearDown() {
        engine.restoreNow()
        engine = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func wait(_ seconds: TimeInterval) {
        let e = XCTestExpectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        XCTWaiter().wait(for: [e], timeout: seconds + 2)
    }

    func testFrequencyRangeStopsAtTheMeasuredCeiling() {
        XCTAssertEqual(
            DitherEngine.frequencyRange.upperBound, DitherEngine.maxStableFrequencyHz)
        XCTAssertEqual(DitherEngine.maxStableFrequencyHz, 8.0)
        XCTAssertGreaterThan(
            DitherEngine.unstableFrequencyRange.upperBound,
            DitherEngine.maxStableFrequencyHz,
            "the research range must actually reach past the ceiling")
    }

    func testAskingForNineRunsAtEight() {
        engine.start(frequencyHz: 9.0, duty: 0.5)
        wait(0.1)
        XCTAssertEqual(engine.state, .running(frequencyHz: 8.0, duty: 0.5))
        XCTAssertEqual(engine.clampedFrequency(9.0), 8.0)
        XCTAssertEqual(engine.clampedFrequency(40.0), 8.0)
        XCTAssertEqual(
            engine.clampedFrequency(.nan), 8.0,
            "a non-finite request lands on the ceiling")
        XCTAssertEqual(engine.clampedFrequency(6.0), 6.0, "a legal request is untouched")
    }

    func testSetFrequencyIsAlsoClamped() {
        engine.start(frequencyHz: 6.0, duty: 0.5)
        wait(0.1)
        engine.setFrequency(12.0)
        wait(0.1)
        XCTAssertEqual(engine.state, .running(frequencyHz: 8.0, duty: 0.5))
    }

    func testTheResearchOverrideAdmitsNine() {
        engine.allowsUnstableFrequency = true
        XCTAssertEqual(engine.clampedFrequency(9.0), 9.0)
        engine.start(frequencyHz: 9.0, duty: 0.5)
        wait(0.1)
        XCTAssertEqual(engine.state, .running(frequencyHz: 9.0, duty: 0.5))
        XCTAssertEqual(
            engine.clampedFrequency(100.0),
            DitherEngine.unstableFrequencyRange.upperBound,
            "the override lifts the ceiling, it does not remove all bounds")
    }
}

/// The exit gate: a process that never commanded the backlight must leave the
/// user's state alone when it quits.
final class HardwareTouchedTests: XCTestCase {

    private var tempDir: URL!
    private var recorder: RecordingCommander!
    private var diag: EngineDiagnostics!
    private var engine: DitherEngine!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-touched-\(UUID().uuidString)")
        recorder = RecordingCommander()
        diag = EngineDiagnostics()
        engine = DitherEngine(
            commander: recorder, highLevel: 0.0625,
            dirtyFlag: DirtyFlag(
                directory: tempDir,
                defaults: UserDefaults(
                    suiteName: "sublight.touched.\(UUID().uuidString)")!),
            diagnostics: diag)
        engine.allowsUnstableFrequency = true
    }

    override func tearDown() {
        engine = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func wait(_ seconds: TimeInterval) {
        let e = XCTestExpectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        XCTWaiter().wait(for: [e], timeout: seconds + 2)
    }

    func testAFreshSessionHasNotTouchedTheHardware() {
        XCTAssertFalse(diag.hardwareTouched)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testExitRestoreCommandsNothingWhenTheBacklightWasNeverTouched() {
        XCTAssertTrue(
            engine.restoreOnExit(level: 0.4), "a no-op exit still reports success")
        XCTAssertTrue(
            recorder.commands.isEmpty,
            "quitting without ever dimming must not impose auto-brightness and a level")
    }

    func testExitRestoreCommandsOnceTheBacklightHasBeenTouched() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.15)
        XCTAssertTrue(diag.hardwareTouched)
        engine.restoreOnExit(level: 0.4)
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        XCTAssertFalse(engine.isRunning)
    }

    func testExitRestoreStillForcesAfterASuppressionOnlyTouch() {
        // The calibration shape: the hardware was mutated, but the engine is
        // not running, so `engaged`-gated logic would decline and leave the
        // ambient light sensor switched off.
        diag.noteHardwareTouched()
        _ = recorder.assertSuppression()
        engine.restoreOnExit(level: 0.4)
        XCTAssertEqual(
            recorder.commands.last, .restore(0.4),
            "a suppression-only session must still hand control back")
    }

    func testHardwareTouchedSurvivesACounterReset() {
        diag.noteCommand(kind: "brightness", value: 0.0625, latencyMs: 0.2)
        XCTAssertTrue(diag.hardwareTouched)
        diag.reset()
        XCTAssertEqual(diag.snapshot(), EngineCounters(), "reset clears the measurement…")
        XCTAssertTrue(
            diag.hardwareTouched, "…but not the fact that the hardware was touched")
    }

    func testAnyMutatingCommandKindSetsTheFlag() {
        for kind in [
            "brightness", "brightness-fade", "auto-brightness", "idle-dim-suspend",
        ] {
            let d = EngineDiagnostics()
            XCTAssertFalse(d.hardwareTouched)
            d.noteCommand(kind: kind, latencyMs: 0.1)
            XCTAssertTrue(d.hardwareTouched, "\(kind) mutates the backlight state")
        }
    }
}
