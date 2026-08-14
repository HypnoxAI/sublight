// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SolarTests.swift
//
//  The solar maths is the one piece of Sublight that is pure, deterministic,
//  and completely untestable by eye — a sunset time that is quietly an hour
//  wrong looks exactly like a correct one. Expected values below are published
//  sunrise/sunset times for the given dates; a two-minute tolerance covers the
//  low-precision formulation and any rounding.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
@testable import SublightKit

final class SolarTests: XCTestCase {

    /// Noon UTC on the given day — safely inside the correct calendar day for
    /// every longitude, so the day-number rounding can't slip.
    private func noonUTC(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func hhmm(_ date: Date, tzOffsetHours: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: tzOffsetHours * 3600)!
        return f.string(from: date)
    }

    private func assertTime(_ actual: Date?, _ expected: String, tz: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            return XCTFail("expected \(expected), got no time", file: file, line: line)
        }
        let got = hhmm(actual, tzOffsetHours: tz)
        // Compare as minutes so a 2-minute tolerance is expressible.
        func minutes(_ s: String) -> Int {
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p[0] * 60 + p[1]
        }
        XCTAssertLessThanOrEqual(abs(minutes(got) - minutes(expected)), 2,
                                 "expected ~\(expected), got \(got)", file: file, line: line)
    }

    func testSanFranciscoMidsummer() {
        let t = Solar.times(latitude: 37.7749, longitude: -122.4194,
                            date: noonUTC(2026, 7, 24))
        XCTAssertEqual(t.condition, .normal)
        assertTime(t.sunrise, "06:06", tz: -7)
        assertTime(t.sunset, "20:25", tz: -7)
    }

    func testLondonSolstices() {
        let summer = Solar.times(latitude: 51.5074, longitude: -0.1278,
                                 date: noonUTC(2026, 6, 21))
        assertTime(summer.sunrise, "04:43", tz: 1)
        assertTime(summer.sunset, "21:21", tz: 1)

        let winter = Solar.times(latitude: 51.5074, longitude: -0.1278,
                                 date: noonUTC(2026, 12, 21))
        assertTime(winter.sunrise, "08:03", tz: 0)
        assertTime(winter.sunset, "15:53", tz: 0)
    }

    /// Southern hemisphere, and a negative-longitude/positive-longitude mix —
    /// the classic place for sign errors to hide.
    func testSydneyMidwinter() {
        let t = Solar.times(latitude: -33.8688, longitude: 151.2093,
                            date: noonUTC(2026, 7, 24))
        XCTAssertEqual(t.condition, .normal)
        assertTime(t.sunrise, "06:53", tz: 10)
        assertTime(t.sunset, "17:09", tz: 10)
    }

    func testPolarDayAndNight() {
        let midsummer = Solar.times(latitude: 69.6492, longitude: 18.9553,
                                    date: noonUTC(2026, 6, 21))
        XCTAssertEqual(midsummer.condition, .polarDay)
        XCTAssertNil(midsummer.sunrise)

        let midwinter = Solar.times(latitude: 69.6492, longitude: 18.9553,
                                    date: noonUTC(2026, 12, 21))
        XCTAssertEqual(midwinter.condition, .polarNight)
        XCTAssertNil(midwinter.sunset)
    }

    func testLocationValidation() {
        XCTAssertTrue(Solar.isValidLocation(latitude: 51.5, longitude: -0.12))
        XCTAssertTrue(Solar.isValidLocation(latitude: -33.87, longitude: 151.2))
        // 0,0 is a real place but overwhelmingly means "not set".
        XCTAssertFalse(Solar.isValidLocation(latitude: 0, longitude: 0))
        XCTAssertFalse(Solar.isValidLocation(latitude: 91, longitude: 0))
        XCTAssertFalse(Solar.isValidLocation(latitude: 0, longitude: 181))
    }

    /// Sunset falls later in the day than sunrise — **in the location's own time
    /// zone**. That qualifier is the whole point: an earlier version of this
    /// test measured foreign cities against the machine's local calendar and
    /// failed, because Sydney's sunset expressed in Pacific time genuinely does
    /// land before Sydney's sunrise expressed in Pacific time. The algorithm was
    /// right; the assumption wasn't.
    ///
    /// This is also why the schedule must not *rely* on the ordering — see
    /// `ScheduleWindowTests`.
    func testSunsetIsAfterSunriseInTheLocationsOwnTimeZone() {
        let places: [(lat: Double, lon: Double, tz: String)] = [
            (37.7749, -122.4194, "America/Los_Angeles"),
            (51.5074, -0.1278, "Europe/London"),
            (-33.8688, 151.2093, "Australia/Sydney"),
            (25.2048, 55.2708, "Asia/Dubai"),
        ]
        for place in places {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: place.tz)!
            for month in 1...12 {
                let t = Solar.times(latitude: place.lat, longitude: place.lon,
                                    date: noonUTC(2026, month, 15))
                guard t.condition == .normal,
                      let rise = t.sunrise, let set = t.sunset else { continue }
                XCTAssertGreaterThan(Solar.minutesOfDay(set, calendar: cal),
                                     Solar.minutesOfDay(rise, calendar: cal),
                                     "\(place.tz) month \(month)")
            }
        }
    }
}
