// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  EngineCounters.swift
//  SublightKit
//
//  COMMAND TRUTH — the instrument, not the engine.
//
//  Watching the keys tells you what the LED did. It does not tell you what was
//  ASKED of the daemon, what the daemon accepted, or what the engine decided
//  not to ask for. Those three are different, and a dark envelope in the middle
//  of a steady dither is exactly the symptom that cannot be attributed without
//  separating them. This file is the separation:
//
//    scheduled  a deadline came due, by anchor arithmetic (DitherSchedule)
//    fired      the timer handler actually ran — a repeating DispatchSourceTimer
//               COALESCES deadlines missed while its queue was blocked, so
//               `scheduled - fired` is precisely what the timer swallowed
//    executed   a setBrightness command was issued to the daemon
//    skipped    the engine reached the edge and deliberately did not command
//               (the err-dark rule in DitherEngine.highEdge)
//
//  Plus the round-trip latency of every backlight-mutating daemon call, timed
//  at the bridge seam where the call actually crosses out of our process.
//
//  Everything here is process-wide by default (`EngineDiagnostics.shared`):
//  there is one EngineQueue and one daemon per process, so one tally is the
//  honest scope. Tests inject their own instance so the global cannot make
//  them flaky.
//
//  COST. The counters are a lock plus integer arithmetic per edge — permanent,
//  always on. The latency percentiles keep a FIXED window of recent samples
//  (count, sum and max stay exact over all time), so a process that dithers for
//  a week costs the same memory as one that dithers for a minute.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

// MARK: - Latency

/// Round-trip latency of daemon calls, in milliseconds.
public struct LatencyStats: Equatable, Codable, Sendable {

    /// Samples retained for percentiles. Count/sum/max are exact over all
    /// time; percentiles are over this trailing window.
    public static let window = 4096

    public private(set) var count: UInt64 = 0
    public private(set) var sumMs: Double = 0
    public private(set) var maxMs: Double = 0
    /// Trailing ring of samples. Order is not meaningful — only the multiset is.
    public private(set) var recentMs: [Double] = []
    private var cursor: Int = 0

    public init() {}

    public mutating func record(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        count &+= 1
        sumMs += ms
        if ms > maxMs { maxMs = ms }
        if recentMs.count < Self.window {
            recentMs.append(ms)
        } else {
            recentMs[cursor] = ms
            cursor = (cursor + 1) % Self.window
        }
    }

    public var meanMs: Double { count == 0 ? 0 : sumMs / Double(count) }

