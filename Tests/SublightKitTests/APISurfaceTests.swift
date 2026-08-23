// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  APISurfaceTests.swift — ValidationReport decision logic against mock
//  encodings. The live probe is exercised by hand on real hardware.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
@testable import SublightKit

final class APISurfaceTests: XCTestCase {

    private let build = "Version 26.6.1 (Build 25G76)"

    private var good: [String: String?] {
        Dictionary(uniqueKeysWithValues: APISurface.expectedEncodings.map { ($0.selector, Optional($0.encoding)) })
    }

    func testAllMatchingEncodingsPass() {
        let r = APISurface.evaluate(frameworkLoaded: true, classPresent: true, encodings: good, macOSBuild: build)
        XCTAssertTrue(r.passed)
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertEqual(r.macOSBuild, build)
        XCTAssertTrue(r.text.contains("PASS"))
        XCTAssertTrue(r.text.contains(build))
    }

    func testFadeSpeedEncodedAsDoubleFails() {
        var enc = good
        enc["setBrightness:fadeSpeed:commit:forKeyboard:"] = "B40@0:8f16d20B28Q32"
        let r = APISurface.evaluate(frameworkLoaded: true, classPresent: true, encodings: enc, macOSBuild: build)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(r.failures[0].selector, "setBrightness:fadeSpeed:commit:forKeyboard:")
        XCTAssertEqual(r.failures[0].kind, .encodingMismatch(expected: "B36@0:8f16i20B24Q28", actual: "B40@0:8f16d20B28Q32"))
        XCTAssertTrue(r.text.contains("FAIL"))
        XCTAssertTrue(r.text.contains("type encoding changed"))
    }

    func testMissingSelectorFails() {
        var enc = good
        enc["backlightLevelForKeyboard:"] = .some(nil)
        let r = APISurface.evaluate(frameworkLoaded: true, classPresent: true, encodings: enc, macOSBuild: build)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.failures, [.init(selector: "backlightLevelForKeyboard:", kind: .selectorMissing)])
    }

    func testAbsentSelectorKeyIsAlsoMissing() {
        var enc = good
        enc.removeValue(forKey: "suspendIdleDimming:forKeyboard:")
        let r = APISurface.evaluate(frameworkLoaded: true, classPresent: true, encodings: enc, macOSBuild: build)
        XCTAssertEqual(r.failures.map(\.selector), ["suspendIdleDimming:forKeyboard:"])
    }

    func testEveryMismatchIsReportedIndividually() {
        var enc = good
        enc["brightnessForKeyboard:"] = "d24@0:8Q16"
        enc["enableAutoBrightness:forKeyboard:"] = .some(nil)
        let r = APISurface.evaluate(frameworkLoaded: true, classPresent: true, encodings: enc, macOSBuild: build)
        XCTAssertEqual(r.failures.count, 2)
        XCTAssertEqual(Set(r.failures.map(\.selector)), ["brightnessForKeyboard:", "enableAutoBrightness:forKeyboard:"])
    }

    func testClassMissingFailsWithoutJudgingSelectors() {
        let r = APISurface.evaluate(frameworkLoaded: true, classPresent: false, encodings: [:], macOSBuild: build)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.failures.map(\.kind), [.classMissing])
    }

    func testFrameworkNotLoadableFails() {
        let r = APISurface.evaluate(frameworkLoaded: false, classPresent: false, encodings: [:], macOSBuild: build)
        XCTAssertEqual(r.failures.map(\.kind), [.frameworkNotLoadable])
    }

    func testExpectedTableMatchesTheArm64Finding() {
        let fade = APISurface.expectedEncodings.first { $0.selector == "setBrightness:fadeSpeed:commit:forKeyboard:" }
        XCTAssertEqual(fade?.encoding, "B36@0:8f16i20B24Q28", "fadeSpeed is a 32-bit int (i), not a float")
    }
}
