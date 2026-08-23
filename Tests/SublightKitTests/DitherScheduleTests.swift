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
        XCTAssertEqual(s.cycle(at: anchor + 1_000_000), s.cycle(at: anchor + 1_000_000))  // no trap
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
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 10, duty: 0.5)   // period 100 ms, LOW at +50 ms
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
        let s = DitherSchedule(anchorNanos: anchor, frequencyHz: 10, duty: 0.8)   // LOW at +80 ms
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
        XCTAssertEqual(s.cycle(at: anchor + 99 * ms), 0)
        XCTAssertEqual(s.cycle(at: anchor + 100 * ms), 1)
        XCTAssertEqual(s.cycle(at: anchor + 1234 * ms), 12)
    }
}
