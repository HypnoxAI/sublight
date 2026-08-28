// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DiagnosticsCopy.swift
//  SublightKit
//
//  THE paste-ready diagnostics block. Settings → Diagnostics → Copy and the
//  hardware-report issue form are the same text, produced here so a change in
//  one cannot drift from the other, and so the field labels are pinned by a
//  test against `.github/ISSUE_TEMPLATE/hardware_report.yml`.
//
//  Two audiences, one blob. The header is shaped for the Hardware report
//  template (model, macOS, floor, ceiling, works). The body is the existing
//  Diagnostics block plus the live engine identity that a marketing version
//  alone cannot carry: git revision, how long this engine has been up, the
//  skip counters, and the last skip (or explicit "none"). Coordinates stay
//  out — this text is written to be pasted into public issue trackers.
//
//  LIVE, not reconstructed. The snapshot is taken from the menu-bar process's
//  own DitherEngine at Copy time. `sublight-cli status` cannot do this: it
//  constructs a new controller, so its counters are empty by construction.
//  Capture of skip truth from outside the app remains `log stream`.
//
//  Modified 2026-08-28: added — live engine identity and hardware-report Copy.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

/// Inputs for one Diagnostics / hardware-report Copy. Pure data: the app
/// gathers from the live engine; tests fabricate.
public struct DiagnosticsSnapshot: Equatable, Sendable {

    public var version: String
    public var build: String
    /// Bundle-time git revision, or `"unknown"` when the binary was not stamped.
    public var gitRevision: String
    public var macOS: String
    public var modelIdentifier: String
    public var hardwareSummary: String
    public var appleSilicon: Bool
    public var measuredFloor: Float
    public var floorCalibrated: Bool
    public var stabilityCeilingHz: Double
    public var engineAvailable: Bool
    public var engineError: String
    public var keyboardID: UInt64?

    /// Seconds since this engine instance was created (process session).
    public var sessionElapsedSeconds: Double
    /// Seconds the current dither run has been going, or nil when stopped.
    public var ditherRunElapsedSeconds: Double?

    public var counters: EngineCounters

    public var advancedMode: Bool
    public var dimmingOn: Bool
    public var systemSuspended: Bool
    public var engineRunning: Bool
    public var effectiveFrequencyHz: Double
    public var brightness: Double
    public var calibratedFrequencyHz: Double?

    public var scheduleDescription: String
    public var locationDescription: String?
    public var solarLine: String?
    public var shortcut: String
    public var launchAtLogin: Bool

    public init(
        version: String, build: String, gitRevision: String, macOS: String,
        modelIdentifier: String, hardwareSummary: String, appleSilicon: Bool,
        measuredFloor: Float, floorCalibrated: Bool, stabilityCeilingHz: Double,
        engineAvailable: Bool, engineError: String, keyboardID: UInt64?,
        sessionElapsedSeconds: Double, ditherRunElapsedSeconds: Double?,
        counters: EngineCounters, advancedMode: Bool, dimmingOn: Bool,
        systemSuspended: Bool, engineRunning: Bool, effectiveFrequencyHz: Double,
        brightness: Double, calibratedFrequencyHz: Double?,
        scheduleDescription: String, locationDescription: String?,
        solarLine: String?, shortcut: String, launchAtLogin: Bool
    ) {
        self.version = version
        self.build = build
        self.gitRevision = gitRevision
        self.macOS = macOS
        self.modelIdentifier = modelIdentifier
        self.hardwareSummary = hardwareSummary
        self.appleSilicon = appleSilicon
        self.measuredFloor = measuredFloor
        self.floorCalibrated = floorCalibrated
        self.stabilityCeilingHz = stabilityCeilingHz
        self.engineAvailable = engineAvailable
        self.engineError = engineError
        self.keyboardID = keyboardID
        self.sessionElapsedSeconds = sessionElapsedSeconds
        self.ditherRunElapsedSeconds = ditherRunElapsedSeconds
        self.counters = counters
        self.advancedMode = advancedMode
        self.dimmingOn = dimmingOn
        self.systemSuspended = systemSuspended
        self.engineRunning = engineRunning
        self.effectiveFrequencyHz = effectiveFrequencyHz
        self.brightness = brightness
        self.calibratedFrequencyHz = calibratedFrequencyHz
        self.scheduleDescription = scheduleDescription
        self.locationDescription = locationDescription
        self.solarLine = solarLine
        self.shortcut = shortcut
        self.launchAtLogin = launchAtLogin
    }
}

public enum DiagnosticsCopy {

    /// Exact labels of `.github/ISSUE_TEMPLATE/hardware_report.yml`, so Copy
    /// is paste-ready for that form. Pinned by test.
    public static let modelLabel = "Model identifier"
    public static let macOSLabel = "macOS version"
    public static let floorLabel = "Measured floor"
    public static let ceilingLabel = "Stability ceiling"
    public static let worksLabel = "Does sub-floor dimming visibly work?"

