// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  EngineCountersTests.swift — the command-truth instrument itself. If the
//  percentiles or the scheduled/fired bookkeeping lie, every diagnosis built
//  on them is wrong, so the arithmetic is pinned here.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
@testable import SublightKit

final class LatencyStatsTests: XCTestCase {

    func testEmptyStatsAreZeroAndDoNotDivideByZero() {
        let s = LatencyStats()
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.meanMs, 0)
        XCTAssertEqual(s.p50Ms, 0)
        XCTAssertEqual(s.p95Ms, 0)
        XCTAssertEqual(s.maxMs, 0)
    }

    func testCountSumMaxAndNearestRankPercentiles() {
        var s = LatencyStats()
        for v in stride(from: 1.0, through: 100.0, by: 1.0) { s.record(v) }
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.maxMs, 100)
        XCTAssertEqual(s.meanMs, 50.5, accuracy: 1e-9)
        XCTAssertEqual(s.p50Ms, 50)      // nearest rank: ceil(0.50 * 100) = 50th
        XCTAssertEqual(s.p95Ms, 95)
        XCTAssertEqual(s.percentileMs(0), 1)
        XCTAssertEqual(s.percentileMs(1), 100)
    }

    func testNonFiniteAndNegativeSamplesAreRejected() {
        var s = LatencyStats()
        s.record(.nan); s.record(.infinity); s.record(-1)
        XCTAssertEqual(s.count, 0)
        s.record(2)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.maxMs, 2)
    }

    func testWindowIsBoundedButCountSumAndMaxStayExact() {
        var s = LatencyStats()
        // One big sample first, then enough small ones to push it out of the ring.
        s.record(999)
        for _ in 0..<(LatencyStats.window + 10) { s.record(1) }
        XCTAssertEqual(s.count, UInt64(LatencyStats.window + 11))
        XCTAssertEqual(s.maxMs, 999, "max is exact over all time, not just the window")
        XCTAssertEqual(s.recentMs.count, LatencyStats.window, "the ring is bounded")
        XCTAssertEqual(s.p50Ms, 1, "the outlier has aged out of the percentile window")
    }
}

final class EngineCountersTests: XCTestCase {

    func testCoalescedIsScheduledMinusFiredAndNeverUnderflows() {
        var e = EdgeCounters()
        e.scheduled = 100; e.fired = 93
        XCTAssertEqual(e.coalesced, 7)
        e.fired = 120                      // can't happen, must not wrap
        XCTAssertEqual(e.coalesced, 0)
    }

    func testReportNamesEveryColumnTheDiagnosisNeeds() {
        var c = EngineCounters()
        c.high.scheduled = 270; c.high.fired = 270; c.high.executed = 257; c.high.skipped = 13
        c.low.scheduled = 270; c.low.fired = 270; c.low.executed = 270
        c.skipMaxLatenessMs = 41.2
        c.skipLastThresholdMs = 16.67
        c.skipMaxRunLength = 5
        c.longestExecutedHighGapMs = 583.4
        c.nominalPeriodMs = 111.1
        c.nominalOnWindowMs = 16.67
        c.latency.record(0.2); c.latency.record(1.9)
        c.commandsByKind["brightness"] = 527

        let r = c.report()
        for needle in ["HIGH", "LOW", "scheduled", "fired", "executed", "skipped", "coalesced",
                       "err-dark skips: 13", "longest burst 5", "583.4", "brightness=527"] {
            XCTAssertTrue(r.contains(needle), "report is missing \(needle):\n\(r)")
        }
    }

    func testDiagnosticsCollectorTracksGapsBurstsAndResets() {
        let d = EngineDiagnostics()
        d.noteAnchorReset(periodNanos: 111_111_111, onWindowNanos: 16_666_666)

        // Two executed HIGHs 500 ms apart, with a 3-cycle skip burst between.
        d.noteHighEdge(cycle: 0); d.noteHighExecuted(atNanos: 1_000_000_000)
        for c in 1...3 {
            d.noteHighEdge(cycle: UInt64(c))
            d.noteHighSkipped(latenessMs: 20 + Double(c), thresholdMs: 16.67)
        }
        d.noteHighEdge(cycle: 4); d.noteHighExecuted(atNanos: 1_500_000_000)
        d.noteCommand(kind: "brightness", latencyMs: 0.5)

        let c = d.snapshot()
        XCTAssertEqual(c.high.scheduled, 5, "cycle 4 means five deadlines have come due")
        XCTAssertEqual(c.high.fired, 5)
        XCTAssertEqual(c.high.executed, 2)
        XCTAssertEqual(c.high.skipped, 3)
        XCTAssertEqual(c.high.coalesced, 0)
        XCTAssertEqual(c.skipMaxRunLength, 3, "three consecutive skips is a 3-cycle dark envelope")
        XCTAssertEqual(c.skipMaxLatenessMs, 23, accuracy: 1e-9)
        XCTAssertEqual(c.skipLastThresholdMs, 16.67, accuracy: 1e-9)
        XCTAssertEqual(c.longestExecutedHighGapMs, 500, accuracy: 1e-6)
        XCTAssertEqual(c.nominalPeriodMs, 111.111111, accuracy: 1e-4)
        XCTAssertEqual(c.commandsByKind["brightness"], 1)

        d.reset()
        XCTAssertEqual(d.snapshot(), EngineCounters())
    }

    func testSkipRunLengthIsTheLONGESTBurstNotTheLastOne() {
        let d = EngineDiagnostics()
        for _ in 0..<4 { d.noteHighSkipped(latenessMs: 20, thresholdMs: 16) }
        d.noteHighExecuted(atNanos: 1)
        d.noteHighSkipped(latenessMs: 20, thresholdMs: 16)
        XCTAssertEqual(d.snapshot().skipMaxRunLength, 4)
    }

    func testScheduledSurvivesAnAnchorResetByFoldingTheRunIntoABase() {
        let d = EngineDiagnostics()
        d.noteAnchorReset(periodNanos: 50_000_000, onWindowNanos: 7_500_000)
        d.noteHighEdge(cycle: 9)                  // ten deadlines in run 1
        d.noteLowEdge(cycle: 9)
        d.noteAnchorReset(periodNanos: 50_000_000, onWindowNanos: 7_500_000)
        d.noteHighEdge(cycle: 4)                  // cycle index restarts at 0
        d.noteLowEdge(cycle: 4)

        let c = d.snapshot()
        XCTAssertEqual(c.high.scheduled, 15, "10 from the first anchor + 5 from the second")
        XCTAssertEqual(c.low.scheduled, 15)
        XCTAssertEqual(c.high.fired, 2, "fired counts handler runs, not deadlines")
    }

    func testDiagnosticsRecordRoundTripsThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-diag-\(UUID().uuidString)")
        let url = dir.appendingPathComponent(DiagnosticsStore.fileName)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(DiagnosticsStore.load(from: url), "absent file reads as nil, not a crash")

        var counters = EngineCounters()
        counters.high.executed = 42
        counters.skipMaxRunLength = 5
        counters.latency.record(1.25)
        let record = DiagnosticsRecord(label: "hold 9 Hz duty 0.15", counters: counters,
                                       recordedAt: Date(timeIntervalSince1970: 1_700_000_000), pid: 4242)

        XCTAssertTrue(DiagnosticsStore.save(record, to: url))
        let back = try XCTUnwrap(DiagnosticsStore.load(from: url))
        XCTAssertEqual(back, record)
    }
}
