// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  HardwareInfo.swift
//  SublightKit
//
//  Detects the host Mac so Sublight can (a) gate to Apple Silicon, (b) key
//  calibration data per model, and (c) show what it's running on. Everything
//  here is read from sysctl — no private APIs, no entitlements.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct HardwareInfo: Sendable, Equatable {

    /// e.g. "Mac16,3" — stable per model, used as the calibration key.
    public let modelIdentifier: String
    /// e.g. "Apple M4".
    public let chip: String
    /// True on arm64 Macs. Intel and unknown report false.
    public let isAppleSilicon: Bool

    public static let current = HardwareInfo()

    public init() {
        modelIdentifier = HardwareInfo.string("hw.model") ?? "Unknown"
        chip = HardwareInfo.string("machdep.cpu.brand_string") ?? "Unknown"
        isAppleSilicon = (HardwareInfo.int("hw.optional.arm64") ?? 0) == 1
    }

    /// One-line summary for display, e.g. "Mac16,3 · Apple M4".
    public var summary: String {
        chip == "Unknown" ? modelIdentifier : "\(modelIdentifier) · \(chip)"
    }

    // MARK: sysctl helpers

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }

    private static func int(_ name: String) -> Int? {
        var value = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
