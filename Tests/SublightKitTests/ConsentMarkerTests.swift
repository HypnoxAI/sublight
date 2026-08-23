// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  ConsentMarkerTests.swift — the gate in front of every backlight command.
//  An unreadable marker must never read as consent, and a decline must be
//  indistinguishable from never having asked.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import XCTest
@testable import SublightKit

final class ConsentMarkerTests: XCTestCase {

    private var dir: URL!
    private var marker: ConsentMarker!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-consent-\(UUID().uuidString)")
        marker = ConsentMarker(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ text: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: marker.fileURL)
    }

    func testAFreshInstallHasNotConsented() {
        XCTAssertNil(marker.recordedVersion)
        XCTAssertFalse(marker.isGranted)
    }

    func testRecordingGrantsAndPersists() {
        XCTAssertTrue(marker.record())
        XCTAssertEqual(marker.recordedVersion, ConsentMarker.currentVersion)
        XCTAssertTrue(marker.isGranted)
        // A separate instance over the same directory sees it — this is what
        // lets the CLI read what the app recorded.
        XCTAssertTrue(ConsentMarker(directory: dir).isGranted)
    }

    func testRecordCreatesTheDirectory() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(marker.record())
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.fileURL.path))
    }

    func testAnOlderConsentVersionDoesNotCount() {
        marker.record(version: ConsentMarker.currentVersion - 1)
        XCTAssertEqual(marker.recordedVersion, ConsentMarker.currentVersion - 1)
        XCTAssertFalse(marker.isGranted, "bumping the copy must re-prompt everyone")
    }

    func testANewerConsentVersionStillCounts() {
        marker.record(version: ConsentMarker.currentVersion + 5)
        XCTAssertTrue(marker.isGranted, "a downgrade must not re-ask someone who agreed to more")
    }

    func testAnUnreadableMarkerReadsAsNotConsented() {
        write("{ this is not json")
        XCTAssertNil(marker.recordedVersion)
        XCTAssertFalse(marker.isGranted, "a corrupt marker must fail toward asking, never toward granted")
    }

    func testAnEmptyMarkerReadsAsNotConsented() {
        write("")
        XCTAssertFalse(marker.isGranted)
    }

    func testABareIntegerMarkerIsStillUnderstood() {
        write("\(ConsentMarker.currentVersion)\n")
        XCTAssertEqual(marker.recordedVersion, ConsentMarker.currentVersion)
        XCTAssertTrue(marker.isGranted)
    }

    func testClearRevokesAndIsSafeToRepeat() {
        marker.record()
        XCTAssertTrue(marker.isGranted)
        marker.clear()
        XCTAssertFalse(marker.isGranted)
        marker.clear()   // must not throw or trap on an already-absent file
        XCTAssertFalse(marker.isGranted)
    }

    func testTheCurrentVersionIsOne() {
        XCTAssertEqual(ConsentMarker.currentVersion, 1,
                       "bump this deliberately, together with the alert copy")
    }
}
