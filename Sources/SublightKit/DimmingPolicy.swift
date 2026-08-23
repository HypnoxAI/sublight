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

public enum DimmingPolicy {

    public static func effectiveRunning(userEnabled: Bool, systemSuspended: Bool) -> Bool {
        userEnabled && !systemSuspended
    }

    /// Menu bar glyph fill: hollow unless effectively running, otherwise the
    /// frequency in use bucketed to the nearest preset — Low 3 Hz → 0.3,
    /// Medium 6 Hz → 0.5, High 9 Hz → 0.8.
    public static func glyphFraction(userEnabled: Bool, systemSuspended: Bool, frequencyHz: Double) -> Double {
        guard effectiveRunning(userEnabled: userEnabled, systemSuspended: systemSuspended) else { return 0 }
        switch frequencyHz {
        case ..<4.5: return 0.3
        case ..<7.5: return 0.5
        default:     return 0.8
        }
    }
}
