// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  BacklightController.swift
//  SublightKit
//
//  The public face of the engine. One call — setLevel(_:) — routes to the
//  right engine:
//
//      level == 0            → direct set to 0 (off is a legal value)
//      0 < level < floor     → Engine B: dither hold (duty = level / floor)
//      level >= floor        → Engine A: direct set (fully idle afterwards)
//
//  Entering the sub-minimum zone also disables keyboard auto-brightness
//  (saving its prior state) so the ambient light sensor doesn't fight the
//  hold loop; leaving the zone restores it.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public final class BacklightController {

    public let bridge: KeyboardBrightnessBridge
    public let keyboardID: UInt64

    /// The assumed macOS clamp floor, normalized [0, 1].
    ///
    /// 0.0625 = 1/16 — the lowest non-zero step of the 16-step system
    /// brightness ladder — is a REASONABLE GUESS, not a measured constant.
    /// Run `sublight-cli probe` on your machine and adjust (persisted by the
    /// app via UserDefaults, or pass --floor to the CLI).
    public var floor: Float {
        didSet { floor = min(max(floor, 0.005), 0.5) }
    }

    /// Dither period while holding sub-minimum. Placeholder pending
    /// calibration; see SPEC §5.4.
    public var period: TimeInterval = 0.25

    public private(set) var isHolding = false

    private let dither: DitherEngine
    private var savedAutoBrightness: Bool?

    // MARK: - Init

    public init(floor: Float = 0.0625) throws {
        let bridge = try KeyboardBrightnessBridge()
        self.bridge = bridge
        self.keyboardID = bridge.resolveBuiltInKeyboard()
        self.floor = min(max(floor, 0.005), 0.5)
        let id = self.keyboardID
        self.dither = DitherEngine { value in
            bridge.setBrightness(value, id)
        }
    }

    // MARK: - Unified level control

    /// Set the perceived backlight level, 0…1. Values inside (0, floor)
    /// engage the dither hold; everything else is a plain direct set.
    public func setLevel(_ level: Float) {
        let l = min(max(level, 0), 1)

        if l < 0.001 {
            releaseHoldIfNeeded()
            bridge.setBrightness(0, keyboardID)
            return
        }

        if l >= floor {
            releaseHoldIfNeeded()
            bridge.setBrightness(l, keyboardID)
            return
        }

        // Sub-minimum zone.
        beginHoldIfNeeded()
        let duty = Double(l / floor) // first-order linear model; SPEC §5.3
        dither.run(DitherEngine.Parameters(period: period, duty: duty, high: floor, low: 0))
    }

    /// Read what the daemon reports (may be a fade target, not the LED —
    /// see KeyboardBrightnessBridge.brightness docs).
    public func reportedBrightness() -> Float? {
        bridge.brightness(keyboardID)
    }

    // MARK: - Hold lifecycle

    private func beginHoldIfNeeded() {
        guard !isHolding else { return }
        if bridge.supportsAutoBrightnessControl {
            savedAutoBrightness = bridge.isAutoBrightnessEnabled(keyboardID)
            bridge.setAutoBrightness(false, keyboardID)
        }
        isHolding = true
    }

    private func releaseHoldIfNeeded() {
        guard isHolding else { return }
        dither.stop(finalLevel: nil)
        if let saved = savedAutoBrightness {
            bridge.setAutoBrightness(saved, keyboardID)
        }
        savedAutoBrightness = nil
        isHolding = false
    }

    /// Pause the hold without touching auto-brightness bookkeeping —
    /// used on system sleep so we stop issuing commands.
    public func suspendHold() {
        dither.stop(finalLevel: nil)
    }

    /// Reassert the current mode after wake. Callers pass the level they
    /// want live again (the app keeps it in its own state).
    public func resume(level: Float) {
        setLevel(level)
    }

    // MARK: - Safety

    /// The panic button: stop everything, hand control back to the system,
    /// and land on a plainly visible level. Safe to call at any time from
    /// any state, including a half-initialized one.
    public func panicRestore(to level: Float = 0.3) {
        dither.stop(finalLevel: nil)
        if bridge.supportsAutoBrightnessControl {
            bridge.setAutoBrightness(true, keyboardID)
        }
        bridge.setBrightness(level, keyboardID)
        savedAutoBrightness = nil
        isHolding = false
    }
}
