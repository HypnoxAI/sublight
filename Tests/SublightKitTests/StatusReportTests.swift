// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  StatusReportTests.swift — the machine-readable status schema.
//
//  `status --json` is a contract with whatever is parsing it. Human status
//  output can be reworded freely; this cannot. These tests pin the key set, so
//  a rename or a dropped field fails here rather than silently downstream.
//
//  Modified 2026-08-28: Build.gitRevision is part of the pinned key set.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest

@testable import SublightKit

final class StatusReportTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-status-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Everything populated, so the encoder exercises every field.
    private func fullReport() -> StatusReport {
        var counters = EngineCounters()
        counters.high.scheduled = 2251
        counters.high.executed = 2251
        counters.nominalPeriodMs = 133.33
        counters.latency.record(0.15)
        counters.commandsByKind["brightness"] = 4502
        let marker = ConsentMarker(directory: dir)
        marker.record()
        return StatusReport(
            sublight: .init(
                version: "0.4.0", build: "4", gitRevision: "abc123def456"),
            hardware: .init(model: "Mac16,12", chip: "Apple M4", appleSilicon: true),
            probe: .init(
                passed: true, macOSBuild: "Version 26.6.1 (Build 25G76)", failures: []),
            keyboard: .init(
                id: 95_158_272, reportedLevel: 0.1248, autoBrightness: false,
                idleDimmed: false, assumedFloor: 0.0625),
            engine: .init(
                state: .running(frequencyHz: 8.0, duty: 0.15), stabilityCeilingHz: 8.0),
            consent: .init(marker: marker),
            suspended: false,
            counters: counters,
            lastRecordedRun: DiagnosticsRecord(
                label: "hold 7.500 Hz duty 0.150 for 300 s", counters: counters,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000), pid: 4242))
    }

    /// Nothing known, so the encoder exercises every nullable field.
    private func emptyReport() -> StatusReport {
        StatusReport(
            sublight: .init(version: "0.4.0", build: "4"),
            hardware: .init(model: "Unknown", chip: "Unknown", appleSilicon: false),
            probe: .init(
                passed: false, macOSBuild: "?", failures: ["a: selector missing"]),
            keyboard: .init(
                id: 1, reportedLevel: nil, autoBrightness: nil, idleDimmed: nil,
                assumedFloor: 0.0625),
            engine: .init(state: .stopped, stabilityCeilingHz: 8.0),
            consent: .init(marker: ConsentMarker(directory: dir)),
            suspended: nil,
            counters: EngineCounters(),
            lastRecordedRun: nil)
    }

    private func object(_ report: StatusReport) throws -> [String: Any] {
        let data = Data(try report.json().utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Round trip

    func testFullReportSurvivesARoundTrip() throws {
        let original = fullReport()
        let decoded = try StatusReport.decoder()
            .decode(StatusReport.self, from: Data(try original.json().utf8))
        XCTAssertEqual(decoded, original)
    }

    func testEmptyReportSurvivesARoundTrip() throws {
        let original = emptyReport()
        let decoded = try StatusReport.decoder()
            .decode(StatusReport.self, from: Data(try original.json().utf8))
        XCTAssertEqual(decoded, original)
    }

    // MARK: The pinned schema

    func testSchemaVersionIsOne() throws {
        XCTAssertEqual(StatusReport.currentSchemaVersion, 1)
        XCTAssertEqual(try object(fullReport())["schemaVersion"] as? Int, 1)
        let emptySub = try XCTUnwrap(
            try object(emptyReport())["sublight"] as? [String: Any])
        XCTAssertEqual(
            emptySub["gitRevision"] as? String, "unknown",
            "an unstamped binary reports unknown, not a missing key")
    }

    func testTopLevelKeySetIsExactlyThis() throws {
        let expected: Set<String> = [
            "schemaVersion", "sublight", "hardware", "probe", "keyboard",
            "engine", "consent", "suspended", "counters", "lastRecordedRun",
        ]
        XCTAssertEqual(Set(try object(fullReport()).keys), expected)
        XCTAssertEqual(
            Set(try object(emptyReport()).keys), expected,
            "an empty report must carry the same keys, with nulls")
    }

    func testNestedKeySetsArePinned() throws {
        let o = try object(fullReport())
        func keys(_ name: String) -> Set<String> {
            Set((o[name] as? [String: Any] ?? [:]).keys)
        }
        XCTAssertEqual(keys("sublight"), ["version", "build", "gitRevision"])
        XCTAssertEqual(keys("hardware"), ["model", "chip", "appleSilicon"])
        XCTAssertEqual(keys("probe"), ["passed", "macOSBuild", "failures"])
        XCTAssertEqual(
            keys("keyboard"),
            ["id", "reportedLevel", "autoBrightness", "idleDimmed", "assumedFloor"])
        XCTAssertEqual(
            keys("engine"),
            ["mode", "running", "frequencyHz", "duty", "stabilityCeilingHz"])
        XCTAssertEqual(
            keys("consent"), ["granted", "recordedVersion", "requiredVersion", "pending"])
    }

    /// The thing the synthesised encoder gets wrong: a nil optional is dropped
    /// rather than written as null, so a consumer cannot tell "not measurable"
    /// from "field removed in a newer schema".
    func testUnknownValuesAreNullRatherThanMissing() throws {
        let o = try object(emptyReport())
        XCTAssertTrue(o["suspended"] is NSNull, "suspended must be null, not absent")
        XCTAssertTrue(o["lastRecordedRun"] is NSNull)
        let engine = try XCTUnwrap(o["engine"] as? [String: Any])
        XCTAssertTrue(
            engine["frequencyHz"] is NSNull, "a stopped engine has null frequency")
        XCTAssertTrue(engine["duty"] is NSNull)
        let keyboard = try XCTUnwrap(o["keyboard"] as? [String: Any])
        for k in ["reportedLevel", "autoBrightness", "idleDimmed"] {
            XCTAssertTrue(keyboard[k] is NSNull, "\(k) must be null, not absent")
        }
    }

    func testEngineModeReflectsTheState() throws {
        XCTAssertEqual(
            StatusReport.Engine(state: .stopped, stabilityCeilingHz: 8).mode, "stopped")
        let running = StatusReport.Engine(
            state: .running(frequencyHz: 8, duty: 0.15), stabilityCeilingHz: 8)
        XCTAssertEqual(running.mode, "dithering")
        XCTAssertEqual(running.frequencyHz, 8)
        XCTAssertEqual(running.duty, 0.15)
        XCTAssertTrue(running.running)
    }

    func testOutputIsStableAcrossEncodings() throws {
        let report = fullReport()
        XCTAssertEqual(try report.json(), try report.json(), "sorted keys, stable output")
    }
}
