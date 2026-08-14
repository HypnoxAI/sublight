// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  ScheduleWindow.swift
//  SublightKit
//
//  Time-of-day window arithmetic, extracted from the app so it can be tested.
//
//  This is deceptively fiddly: a dimming schedule almost always runs overnight,
//  so the window wraps past midnight and the naive `start <= now < end` check is
//  wrong for the common case. It is also exactly the kind of logic that breaks
//  silently — the schedule simply doesn't fire, and nobody notices for a week.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public enum ScheduleWindow {

    /// Whether `now` falls inside the window, where all values are minutes
    /// since local midnight (0..<1440).
    ///
    /// Handles both orderings deliberately:
    /// - `start < end` — a same-day window, e.g. 09:00→17:00.
    /// - `start > end` — a window that wraps past midnight, e.g. 21:00→07:00.
    ///   This is the normal case for a dimming schedule.
    ///
    /// The wrapping case is not merely a fixed-times concern: solar scheduling
    /// produces (sunset, sunrise), which wraps whenever the machine's time zone
    /// matches its coordinates. When they *don't* match — someone entering
    /// coordinates from the other side of the world — the pair arrives in the
    /// other order, and the same-day branch handles it correctly rather than
    /// silently doing nothing.
    ///
    /// Equal start and end means an empty window, not a full day: a user who
    /// sets both times the same has expressed no window, and dimming for 24
    /// hours would be a surprising reading of that.
    public static func contains(now: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end {
            return now >= start && now < end
        }
        return now >= start || now < end
    }

    /// Minutes since local midnight for a given date.
    public static func minutesOfDay(_ date: Date = Date(),
                                    calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
