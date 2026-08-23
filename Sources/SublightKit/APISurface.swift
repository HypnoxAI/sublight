// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  APISurface.swift
//  SublightKit
//
//  Launch-time capability probe. Sublight drives a private framework through
//  guessed Swift signatures; if Apple changes an argument type the call does
//  not fail, it silently misaligns registers (the arm64 finding: fadeSpeed is
//  a 32-bit int in an x-register — declaring it as a float would shift every
//  later argument). So before the engine is allowed to run, every selector it
//  depends on is checked against the exact Objective-C type encoding observed
//  on the build Sublight was verified on. Any drift fails the probe and the
//  caller disables itself. The decision logic is a pure function over
//  encodings so it is unit-tested against mocks; `validateAPISurface()` feeds
//  it the live runtime.
//
//  This file and KeyboardBrightnessBridge.swift are the only places the
//  class name and selector strings appear.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import ObjectiveC
import Darwin

public struct ValidationReport: Equatable {

    public struct Failure: Equatable, CustomStringConvertible {
        public enum Kind: Equatable {
            case frameworkNotLoadable
            case classMissing
            case selectorMissing
            case encodingMismatch(expected: String, actual: String)
        }
        public let selector: String
        public let kind: Kind

        public var description: String {
            switch kind {
            case .frameworkNotLoadable:
                return "CoreBrightness.framework could not be loaded"
            case .classMissing:
                return "class \(APISurface.className) not found"
            case .selectorMissing:
                return "\(selector): selector missing"
            case .encodingMismatch(let expected, let actual):
                return "\(selector): type encoding changed — expected \(expected), found \(actual)"
            }
        }
    }

    public let passed: Bool
    public let failures: [Failure]
    /// e.g. "Version 26.6.1 (Build 25G76)"
    public let macOSBuild: String
    /// Every encoding observed for the introspection list (nil = absent), so
    /// `sublight-cli sig` can print what it always printed.
    public let observed: [String: String?]

    /// Human-readable report — what the user pastes into an issue.
    public var text: String {
        var lines = ["Sublight API surface probe: \(passed ? "PASS" : "FAIL")",
                     "macOS: \(macOSBuild)",
                     "Class: \(APISurface.className)"]
        if failures.isEmpty {
            lines.append("All \(APISurface.expectedEncodings.count) required selectors present with verified type encodings.")
        } else {
            lines.append("Failures (\(failures.count)):")
            lines += failures.map { "  - \($0.description)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum APISurface {

    public static let className = "KeyboardBrightnessClient"
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    /// Required selectors and their type encodings, captured on macOS 26.6.1
    /// (Build 25G76). Layout: <return><self:@><cmd::><args…> with stack
    /// offsets. `i` at offset 20 in the fade setter is the 32-bit fadeSpeed.
    public static let expectedEncodings: [(selector: String, encoding: String)] = [
        ("setBrightness:fadeSpeed:commit:forKeyboard:", "B36@0:8f16i20B24Q28"),
        ("setBrightness:forKeyboard:",                  "B28@0:8f16Q20"),
        ("brightnessForKeyboard:",                      "f24@0:8Q16"),
        ("backlightLevelForKeyboard:",                  "f24@0:8Q16"),
        ("enableAutoBrightness:forKeyboard:",           "B28@0:8B16Q20"),
        ("suspendIdleDimming:forKeyboard:",             "B28@0:8B16Q20"),
    ]

    /// Everything `sublight-cli sig` prints: the required set plus the
    /// discovered read-only selectors that are informative but not gating.
    public static let introspectionSelectors: [String] =
        expectedEncodings.map(\.selector) + [
            "isIdleDimmingSuspendedOnKeyboard:",
            "isAmbientFeatureAvailableOnKeyboard:",
        ]

    /// The change-notification selector probed by `sublight-cli notify-probe`.
    public static let notificationSelector = "registerNotificationForKeys:keyboardID:block:"

    // MARK: Decision logic (pure)

    /// - Parameters:
    ///   - frameworkLoaded: dlopen succeeded.
    ///   - classPresent: the class was found (ignored if the framework failed).
    ///   - encodings: selector → observed encoding; nil or absent = selector
    ///     missing. Only the `expected` selectors are judged.
    public static func evaluate(
        frameworkLoaded: Bool,
        classPresent: Bool,
        encodings: [String: String?],
        expected: [(selector: String, encoding: String)] = expectedEncodings,
        macOSBuild: String
    ) -> ValidationReport {
        var failures: [ValidationReport.Failure] = []
        if !frameworkLoaded {
            failures.append(.init(selector: "", kind: .frameworkNotLoadable))
        } else if !classPresent {
            failures.append(.init(selector: "", kind: .classMissing))
        } else {
            for (selector, want) in expected {
                guard let got = encodings[selector] ?? nil else {
                    failures.append(.init(selector: selector, kind: .selectorMissing))
                    continue
                }
                if got != want {
                    failures.append(.init(selector: selector,
                                          kind: .encodingMismatch(expected: want, actual: got)))
                }
            }
        }
        return ValidationReport(passed: failures.isEmpty, failures: failures,
                                macOSBuild: macOSBuild, observed: encodings)
    }

    // MARK: Live probe

    /// Introspect the real class on this machine. Read-only: loads the
    /// framework and reads method type encodings; never instantiates the
    /// client or commands the backlight.
    public static func validate() -> ValidationReport {
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            return evaluate(frameworkLoaded: false, classPresent: false, encodings: [:], macOSBuild: build)
        }
        guard let cls = NSClassFromString(className) else {
            return evaluate(frameworkLoaded: true, classPresent: false, encodings: [:], macOSBuild: build)
        }
        var observed: [String: String?] = [:]
        for selector in introspectionSelectors {
            let sel = NSSelectorFromString(selector)
            if let m = class_getInstanceMethod(cls, sel) {
                observed[selector] = method_getTypeEncoding(m).map { String(cString: $0) }
            } else {
                observed[selector] = .some(nil)
            }
        }
        let report = evaluate(frameworkLoaded: true, classPresent: true, encodings: observed, macOSBuild: build)
        if report.passed {
            Log.probe.info("API surface verified on \(build, privacy: .public)")
        } else {
            Log.probe.error("API surface FAILED on \(build, privacy: .public): \(report.failures.map(\.description).joined(separator: "; "), privacy: .public)")
        }
        return report
    }
}

/// Module-level entry point: `SublightKit.validateAPISurface()`.
public func validateAPISurface() -> ValidationReport {
    APISurface.validate()
}
