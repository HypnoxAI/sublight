// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  ScheduleWindowTests.swift
//
//  The overnight-wrapping case is the normal one for a dimming schedule and
//  the easy one to get wrong, so it's pinned down here rather than discovered
//  in the field when someone's keyboard quietly fails to dim.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest

@testable import SublightKit

final class ScheduleWindowTests: XCTestCase {

    private func hm(_ h: Int, _ m: Int = 0) -> Int { h * 60 + m }

    /// 21:00 → 07:00, the typical night-time schedule.
    func testOvernightWindow() {
        let start = hm(21), end = hm(7)
        XCTAssertTrue(
            ScheduleWindow.contains(now: hm(21), start: start, end: end),
            "should be active exactly at the start")
        XCTAssertTrue(ScheduleWindow.contains(now: hm(23, 30), start: start, end: end))
        XCTAssertTrue(
            ScheduleWindow.contains(now: hm(0), start: start, end: end),
            "should stay active across midnight")
        XCTAssertTrue(ScheduleWindow.contains(now: hm(6, 59), start: start, end: end))

        XCTAssertFalse(
            ScheduleWindow.contains(now: hm(7), start: start, end: end),
            "end is exclusive")
        XCTAssertFalse(ScheduleWindow.contains(now: hm(12), start: start, end: end))
        XCTAssertFalse(ScheduleWindow.contains(now: hm(20, 59), start: start, end: end))
    }

    /// 09:00 → 17:00 — a same-day window, which solar scheduling can also
    /// produce when coordinates and time zone disagree.
    func testSameDayWindow() {
        let start = hm(9), end = hm(17)
        XCTAssertFalse(ScheduleWindow.contains(now: hm(8, 59), start: start, end: end))
        XCTAssertTrue(ScheduleWindow.contains(now: hm(9), start: start, end: end))
        XCTAssertTrue(ScheduleWindow.contains(now: hm(16, 59), start: start, end: end))
        XCTAssertFalse(ScheduleWindow.contains(now: hm(17), start: start, end: end))
        XCTAssertFalse(ScheduleWindow.contains(now: hm(2), start: start, end: end))
    }

    /// Equal start and end is an empty window, not a 24-hour one.
    func testEqualTimesIsEmpty() {
        for h in [0, 9, 21] {
            XCTAssertFalse(ScheduleWindow.contains(now: hm(h), start: hm(h), end: hm(h)))
            XCTAssertFalse(
                ScheduleWindow.contains(now: hm((h + 5) % 24), start: hm(h), end: hm(h)))
        }
    }

    /// Polar night arrives as (0, 1440) and must mean "always".
    func testFullDayWindow() {
        for h in 0..<24 {
            XCTAssertTrue(ScheduleWindow.contains(now: hm(h), start: 0, end: 24 * 60))
        }
    }

    /// Every minute of the day belongs to exactly one of a window or its
    /// complement — a cheap way to catch off-by-one errors at the boundaries.
    func testWindowAndComplementPartitionTheDay() {
        let start = hm(21), end = hm(7)
        for minute in 0..<(24 * 60) {
            let inside = ScheduleWindow.contains(now: minute, start: start, end: end)
            let outside = ScheduleWindow.contains(now: minute, start: end, end: start)
            XCTAssertNotEqual(inside, outside, "minute \(minute) is in both or neither")
        }
    }
}
