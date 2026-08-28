// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  StatusReport.swift
//  SublightKit
//
//  The machine-readable form of `sublight-cli status`, and a deliberately
//  STABLE one.
//
//  Human status output is free to be reworded whenever it reads better. This
//  is not: something is parsing it. So the shape lives in one place, as a
//  Codable type rather than hand-assembled JSON, its key set is pinned by a
//  test, and it carries its own `schemaVersion` so a consumer can tell what it
//  is looking at instead of guessing from the fields present.
//
//  Absent values are `null`, never a plausible-looking default. A CLI process
//  genuinely cannot know whether the machine is suspended — it has no
//  sleep/wake observer, the app does — so `suspended` is null there rather
//  than a confident `false`. This is the same discipline as the read-back
//  finding: reporting a number you did not measure is worse than reporting
//  nothing.
//
//  Modified 2026-08-28: Build.gitRevision (bundle-time SHA, or "unknown").
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct StatusReport: Codable, Equatable, Sendable {

    /// Bump when a field is REMOVED or changes meaning. Adding an optional
    /// field is backwards compatible and does not need a bump.
    public static let currentSchemaVersion = 1

    public struct Build: Codable, Equatable, Sendable {
        public var version: String
        public var build: String
        /// Bundle-time git revision, or `"unknown"` when the binary was not
        /// stamped. Optional addition: does not bump `schemaVersion`.
        public var gitRevision: String
        public init(version: String, build: String, gitRevision: String = "unknown") {
            self.version = version
            self.build = build
            self.gitRevision = gitRevision
        }
    }

    public struct Hardware: Codable, Equatable, Sendable {
        public var model: String
        public var chip: String
        public var appleSilicon: Bool
        public init(model: String, chip: String, appleSilicon: Bool) {
            self.model = model
            self.chip = chip
            self.appleSilicon = appleSilicon
        }
    }

    public struct Probe: Codable, Equatable, Sendable {
        /// False means the app disables itself and the CLI refuses to drive
        /// the backlight — see APISurface.
        public var passed: Bool
        public var macOSBuild: String
        public var failures: [String]
        public init(passed: Bool, macOSBuild: String, failures: [String]) {
            self.passed = passed
            self.macOSBuild = macOSBuild
            self.failures = failures
        }
    }

    public struct Keyboard: Codable, Equatable, Sendable {
        public var id: UInt64
        /// What the daemon reports. NOT what the LED is doing — see
        /// docs/COREBRIGHTNESS.md finding 3.
        public var reportedLevel: Double?
        public var autoBrightness: Bool?
        public var idleDimmed: Bool?
        public var assumedFloor: Double
        public init(
            id: UInt64, reportedLevel: Double?, autoBrightness: Bool?,
            idleDimmed: Bool?, assumedFloor: Double
        ) {
            self.id = id
            self.reportedLevel = reportedLevel
            self.autoBrightness = autoBrightness
            self.idleDimmed = idleDimmed
            self.assumedFloor = assumedFloor
        }

        enum CodingKeys: String, CodingKey {
            case id, reportedLevel, autoBrightness, idleDimmed, assumedFloor
        }

        /// Explicit, because the synthesised encoder uses `encodeIfPresent` and
        /// would drop these keys entirely when nil. A consumer must be able to
        /// tell "not measurable" from "field gone in a newer schema".
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(reportedLevel, forKey: .reportedLevel)
            try c.encode(autoBrightness, forKey: .autoBrightness)
            try c.encode(idleDimmed, forKey: .idleDimmed)
            try c.encode(assumedFloor, forKey: .assumedFloor)
        }
    }

    public struct Engine: Codable, Equatable, Sendable {
        /// "stopped" or "dithering".
        public var mode: String
        public var running: Bool
        /// Null when stopped.
        public var frequencyHz: Double?
        public var duty: Double?
        public var stabilityCeilingHz: Double
        public init(state: EngineState, stabilityCeilingHz: Double) {
            switch state {
            case .stopped:
                mode = "stopped"
                running = false
                frequencyHz = nil
                duty = nil
            case .running(let hz, let duty):
                mode = "dithering"
                running = true
                frequencyHz = hz
                self.duty = duty
            }
            self.stabilityCeilingHz = stabilityCeilingHz
        }

        enum CodingKeys: String, CodingKey {
            case mode, running, frequencyHz, duty, stabilityCeilingHz
        }

        /// See Keyboard.encode(to:) — frequency and duty are null when stopped,
        /// not absent.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mode, forKey: .mode)
            try c.encode(running, forKey: .running)
            try c.encode(frequencyHz, forKey: .frequencyHz)
            try c.encode(duty, forKey: .duty)
            try c.encode(stabilityCeilingHz, forKey: .stabilityCeilingHz)
        }
    }

    public struct Consent: Codable, Equatable, Sendable {
        public var granted: Bool
        public var recordedVersion: Int?
        public var requiredVersion: Int
        /// A scheduled dim was skipped for lack of consent, and the popover
        /// has not yet reported it.
        public var pending: Bool
        public init(marker: ConsentMarker) {
            granted = marker.isGranted
            recordedVersion = marker.recordedVersion
            requiredVersion = ConsentMarker.currentVersion
            pending = marker.isPending
        }

        enum CodingKeys: String, CodingKey {
            case granted, recordedVersion, requiredVersion, pending
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(granted, forKey: .granted)
            try c.encode(recordedVersion, forKey: .recordedVersion)
            try c.encode(requiredVersion, forKey: .requiredVersion)
            try c.encode(pending, forKey: .pending)
        }
    }

    public var schemaVersion: Int
    public var sublight: Build
    public var hardware: Hardware
    public var probe: Probe
    public var keyboard: Keyboard
    public var engine: Engine
    public var consent: Consent
    /// Null from the CLI, which has no sleep/wake observer. Only a process
    /// that observes those transitions can answer this honestly.
    public var suspended: Bool?
    public var counters: EngineCounters
    public var lastRecordedRun: DiagnosticsRecord?

    public init(
        sublight: Build, hardware: Hardware, probe: Probe, keyboard: Keyboard,
        engine: Engine, consent: Consent, suspended: Bool?, counters: EngineCounters,
        lastRecordedRun: DiagnosticsRecord?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sublight = sublight
        self.hardware = hardware
        self.probe = probe
        self.keyboard = keyboard
        self.engine = engine
        self.consent = consent
        self.suspended = suspended
        self.counters = counters
        self.lastRecordedRun = lastRecordedRun
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sublight, hardware, probe, keyboard, engine, consent
        case suspended, counters, lastRecordedRun
    }

    /// See Keyboard.encode(to:). `suspended` and `lastRecordedRun` are null when
    /// unknown or absent, never missing.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sublight, forKey: .sublight)
        try c.encode(hardware, forKey: .hardware)
        try c.encode(probe, forKey: .probe)
        try c.encode(keyboard, forKey: .keyboard)
        try c.encode(engine, forKey: .engine)
        try c.encode(consent, forKey: .consent)
        try c.encode(suspended, forKey: .suspended)
        try c.encode(counters, forKey: .counters)
        try c.encode(lastRecordedRun, forKey: .lastRecordedRun)
    }

    /// Stable rendering: sorted keys so a diff of two reports is meaningful,
    /// ISO-8601 dates so they are unambiguous across locales.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// The decoder that matches `json()`.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
