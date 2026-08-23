// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  CityDirectoryTests.swift
//
//  A hand-typed table of ~120 cities is exactly the sort of data that acquires
//  a silent typo — a transposed sign, a duplicated entry, a time zone
//  identifier that doesn't exist. None of those would crash; they'd just make
//  someone's sunset wrong. These checks are cheap insurance.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest

@testable import SublightKit

final class CityDirectoryTests: XCTestCase {

    func testAllCoordinatesAreValid() {
        for city in CityDirectory.all {
            XCTAssertTrue(
                Solar.isValidLocation(latitude: city.latitude, longitude: city.longitude),
                "\(city.displayName) has implausible coordinates "
                    + "(\(city.latitude), \(city.longitude))")
        }
    }

    /// Catches typos in IANA identifiers, which would otherwise silently break
    /// time-zone auto-detection for that city.
    func testAllTimeZoneIdentifiersResolve() {
        for city in CityDirectory.all {
            XCTAssertNotNil(
                TimeZone(identifier: city.timeZoneID),
                "\(city.displayName): unknown time zone '\(city.timeZoneID)'")
        }
    }

    func testIDsAreUnique() {
        let ids = CityDirectory.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate city IDs")
    }

    func testLookupRoundTrips() {
        for city in CityDirectory.all {
            XCTAssertEqual(CityDirectory.city(id: city.id), city)
        }
        XCTAssertNil(CityDirectory.city(id: CityDirectory.customID))
    }

    /// The whole point of keying by time zone: a Mac set to one of these zones
    /// should get a sensible pre-filled location.
    func testTimeZoneMatching() {
        XCTAssertEqual(CityDirectory.match(timeZoneID: "Europe/London")?.city, "London")
        XCTAssertEqual(
            CityDirectory.match(timeZoneID: "Australia/Sydney")?.city, "Sydney")

        // Zones containing several listed cities must resolve to the city the
        // zone is named after, not merely the first one in the table.
        XCTAssertEqual(CityDirectory.match(timeZoneID: "Asia/Tokyo")?.city, "Tokyo")
        XCTAssertEqual(
            CityDirectory.match(timeZoneID: "America/New_York")?.city, "New York")
        XCTAssertEqual(CityDirectory.match(timeZoneID: "Asia/Kolkata")?.city, "Kolkata")
        XCTAssertEqual(
            CityDirectory.match(timeZoneID: "Africa/Johannesburg")?.city, "Johannesburg")

        // Accent-insensitive.
        XCTAssertEqual(
            CityDirectory.match(timeZoneID: "America/Sao_Paulo")?.city, "São Paulo")
        XCTAssertEqual(CityDirectory.match(timeZoneID: "Europe/Zurich")?.city, "Zürich")

        // Prefix match, for zones whose name is shorter than the city's.
        XCTAssertEqual(
            CityDirectory.match(timeZoneID: "Asia/Ho_Chi_Minh")?.city, "Ho Chi Minh City")

        // Multi-segment identifier.
        XCTAssertEqual(
            CityDirectory.match(timeZoneID: "America/Argentina/Buenos_Aires")?.city,
            "Buenos Aires")

        // An unlisted zone should still fall back within the right region
        // rather than giving up entirely.
        let fallback = CityDirectory.match(timeZoneID: "Europe/Andorra")
        XCTAssertNotNil(fallback)
        XCTAssertEqual(fallback?.group, "Europe")

        XCTAssertNil(CityDirectory.match(timeZoneID: "Nonsense/Nowhere"))
    }

    /// Every city must appear in exactly one group, or the picker would drop
    /// or duplicate entries.
    func testGroupingCoversEveryCityExactlyOnce() {
        let grouped = CityDirectory.grouped.flatMap(\.cities)
        XCTAssertEqual(grouped.count, CityDirectory.all.count)
        XCTAssertEqual(Set(grouped.map(\.id)), Set(CityDirectory.all.map(\.id)))
    }

    /// Sanity-check the table against the solar maths: every city should get a
    /// real sunrise and sunset at an equinox, when nowhere on earth is in
    /// polar day or night. A sign error would show up here.
    func testEveryCityProducesSaneEquinoxTimes() {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 20; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let equinox = cal.date(from: c)!

        for city in CityDirectory.all {
            let t = Solar.times(
                latitude: city.latitude, longitude: city.longitude, date: equinox)
            XCTAssertEqual(
                t.condition, .normal, "\(city.displayName) has no equinox sunrise/sunset")

            guard let rise = t.sunrise, let set = t.sunset else { continue }
            // At an equinox day length is close to 12 hours everywhere.
            let hours = set.timeIntervalSince(rise) / 3600
            XCTAssertEqual(
                hours, 12, accuracy: 1.0,
                "\(city.displayName): equinox day length \(hours)h")
        }
    }
}
