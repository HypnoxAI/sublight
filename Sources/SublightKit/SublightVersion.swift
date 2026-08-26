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
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public enum SublightVersion {
    /// Marketing version, e.g. "0.5.0". Also the git tag, prefixed with "v".
    public static let current = "0.5.0"
    /// Monotonic build number for CFBundleVersion.
    public static let build = "5"

    /// "0.5.0 (5)" — what `sublight-cli version` and the About pane show.
    public static var display: String { "\(current) (\(build))" }
}
