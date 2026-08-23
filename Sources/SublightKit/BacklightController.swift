// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  BacklightController.swift
//  SublightKit
//
//  The public face of the engine: composition root for the bridge, the
//  engine, and the per-machine floor. One call — setLevel(_:) — routes to
//  the right path:
//
//      level == 0            → restore (if engaged), then direct set to 0
//      0 < level < floor     → Engine B: dither hold (duty = level / floor)
//      level >= floor        → restore (if engaged), then direct set
//
//  Every direct set goes through the queue-confined bridge, so it is ordered
//  with respect to the dither edges. Every path that leaves the sub-minimum
//  zone commands a restore to system control first (DitherEngine's rule).
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

/// `@unchecked Sendable`: it owns nothing mutable of its own beyond two
/// configuration values, and every call it makes goes through the
/// queue-confined bridge or the engine (both of which state the same
/// invariant). It is handed between the app's main actor and the engine queue
/// for exactly that reason.
public final class BacklightController: @unchecked Sendable {

    public let bridge: KeyboardBrightnessBridge
    public let keyboardID: UInt64
    public let engine: DitherEngine

    /// The assumed macOS clamp floor, normalized [0, 1].
    ///
    /// 0.0625 = 1/16 — the lowest non-zero step of the 16-step system
    /// brightness ladder — is a REASONABLE GUESS, not a measured constant.
    /// Run `sublight-cli probe` on your machine and adjust (persisted by the
    /// app via UserDefaults, or pass --floor to the CLI).
    public var floor: Float {
        didSet {
            floor = min(max(floor, 0.005), 0.5)
            engine.highLevel = floor
        }
    }

    /// Dither frequency while holding sub-minimum. Applied on the next
    /// `setLevel`; changing it mid-run takes a new timing anchor.
    ///
    /// Clamped through the ENGINE rather than against the static range, so
    /// that reading this property back always tells you what will actually
    /// run — including when `allowsUnstableFrequency` has lifted the ceiling.
    public var frequencyHz: Double = DitherEngine.maxStableFrequencyHz {
        didSet { frequencyHz = engine.clampedFrequency(frequencyHz) }
    }

    /// Research escape hatch — lifts the measured stability ceiling. Set it
    /// BEFORE assigning `frequencyHz`, or the assignment clamps first.
    public var allowsUnstableFrequency: Bool {
        get { engine.allowsUnstableFrequency }
        set { engine.allowsUnstableFrequency = newValue }
    }

    /// Period form of `frequencyHz`, for callers that think in seconds
    /// (the CLI's --period flag).
    public var period: TimeInterval {
        get { 1.0 / frequencyHz }
        set { frequencyHz = 1.0 / newValue }
    }

    public var isHolding: Bool { engine.isRunning }

    // MARK: - Init

    public init(floor: Float = 0.0625) throws {
        let bridge = try KeyboardBrightnessBridge()
        self.bridge = bridge
        self.keyboardID = bridge.resolveBuiltInKeyboard()
        let f = min(max(floor, 0.005), 0.5)
        self.floor = f
        self.engine = DitherEngine(
            commander: BridgeCommander(bridge: bridge, keyboardID: keyboardID),
            highLevel: f)
    }

    // MARK: - Unified level control

    /// Set the perceived backlight level, 0…1. Values inside (0, floor)
    /// engage the dither hold; everything else is a plain direct set.
    public func setLevel(_ level: Float) {
        let l = min(max(level, 0), 1)

        if l < 0.001 {
            engine.restoreNow()
            bridge.setBrightness(0, keyboardID)
            return
        }

        if l >= floor {
            engine.restoreNow()
            bridge.setBrightness(l, keyboardID)
            return
        }

        // Sub-minimum zone. First-order linear model (SPEC §5.3); the engine
        // clamps the duty to its holdable range.
        let duty = Double(l / floor)
        if engine.isRunning {
            engine.setFrequency(frequencyHz)
            engine.setDuty(duty)
        } else {
            engine.start(frequencyHz: frequencyHz, duty: duty)
        }
    }

    /// Read what the daemon reports (may be a fade target, not the LED —
    /// see KeyboardBrightnessBridge.brightness docs).
    public func reportedBrightness() -> Float? {
        bridge.brightness(keyboardID)
    }

    // MARK: - Safety

    /// The panic button: stop everything, hand control back to the system,
    /// and land on a plainly visible level. Synchronous; safe to call at any
    /// time from any thread and any state, including a half-initialized one.
    @discardableResult
    public func panicRestore(to level: Float = 0.3) -> Bool {
        engine.restoreLevel = level
        return engine.restoreNow(force: true)
    }

    /// Exit-time restore for terminate and signal handlers: identical to
    /// `panicRestore` once this process has commanded the backlight, and a
    /// no-op when it never has. See DitherEngine.restoreOnExit.
    @discardableResult
    public func restoreOnExit(to level: Float = 0.4) -> Bool {
        engine.restoreOnExit(level: level)
    }

    /// True once any backlight-mutating command has been issued this session,
    /// including calibration's direct bridge writes.
    public var hardwareTouched: Bool { EngineDiagnostics.shared.hardwareTouched }

    /// Launch-time crash recovery (see DirtyFlag). Call once, before any
    /// other backlight command.
    @discardableResult
    public func recoverFromCrashIfNeeded() -> DirtyFlag.Recovery {
        engine.recoverFromCrashIfNeeded()
    }

    /// Arm crash recovery for a direct-write suppression the engine is not
    /// driving (used by guided calibration). See DitherEngine.armCrashRecovery.
    public func armCrashRecovery() {
        engine.armCrashRecovery()
    }
}
