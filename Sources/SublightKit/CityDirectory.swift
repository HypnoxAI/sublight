// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  CityDirectory.swift
//  SublightKit
//
//  A small bundled list of cities, so solar scheduling doesn't demand that
//  people go and look up their own coordinates.
//
//  Keyed by IANA time zone identifier, which buys two things. First, the
//  identifiers are already city-named (`Europe/Madrid`, `Asia/Dubai`), so
//  matching `TimeZone.current` lets Sublight pre-fill a sensible location with
//  no input at all — using data the OS already has, with no permission and no
//  network. Second, it makes the entries unambiguous in a way bare city names
//  aren't.
//
//  ON ACCURACY: these are approximate city-centre coordinates, and that is
//  entirely sufficient. One degree of longitude shifts sunset by four minutes,
//  so even a city 300 km away lands within about a quarter of an hour — which
//  does not matter when the outcome is "dim the keyboard". Anyone who wants
//  precision can still enter coordinates by hand.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct CityLocation: Identifiable, Hashable, Sendable {
    public let city: String
    public let region: String
    public let latitude: Double
    public let longitude: Double
    public let timeZoneID: String

    /// Stable across launches, and unique because no two entries share both a
    /// time zone and a city name.
    public var id: String { "\(timeZoneID)#\(city)" }

    public var displayName: String { "\(city), \(region)" }

    /// Continent-ish grouping, taken from the time zone identifier's prefix so
    /// there's no second field to keep in sync.
    public var group: String {
        guard let prefix = timeZoneID.split(separator: "/").first else { return "Other" }
        switch prefix {
        case "America":   return "Americas"
        case "Europe":    return "Europe"
        case "Asia":      return "Asia"
        case "Africa":    return "Africa"
        case "Australia": return "Oceania"
        case "Pacific":   return "Pacific"
        case "Atlantic":  return "Atlantic"
        default:          return String(prefix)
        }
    }

    public init(_ city: String, _ region: String,
                _ latitude: Double, _ longitude: Double, _ timeZoneID: String) {
        self.city = city
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneID = timeZoneID
    }
}

public enum CityDirectory {

    /// The picker entry meaning "I'll type coordinates myself".
    public static let customID = "__custom__"

    public static func city(id: String) -> CityLocation? {
        all.first { $0.id == id }
    }

    /// Best match for a time zone identifier.
    ///
    /// Within a zone, prefers the city the zone is *named after* rather than
    /// whichever entry happens to come first. That distinction matters: several
    /// zones contain multiple listed cities, and taking the first would hand
    /// `Asia/Tokyo` to Osaka, `America/New_York` to Atlanta and
    /// `Asia/Ho_Chi_Minh` to Hanoi — errors of hundreds of kilometres, which is
    /// enough to visibly shift sunset.
    ///
    /// Comparison folds accents and case so `America/Sao_Paulo` still finds
    /// "São Paulo", and allows a prefix so `Asia/Ho_Chi_Minh` finds
    /// "Ho Chi Minh City".
    public static func match(timeZoneID: String) -> CityLocation? {
        let inZone = all.filter { $0.timeZoneID == timeZoneID }
        if !inZone.isEmpty {
            let zoneName = folded(String(timeZoneID.split(separator: "/").last ?? "")
                .replacingOccurrences(of: "_", with: " "))
            if let exact = inZone.first(where: { folded($0.city) == zoneName }) {
                return exact
            }
            if let prefixed = inZone.first(where: { folded($0.city).hasPrefix(zoneName) }) {
                return prefixed
            }
            return inZone.first
        }

        // Unlisted zone: fall back to the same region rather than giving up, so
        // the user at least starts somewhere plausible.
        guard let prefix = timeZoneID.split(separator: "/").first else { return nil }
        return all.first { $0.timeZoneID.hasPrefix(prefix + "/") }
    }

