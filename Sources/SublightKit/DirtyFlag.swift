// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  DirtyFlag.swift
//  SublightKit
//
//  Crash safety. A file is created atomically before the first backlight
//  command of an engagement and removed after any successful restore. If the
//  process dies in between — kill -9, a panic, a force quit — the file
//  survives, and the next launch of EITHER the app or the CLI sees it,
//  commands a restore, and removes it. Shared through Application Support so
//  both executables heal each other.
//
//  The previous mechanism was a UserDefaults key ("sublight.active"), app-only
//  and invisible to the CLI. It is migrated: if the legacy key is found at
//  launch it is treated as dirty once, then deleted.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct DirtyFlag {

    public static let legacyDefaultsKey = "sublight.active"
    public static let fileName = "engine.dirty"

    public enum Recovery: Equatable {
        case clean
        case recoveredFromFile
        case recoveredFromLegacyKey
        /// The flag was set but the restore command was rejected; the flag
        /// is kept so the next launch tries again.
        case restoreFailed
    }

    public let fileURL: URL
    private let defaults: UserDefaults

    /// - Parameters:
    ///   - directory: where the flag lives. Defaults to
    ///     ~/Library/Application Support/Sublight. Tests inject a temp dir.
    ///   - defaults: where the legacy key is looked for.
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sublight", isDirectory: true)
        self.fileURL = dir.appendingPathComponent(Self.fileName)
        self.defaults = defaults
    }

    public var isSet: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Create the flag, stamped with our PID. Atomic: written to a temp name
    /// and renamed into place, so a crash mid-write cannot leave a torn file.
    /// The PID lets recovery tell a genuine crash remnant from a flag a
    /// DIFFERENT, still-live process is holding — the flag is shared between
    /// the app and the CLI, so a read-only CLI command must not mistake the
    /// app's live hold for a crash and restore it out from under it.
    public func set() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(Self.bootSeconds()):\(getpid())\n".utf8).write(to: fileURL, options: .atomic)
            Log.engine.debug("dirty flag set (pid \(getpid(), privacy: .public))")
        } catch {
            Log.engine.error("could not set dirty flag: \(String(describing: error), privacy: .public)")
        }
    }

    /// System boot time in seconds — a reboot changes it, so a flag from a
    /// prior boot is always a crash remnant regardless of what PID means now.
    private static func bootSeconds() -> Int64 {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Int64(tv.tv_sec)
    }

    /// Parsed "<bootSeconds>:<pid>" from the flag, tolerating the older
    /// pid-only and "dirty" formats (both parse as no boot / no pid).
    private func stamp() -> (boot: Int64?, pid: pid_t?) {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        if parts.count == 2 { return (Int64(parts[0]), pid_t(parts[1])) }
        if parts.count == 1 { return (nil, pid_t(parts[0])) }   // legacy pid-only
        return (nil, nil)
    }

    /// True only if the flag was written THIS boot by a PID that is still a
    /// live Sublight process — i.e. a genuine concurrent holder, not a crash
    /// remnant. A prior-boot flag, a dead PID, or a PID now owned by an
    /// unrelated process all read as "not a live owner" so recovery proceeds.
    private func heldByLiveOtherProcess() -> Bool {
        let s = stamp()
        // A flag from a previous boot (or unknown boot) is never a live owner.
        guard let boot = s.boot, boot == Self.bootSeconds() else { return false }
        guard let pid = s.pid, pid != getpid() else { return false }
        // Alive? kill(pid,0)==0 signalable; EPERM = exists, other user.
        let alive = kill(pid, 0) == 0 || errno == EPERM
        guard alive else { return false }
        // Reused PID? Only a live *Sublight* process counts as an owner.
        return Self.isSublightProcess(pid)
    }

    private static func isSublightProcess(_ pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else {
            // Can't read the path (e.g. another user's process) — be
            // conservative and assume it IS an owner, so we don't stomp it.
            return true
        }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
        return path.contains("sublight")
    }

    public func clear() {
        guard isSet else { return }
        // Never delete a marker a DIFFERENT live process is holding: a forced
        // restore on quit would otherwise erase a concurrently-dithering CLI's
        // crash marker. Our own flag (or a stale one) clears normally.
        if heldByLiveOtherProcess() { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
            Log.engine.debug("dirty flag cleared")
        } catch {
            Log.engine.error("could not clear dirty flag: \(String(describing: error), privacy: .public)")
        }
    }

    /// Launch-time recovery for both executables. `restore` must command the
    /// backlight back to system control and report whether the command was
    /// accepted.
    @discardableResult
    public func recoverIfNeeded(restore: () -> Bool) -> Recovery {
        let legacy = defaults.object(forKey: Self.legacyDefaultsKey) != nil
        let legacyDirty = defaults.bool(forKey: Self.legacyDefaultsKey)
        let fileDirty = isSet

        // A flag another live process is holding is NOT a crash remnant — leave
        // it and its owner alone. (A stale legacy key alongside it is still
        // cleared, since only this process's defaults carry it.)
        if fileDirty, heldByLiveOtherProcess() {
            if legacy { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
            return .clean
        }

        guard fileDirty || legacyDirty else {
            if legacy { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
            return .clean
        }

        let source = fileDirty ? "engine.dirty" : "legacy sublight.active key"
        Log.engine.warning("previous session did not restore cleanly (\(source, privacy: .public)) — restoring backlight")
        let ok = restore()
        guard ok else {
            // Keep a marker so the NEXT launch retries. For a legacy-only
            // source there is no file yet, so convert it into one; then it is
            // safe to drop the legacy key.
            if !fileDirty { set() }
            if legacy { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
            Log.engine.error("crash recovery: restore command rejected; flag kept for next launch")
            return .restoreFailed
        }
        if legacy { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
        clear()
        Log.engine.info("crash recovery complete; dirty flag removed")
        return fileDirty ? .recoveredFromFile : .recoveredFromLegacyKey
    }
}
