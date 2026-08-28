// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SublightVersion.swift
//  SublightKit
//
//  THE single source of truth for the version, for both products.
//
//  The app bundle's Info.plist used to carry its own copy, which is exactly the
//  arrangement where one of two numbers gets bumped and nobody notices until a
//  user reports the wrong version in a bug. `make_app.sh` now stamps the built
//  bundle from the constants below, so the committed plist values are only a
//  fallback and the number that ships is this one.
//
//  Git identity is NOT a constant here. A SHA in source is how two binaries
//  built from different commits report the same thing. `make_app.sh` injects
//  `git rev-parse HEAD` into Info.plist key `SublightGitRevision` at bundle
//  time; `gitRevision` reads that. Unstamped builds (plain `swift build`,
//  tests) report "unknown" rather than a plausible-looking fake.
//
//  Modified 2026-08-28: build 6; bundle-time git revision; identity display.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public enum SublightVersion {
    /// Marketing version, e.g. "0.5.0". Also the git tag, prefixed with "v".
    public static let current = "0.5.0"
    /// Monotonic build number for CFBundleVersion.
    ///
    /// Bumped independently of the marketing version so a rebuilt app is
    /// distinguishable from the previous binary without reading a git SHA —
    /// Diagnostics used to show only `0.5.0 (5)`, which is how an 8.5-hour-old
    /// process and a HEAD rebuild were indistinguishable.
    public static let build = "6"

    /// Info.plist key stamped by `scripts/make_app.sh` from `git rev-parse HEAD`.
    public static let gitRevisionKey = "SublightGitRevision"

    /// "0.5.0 (6)" — what `sublight-cli version` and the About pane show.
    public static var display: String { "\(current) (\(build))" }

    /// Bundle-time git revision, or `"unknown"` if this binary was not stamped.
    ///
    /// Reads the running bundle so the menu-bar app reports the SHA it was
    /// built from, not whatever `git rev-parse` would say in some other tree.
    public static var gitRevision: String {
        gitRevision(from: Bundle.main)
    }

    public static func gitRevision(from bundle: Bundle) -> String {
        guard
            let raw = bundle.object(forInfoDictionaryKey: gitRevisionKey) as? String
        else { return "unknown" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