    private static func folded(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Best guess for this Mac, or nil if nothing plausible matches.
    public static func currentGuess(timeZone: TimeZone = .current) -> CityLocation? {
        match(timeZoneID: timeZone.identifier)
    }

    public static var grouped: [(group: String, cities: [CityLocation])] {
        let order = ["Americas", "Europe", "Africa", "Asia", "Oceania", "Pacific", "Atlantic"]
        let buckets = Dictionary(grouping: all, by: \.group)
        return order.compactMap { name in
            guard let cities = buckets[name] else { return nil }
            return (name, cities.sorted { $0.city < $1.city })
        }
    }

    public static let all: [CityLocation] = [
        // — Americas —
        .init("Anchorage", "USA", 61.22, -149.90, "America/Anchorage"),
        .init("Atlanta", "USA", 33.75, -84.39, "America/New_York"),
        .init("Bogotá", "Colombia", 4.71, -74.07, "America/Bogota"),
        .init("Boston", "USA", 42.36, -71.06, "America/New_York"),
        .init("Buenos Aires", "Argentina", -34.60, -58.38, "America/Argentina/Buenos_Aires"),
        .init("Calgary", "Canada", 51.05, -114.07, "America/Edmonton"),
        .init("Caracas", "Venezuela", 10.48, -66.90, "America/Caracas"),
        .init("Chicago", "USA", 41.88, -87.63, "America/Chicago"),
        .init("Denver", "USA", 39.74, -104.99, "America/Denver"),
        .init("Guadalajara", "Mexico", 20.67, -103.35, "America/Mexico_City"),
        .init("Houston", "USA", 29.76, -95.37, "America/Chicago"),
        .init("Lima", "Peru", -12.05, -77.04, "America/Lima"),
        .init("Los Angeles", "USA", 34.05, -118.24, "America/Los_Angeles"),
        .init("Mexico City", "Mexico", 19.43, -99.13, "America/Mexico_City"),
        .init("Miami", "USA", 25.76, -80.19, "America/New_York"),
        .init("Minneapolis", "USA", 44.98, -93.27, "America/Chicago"),
        .init("Montevideo", "Uruguay", -34.90, -56.16, "America/Montevideo"),
        .init("Montréal", "Canada", 45.50, -73.57, "America/Toronto"),
        .init("New York", "USA", 40.71, -74.01, "America/New_York"),
        .init("Phoenix", "USA", 33.45, -112.07, "America/Phoenix"),
        .init("Quito", "Ecuador", -0.18, -78.47, "America/Guayaquil"),
        .init("Rio de Janeiro", "Brazil", -22.91, -43.17, "America/Sao_Paulo"),
        .init("San Francisco", "USA", 37.77, -122.42, "America/Los_Angeles"),
        .init("Santiago", "Chile", -33.45, -70.67, "America/Santiago"),
        .init("São Paulo", "Brazil", -23.55, -46.63, "America/Sao_Paulo"),
        .init("Seattle", "USA", 47.61, -122.33, "America/Los_Angeles"),
        .init("Toronto", "Canada", 43.65, -79.38, "America/Toronto"),
        .init("Vancouver", "Canada", 49.28, -123.12, "America/Vancouver"),

        // — Europe —
        .init("Amsterdam", "Netherlands", 52.37, 4.90, "Europe/Amsterdam"),
        .init("Athens", "Greece", 37.98, 23.73, "Europe/Athens"),
        .init("Barcelona", "Spain", 41.39, 2.17, "Europe/Madrid"),
        .init("Berlin", "Germany", 52.52, 13.40, "Europe/Berlin"),
        .init("Brussels", "Belgium", 50.85, 4.35, "Europe/Brussels"),
        .init("Bucharest", "Romania", 44.43, 26.11, "Europe/Bucharest"),
        .init("Budapest", "Hungary", 47.50, 19.04, "Europe/Budapest"),
        .init("Copenhagen", "Denmark", 55.68, 12.57, "Europe/Copenhagen"),
        .init("Dublin", "Ireland", 53.35, -6.26, "Europe/Dublin"),
        .init("Helsinki", "Finland", 60.17, 24.94, "Europe/Helsinki"),
        .init("Istanbul", "Türkiye", 41.01, 28.98, "Europe/Istanbul"),
        .init("Kyiv", "Ukraine", 50.45, 30.52, "Europe/Kyiv"),
        .init("Lisbon", "Portugal", 38.72, -9.14, "Europe/Lisbon"),
        .init("London", "United Kingdom", 51.51, -0.13, "Europe/London"),
        .init("Madrid", "Spain", 40.42, -3.70, "Europe/Madrid"),
        .init("Milan", "Italy", 45.46, 9.19, "Europe/Rome"),
        .init("Moscow", "Russia", 55.76, 37.62, "Europe/Moscow"),
        .init("Oslo", "Norway", 59.91, 10.75, "Europe/Oslo"),
        .init("Paris", "France", 48.86, 2.35, "Europe/Paris"),
        .init("Prague", "Czechia", 50.08, 14.44, "Europe/Prague"),
        .init("Rome", "Italy", 41.90, 12.50, "Europe/Rome"),
        .init("Stockholm", "Sweden", 59.33, 18.07, "Europe/Stockholm"),
        .init("Vienna", "Austria", 48.21, 16.37, "Europe/Vienna"),
        .init("Warsaw", "Poland", 52.23, 21.01, "Europe/Warsaw"),
        .init("Zürich", "Switzerland", 47.38, 8.54, "Europe/Zurich"),

        // — Africa —
        .init("Accra", "Ghana", 5.60, -0.19, "Africa/Accra"),
        .init("Addis Ababa", "Ethiopia", 9.03, 38.74, "Africa/Addis_Ababa"),
        .init("Algiers", "Algeria", 36.75, 3.06, "Africa/Algiers"),
        .init("Cairo", "Egypt", 30.04, 31.24, "Africa/Cairo"),
        .init("Cape Town", "South Africa", -33.92, 18.42, "Africa/Johannesburg"),
        .init("Casablanca", "Morocco", 33.57, -7.59, "Africa/Casablanca"),
        .init("Johannesburg", "South Africa", -26.20, 28.05, "Africa/Johannesburg"),
        .init("Lagos", "Nigeria", 6.52, 3.38, "Africa/Lagos"),
        .init("Nairobi", "Kenya", -1.29, 36.82, "Africa/Nairobi"),
        .init("Tunis", "Tunisia", 36.81, 10.18, "Africa/Tunis"),

        // — Asia —
        .init("Almaty", "Kazakhstan", 43.24, 76.89, "Asia/Almaty"),
        .init("Amman", "Jordan", 31.95, 35.93, "Asia/Amman"),
        .init("Baghdad", "Iraq", 33.31, 44.36, "Asia/Baghdad"),
        .init("Bangkok", "Thailand", 13.76, 100.50, "Asia/Bangkok"),
        .init("Beijing", "China", 39.90, 116.41, "Asia/Shanghai"),
        .init("Beirut", "Lebanon", 33.89, 35.50, "Asia/Beirut"),
        .init("Bengaluru", "India", 12.97, 77.59, "Asia/Kolkata"),
        .init("Chennai", "India", 13.08, 80.27, "Asia/Kolkata"),
        .init("Colombo", "Sri Lanka", 6.93, 79.86, "Asia/Colombo"),
        .init("Delhi", "India", 28.61, 77.21, "Asia/Kolkata"),
        .init("Dhaka", "Bangladesh", 23.81, 90.41, "Asia/Dhaka"),
        .init("Doha", "Qatar", 25.29, 51.53, "Asia/Qatar"),
        .init("Dubai", "UAE", 25.20, 55.27, "Asia/Dubai"),
        .init("Hanoi", "Vietnam", 21.03, 105.85, "Asia/Ho_Chi_Minh"),
        .init("Ho Chi Minh City", "Vietnam", 10.82, 106.63, "Asia/Ho_Chi_Minh"),
        .init("Hong Kong", "Hong Kong", 22.32, 114.17, "Asia/Hong_Kong"),
        .init("Hyderabad", "India", 17.39, 78.49, "Asia/Kolkata"),
        .init("Islamabad", "Pakistan", 33.68, 73.05, "Asia/Karachi"),
        .init("Jakarta", "Indonesia", -6.21, 106.85, "Asia/Jakarta"),
        .init("Jerusalem", "Israel", 31.77, 35.21, "Asia/Jerusalem"),
        .init("Karachi", "Pakistan", 24.86, 67.01, "Asia/Karachi"),
        .init("Kathmandu", "Nepal", 27.72, 85.32, "Asia/Kathmandu"),
        .init("Kolkata", "India", 22.57, 88.36, "Asia/Kolkata"),
        .init("Kuala Lumpur", "Malaysia", 3.14, 101.69, "Asia/Kuala_Lumpur"),
        .init("Kuwait City", "Kuwait", 29.38, 47.98, "Asia/Kuwait"),
        .init("Lahore", "Pakistan", 31.55, 74.34, "Asia/Karachi"),
        .init("Manila", "Philippines", 14.60, 120.98, "Asia/Manila"),
        .init("Mumbai", "India", 19.08, 72.88, "Asia/Kolkata"),
        .init("Muscat", "Oman", 23.59, 58.41, "Asia/Muscat"),
        .init("Osaka", "Japan", 34.69, 135.50, "Asia/Tokyo"),
        .init("Riyadh", "Saudi Arabia", 24.71, 46.68, "Asia/Riyadh"),
        .init("Seoul", "South Korea", 37.57, 126.98, "Asia/Seoul"),
        .init("Shanghai", "China", 31.23, 121.47, "Asia/Shanghai"),
        .init("Shenzhen", "China", 22.54, 114.06, "Asia/Shanghai"),
        .init("Singapore", "Singapore", 1.35, 103.82, "Asia/Singapore"),
        .init("Taipei", "Taiwan", 25.03, 121.57, "Asia/Taipei"),
        .init("Tashkent", "Uzbekistan", 41.30, 69.24, "Asia/Tashkent"),
        .init("Tehran", "Iran", 35.69, 51.39, "Asia/Tehran"),
        .init("Tokyo", "Japan", 35.68, 139.69, "Asia/Tokyo"),
        .init("Vladivostok", "Russia", 43.12, 131.89, "Asia/Vladivostok"),

        // — Oceania & Pacific —
        .init("Adelaide", "Australia", -34.93, 138.60, "Australia/Adelaide"),
        .init("Brisbane", "Australia", -27.47, 153.03, "Australia/Brisbane"),
        .init("Melbourne", "Australia", -37.81, 144.96, "Australia/Melbourne"),
        .init("Perth", "Australia", -31.95, 115.86, "Australia/Perth"),
        .init("Sydney", "Australia", -33.87, 151.21, "Australia/Sydney"),
        .init("Auckland", "New Zealand", -36.85, 174.76, "Pacific/Auckland"),
        .init("Honolulu", "USA", 21.31, -157.86, "Pacific/Honolulu"),
        .init("Suva", "Fiji", -18.14, 178.44, "Pacific/Fiji"),
        .init("Wellington", "New Zealand", -41.29, 174.78, "Pacific/Auckland"),

        // — Atlantic —
        .init("Reykjavík", "Iceland", 64.15, -21.94, "Atlantic/Reykjavik"),
    ]
}
