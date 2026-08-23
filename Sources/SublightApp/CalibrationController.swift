// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  CalibrationController.swift
//  SublightApp
//
//  Guided calibration. Three findings, in order:
//
//    1. FLOOR (hardware).  Where this Mac's driver clamps the backlight.
//       Below the clamp every commanded value renders identically, so the
//       test is: play a known sub-floor reference, then a candidate, and ask
//       whether the candidate looked BRIGHTER or the SAME. "Brighter" means
//       the candidate cleared the clamp. Bisect to the boundary.
//       These are DIRECT bridge writes, deliberately bypassing
//       BacklightController.setLevel — routing through setLevel would engage
//       the dither and we'd be measuring the dither, not the clamp.
//
//    2. FLICKER-FREE FREQUENCY (subjective).  The lowest dither frequency
//       that still looks steady TO THIS PERSON. Flicker fusion varies by
//       individual, so 8 Hz being smooth here says nothing about anyone else.
//       Bisect on "steady or pulsing?".
//
//    3. PREFERRED LEVEL (subjective).  Not a bisection — a live slider, since
//       preference is something you set rather than something you converge on.
//
//  Results are stored per hardware model identifier, so moving to a different
//  Mac transparently falls back to defaults and asks to recalibrate.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import SwiftUI
import os
import SublightKit

@MainActor
final class CalibrationController: ObservableObject {

    enum Step: Int, CaseIterable {
        case intro, floor, frequency, level, summary

        var title: String {
            switch self {
            case .intro:     return "Calibrate for this Mac"
            case .floor:     return "Step 1 of 3 — brightness floor"
            case .frequency: return "Step 2 of 3 — flicker"
            case .level:     return "Step 3 of 3 — your dim level"
            case .summary:   return "Calibration complete"
            }
        }
    }

    // Search bounds. Floor: 0.005 is far below any plausible clamp; 0.30 is
    // far above one. Frequency: 2 Hz visibly pulses, and we stop at 11 Hz
    // because past ~10 the daemon coalesces commands and the light holds
    // steady WITHOUT dithering — "steady" for the wrong reason (SPEC §3-C).
    private static let floorFloor: Float = 0.005
    private static let floorCeil: Float = 0.30
    private static let freqFloor: Double = 2.0
    /// The ladder stops at the measured stability ceiling. Searching above it
    /// would let calibration "discover" a frequency that reads steady only
    /// because the daemon has stopped honouring the dither — which is exactly
    /// the failure this ceiling exists to prevent, and Simple mode adopts
    /// whatever this returns.
    private static let freqCeil: Double = DitherEngine.maxStableFrequencyHz
    static let rounds = 5
    /// Enough cycles to be sure, short enough not to be tedious (~6 s).
    private static let floorAlternations = 6

    @Published private(set) var step: Step = .intro
    @Published private(set) var round = 0
    @Published private(set) var isPlaying = false
    @Published var previewLevel: Double = 0.4

    @Published private(set) var measuredFloor: Float?
    @Published private(set) var measuredFrequency: Double?

    /// True when the found frequency sits at the top of the search range,
    /// where "steady" may mean coalesced rather than fused.
    var frequencyHitCeiling: Bool { (measuredFrequency ?? 0) >= Self.freqCeil - 0.25 }

    private let controller: BacklightController
    private let restoreFloor: Float
    private let restoreFrequency: Double

    private var floorLo = CalibrationController.floorFloor
    private var floorHi = CalibrationController.floorCeil
    private var freqLo = CalibrationController.freqFloor
    private var freqHi = CalibrationController.freqCeil

    private var playback: Task<Void, Never>?

    /// Set once the result has been adopted. cancel() must then NOT roll the
    /// controller back — the sheet's onDisappear fires after saving, and
    /// restoring here would silently undo the calibration.
    private var saved = false

    init(controller: BacklightController) {
        self.controller = controller
        self.restoreFloor = controller.floor
        self.restoreFrequency = controller.frequencyHz
    }

    // MARK: Current candidates

    var floorCandidate: Float { (floorLo + floorHi) / 2 }
    var freqCandidate: Double { ((freqLo + freqHi) / 2 * 2).rounded() / 2 }

    var progress: Double {
        switch step {
        case .intro:     return 0
        case .floor:     return Double(round) / Double(Self.rounds) / 3
        case .frequency: return (1 + Double(round) / Double(Self.rounds)) / 3
        case .level:     return 2.0 / 3
        case .summary:   return 1
        }
    }

    // MARK: Lifecycle

