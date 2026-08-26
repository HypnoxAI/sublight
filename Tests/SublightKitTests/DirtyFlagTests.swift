// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DirtyFlagTests.swift — crash-marker lifecycle and legacy-key migration.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Darwin
import XCTest

@testable import SublightKit

private func currentBootSeconds() -> Int64 {
    var tv = timeval(); var size = MemoryLayout<timeval>.stride
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return Int64(tv.tv_sec)
}

final class DirtyFlagTests: XCTestCase {

    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var flag: DirtyFlag!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sublight-flag-\(UUID().uuidString)")
        suiteName = "sublight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        flag = DirtyFlag(directory: dir, defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        // removePersistentDomain empties the keys, but cfprefsd leaves an empty
        // plist behind — delete the file too so nothing accumulates in
        // ~/Library/Preferences across runs.
        defaults.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName!).plist")
        try? FileManager.default.removeItem(at: plist)
        super.tearDown()
    }

    func testFlagHeldByThisProcessIsStillRecoverable() {
        // set() stamps our own PID; recovery from a fresh launch treats the
        // file as a crash remnant of a prior run (our PID == the recovering
        // process here, which is the same-process launch case → recover).
        flag.set()
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromFile)
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(flag.isSet)
    }

    /// Spawn a long-lived helper by copying /bin/sleep to `name` (so its
    /// executable path contains — or not — "sublight"), and return its PID.
    /// The caller must terminate it.
    private func spawnHelper(named name: String) -> Process {
        let exe = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: exe)
        // A copied system binary has an invalid signature on arm64 and would be
        // killed on exec; ad-hoc re-sign so the helper actually runs.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", exe.path]
        try? sign.run(); sign.waitUntilExit()
        let p = Process()
        p.executableURL = exe
        p.arguments = ["60"]
        try? p.run()
        return p
    }

    private func writeStamp(pid: pid_t, boot: Int64) {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? Data("\(boot):\(pid)\n".utf8).write(
            to: dir.appendingPathComponent("engine.dirty"))
    }

    func testFlagHeldByALiveSublightProcessIsNotTreatedAsDirty() throws {
        // A live process THIS boot whose executable path contains "sublight" is
        // a genuine concurrent owner — recovery must leave it and its flag be.
        let helper = spawnHelper(named: "sublight-holder")
        defer { helper.terminate() }
        usleep(200_000)
        // If the ad-hoc-signed helper could not launch on this host, the
        // premise (a live Sublight-named process) does not hold — skip rather
        // than fail. The logic is still covered by the reused-PID test.
        let pid = helper.processIdentifier
        try XCTSkipUnless(pid > 0 && kill(pid, 0) == 0, "helper process did not start")
        writeStamp(pid: pid, boot: currentBootSeconds())
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .clean,
            "a flag a live Sublight process owns must not be treated as a crash")
        XCTAssertEqual(restored, 0)
        XCTAssertTrue(flag.isSet, "the live owner's flag is left in place")
    }

    func testFlagWhosePIDWasReusedByANonSublightProcessIsRecovered() {
        // Live PID this boot, but the executable (/bin/sleep) is not Sublight —
        // a reused PID, so treat the flag as a crash remnant and recover.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try? p.run()
        defer { p.terminate() }
        usleep(150_000)
        writeStamp(pid: p.processIdentifier, boot: currentBootSeconds())
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromFile,
            "a reused PID owned by an unrelated process is not a live owner")
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(flag.isSet)
    }

    func testFlagFromAPriorBootIsAlwaysRecovered() {
        // Same PID as a live process (1), but stamped with an OLD boot time:
        // a reboot means it is unquestionably a crash remnant.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? Data("\(currentBootSeconds() - 100_000):1\n".utf8).write(
            to: dir.appendingPathComponent("engine.dirty"))
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromFile,
            "a prior-boot flag heals regardless of what its PID means now")
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(flag.isSet)
    }

    func testReusedPIDByNonSublightProcessIsRecovered() {
        // Current boot, a live PID (1) — but the reused-PID guard only counts a
        // live *Sublight* process as an owner. PID 1's path is unreadable so it
        // is treated conservatively as an owner (covered above); to exercise the
        // reused-PID recovery deterministically we use a definitely-dead PID.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? Data("\(currentBootSeconds()):999999\n".utf8).write(
            to: dir.appendingPathComponent("engine.dirty"))
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromFile)
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(flag.isSet)
    }

    func testLegacyPidOnlyFlagIsRecovered() {
        // Old pid-only format (no boot stamp) is treated as a crash remnant.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? Data("999999\n".utf8).write(to: dir.appendingPathComponent("engine.dirty"))
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromFile)
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(flag.isSet)
    }

    func testLegacyKeyRestoreFailureConvertsToFileFlagForRetry() {
        defaults.set(true, forKey: DirtyFlag.legacyDefaultsKey)
        XCTAssertEqual(flag.recoverIfNeeded { false }, .restoreFailed)
        XCTAssertNil(
            defaults.object(forKey: DirtyFlag.legacyDefaultsKey),
            "legacy key migrated away")
        XCTAssertTrue(flag.isSet, "converted to a file flag so the next launch retries")
    }

    func testSetAndClear() {
        XCTAssertFalse(flag.isSet)
        flag.set()
        XCTAssertTrue(flag.isSet)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("engine.dirty").path))
        flag.clear()
        XCTAssertFalse(flag.isSet)
        flag.clear()  // idempotent
    }

    func testCleanLaunchDoesNotRestore() {
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .clean)
        XCTAssertEqual(restored, 0)
    }

    func testFileFlagTriggersRestoreAndIsRemoved() {
        flag.set()
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromFile)
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(flag.isSet)
    }

    func testFailedRestoreKeepsTheFlag() {
        flag.set()
        XCTAssertEqual(flag.recoverIfNeeded { false }, .restoreFailed)
        XCTAssertTrue(flag.isSet, "kept so the next launch tries again")
    }

    func testLegacyKeyIsTreatedAsDirtyOnceThenDeleted() {
        defaults.set(true, forKey: DirtyFlag.legacyDefaultsKey)
        var restored = 0
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .recoveredFromLegacyKey)
        XCTAssertEqual(restored, 1)
        XCTAssertNil(defaults.object(forKey: DirtyFlag.legacyDefaultsKey))
        XCTAssertEqual(
            flag.recoverIfNeeded {
                restored += 1; return true
            }, .clean)
        XCTAssertEqual(restored, 1)
    }

    func testLegacyKeyFalseIsCleanAndDeleted() {
        defaults.set(false, forKey: DirtyFlag.legacyDefaultsKey)
        XCTAssertEqual(
            flag.recoverIfNeeded {
                XCTFail("no restore"); return true
            }, .clean)
        XCTAssertNil(defaults.object(forKey: DirtyFlag.legacyDefaultsKey))
    }

    func testFileFlagWinsOverLegacyKeyAndBothAreCleared() {
        flag.set()
        defaults.set(true, forKey: DirtyFlag.legacyDefaultsKey)
        XCTAssertEqual(flag.recoverIfNeeded { true }, .recoveredFromFile)
        XCTAssertFalse(flag.isSet)
        XCTAssertNil(defaults.object(forKey: DirtyFlag.legacyDefaultsKey))
    }
}