    /// The template's dropdown options, listed so the reporter can pick one
    /// without opening GitHub first. Not pre-filled — "works" is a human
    /// observation and claiming it from software would be a lie.
    public static let worksPlaceholder =
        "(fill in: Yes — clearly dimmer than the system minimum / "
        + "Partially — dims, but with issues (describe below) / "
        + "No — no visible difference)"

    /// The full Copy blob: hardware-report header, then the Diagnostics body.
    public static func text(_ s: DiagnosticsSnapshot) -> String {
        (hardwareReportFields(s) + [""] + diagnosticsBody(s)).joined(separator: "\n")
    }

    /// Hardware-report fields only. The Notes textarea gets `diagnosticsBody`.
    public static func hardwareReportFields(_ s: DiagnosticsSnapshot) -> [String] {
        let floorNote =
            s.floorCalibrated ? " (calibrated)" : " (default — not calibrated)"
        return [
            "\(modelLabel): \(s.modelIdentifier)",
            "\(macOSLabel): \(s.macOS)",
            "\(floorLabel): \(String(format: "%.4f", s.measuredFloor))\(floorNote)",
            "\(ceilingLabel): \(String(format: "%.1f Hz", s.stabilityCeilingHz))",
            "\(worksLabel): \(worksPlaceholder)",
        ]
    }

    /// Existing Diagnostics block, plus git SHA / engine age / live counters /
    /// last skip. No coordinates, no emoji.
    public static func diagnosticsBody(_ s: DiagnosticsSnapshot) -> [String] {
        var lines: [String] = [
            "Sublight \(s.version) (\(s.build))",
            "Git revision: \(s.gitRevision)",
            "macOS \(s.macOS)",
            "Hardware: \(s.hardwareSummary)",
            "Apple Silicon: \(s.appleSilicon ? "yes" : "no")",
            "",
            "Engine: \(s.engineAvailable ? "available" : "UNAVAILABLE")",
            "Engine session: \(formatElapsed(s.sessionElapsedSeconds))",
            "Dither run: "
                + (s.ditherRunElapsedSeconds.map(formatElapsed) ?? "not running"),
        ]
        if !s.engineError.isEmpty {
            lines.append("Engine error: \(s.engineError)")
        }
        if let id = s.keyboardID {
            lines.append("Keyboard ID: \(id)")
        }
        lines.append(
            String(
                format: "Floor: %.4f%@", s.measuredFloor,
                s.floorCalibrated ? " (calibrated)" : " (default — not calibrated)"))
        lines.append(
            String(format: "Stability ceiling: %.1f Hz", s.stabilityCeilingHz))

        lines += [
            "",
            "Mode: \(s.advancedMode ? "advanced" : "simple")",
            "Dimming: \(s.dimmingOn ? "on" : "off")"
                + (s.systemSuspended ? " (suspended by system)" : ""),
            "Engine: \(s.engineRunning ? "running" : "stopped")",
            String(format: "Effective frequency: %.1f Hz", s.effectiveFrequencyHz),
            String(format: "Brightness: %.0f%%", s.brightness * 100),
            "Calibrated: "
                + (s.calibratedFrequencyHz.map { String(format: "yes, %.1f Hz", $0) }
                    ?? "no"),
            "",
            "Schedule: \(s.scheduleDescription)",
        ]
        if let loc = s.locationDescription {
            lines.append("Location: \(loc)")
        }
        if let solar = s.solarLine {
            lines.append(solar)
        }
        lines += [
            "Shortcut: \(s.shortcut)",
            "Launch at login: \(s.launchAtLogin ? "on" : "off")",
            "",
        ]
        lines += liveCounters(s.counters)
        return lines
    }

    /// Live skip counters and last-skip record from the process's own engine.
    public static func liveCounters(_ c: EngineCounters) -> [String] {
        [
            "HIGH skipped: \(c.high.skipped)",
            "LOW skipped: \(c.low.skipped)",
            "skipMaxRunLength: \(c.skipMaxRunLength)",
            "consecutive err-dark run: \(c.skipCurrentRunLength)",
            "HIGH scheduled/fired/executed: \(c.high.scheduled)/"
                + "\(c.high.fired)/\(c.high.executed)",
            "LOW scheduled/fired/executed: \(c.low.scheduled)/"
                + "\(c.low.fired)/\(c.low.executed)",
            "Last skip: \(formatLastSkip(c))",
        ]
    }

    /// "when, which edge, late ms, threshold" — or explicit "none".
    public static func formatLastSkip(_ c: EngineCounters) -> String {
        guard let skip = c.lastSkip else { return "none" }
        return String(
            format: "t+%.1f s  HIGH  late %.2f ms  threshold %.2f ms",
            skip.elapsedRunSeconds, skip.highLatenessMs, c.skipLastThresholdMs)
    }

    /// Compact elapsed time. Seconds below a minute so a short soak still
    /// reads; hours for the 8-hour-old-binary case that made this necessary.
    public static func formatElapsed(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0.0 s" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        return String(format: "%dm %02ds", m, s)
    }
}
