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

    func testGlyphIsHollowWheneverNotEffectivelyRunning() {
        for hz in [3.0, 6.0, 9.0] {
            XCTAssertEqual(DimmingPolicy.glyphFraction(userEnabled: false, systemSuspended: false, frequencyHz: hz), 0)
            XCTAssertEqual(DimmingPolicy.glyphFraction(userEnabled: false, systemSuspended: true, frequencyHz: hz), 0)
            XCTAssertEqual(DimmingPolicy.glyphFraction(userEnabled: true, systemSuspended: true, frequencyHz: hz), 0,
                           "suspended must read hollow even with the toggle on")
        }
    }

    func testGlyphBucketsFrequencyWhenRunning() {
        func g(_ hz: Double) -> Double {
            DimmingPolicy.glyphFraction(userEnabled: true, systemSuspended: false, frequencyHz: hz)
        }
        XCTAssertEqual(g(2), 0.3)
        XCTAssertEqual(g(3), 0.3)
        XCTAssertEqual(g(4.5), 0.5)
        XCTAssertEqual(g(6), 0.5)
        XCTAssertEqual(g(7.0), 0.5)
        XCTAssertEqual(g(7.5), 0.8)
        XCTAssertEqual(g(9), 0.8)
        XCTAssertEqual(g(12), 0.8)
    }
}