    func begin() {
        // Calibration disables auto-brightness with direct bridge writes that
        // bypass the engine, so arm the dirty flag: a hard crash mid-calibration
        // then heals on next launch. Every normal exit (cancel/finishLevel/
        // discardAndRestore) calls panicRestore, which clears the flag.
        controller.armCrashRecovery()
        controller.bridge.setAutoBrightness(false, controller.keyboardID)
        floorLo = Self.floorFloor
        floorHi = Self.floorCeil
        freqLo = Self.freqFloor
        freqHi = Self.freqCeil
        round = 0
        measuredFloor = nil
        measuredFrequency = nil
        step = .floor
        playFloorComparison()
    }

    /// Leave the backlight and the controller exactly as we found them.
    /// No-op once the result has been saved.
    func cancel() {
        playback?.cancel()
        playback = nil
        isPlaying = false
        guard !saved else { return }
        controller.floor = restoreFloor
        controller.frequencyHz = restoreFrequency
        controller.panicRestore(to: 0.4)
        step = .intro
        round = 0
    }

    // MARK: Step 1 — floor

    /// Alternate a known sub-floor reference with the candidate at ~1 Hz, and
    /// ask whether anything moves.
    ///
    /// WHY ALTERNATE rather than show each once: an earlier version played
    /// reference, then candidate, and asked "was the second brighter?". That
    /// requires holding a brightness in memory across a two-second gap, which
    /// people are bad at — it produced answers that contradicted each other
    /// across sessions and converged on a floor roughly twice the real one.
    /// Flicker detection is among the most sensitive things the visual system
    /// does, so turning "is it brighter?" into "does it flicker?" makes the
    /// same measurement dramatically easier and more repeatable.
    ///
    /// Both values are written directly, bypassing BacklightController.setLevel
    /// — routing through it would engage the dither and we'd be measuring the
    /// dither instead of the clamp.
    func playFloorComparison() {
        let candidate = floorCandidate
        let reference = Self.floorFloor
        playback?.cancel()
        isPlaying = true
        playback = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<Self.floorAlternations {
                guard !Task.isCancelled else { return }
                self.controller.bridge.setBrightness(reference, self.controller.keyboardID)
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self.controller.bridge.setBrightness(candidate, self.controller.keyboardID)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            self.isPlaying = false
        }
    }

    /// - Parameter flickered: true if the light visibly changed as it
    ///   alternated, meaning the candidate rendered differently from the
    ///   sub-floor reference and therefore cleared the clamp. False means both
    ///   values produced identical output, so the candidate is still clamped.
    func answerFloor(flickered: Bool) {
        if flickered { floorHi = floorCandidate } else { floorLo = floorCandidate }
        round += 1
        if round >= Self.rounds {
            // floorHi is the lowest value known to render at full floor
            // brightness — the safe choice for the dither's high value.
            measuredFloor = floorHi
            controller.floor = floorHi
            Log.calibration.info("floor measured: \(self.floorHi, privacy: .public)")
            round = 0
            step = .frequency
            playFrequency()
        } else {
            playFloorComparison()
        }
    }

    // MARK: Step 2 — frequency

    func playFrequency() {
        let f = freqCandidate
        let floor = measuredFloor ?? restoreFloor
        playback?.cancel()
        isPlaying = true
        controller.frequencyHz = f
        controller.setLevel(0.5 * floor)   // mid duty: fair test of steadiness
        playback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isPlaying = false
        }
    }

    /// - Parameter steady: true if the light looked continuous, false if the
    ///   person could see it pulsing.
    func answerFrequency(steady: Bool) {
        if steady { freqHi = freqCandidate } else { freqLo = freqCandidate }
        round += 1
        if round >= Self.rounds {
            measuredFrequency = (freqHi * 2).rounded() / 2
            Log.calibration.info("flicker-free at: \(self.measuredFrequency ?? 0, privacy: .public) Hz")
            round = 0
            step = .level
            applyPreview()
        } else {
            playFrequency()
        }
    }

    // MARK: Step 3 — level

    func applyPreview() {
        let floor = measuredFloor ?? restoreFloor
        let f = measuredFrequency ?? FrequencyPreset.high
        controller.frequencyHz = f
        controller.setLevel(Float(previewLevel) * floor)
    }

    func finishLevel() {
        step = .summary
        controller.panicRestore(to: 0.4)
    }

    // MARK: Result

    struct Result {
        let floor: Float
        let frequency: Double
        let brightness: Double
    }

    /// Call after the result has been persisted, so teardown leaves it alone.
    func markSaved() { saved = true }

    var result: Result? {
        guard let f = measuredFloor, let hz = measuredFrequency else { return nil }
        return Result(floor: f, frequency: hz, brightness: previewLevel)
    }

    func discardAndRestore() {
        controller.floor = restoreFloor
        controller.frequencyHz = restoreFrequency
        controller.panicRestore(to: 0.4)
    }
}
