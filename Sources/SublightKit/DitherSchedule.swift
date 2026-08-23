// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DitherSchedule.swift
//  SublightKit
//
//  Pure anchor arithmetic for the dither's two edge timers. Everything the
//  engine schedules is derived from ONE anchor instant and a period:
//
//      HIGH edge n  at  anchor + n * period
//      LOW  edge n  at  anchor + (n + duty) * period
//
//  No deadline is ever computed from "now + interval", so the latency of the
//  XPC call made inside an edge handler can never leak into the next
//  deadline — the schedule is fixed before the daemon is spoken to. Kept as a
//  value type with no timers so the arithmetic is unit-testable.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct DitherSchedule: Equatable {

    /// The duty range the engine will hold. Below 0.15 the LED spends so
    /// little time at the floor that the hold reads as off; above 0.85 the
    /// LOW edge sits so close to the next HIGH edge that the daemon merges
    /// them. The app's brightness slider maps onto exactly this range.
    public static let dutyRange: ClosedRange<Double> = 0.15...0.85

    /// Mach absolute uptime, in nanoseconds (DispatchTime's clock).
    public let anchorNanos: UInt64
    public let periodNanos: UInt64
    /// Fraction of each period spent at the HIGH level, already clamped.
    public let duty: Double

    public init(anchorNanos: UInt64, frequencyHz: Double, duty: Double) {
        self.anchorNanos = anchorNanos
        // Guard against non-finite / non-positive / absurdly-large input: a
        // NaN or 0 would trap in UInt64(...), and a frequency above ~1 GHz
        // would round the period down to 0 nanoseconds and then divide-by-zero
        // in cycle(at:). Callers clamp too; this is the last line of defence.
        let hz = (frequencyHz.isFinite && (1e-3...1e6).contains(frequencyHz)) ? frequencyHz : 9.0
        self.periodNanos = max(1, UInt64((1.0 / hz) * 1_000_000_000))
        self.duty = Self.clampDuty(duty)
    }

    private init(anchorNanos: UInt64, periodNanos: UInt64, duty: Double) {
        self.anchorNanos = anchorNanos
        self.periodNanos = periodNanos
        self.duty = Self.clampDuty(duty)
    }

    public static func clampDuty(_ duty: Double) -> Double {
        guard duty.isFinite else { return dutyRange.lowerBound }
        return min(max(duty, dutyRange.lowerBound), dutyRange.upperBound)
    }

    public var frequencyHz: Double { 1_000_000_000 / Double(periodNanos) }

    /// Offset of the LOW edge from its HIGH edge.
    public var lowOffsetNanos: UInt64 { UInt64(duty * Double(periodNanos)) }

    public func highDeadline(cycle n: UInt64) -> UInt64 {
        anchorNanos + n * periodNanos
    }

    public func lowDeadline(cycle n: UInt64) -> UInt64 {
        highDeadline(cycle: n) + lowOffsetNanos
    }

    /// Same anchor and period, new duty — the phase-continuous change.
    public func withDuty(_ newDuty: Double) -> DitherSchedule {
        DitherSchedule(anchorNanos: anchorNanos, periodNanos: periodNanos, duty: newDuty)
    }

    /// The cycle index `now` falls in (0 before the anchor).
    public func cycle(at now: UInt64) -> UInt64 {
        now <= anchorNanos ? 0 : (now - anchorNanos) / periodNanos
    }

    /// The next LOW deadline strictly after `now`: the smallest
    /// anchor + (n + duty) * period that lies in the future. If the LOW edge
    /// of cycle `firedCycle` has already been commanded, that cycle is
    /// skipped so no cycle gets two OFF edges.
    public func nextLowDeadline(after now: UInt64, lowAlreadyFiredIn firedCycle: UInt64? = nil) -> UInt64 {
        var n = cycle(at: now)
        if let fired = firedCycle, n <= fired { n = fired + 1 }
        var candidate = lowDeadline(cycle: n)
        while candidate <= now {
            n += 1
            candidate = lowDeadline(cycle: n)
        }
        return candidate
    }
}