    /// Nearest-rank percentile over the retained window, `p` in 0…1.
    public func percentileMs(_ p: Double) -> Double {
        guard !recentMs.isEmpty else { return 0 }
        let sorted = recentMs.sorted()
        let clamped = min(max(p, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    public var p50Ms: Double { percentileMs(0.50) }
    public var p95Ms: Double { percentileMs(0.95) }
}

// MARK: - Edges

/// One edge's tally. See the file header for what each field means; the
/// distinction between `scheduled`, `fired` and `executed` is the whole point.
public struct EdgeCounters: Equatable, Codable, Sendable {
    public var scheduled: UInt64 = 0
    public var fired: UInt64 = 0
    public var executed: UInt64 = 0
    public var skipped: UInt64 = 0

    public init() {}

    /// Deadlines the repeating timer merged away because the queue was busy.
    public var coalesced: UInt64 { scheduled > fired ? scheduled - fired : 0 }
}

// MARK: - Skip diagnostic

/// EVERYTHING NEEDED TO ADJUDICATE ONE ERR-DARK SKIP, in one record.
///
/// A dark envelope in a long run has several candidate causes that look
/// identical from the keys: timer coalescing after the machine decides we are
/// idle, an activity assertion that stopped being honoured, the backlight
/// daemon pulling the level down between our writes, or the two edge timers
/// drifting apart. They are told apart by WHICH clock slipped, so the skip
/// record carries both edges' lateness rather than only the one that skipped.
///
/// The suppression flag states here are the ones READ AT THE LAST KEEPER TICK,
/// not read at the skip. Reading them is a daemon round trip, and doing that
/// inside an edge handler would put an XPC call on the timing-critical path the
/// rest of this engine exists to keep clear. `secondsSinceKeeperTick` is what
/// makes them interpretable: it dates the reading. The keeper drops to a 2 s
/// period after any skip precisely so that this number is small when it matters.
public struct SkipDiagnostic: Equatable, Codable, Sendable {

    /// Cycle index of the HIGH edge that was skipped.
    public var cycle: UInt64 = 0
    /// How late the skipped HIGH edge ran, past its own absolute deadline.
    public var highLatenessMs: Double = 0
    /// How late the most recent LOW edge ran, past ITS absolute deadline.
    public var lowLatenessMs: Double = 0
    /// True when that LOW edge belonged to the same cycle as the skipped HIGH,
    /// so `lowLatenessMs` is a same-cycle comparison rather than a stale one.
    public var lowWasSameCycle: Bool = false
    /// True when the LOW edge was itself late by more than the early-fire
    /// guard — i.e. BOTH timers slipped, not just the HIGH one.
    public var lowAlsoLate: Bool = false
    /// Seconds since the run started. The whole point: a defect with a ~20 min
    /// onset is invisible to a 5 min soak, so onset time is a first-class
    /// measurement, not a log timestamp to be reconstructed afterwards.
    public var elapsedRunSeconds: Double = 0
    /// Seconds since the last keeper tick. The keeper is driven by a timer and
    /// nothing else, so it is INDEPENDENT of user input: if it has also stopped
    /// running on time, the whole queue was starved rather than one timer.
    public var secondsSinceKeeperTick: Double = 0
    /// Suppression flag states as of that keeper tick. `nil` where the build
    /// has no getter for the flag.
    public var autoBrightnessOn: Bool?
    public var idleDimSuspended: Bool?

    public init() {}

    /// Onset histogram bucket for `elapsedRunSeconds`. Labels are zero-padded
    /// so a sorted-key JSON encoding comes out in chronological order.
    public static func onsetBucket(elapsedSeconds t: Double) -> String {
        guard t.isFinite, t > 0 else { return "00-01m" }
        switch t {
        case ..<60: return "00-01m"
        case ..<300: return "01-05m"
        case ..<600: return "05-10m"
        case ..<900: return "10-15m"
        case ..<1200: return "15-20m"
        case ..<1800: return "20-30m"
        case ..<3600: return "30-60m"
        default: return "60m+"
        }
    }

    /// The one-line discrimination record, as it goes to the log and the report.
    public var line: String {
        String(
            format:
                "cycle %llu  HIGH late %.2f ms  LOW late %.2f ms (%@, %@)  t+%.1f s  keeper %+.1f s ago  autoBrightnessOn=%@ idleDimSuspended=%@",
            cycle, highLatenessMs, lowLatenessMs,
            lowWasSameCycle ? "same cycle" : "previous cycle",
            lowAlsoLate ? "ALSO LATE" : "punctual",
            elapsedRunSeconds, secondsSinceKeeperTick,
            autoBrightnessOn.map { $0 ? "true" : "false" } ?? "n/a",
            idleDimSuspended.map { $0 ? "true" : "false" } ?? "n/a")
    }
}

// MARK: - Counters

public struct EngineCounters: Equatable, Codable, Sendable {

    public var high = EdgeCounters()
    public var low = EdgeCounters()

    /// Worst observed lateness of a HIGH edge that was skipped, in ms.
    public var skipMaxLatenessMs: Double = 0
    /// The err-dark threshold in force at the last skip (= the ON window), ms.
    public var skipLastThresholdMs: Double = 0
    /// Longest run of CONSECUTIVE skipped HIGH edges. A dark envelope of N
    /// cycles shows up here as N; scattered singles show up as 1.
    public var skipMaxRunLength: UInt64 = 0

    /// Longest interval between two consecutive EXECUTED HIGH commands, ms.
    /// With no skips and no coalescing this equals the nominal period.
    public var longestExecutedHighGapMs: Double = 0

    /// How many times the engine took a FRESH anchor: once at start, once per
    /// frequency change, and once per skip-burst re-anchor. A run that
    /// re-anchors repeatedly is a run whose queue keeps stalling.
    public var anchorResets: UInt64 = 0

    /// Skips by how far into the run they happened. A defect whose onset is
    /// ~20 minutes puts every count in the 15-20m bucket and later; a defect
    /// present from the start fills 00-01m. See `SkipDiagnostic.onsetBucket`.
    public var skipOnsetBuckets: [String: UInt64] = [:]

    /// The full discrimination record for the MOST RECENT skip, so a soak can
    /// be adjudicated from `status --json` alone instead of by log scraping.
    public var lastSkip: SkipDiagnostic?

    /// Schedule in force, for reading the numbers above against.
    public var nominalPeriodMs: Double = 0
    public var nominalOnWindowMs: Double = 0

    /// Round-trip latency of every backlight-mutating daemon call.
    public var latency = LatencyStats()
    /// Per-selector command tallies, e.g. "brightness", "brightness-fade".
    public var commandsByKind: [String: UInt64] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case high, low, skipMaxLatenessMs, skipLastThresholdMs, skipMaxRunLength
        case longestExecutedHighGapMs, anchorResets, skipOnsetBuckets, lastSkip
        case nominalPeriodMs, nominalOnWindowMs, latency, commandsByKind
    }

    /// Explicit, for the same reason `StatusReport` is: the synthesised encoder
    /// uses `encodeIfPresent` and would drop `lastSkip` entirely when there has
    /// been no skip. A consumer must be able to tell "no skip has happened yet"
    /// from "this field is gone in a newer schema", and a key that appears only
    /// once something has gone wrong is the worst of both.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(high, forKey: .high)
        try c.encode(low, forKey: .low)
        try c.encode(skipMaxLatenessMs, forKey: .skipMaxLatenessMs)
        try c.encode(skipLastThresholdMs, forKey: .skipLastThresholdMs)
        try c.encode(skipMaxRunLength, forKey: .skipMaxRunLength)
        try c.encode(longestExecutedHighGapMs, forKey: .longestExecutedHighGapMs)
        try c.encode(anchorResets, forKey: .anchorResets)
        try c.encode(skipOnsetBuckets, forKey: .skipOnsetBuckets)
        try c.encode(lastSkip, forKey: .lastSkip)
        try c.encode(nominalPeriodMs, forKey: .nominalPeriodMs)
        try c.encode(nominalOnWindowMs, forKey: .nominalOnWindowMs)
        try c.encode(latency, forKey: .latency)
        try c.encode(commandsByKind, forKey: .commandsByKind)
    }

    /// Fixed-width table. Same text from `hold`, `pair-sweep` and `status`, so
    /// two runs can be diffed by eye.
    public func report(indent: String = "  ") -> String {
        var out: [String] = []
        out.append(indent + "edge  scheduled     fired  executed   skipped coalesced")
        for (name, e) in [("HIGH", high), ("LOW ", low)] {
            out.append(
                indent
                    + String(
                        format: "%@  %9llu %9llu %9llu %9llu %9llu",
                        name, e.scheduled, e.fired, e.executed, e.skipped, e.coalesced))
        }
        out.append(
            indent
                + String(
                    format:
                        "err-dark skips: %llu   max lateness %.2f ms   threshold at last skip %.2f ms   longest burst %llu cycles",
                    high.skipped, skipMaxLatenessMs, skipLastThresholdMs, skipMaxRunLength
                ))
        out.append(
            indent
                + String(
                    format:
                        "longest gap between EXECUTED HIGH commands: %.1f ms   (nominal period %.1f ms, ON window %.2f ms)",
                    longestExecutedHighGapMs, nominalPeriodMs, nominalOnWindowMs))
        out.append(
            indent
                + String(
                    format:
                        "daemon command latency: n=%llu  p50 %.3f ms  p95 %.3f ms  max %.3f ms  mean %.3f ms",
                    latency.count, latency.p50Ms, latency.p95Ms, latency.maxMs,
                    latency.meanMs))
        let kinds = commandsByKind.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
        out.append(indent + "commands by kind: " + (kinds.isEmpty ? "(none)" : kinds))
        out.append(indent + "anchor resets: \(anchorResets)")
        let onset = skipOnsetBuckets.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
        out.append(indent + "skip onset: " + (onset.isEmpty ? "(none)" : onset))
        if let lastSkip {
            out.append(indent + "last skip: " + lastSkip.line)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Collector

/// Thread-safe tally fed by the engine (edges) and the bridge (commands).
///
/// Both feeders already run on EngineQueue, so the lock is only there to make
/// a read from any thread — `sublight-cli status`, the app's UI — safe without
/// a queue hop.
///
/// `@unchecked Sendable` is justified in the strict sense: every stored
/// property below is private, and every read and write of one happens inside
/// `lock`. Nothing escapes; the snapshot handed out is a value type.
public final class EngineDiagnostics: @unchecked Sendable {

    public static let shared = EngineDiagnostics()

    private let lock = NSLock()
    private var counters = EngineCounters()

    /// `scheduled` is derived from the cycle index, which restarts at 0 on
    /// every new anchor, so each run's contribution is folded into a base when
    /// the anchor resets.
    private var highBase: UInt64 = 0
    private var highInRun: UInt64 = 0
    private var lowBase: UInt64 = 0
    private var lowInRun: UInt64 = 0

    private var lastExecutedHighNanos: UInt64?
    private var skipRun: UInt64 = 0

    /// The most recent brightness LEVEL commanded, and when. A read-back
    /// sampler needs something to compare against, and the only honest
    /// reference is what we last actually asked the daemon for.
    private var lastValue: Float?
    private var lastValueAtNanos: UInt64?

    /// True once this PROCESS has issued any backlight-mutating command —
    /// a dither edge, a suppression flag, a calibration write, a restore.
    ///
    /// Deliberately NOT cleared by `reset()`. `reset()` brackets one
    /// measurement; this is a fact about the session that cannot be undone,
    /// and the exit path depends on it: a process that never touched the
    /// backlight must exit without imposing auto-brightness and a level on
    /// whatever state the user already had.
    private var _hardwareTouched = false

    public init() {}

    /// Last commanded brightness level and the monotonic time of the call.
    public func lastCommand() -> (value: Float, atNanos: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let v = lastValue, let t = lastValueAtNanos else { return nil }
        return (v, t)
    }

    // MARK: Read

    public func snapshot() -> EngineCounters {
        lock.lock(); defer { lock.unlock() }
        var c = counters
        c.high.scheduled = highBase &+ highInRun
        c.low.scheduled = lowBase &+ lowInRun
        return c
    }

    /// See `_hardwareTouched`: survives `reset()` by design.
    public var hardwareTouched: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hardwareTouched
    }

    /// Mark that a backlight-mutating command is about to be issued. Called by
    /// the bridge for every real daemon mutation, and by the engine at its
    /// commander seam so the flag is observable when a test stands in for the
    /// hardware.
    public func noteHardwareTouched() {
        lock.lock(); defer { lock.unlock() }
        _hardwareTouched = true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        counters = EngineCounters()
        highBase = 0; highInRun = 0; lowBase = 0; lowInRun = 0
        lastExecutedHighNanos = nil
        skipRun = 0
    }

    // MARK: Schedule

    /// A new anchor was installed (start, or a frequency change).
    public func noteAnchorReset(periodNanos: UInt64, onWindowNanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        highBase &+= highInRun; highInRun = 0
        lowBase &+= lowInRun; lowInRun = 0
        lastExecutedHighNanos = nil
        counters.anchorResets &+= 1
        counters.nominalPeriodMs = Double(periodNanos) / 1e6
        counters.nominalOnWindowMs = Double(onWindowNanos) / 1e6
    }

    /// A phase-continuous duty change moved the ON window.
    public func noteOnWindow(nanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        counters.nominalOnWindowMs = Double(nanos) / 1e6
    }

    // MARK: HIGH

    public func noteHighEdge(cycle: UInt64) {
        lock.lock(); defer { lock.unlock() }
        highInRun = max(highInRun, cycle &+ 1)
        counters.high.fired &+= 1
    }

    public func noteHighExecuted(atNanos now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        counters.high.executed &+= 1
        if let last = lastExecutedHighNanos, now > last {
            let gap = Double(now - last) / 1e6
            if gap > counters.longestExecutedHighGapMs {
                counters.longestExecutedHighGapMs = gap
            }
        }
        lastExecutedHighNanos = now
        skipRun = 0
    }

    /// - Parameter diagnostic: the full discrimination record for this skip.
    ///   Optional so the collector's own arithmetic stays unit-testable without
    ///   having to fabricate a plausible engine state around it.
    public func noteHighSkipped(
        latenessMs: Double, thresholdMs: Double, diagnostic: SkipDiagnostic? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        counters.high.skipped &+= 1
        if latenessMs > counters.skipMaxLatenessMs {
            counters.skipMaxLatenessMs = latenessMs
        }
        counters.skipLastThresholdMs = thresholdMs
        skipRun &+= 1
        if skipRun > counters.skipMaxRunLength { counters.skipMaxRunLength = skipRun }
        if let diagnostic {
            counters.lastSkip = diagnostic
            let bucket = SkipDiagnostic.onsetBucket(
                elapsedSeconds: diagnostic.elapsedRunSeconds)
            counters.skipOnsetBuckets[bucket, default: 0] &+= 1
        }
    }

    // MARK: LOW

    public func noteLowEdge(cycle: UInt64) {
        lock.lock(); defer { lock.unlock() }
        lowInRun = max(lowInRun, cycle &+ 1)
        counters.low.fired &+= 1
    }

    public func noteLowExecuted() {
        lock.lock(); defer { lock.unlock() }
        counters.low.executed &+= 1
    }

    public func noteLowSkipped() {
        lock.lock(); defer { lock.unlock() }
        counters.low.skipped &+= 1
    }

    // MARK: Commands (fed by the bridge)

    /// - Parameter value: the brightness level, for the brightness setters;
    ///   nil for the flag mutators (auto-brightness, idle dimming), which do
    ///   not move the level and must not overwrite the read-back reference.
    public func noteCommand(
        kind: String, value: Float? = nil, atNanos: UInt64? = nil, latencyMs: Double
    ) {
        lock.lock(); defer { lock.unlock() }
        counters.latency.record(latencyMs)
        counters.commandsByKind[kind, default: 0] &+= 1
        _hardwareTouched = true
        if let value {
            lastValue = value
            lastValueAtNanos = atNanos ?? DispatchTime.now().uptimeNanoseconds
        }
    }
}

// MARK: - Persistence

/// One recorded run, so `sublight-cli status` can report the counters of a
/// process that has already exited. Diagnostics only: nothing reads this back
/// into the engine, and deleting the file loses nothing but history.
public struct DiagnosticsRecord: Codable, Equatable, Sendable {
    public var label: String
    public var recordedAt: Date
    public var pid: Int32
    public var counters: EngineCounters

    public init(
        label: String, counters: EngineCounters,
        recordedAt: Date = Date(), pid: Int32 = getpid()
    ) {
        self.label = label
        self.recordedAt = recordedAt
        self.pid = pid
        self.counters = counters
    }
}

public enum DiagnosticsStore {

    public static let fileName = "diagnostics.json"

    /// Alongside the dirty flag, so both executables see the same history.
    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sublight", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    @discardableResult
    public static func save(_ record: DiagnosticsRecord, to url: URL = defaultURL) -> Bool
    {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            Log.engine.error(
                "could not write diagnostics: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    public static func load(from url: URL = defaultURL) -> DiagnosticsRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiagnosticsRecord.self, from: data)
    }
}
