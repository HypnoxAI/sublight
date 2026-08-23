// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DimmingPolicyTests.swift — the userEnabled × systemSuspended matrix.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
@testable import SublightKit

final class DimmingPolicyTests: XCTestCase {

    func testEffectiveRunningMatrix() {
        XCTAssertFalse(DimmingPolicy.effectiveRunning(userEnabled: false, systemSuspended: false))
        XCTAssertFalse(DimmingPolicy.effectiveRunning(userEnabled: false, systemSuspended: true))
        XCTAssertTrue(DimmingPolicy.effectiveRunning(userEnabled: true, systemSuspended: false))
        XCTAssertFalse(DimmingPolicy.effectiveRunning(userEnabled: true, systemSuspended: true))
    }

    // MARK: Schedule transitions
    //
    // The rule being pinned: automation may never be the first thing that
    // commands the backlight. A window opening without consent must produce
    // NO enable — and therefore no mutating command — while still recording
    // that something was skipped, so it does not fail silently.

    func testScheduleTransitionMatrix() {
        XCTAssertEqual(DimmingPolicy.scheduleTransition(enteringWindow: true, consentGranted: true), .engage)
        XCTAssertEqual(DimmingPolicy.scheduleTransition(enteringWindow: true, consentGranted: false), .deferForConsent)
        XCTAssertEqual(DimmingPolicy.scheduleTransition(enteringWindow: false, consentGranted: true), .disengage)
        XCTAssertEqual(DimmingPolicy.scheduleTransition(enteringWindow: false, consentGranted: false), .disengage,
                       "leaving the window is a disengage regardless — there is nothing to consent to")
    }

    func testAnUnconsentedAutoEnableNeverEngages() {
        // The one case that must never be `.engage`, stated on its own so a
        // future edit to the matrix cannot quietly flip it.
        XCTAssertNotEqual(DimmingPolicy.scheduleTransition(enteringWindow: true, consentGranted: false), .engage)
    }

    /// The whole deferred-consent lifecycle, exercised over a real marker:
    /// an unconsented window entry sets pending and grants nothing; accepting
    /// from the popover then both grants and retires the pending question.
    func testDeferredConsentLifecycleAcrossAScheduleTransition() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-sched-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ConsentMarker(directory: dir)

        // Window opens, nobody has consented.
        let entering = DimmingPolicy.scheduleTransition(enteringWindow: true,
                                                        consentGranted: marker.isGranted)
        XCTAssertEqual(entering, .deferForConsent)
        if case .deferForConsent = entering { marker.setPending() }
        XCTAssertTrue(marker.isPending)
        XCTAssertFalse(marker.isGranted, "nothing may be commanded on this path")

        // The popover's "Review and enable", accepted, with the window still open.
        marker.record()
        XCTAssertFalse(marker.isPending)
        XCTAssertEqual(DimmingPolicy.scheduleTransition(enteringWindow: true,
                                                        consentGranted: marker.isGranted),
                       .engage, "the still-open window engages immediately rather than waiting")
    }

    func testGlyphIsHollowWheneverNotEffectivelyRunning() {
        for hz in [3.0, 6.0, 8.0] {
            XCTAssertEqual(DimmingPolicy.glyphFraction(userEnabled: false, systemSuspended: false, frequencyHz: hz), 0)
            XCTAssertEqual(DimmingPolicy.glyphFraction(userEnabled: false, systemSuspended: true, frequencyHz: hz), 0)
            XCTAssertEqual(DimmingPolicy.glyphFraction(userEnabled: true, systemSuspended: true, frequencyHz: hz), 0,
                           "suspended must read hollow even with the toggle on")
        }
    }

    /// Buckets are the PRESET MIDPOINTS: 4.5 between Low 3 and Medium 6,
    /// 7.0 between Medium 6 and High 8.
    func testGlyphBucketsFrequencyWhenRunning() {
        func g(_ hz: Double) -> Double {
            DimmingPolicy.glyphFraction(userEnabled: true, systemSuspended: false, frequencyHz: hz)
        }
        XCTAssertEqual(g(2), 0.3)
        XCTAssertEqual(g(FrequencyPreset.low), 0.3)
        XCTAssertEqual(g(4.49), 0.3, "just below the Low/Medium midpoint")
        XCTAssertEqual(g(4.5), 0.5, "the midpoint itself rounds up to Medium")
        XCTAssertEqual(g(FrequencyPreset.medium), 0.5)
        XCTAssertEqual(g(6.99), 0.5, "just below the Medium/High midpoint")
        XCTAssertEqual(g(7.0), 0.8, "the midpoint itself rounds up to High")
        XCTAssertEqual(g(FrequencyPreset.high), 0.8)
    }

    func testPresetsAreThreeSixAndTheCeiling() {
        XCTAssertEqual(FrequencyPreset.low, 3)
        XCTAssertEqual(FrequencyPreset.medium, 6)
        XCTAssertEqual(FrequencyPreset.high, 8)
        XCTAssertEqual(FrequencyPreset.high, DitherEngine.maxStableFrequencyHz,
                       "High is DEFINED as the measured ceiling, not a number chosen alongside it")
        XCTAssertEqual(FrequencyPreset.all.map(\.label), ["Low", "Medium", "High"])
        XCTAssertEqual(FrequencyPreset.all.map(\.hz), [3, 6, 8])
    }
}