final class LiveOwnerTests: XCTestCase {

    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sublight-owner-\(UUID().uuidString)")
        suiteName = "sublight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func flag() -> DirtyFlag { DirtyFlag(directory: dir, defaults: defaults) }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: flag().fileURL)
    }

    private func bootSeconds() -> Int64 {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Int64(tv.tv_sec)
    }

    func testNoFlagMeansNoOwner() {
        XCTAssertNil(flag().liveOwnerPID())
    }

    func testOurOwnFlagIsNotAnotherOwner() {
        let f = flag()
        f.set()
        XCTAssertTrue(f.isSet)
        XCTAssertNil(
            f.liveOwnerPID(), "a process must not find ITSELF and refuse to run")
    }

    func testAFlagFromAPriorBootIsACrashRemnantNotAnOwner() throws {
        // PID 1 is always alive, so only the boot stamp can rule this out —
        // which is the point: a reboot invalidates every PID.
        try write("\(bootSeconds() - 10_000):1\n")
        XCTAssertNil(
            flag().liveOwnerPID(), "a prior-boot flag is a remnant, not a live engine")
    }

    func testADeadPIDIsNotAnOwner() throws {
        // Reap a real child so its PID is genuinely gone rather than guessed.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        try write("\(bootSeconds()):\(p.processIdentifier)\n")
        XCTAssertNil(flag().liveOwnerPID(), "an exited process holds nothing")
    }

    func testALivePIDThatIsNotSublightIsNotAnOwner() throws {
        // PID 1 is launchd: alive, this boot, and emphatically not ours. Guards
        // against a recycled PID reading as a concurrent engine.
        try write("\(bootSeconds()):1\n")
        XCTAssertNil(
            flag().liveOwnerPID(), "only a live *Sublight* process is an owner")
    }

    func testAMalformedFlagIsNotAnOwner() throws {
        for text in ["", "dirty", "not:a:number", "\(bootSeconds()):notapid"] {
            try write(text)
            XCTAssertNil(
                flag().liveOwnerPID(), "malformed flag must not read as an owner: \(text)"
            )
        }
    }
}
