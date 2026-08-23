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
    /// Called on every command, before it is recorded (used to observe the
    /// dirty flag at the moment of the first command).
    var onCommand: ((Command) -> Void)?

    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return _entries }
    var commands: [Command] { entries.map(\.command) }

    private func record(_ c: Command) {
        onCommand?(c)
        lock.lock(); _entries.append(Entry(command: c, at: DispatchTime.now().uptimeNanoseconds)); lock.unlock()
    }

    func setBrightness(_ value: Float) -> Bool { record(.set(value)); return true }
    func restoreSystemControl(level: Float) -> Bool { record(.restore(level)); return true }
    func assertSuppression() -> SuppressionFlips { record(.assertSuppression); return flips }
}

final class DitherEngineTests: XCTestCase {

    private var tempDir: URL!
    private var flag: DirtyFlag!
    private var recorder: RecordingCommander!
    private var engine: DitherEngine!

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sublight-engine-\(UUID().uuidString)")
        suiteName = "sublight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        flag = DirtyFlag(directory: tempDir, defaults: defaults)
        recorder = RecordingCommander()
        engine = DitherEngine(commander: recorder, highLevel: 0.0625, dirtyFlag: flag)
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
        recorder.commands.compactMap { if case .set(let v) = $0 { return v } else { return nil } }
    }

    // MARK: Alternation and restore

    func testTicksAlternateHighLowAndStopEndsWithRestore() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.5)
        engine.stopAndRestore(ramp: 0)
        wait(0.15)

        let cmds = recorder.commands
        XCTAssertEqual(cmds.first, .assertSuppression, "suppression is asserted before the first edge")
        XCTAssertEqual(cmds.last, .restore(0.4), "the last command is the restore")
        XCTAssertFalse(engine.isRunning)

        let levels = sets()
        XCTAssertGreaterThanOrEqual(levels.count, 14, "≈20 edges in 0.5 s at 20 Hz; got \(levels.count)")
        XCTAssertEqual(levels.first, 0.0625, "the first edge is ON")
        for (i, v) in levels.enumerated() {
            XCTAssertEqual(v, i % 2 == 0 ? 0.0625 : 0, "edge \(i) must alternate ON/OFF")
        }
    }

    func testRampDownStillEndsWithRestoreAndStops() {
        engine.start(frequencyHz: 20, duty: 0.3)
        wait(0.3)
        engine.stopAndRestore(ramp: 0.2)   // 4 cycles at 20 Hz
        wait(0.6)
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.state, .stopped)
    }

    func testRestoreNowCutsThroughARampDown() {
        engine.start(frequencyHz: 10, duty: 0.5)
        wait(0.25)
        engine.stopAndRestore(ramp: 5)     // would take 5 s
        wait(0.05)
        engine.restoreNow()
        XCTAssertEqual(recorder.commands.last, .restore(0.4))
        XCTAssertFalse(engine.isRunning)
        let count = recorder.commands.count
        wait(0.3)
        XCTAssertEqual(recorder.commands.count, count, "no edges after a synchronous restore")
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
        for o in offsets { XCTAssertEqual(o, 15, accuracy: 10, "OFF offset after ramp: \(o) ms") }
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
        XCTAssertEqual(flagAtFirstCommand, true, "flag exists before the first backlight command")
        XCTAssertTrue(flag.isSet)
        engine.stopAndRestore(ramp: 0)
        wait(0.1)
        XCTAssertFalse(flag.isSet, "flag removed after a successful restore")
    }

    // MARK: Restore semantics

    func testRestoreNowIsSilentWhenNeverEngagedButForceCommands() {
        engine.restoreNow()
        XCTAssertTrue(recorder.commands.isEmpty, "quitting without ever dimming must not touch the backlight")
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
        engine.stopAndRestore(ramp: 0.25)   // already stopped and not engaged → nothing to command
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
        let ons = recorder.entries.dropFirst(before).filter { if case .set(let v) = $0.command { return v > 0 }; return false }
        XCTAssertGreaterThan(ons.count, 3)
        for (a, b) in zip(ons, ons.dropFirst()) {
            XCTAssertEqual(Double(b.at - a.at) / 1e6, 50, accuracy: 8, "ON-to-ON spacing")
        }
    }

    func testStartWhileRunningRetunesInsteadOfRestarting() {
        engine.start(frequencyHz: 20, duty: 0.5)
        wait(0.15)
        let asserts = recorder.commands.filter { $0 == .assertSuppression }.count
        engine.start(frequencyHz: 20, duty: 0.3, rampFrom: 0.85)
        wait(0.15)
        XCTAssertEqual(recorder.commands.filter { $0 == .assertSuppression }.count, asserts,
                       "a second start while running is a retune, not a re-engagement")
        XCTAssertEqual(engine.state, .running(frequencyHz: 20, duty: 0.3))
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
