// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DitherScheduleTests.swift — anchor arithmetic for the edge timers.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
@testable import SublightKit

final class DitherScheduleTests: XCTestCase {

    private let anchor: UInt64 = 5_000_000_000   // arbitrary uptime

    func testDeadlinesAreAnchorArithmeticAcrossRepresentativePairs() {
        let pairs: [(hz: Double, duty: Double)] = [(9, 0.5), (3, 0.15), (12, 0.85), (6, 0.3), (2, 0.6)]
        for (hz, duty) in pairs {
            let s = DitherSchedule(anchorNanos: anchor, frequencyHz: hz, duty: duty)
            let period = UInt64(1e9 / hz)
            XCTAssertEqual(s.periodNanos, period, "\(hz) Hz period")
            for n: UInt64 in [0, 1, 7, 1000] {
                XCTAssertEqual(s.highDeadline(cycle: n), anchor + n * period, "\(hz) Hz HIGH \(n)")
                XCTAssertEqual(s.lowDeadline(cycle: n), anchor + n * period + UInt64(duty * Double(period)),
                               "\(hz) Hz LOW \(n) at duty \(duty)")
            }
        }
    }

    func testNineHertzNominals() {
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 9, duty: 0.5)
        XCTAssertEqual(Double(s.periodNanos) / 1e6, 111.111, accuracy: 0.001)
        XCTAssertEqual(Double(s.lowOffsetNanos) / 1e6, 55.555, accuracy: 0.001)
    }

    func testExtremeFrequencyDoesNotProducePeriodZero() {
        // A huge finite frequency would round the period to 0 ns and then
        // divide-by-zero in cycle(at:). The init floors periodNanos at 1.
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 1e12, duty: 0.5)
        XCTAssertGreaterThanOrEqual(s.periodNanos, 1)
        // Must not trap.
        XCTAssertEqual(s.cycle(at: anchor + 1_000_000), s.cycle(at: anchor + 1_000_000))
        // Non-finite falls back to a safe default.
        let n = DitherSchedule(anchorNanos: anchor, frequencyHz: .nan, duty: 0.5)
        XCTAssertGreaterThan(n.periodNanos, 0)
    }

    func testDutyIsClampedToHoldableRange() {
        XCTAssertEqual(DitherSchedule(anchorNanos: anchor, frequencyHz: 9, duty: 0.01).duty, 0.15)
        XCTAssertEqual(DitherSchedule(anchorNanos: anchor, frequencyHz: 9, duty: 0.99).duty, 0.85)
        XCTAssertEqual(DitherSchedule(anchorNanos: anchor, frequencyHz: 9, duty: 0.5).duty, 0.5)
        XCTAssertEqual(DitherSchedule.clampDuty(-1), 0.15)
        XCTAssertEqual(DitherSchedule.clampDuty(2), 0.85)
    }

    func testWithDutyKeepsAnchorAndPeriod() {
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 9, duty: 0.5)
        let t = s.withDuty(0.3)
        XCTAssertEqual(t.anchorNanos, s.anchorNanos)
        XCTAssertEqual(t.periodNanos, s.periodNanos)
        XCTAssertEqual(t.duty, 0.3)
        // The ON cadence is untouched by a duty change.
        for n: UInt64 in 0...5 { XCTAssertEqual(t.highDeadline(cycle: n), s.highDeadline(cycle: n)) }
    }

    func testNextLowIsStrictlyInTheFuture() {
        // Period 100 ms, LOW at +50 ms.
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 10, duty: 0.5)
        let ms: UInt64 = 1_000_000
        // Mid-cycle, before this cycle's LOW: this cycle's LOW.
        XCTAssertEqual(s.nextLowDeadline(after: anchor + 320 * ms), anchor + 350 * ms)
        // Exactly at the LOW deadline: not strictly future → next cycle.
        XCTAssertEqual(s.nextLowDeadline(after: anchor + 350 * ms), anchor + 450 * ms)
        // After this cycle's LOW: next cycle.
        XCTAssertEqual(s.nextLowDeadline(after: anchor + 370 * ms), anchor + 450 * ms)
        // Before the anchor: cycle 0.
        XCTAssertEqual(s.nextLowDeadline(after: anchor - 10 * ms), anchor + 50 * ms)
    }

    func testSetDutyPhaseContinuityNeverSchedulesIntoThePast() {
        let ms: UInt64 = 1_000_000
        // LOW at +80 ms.
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 10, duty: 0.8)
        // Mid-phase, 60 ms in, duty drops to 0.3 (LOW would have been at +30 ms, now past).
        let t = s.withDuty(0.3)
        let now = anchor + 3 * 100 * ms + 60 * ms
        let next = t.nextLowDeadline(after: now)
        XCTAssertGreaterThan(next, now)
        XCTAssertEqual(next, anchor + 4 * 100 * ms + 30 * ms)
        // Duty rises to 0.7 at 60 ms in: this cycle's LOW at +70 ms is still ahead.
        let u = s.withDuty(0.7)
        XCTAssertEqual(u.nextLowDeadline(after: now), anchor + 3 * 100 * ms + 70 * ms)
    }

    func testNextLowSkipsACycleWhoseLowAlreadyFired() {
        let ms: UInt64 = 1_000_000
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 10, duty: 0.3)
        let now = anchor + 2 * 100 * ms + 40 * ms                       // cycle 2, LOW (+30) already fired
        let t = s.withDuty(0.7)                                        // new LOW at +70 would be future…
        XCTAssertEqual(t.nextLowDeadline(after: now, lowAlreadyFiredIn: 2), anchor + 3 * 100 * ms + 70 * ms)
        XCTAssertEqual(t.nextLowDeadline(after: now, lowAlreadyFiredIn: nil), anchor + 2 * 100 * ms + 70 * ms)
    }

    func testCycleIndex() {
        let ms: UInt64 = 1_000_000
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 10, duty: 0.5)
        XCTAssertEqual(s.cycle(at: anchor), 0)
        XCTAssertEqual(s.cycle(at: anchor + 50 * ms), 0)
        XCTAssertEqual(s.cycle(at: anchor + 100 * ms), 1)
        XCTAssertEqual(s.cycle(at: anchor + 1234 * ms), 12)
        // 99 ms into a 100 ms period used to floor to cycle 0. It is now binned
        // forward to cycle 1, because 1 ms before a boundary is a punctual edge
        // firing early, not an edge 99 ms late. See earlyFireGuardNanos.
        XCTAssertEqual(s.cycle(at: anchor + 99 * ms), 1)
    }

    // MARK: Early-fire binning
    //
    // A `.strict` timer may fire microseconds BEFORE its deadline. Integer
    // division floored those into the previous cycle, the engine then measured
    // a lateness of nearly a whole period, and the err-dark rule dropped a
    // perfectly punctual edge. Every err-dark skip ever recorded came from
    // this. These pin the fix.

    private func schedule(_ hz: Double) -> DitherSchedule {
        DitherSchedule(anchorNanos: anchor, frequencyHz: hz, duty: 0.15)
    }

    func testGuardIsAlwaysWellUnderHalfAPeriod() {
        // Ambiguity in "nearest boundary" would let two firings share a cycle.
        for hz in [1.0, 3.0, 6.0, 7.5, 8.0, 40.0] {
            let s = schedule(hz)
            XCTAssertLessThan(s.earlyFireGuard * 2, s.periodNanos,
                              "guard must stay under half a period at \(hz) Hz")
        }
    }

    func testAnEdgeFiringEarlyWithinTheGuardBinsToItsOwnCycle() {
        for hz in [3.0, 6.0, 7.5, 8.0, 40.0] {
            let s = schedule(hz)
            // 8-24 µs is the range actually measured; 1 ns and the guard itself
            // are the boundaries of the accepted window.
            for early in [UInt64(1), 8_000, 15_300, 24_300, s.earlyFireGuard] {
                for cycle in [UInt64(1), 2, 2119, 5000] {
                    let now = s.highDeadline(cycle: cycle) - early
                    XCTAssertEqual(s.cycle(at: now), cycle,
                                   "\(hz) Hz, cycle \(cycle), early by \(early) ns")
                }
            }
        }
    }

    func testAnEdgeEarlierThanTheGuardStillBinsToThePreviousCycle() {
        for hz in [3.0, 7.5, 40.0] {
            let s = schedule(hz)
            let now = s.highDeadline(cycle: 100) - (s.earlyFireGuard + 1)
            XCTAssertEqual(s.cycle(at: now), 99, "outside the guard, floor as before (\(hz) Hz)")
        }
    }

    func testLateFiringsBinExactlyAsBefore() {
        for hz in [3.0, 6.0, 7.5, 8.0, 40.0] {
            let s = schedule(hz)
            for late in [UInt64(0), 40_000, 80_000, 2_690_000] where late < s.periodNanos - s.earlyFireGuard {
                let now = s.highDeadline(cycle: 42) + late
                XCTAssertEqual(s.cycle(at: now), 42, "\(hz) Hz, late by \(late) ns")
            }
        }
    }

    /// The engine's own arithmetic: a punctual early firing must measure as
    /// ~zero late, and must NOT trip the err-dark rule.
    func testPunctualEarlyFiringIsNotLateAndIsNotSkipped() {
        for hz in [3.0, 6.0, 7.5, 8.0, 40.0] {
            let s = schedule(hz)
            let cycle: UInt64 = 2119
            let now = s.highDeadline(cycle: cycle) - 15_300   // the observed magnitude
            let binned = s.cycle(at: now)
            XCTAssertEqual(binned, cycle)
            let due = s.highDeadline(cycle: binned)
            XCTAssertLessThanOrEqual(now, due, "a punctual early firing is not late (\(hz) Hz)")
            XCTAssertGreaterThan(s.lowDeadline(cycle: binned), now,
                                 "err-dark must not fire on a punctual edge (\(hz) Hz)")
        }
    }

    /// The 2118-ok / 2118-SKIP pair observed in the field becomes 2118 / 2119.
    /// Walked over a synthetic clock with realistic jitter, indices must be
    /// strictly increasing — no cycle can ever be commanded twice.
    func testConsecutiveFiringsNeverBinToTheSameCycle() {
        let jitter: [Int64] = [-24_300, -15_300, -8_000, -1_000, 0, 40_000, 80_000, 500_000]
        for hz in [3.0, 6.0, 7.5, 8.0, 40.0] {
            let s = schedule(hz)
            var previous: UInt64?
            for c in UInt64(1)...300 {
                let j = jitter[Int(c) % jitter.count]
                let base = s.highDeadline(cycle: c)
                let now = j < 0 ? base - UInt64(-j) : base + UInt64(j)
                let binned = s.cycle(at: now)
                if let previous {
                    XCTAssertGreaterThan(binned, previous,
                                         "\(hz) Hz: cycle \(c) with jitter \(j) ns repeated an index")
                }
                previous = binned
            }
        }
    }

    /// The exact field case, replayed from the recorded fractional parts.
    func testTheObservedFieldSkipsWouldNoLongerSkip() {
        let s = schedule(7.5)
        // Measured: handlers 15.3, 8.0 and 24.3 µs before cycles 2119, 2121, 2134.
        for (cycle, earlyNs) in [(UInt64(2119), UInt64(15_300)),
                                 (2121, 8_000),
                                 (2134, 24_300)] {
            let now = s.highDeadline(cycle: cycle) - earlyNs
            XCTAssertEqual(s.cycle(at: now), cycle, "cycle \(cycle) must bin to itself")
            XCTAssertGreaterThan(s.lowDeadline(cycle: s.cycle(at: now)), now,
                                 "cycle \(cycle) must not be dropped")
        }
    }
}
