// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  BacklightCommanding.swift
//  SublightKit
//
//  The seam between the dither engine and the hardware. The engine only ever
//  needs three things from the backlight: command a level, hand control back
//  to the system, and make sure the system's own automatic adjustments are
//  not fighting the hold. `BridgeCommander` is the real implementation over
//  the private-API bridge; tests inject a recorder so phase logic can be
//  asserted without a keyboard.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

/// Which suppression flags were found flipped (i.e. not in the state the
/// engine wants) when `assertSuppression` read them back. `nil` means the
/// getter is unavailable on this build, so the flag was re-asserted blindly.
public struct SuppressionFlips: Equatable {
    public var autoBrightnessWasOn: Bool?
    public var idleDimWasActive: Bool?

    public init(autoBrightnessWasOn: Bool? = nil, idleDimWasActive: Bool? = nil) {
        self.autoBrightnessWasOn = autoBrightnessWasOn
        self.idleDimWasActive = idleDimWasActive
    }

    /// True if any flag was observed in the wrong state.
    public var any: Bool { autoBrightnessWasOn == true || idleDimWasActive == true }
}

public protocol BacklightCommanding: AnyObject {
    /// Command a brightness level in [0, 1]. Returns whether the daemon
    /// accepted the command.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool

    /// Hand control back to the system: auto-brightness on, idle dimming no
    /// longer suspended, and a plainly visible level so the keys are never
    /// left dark. Returns whether the level command was accepted.
    @discardableResult
    func restoreSystemControl(level: Float) -> Bool

    /// Ensure auto-brightness is off and idle dimming is suspended, so the
    /// ambient light sensor and the idle dimmer cannot stomp the hold.
    /// Reads before writing where a getter exists and reports what it found.
    func assertSuppression() -> SuppressionFlips
}

/// Production implementation: the private-API bridge, which is itself
/// confined to the engine queue, so these calls are safe from any thread.
public final class BridgeCommander: BacklightCommanding {

    public let bridge: KeyboardBrightnessBridge
    public let keyboardID: UInt64

    public init(bridge: KeyboardBrightnessBridge, keyboardID: UInt64) {
        self.bridge = bridge
        self.keyboardID = keyboardID
    }

    @discardableResult
    public func setBrightness(_ value: Float) -> Bool {
        bridge.setBrightness(value, keyboardID)
    }

    @discardableResult
    public func restoreSystemControl(level: Float) -> Bool {
        if bridge.supportsAutoBrightnessControl {
            bridge.setAutoBrightness(true, keyboardID)
        }
        bridge.setIdleDimmingSuspended(false, keyboardID)
        return bridge.setBrightness(level, keyboardID)
    }

    public func assertSuppression() -> SuppressionFlips {
        var flips = SuppressionFlips()
        if bridge.supportsAutoBrightnessControl {
            flips.autoBrightnessWasOn = bridge.isAutoBrightnessEnabled(keyboardID)
            bridge.setAutoBrightness(false, keyboardID)
        }
        if let suspended = bridge.isIdleDimmingSuspended(keyboardID) {
            flips.idleDimWasActive = !suspended
        }
        bridge.setIdleDimmingSuspended(true, keyboardID)
        return flips
    }
}
