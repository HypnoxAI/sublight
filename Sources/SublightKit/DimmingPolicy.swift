// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DimmingPolicy.swift
//  SublightKit
//
//  The one rule that decides whether the engine should be running:
//
//      effectiveRunning = userEnabled && !systemSuspended
//
//  `userEnabled` is the user's intent (the toggle, the hotkey, the schedule).
//  `systemSuspended` is the machine's state (asleep, screens off, session
//  inactive). Suspension never clears the intent, so waking re-engages.
//  AppState owns both inputs and forwards here; the functions are pure so the
//  matrix is unit-tested.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

/// The shipped frequency presets. They live here, not in the app, because
/// High is not a number someone chose — it IS the measured stability ceiling,
/// and tying it to the constant makes that structural rather than a comment
/// somebody has to remember to update.
public enum FrequencyPreset {
    public static let low = 3.0
    public static let medium = 6.0
    public static let high = DitherEngine.maxStableFrequencyHz

    /// Label/value pairs in UI order.
    public static let all: [(label: String, hz: Double)] =
        [("Low", low), ("Medium", medium), ("High", high)]
}

public enum DimmingPolicy {

    public static func effectiveRunning(userEnabled: Bool, systemSuspended: Bool) -> Bool {
        userEnabled && !systemSuspended
    }

    /// Menu bar glyph fill: hollow unless effectively running, otherwise the
    /// frequency in use bucketed to the nearest preset — Low 3 Hz → 0.3,
    /// Medium 6 Hz → 0.5, High 8 Hz → 0.8. The boundaries are the preset
    /// MIDPOINTS (4.5 between 3 and 6; 7.0 between 6 and 8), so a custom
    /// frequency lands on whichever preset it is actually closest to.
    public static func glyphFraction(userEnabled: Bool, systemSuspended: Bool, frequencyHz: Double) -> Double {
        guard effectiveRunning(userEnabled: userEnabled, systemSuspended: systemSuspended) else { return 0 }
        switch frequencyHz {
        case ..<4.5: return 0.3
        case ..<7.0: return 0.5
        default:     return 0.8
        }
    }
}
