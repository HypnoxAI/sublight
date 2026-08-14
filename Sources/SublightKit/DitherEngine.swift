// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DitherEngine.swift
//  SublightKit
//
//  Engine B: temporal dithering.
//
//  macOS clamps commanded keyboard brightness to a floor (lowest legal
//  non-zero step). There is no userspace write path to the PWM hardware.
//  What we DO have is a daemon-managed fade: every setBrightness command is
//  applied as a ramp toward the target, not a step.
//
//  The trick: alternate between two LEGAL targets — the floor and off — at a
//  period shorter than the fade ramp. The LED never completes either
//  transition; its instantaneous output hovers in a narrow band whose
//  time-average sits BELOW the floor. The OS's own fade ramp acts as our
//  low-pass filter. The duty fraction (time spent commanding the high
//  target) sets the perceived level.
//
//  Consequences of the model (see docs/SPEC.md §5 for the full analysis):
//    * Period too long  → LED completes swings → visible blinking.
//    * Timer jitter under CPU load → band widens → visible shimmer.
//    * This is why we use a .strict DispatchSourceTimer with ~1 ms leeway
//      on a userInteractive queue — precision is the feature; the cost is
//      2/period wakeups per second, and ONLY while holding sub-minimum.
//      At or above the floor the engine is fully idle (zero timers).
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public final class DitherEngine {

    public struct Parameters {
        /// One full high+low cycle, in seconds. Default is a placeholder —
        /// calibrate on your machine (README "First run", SPEC §5.4).
        public var period: TimeInterval
        /// Fraction of the period spent commanding `high` (0…1).
        public var duty: Double
        /// The high target — normally the system floor (a legal value).
        public var high: Float
        /// The low target — normally 0 (off; also legal).
        public var low: Float

        public init(period: TimeInterval = 0.25, duty: Double = 0.5, high: Float = 0.0625, low: Float = 0.0) {
            self.period = period
            self.duty = duty
            self.high = high
            self.low = low
        }
    }

    /// Injected setter — in production this is the bridge's setBrightness;
    /// in tests it can be a recorder.
    private let apply: (Float) -> Void

    private let queue = DispatchQueue(label: "sublight.dither", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var params = Parameters()
    private var phaseHigh = true

    public private(set) var isRunning = false

    public init(apply: @escaping (Float) -> Void) {
        self.apply = apply
    }

    deinit {
        timer?.cancel()
    }

    /// Start the hold loop, or retune it in place if already running.
    /// Duty is clamped to [0.02, 0.98]; callers wanting a plain static level
    /// should not be dithering at all (BacklightController handles that).
    public func run(_ newParams: Parameters) {
        queue.async { [weak self] in
            guard let self else { return }
            var p = newParams
            p.duty = min(max(p.duty, 0.02), 0.98)
            p.period = min(max(p.period, 0.02), 5.0)
            self.params = p
            if !self.isRunning {
                self.startLocked()
            }
            // If already running, the new parameters take effect on the next
            // tick — at these periods that is imperceptible.
        }
    }

    /// Stop the loop. If `finalLevel` is non-nil, command it once after
    /// stopping so the backlight lands somewhere deterministic.
    public func stop(finalLevel: Float?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.isRunning = false
            if let level = finalLevel {
                self.apply(level)
            }
        }
    }

    // MARK: - Private (all on `queue`)

    private func startLocked() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer = t
        isRunning = true
        phaseHigh = true
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        // Fire immediately; each tick schedules the next one-shot deadline,
        // which lets high/low phases have different durations (asymmetric duty).
        t.schedule(deadline: .now(), leeway: .milliseconds(1))
        t.resume()
    }

    private func tick() {
        guard let t = timer, isRunning else { return }
        let p = params
        let interval: TimeInterval
        if phaseHigh {
            apply(p.high)
            interval = p.period * p.duty
        } else {
            apply(p.low)
            interval = p.period * (1.0 - p.duty)
        }
        phaseHigh.toggle()
        t.schedule(deadline: .now() + interval, leeway: .milliseconds(1))
    }
}
