// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  Solar.swift
//  SublightKit
//
//  Sunrise and sunset, computed locally.
//
//  WHY THIS IS HERE RATHER THAN CoreLocation + a package:
//  Sublight's defining promise is that it makes no network calls. macOS
//  location services commonly resolve position via Wi-Fi lookups, so asking
//  CoreLocation for coordinates would put a network request behind the app's
//  back — and "the OS made the call, not us" is exactly the technicality that
//  costs an open-source project its credibility. It would also spend a
//  permission prompt, which a tool already asking for trust around private
//  APIs can ill afford. So: the user supplies coordinates once, and the maths
//  happens here.
//
//  The algorithm is the standard sunrise equation (NOAA's low-precision
//  formulation). Accurate to roughly a minute, which is far beyond what a
//  keyboard-dimming schedule needs. It is pure arithmetic — no I/O, no
//  dependency, and trivially testable.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct SolarTimes: Equatable {

    /// At high latitudes the sun may not cross the horizon at all, in which
    /// case there is no sunrise or sunset to schedule against.
    public enum Condition: Equatable {
        case normal
        /// Sun stays up all day — midnight sun.
        case polarDay
        /// Sun never rises.
        case polarNight
    }

    public let sunrise: Date?
    public let sunset: Date?
    public let condition: Condition

    public init(sunrise: Date?, sunset: Date?, condition: Condition) {
        self.sunrise = sunrise
        self.sunset = sunset
        self.condition = condition
    }
}

public enum Solar {

    /// Standard solar zenith for sunrise/sunset: the sun's centre sits just
    /// below the horizon, accounting for atmospheric refraction and the solar
    /// disc's radius.
    private static let horizonAngle = -0.833

    private static let obliquity = 23.4397
    private static let deg = Double.pi / 180

    /// Sunrise and sunset for the calendar day containing `date`.
    ///
    /// - Parameters:
    ///   - latitude: degrees north, −90…90.
    ///   - longitude: degrees **east**, −180…180. (Western hemisphere is
    ///     negative — a classic source of off-by-hours bugs.)
    public static func times(
        latitude: Double,
        longitude: Double,
        date: Date = Date()
    ) -> SolarTimes {

        // Julian day number, then days since the J2000.0 epoch.
        let julianDay = date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
        let n = (julianDay - 2_451_545.0 + 0.0008).rounded()

        // Mean solar noon at this longitude.
        let meanSolarNoon = n - longitude / 360.0

        // Solar mean anomaly.
        let M = (357.5291 + 0.98560028 * meanSolarNoon)
            .truncatingRemainder(dividingBy: 360)
        let Mrad = M * deg

        // Equation of the centre, and the ecliptic longitude that follows.
        let center = 1.9148 * sin(Mrad) + 0.0200 * sin(2 * Mrad) + 0.0003 * sin(3 * Mrad)
        let eclipticLongitude = (M + center + 180 + 102.9372)
            .truncatingRemainder(dividingBy: 360)
        let lambda = eclipticLongitude * deg

        // Solar transit (local solar noon), as a Julian date.
        let transit =
            2_451_545.0 + meanSolarNoon
            + 0.0053 * sin(Mrad)
            - 0.0069 * sin(2 * lambda)

        // Declination of the sun.
        let declination = asin(sin(lambda) * sin(obliquity * deg))

        // Hour angle. No solution means the sun doesn't cross the horizon.
        let phi = latitude * deg
        let numerator = sin(horizonAngle * deg) - sin(phi) * sin(declination)
        let denominator = cos(phi) * cos(declination)
        guard denominator != 0 else {
            return SolarTimes(sunrise: nil, sunset: nil, condition: .polarDay)
        }
        let cosHourAngle = numerator / denominator

        if cosHourAngle > 1 {
            return SolarTimes(sunrise: nil, sunset: nil, condition: .polarNight)
        }
        if cosHourAngle < -1 {
            return SolarTimes(sunrise: nil, sunset: nil, condition: .polarDay)
        }

        let hourAngle = acos(cosHourAngle) / deg
        let setJD = transit + hourAngle / 360.0
        let riseJD = transit - hourAngle / 360.0

        return SolarTimes(
            sunrise: dateFromJulian(riseJD),
            sunset: dateFromJulian(setJD),
            condition: .normal)
    }

    /// Named to avoid colliding with the `date` parameter above — a plain
    /// `date(fromJulian:)` is shadowed by it and fails to compile.
    private static func dateFromJulian(_ jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2_440_587.5) * 86_400.0)
    }

    /// Minutes since local midnight, for slotting into a time-of-day schedule.
    public static func minutesOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// True when the coordinates are plausible. 0,0 is technically valid (a
    /// spot in the Gulf of Guinea) but is overwhelmingly likely to mean
    /// "unset", so it's rejected.
    public static func isValidLocation(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= -90, latitude <= 90,
            longitude >= -180, longitude <= 180
        else { return false }
        return !(latitude == 0 && longitude == 0)
    }
}
