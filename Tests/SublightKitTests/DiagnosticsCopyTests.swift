// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DiagnosticsCopyTests.swift — the paste-ready Diagnostics / hardware-report
//  block. Field labels are pinned against the GitHub Hardware report template
//  so a rename there fails here rather than as a confused issue.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest

@testable import SublightKit

final class DiagnosticsCopyTests: XCTestCase {

    private func snapshot(
        counters: EngineCounters = EngineCounters()
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            version: "0.5.0", build: "6",
            gitRevision: "17c5a967ac6ba8f471ecfb32a6b384f8ee5148c1",
            macOS: "26.6.1 (Version 26.6.1 (Build 25G76))",
            modelIdentifier: "Mac16,12",
            hardwareSummary: "Mac16,12 · Apple M4",
            appleSilicon: true,
            measuredFloor: 0.0625, floorCalibrated: true,
            stabilityCeilingHz: 8.0,
            engineAvailable: true, engineError: "",
            keyboardID: 95_158_272,
            sessionElapsedSeconds: 8.5 * 3600,
            ditherRunElapsedSeconds: 18 * 60 + 42,
            counters: counters,
            advancedMode: false, dimmingOn: true, systemSuspended: false,
            engineRunning: true, effectiveFrequencyHz: 8.0, brightness: 0.5,
            calibratedFrequencyHz: 8.0,
            scheduleDescription: "off",
            locationDescription: nil, solarLine: nil,
            shortcut: "off", launchAtLogin: false)
    }

    func testHardwareReportLabelsMatchTheGitHubTemplate() {
        let fields = DiagnosticsCopy.hardwareReportFields(snapshot()).joined(
            separator: "\n")
        for label in [
            DiagnosticsCopy.modelLabel,
            DiagnosticsCopy.macOSLabel,
            DiagnosticsCopy.floorLabel,
            DiagnosticsCopy.ceilingLabel,
            DiagnosticsCopy.worksLabel,
        ] {
            XCTAssertTrue(fields.contains("\(label):"), "missing template label \(label)")
        }
        XCTAssertEqual(DiagnosticsCopy.modelLabel, "Model identifier")
        XCTAssertEqual(DiagnosticsCopy.macOSLabel, "macOS version")
        XCTAssertEqual(DiagnosticsCopy.floorLabel, "Measured floor")
        XCTAssertEqual(DiagnosticsCopy.ceilingLabel, "Stability ceiling")
        XCTAssertEqual(
            DiagnosticsCopy.worksLabel, "Does sub-floor dimming visibly work?")
    }

    func testWorksIsAPlaceholderNotAClaim() {
        let fields = DiagnosticsCopy.hardwareReportFields(snapshot()).joined(
            separator: "\n")
        XCTAssertTrue(
            fields.contains(
                "\(DiagnosticsCopy.worksLabel): \(DiagnosticsCopy.worksPlaceholder)"))
    }

    func testCopyCarriesLiveIdentityCountersAndLastSkipNone() {
        let text = DiagnosticsCopy.text(snapshot())
        for needle in [
            "Sublight 0.5.0 (6)",
            "Git revision: 17c5a967ac6ba8f471ecfb32a6b384f8ee5148c1",
            "Model identifier: Mac16,12",
            "Measured floor: 0.0625 (calibrated)",
            "Stability ceiling: 8.0 Hz",
            "Engine session: 8h 30m 00s",
            "Dither run: 18m 42s",
            "HIGH skipped: 0",
            "LOW skipped: 0",
            "skipMaxRunLength: 0",
            "consecutive err-dark run: 0",
            "Last skip: none",
        ] {
            XCTAssertTrue(text.contains(needle), "copy is missing \(needle):\n\(text)")
        }
        XCTAssertFalse(
            text.lowercased().contains("latitude")
                || text.lowercased().contains("longitude"),
            "coordinates must never appear in Copy")
    }

    func testLastSkipNamesWhenEdgeLatenessAndThreshold() {
        var c = EngineCounters()
        var skip = SkipDiagnostic()
        skip.elapsedRunSeconds = 1234.5
        skip.highLatenessMs = 19.71
        c.lastSkip = skip
        c.skipLastThresholdMs = 18.75
        c.high.skipped = 3
        c.high.scheduled = 1400
        c.high.fired = 1400
        c.high.executed = 1397
        c.skipMaxRunLength = 1
        c.skipCurrentRunLength = 0
        XCTAssertEqual(
            DiagnosticsCopy.formatLastSkip(c),
            "t+1234.5 s  HIGH  late 19.71 ms  threshold 18.75 ms")
        let text = DiagnosticsCopy.text(snapshot(counters: c))
        XCTAssertTrue(text.contains("HIGH skipped: 3"))
        XCTAssertTrue(text.contains("HIGH scheduled/fired/executed: 1400/1400/1397"))
        XCTAssertTrue(
            text.contains(
                "Last skip: t+1234.5 s  HIGH  late 19.71 ms  threshold 18.75 ms"))
        XCTAssertFalse(text.contains("Last skip: none"))
    }

    func testDitherRunNotRunningWhenElapsedIsNil() {
        var s = snapshot()
        s.ditherRunElapsedSeconds = nil
        let text = DiagnosticsCopy.text(s)
        XCTAssertTrue(text.contains("Dither run: not running"))
    }

    func testElapsedFormatting() {
        XCTAssertEqual(DiagnosticsCopy.formatElapsed(0), "0.0 s")
        XCTAssertEqual(DiagnosticsCopy.formatElapsed(12.3), "12.3 s")
        XCTAssertEqual(DiagnosticsCopy.formatElapsed(90), "1m 30s")
        XCTAssertEqual(DiagnosticsCopy.formatElapsed(8.5 * 3600), "8h 30m 00s")
        XCTAssertEqual(DiagnosticsCopy.formatElapsed(.nan), "0.0 s")
        XCTAssertEqual(DiagnosticsCopy.formatElapsed(-1), "0.0 s")
    }

    func testUnstampedGitRevisionIsTheWordUnknownNotAFakeSHA() {
        XCTAssertEqual(SublightVersion.gitRevision(from: Bundle.main), "unknown")
        XCTAssertEqual(SublightVersion.build, "6")
        XCTAssertEqual(SublightVersion.display, "0.5.0 (6)")
    }
}
