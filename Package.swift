// swift-tools-version:6.0
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
// Sublight — sub-minimum keyboard backlight control for Apple Silicon MacBooks.
// Licensed under the Apache License 2.0 — see LICENSE. See LICENSE.
//
// Three targets, deliberately layered:
//   SublightKit   — the engine library (private-API bridge + dither engine). Zero dependencies.
//   sublight-cli  — command-line tool. Doubles as the validation/probe harness.
//   SublightApp   — thin SwiftUI MenuBarExtra veneer over the kit.
//
// Zero third-party dependencies is a deliberate policy: a utility that pokes
// private frameworks should be trivially auditable in one sitting.

import PackageDescription

let package = Package(
    name: "sublight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SublightKit", targets: ["SublightKit"]),
        .executable(name: "sublight-cli", targets: ["sublight-cli"]),
        .executable(name: "SublightApp", targets: ["SublightApp"]),
    ],
    targets: [
        .target(
            name: "SublightKit",
            path: "Sources/SublightKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "sublight-cli",
            dependencies: ["SublightKit"],
            path: "Sources/sublight-cli",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SublightApp",
            dependencies: ["SublightKit"],
            path: "Sources/SublightApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Covers only the pure, deterministic logic — the private-API surface
        // can't be unit tested, it has to be verified by eye on real hardware
        // (see docs/SPEC.md §9).
        .testTarget(
            name: "SublightKitTests",
            dependencies: ["SublightKit"],
            path: "Tests/SublightKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
