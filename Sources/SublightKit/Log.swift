// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  Log.swift
//  SublightKit
//
//  Structured logging via os.Logger. Sublight drives an undocumented private
//  API on hardware that varies, so when something misbehaves on someone
//  else's Mac there needs to be a trail. These go to the unified log and can
//  be read back with:
//
//      log show --predicate 'subsystem == "com.hypnox.sublight"' --last 30m
//
//  or live, with the engine's info-level events (start/stop/restore/
//  dirty-flag/suspend/resume) and the per-edge signposts:
//
//      log stream --predicate 'subsystem == "com.hypnox.sublight"' --info
//      log show --signpost --predicate 'subsystem == "com.hypnox.sublight" AND category == "engine"' --last 2m
//
//  Nothing here is ever sent anywhere — the unified log is local to the
//  machine, and Sublight makes no network calls at all.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import os

public enum Log {
    /// The app's bundle identifier (CFBundleIdentifier in scripts/Info.plist).
    /// The CLI has no bundle, so the literal is the source of truth for both.
    public static let subsystem = "com.hypnox.sublight"

    /// Private-API bridge: framework loading, selector resolution.
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    /// Dither engine and level changes.
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    /// App lifecycle, restore paths, the crash-recovery watchdog.
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// Guided calibration.
    public static let calibration = Logger(subsystem: subsystem, category: "calibration")
    /// Launch-time private-API capability probe.
    public static let probe = Logger(subsystem: subsystem, category: "probe")
}
