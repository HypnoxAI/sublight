// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  StatusGlyphTests.swift — the menu bar glyph's geometry contract. These
//  numbers are quoted in the README and in SPEC §8, and the legend image is
//  rendered from this same code, so pinning them here is what keeps all three
//  from drifting apart.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
import AppKit
@testable import SublightKit

final class StatusGlyphTests: XCTestCase {

    func testTheDeckHasTenKeys() {
        XCTAssertEqual(StatusGlyph.keyCount, 10)
    }

    /// The counts the README and the legend both quote: 0 / 3 / 5 / 8 of 10.
    func testFillCountsForEveryShippedState() {
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: 0.0), 0, "Off")
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: 0.3), 3, "Low")
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: 0.5), 5, "Medium")
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: 0.8), 8, "High")
    }

    /// The glyph is fed straight from DimmingPolicy, so go through it rather
    /// than re-stating the fractions — if a bucket moves, this fails.
    func testTheGlyphAgreesWithTheDimmingPolicyBuckets() {
        func lit(_ hz: Double) -> Int {
            StatusGlyph.litKeyCount(litFraction: CGFloat(
                DimmingPolicy.glyphFraction(userEnabled: true, systemSuspended: false, frequencyHz: hz)))
        }
        XCTAssertEqual(lit(FrequencyPreset.low), 3)
        XCTAssertEqual(lit(FrequencyPreset.medium), 5)
        XCTAssertEqual(lit(FrequencyPreset.high), 8)
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: CGFloat(
            DimmingPolicy.glyphFraction(userEnabled: false, systemSuspended: false,
                                        frequencyHz: FrequencyPreset.high))), 0,
                       "not dimming reads hollow")
    }

    func testFractionIsClampedRatherThanTrapping() {
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: -5), 0)
        XCTAssertEqual(StatusGlyph.litKeyCount(litFraction: 42), StatusGlyph.keyCount)
    }

    func testTheImageIsATemplateSoMacOSCanTintIt() {
        let image = StatusGlyph.image(litFraction: 0.5)
        XCTAssertTrue(image.isTemplate, "a non-template menu bar icon breaks in dark and high-contrast modes")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "the standard status item canvas")
        XCTAssertEqual(image.accessibilityDescription, "Sublight")
    }

    /// The MenuBarExtra label is re-evaluated on every AppState change, slider
    /// drags included, so equal states must hand back the SAME instance rather
    /// than a freshly built one.
    func testImagesAreMemoizedPerState() {
        XCTAssertTrue(StatusGlyph.image(litFraction: 0.8) === StatusGlyph.image(litFraction: 0.8))
        XCTAssertFalse(StatusGlyph.image(litFraction: 0.8) === StatusGlyph.image(litFraction: 0.3))
        // Clamping means out-of-range requests share the clamped instance.
        XCTAssertTrue(StatusGlyph.image(litFraction: 2.0) === StatusGlyph.image(litFraction: 1.0))
    }
}
