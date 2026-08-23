// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  ConsentMarker.swift
//  SublightKit
//
//  Informed consent, recorded once and shared between both executables.
//
//  Sublight's entire mechanism is flicker: it dims by switching the backlight
//  on and off 3–8 times a second, and every mode it can offer is inside the
//  3–30 Hz band that can trigger seizures in people with photosensitive
//  epilepsy. That is not a caveat about an edge case — it is what the app IS,
//  and it is measured fact (see DitherEngine.maxStableFrequencyHz: the daemon
//  will not hold a cycle short enough to fuse). So the first time anyone turns
//  dimming on, they are told plainly and asked, BEFORE a single backlight
//  command is issued.
//
//  WHY A FILE, not UserDefaults. The marker lives beside the dirty flag in
//  Application Support so the CLI can see it too. The CLI is a research
//  harness and does not block on consent, but it stays quiet about safety
//  only once the app has recorded it — otherwise every mutating command
//  points the operator at SAFETY.md.
//
//  VERSIONED. `currentVersion` is the contract: bump it when the copy makes a
//  materially different claim, and everyone is asked again. A recorded version
//  at or above the current one counts as granted, so a downgrade does not
//  re-prompt someone who has already agreed to strictly more.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public struct ConsentMarker {

    /// Bump ONLY when the consent copy changes materially. Everyone who
    /// agreed to an older version is asked again.
    public static let currentVersion = 1
    public static let fileName = "consent.json"
    /// Set when an UNATTENDED enable (the schedule) was refused for lack of
    /// consent. See `isPending`.
    public static let pendingFileName = "consent-pending"

    public let fileURL: URL

    /// - Parameter directory: where the marker lives. Defaults to
    ///   ~/Library/Application Support/Sublight, beside the dirty flag.
    ///   Tests inject a temp dir.
    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sublight", isDirectory: true)
        self.fileURL = dir.appendingPathComponent(Self.fileName)
    }

    /// Where the deferred-consent flag lives, beside the consent marker.
    public var pendingFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(Self.pendingFileName)
    }

    /// True when a scheduled dim was skipped because consent had never been
    /// given, and nobody has been told yet.
    ///
    /// The schedule fires unattended, so it must not raise a modal — but
    /// declining to act and saying nothing leaves someone with a feature that
    /// silently does not work. This flag is the bridge: it persists the fact
    /// that something was skipped, so the next time the popover opens (the
    /// attention moment for a menu-bar app) it can say so and offer the
    /// prompt. It clears only when consent is granted or the schedule is
    /// turned off — not on a whim, and not merely because time passed.
    public var isPending: Bool {
        FileManager.default.fileExists(atPath: pendingFileURL.path)
    }

    public func setPending() {
        guard !isPending else { return }
        do {
            try FileManager.default.createDirectory(
                at: pendingFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("1\n".utf8).write(to: pendingFileURL, options: .atomic)
            Log.lifecycle.notice("deferred consent: pending flag set")
        } catch {
            Log.lifecycle.error("could not set pending consent flag: \(String(describing: error), privacy: .public)")
        }
    }

    public func clearPending() {
        guard isPending else { return }
        try? FileManager.default.removeItem(at: pendingFileURL)
        Log.lifecycle.notice("deferred consent: pending flag cleared")
    }

    private struct Record: Codable {
        let version: Int
        let recordedAt: Date
    }

    /// The consent version on file, or nil if there is none (or the file is
    /// unreadable/corrupt, which is treated as "never consented" — the safe
    /// direction).
    public var recordedVersion: Int? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let r = try? decoder.decode(Record.self, from: data) { return r.version }
        // Tolerate a bare integer, in case a future version simplifies the
        // format: a marker we cannot parse must never read as "granted", but
        // one we can read in an obvious older shape should still count.
        if let text = String(data: data, encoding: .utf8),
           let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return n
        }
        return nil
    }

    /// True when consent has been recorded for the current copy or later.
    public var isGranted: Bool { (recordedVersion ?? 0) >= Self.currentVersion }

    /// Record consent. Atomic, so a crash mid-write cannot leave a torn file
    /// that later reads as granted.
    @discardableResult
    public func record(version: Int = ConsentMarker.currentVersion,
                       at date: Date = Date()) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Record(version: version, recordedAt: date))
            try data.write(to: fileURL, options: .atomic)
            // Granting consent answers whatever was deferred.
            clearPending()
            Log.lifecycle.notice("consent v\(version, privacy: .public) recorded")
            return true
        } catch {
            Log.lifecycle.error("could not record consent: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Forget consent — the app's "reset to defaults", and the way to re-test
    /// the first-enable flow.
    public func clear() {
        clearPending()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
        Log.lifecycle.notice("consent marker cleared")
    }
}
