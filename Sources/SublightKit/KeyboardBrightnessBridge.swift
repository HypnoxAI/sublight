// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  KeyboardBrightnessBridge.swift
//  SublightKit
//
//  Defensive bridge to the private CoreBrightness `KeyboardBrightnessClient`.
//
//  Design rules (see docs/SPEC.md §4):
//    1. The framework is loaded at runtime with dlopen(), never linked at
//       build time. If Apple removes or renames it, we fail with a clear
//       error instead of failing to launch.
//    2. Every selector is checked with responds(to:) before use. A missing
//       selector degrades the feature; it never crashes the process.
//    3. The selector table below is derived from publicly circulated
//       class dumps, NOT from Apple documentation. Verify it against YOUR
//       machine with `sublight-cli dump`, which introspects the real class
//       via the Objective-C runtime.
//    4. QUEUE CONFINEMENT. Every public method executes on EngineQueue —
//       synchronously, from any thread, inline when the caller is already on
//       it (the tick and signal handlers are). The daemon therefore only ever
//       sees one caller at a time, in order: a calibration write, a CLI probe
//       write, and a dither edge can never interleave. Callers keep their
//       call sites unchanged and inherit this.
//    5. COMMAND TRUTH. Every backlight-MUTATING call goes through
//       `timedMutation`, which times the round trip, emits an `XPC` signpost
//       interval around it, logs the request and the daemon's answer at debug
//       level in category "engine", and feeds EngineDiagnostics. This is the
//       only place in the process where a command actually leaves us, so it is
//       the only honest place to measure one. Read it back with:
//
//         log stream --level debug --predicate \
//           'subsystem == "com.hypnox.sublight" AND category == "engine"'
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import ObjectiveC
import Darwin
import os

/// Selectors we expect `KeyboardBrightnessClient` to implement.
///
/// Declaring them in an `@objc` protocol teaches the Swift compiler the
/// selector shapes so we can use AnyObject dynamic dispatch with optional
/// chaining — the call site `(client as AnyObject).setBrightness?(…)`
/// returns nil instead of crashing if the method does not exist at runtime.
///
/// Swift name                              → Objective-C selector
/// copyKeyboardBacklightIDs()              → copyKeyboardBacklightIDs
/// isKeyboardBuiltIn(_:)                   → isKeyboardBuiltIn:
/// brightness(forKeyboard:)                → brightnessForKeyboard:
/// setBrightness(_:forKeyboard:)           → setBrightness:forKeyboard:
/// enableAutoBrightness(_:forKeyboard:)    → enableAutoBrightness:forKeyboard:
/// isAutoBrightnessEnabled(forKeyboard:)   → isAutoBrightnessEnabledForKeyboard:
/// setIdleDimTime(_:forKeyboard:)          → setIdleDimTime:forKeyboard:
/// idleDimTime(forKeyboard:)               → idleDimTimeForKeyboard:
/// isBacklightDimmed(onKeyboard:)          → isBacklightDimmedOnKeyboard:
/// isBacklightSuppressed(onKeyboard:)      → isBacklightSuppressedOnKeyboard:
@objc private protocol KeyboardBrightnessSelectors {
    func copyKeyboardBacklightIDs() -> NSArray
    func isKeyboardBuiltIn(_ keyboardID: UInt64) -> Bool
    func brightness(forKeyboard keyboardID: UInt64) -> Float
    func setBrightness(_ brightness: Float, forKeyboard keyboardID: UInt64) -> Bool
    func enableAutoBrightness(_ enable: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func isAutoBrightnessEnabled(forKeyboard keyboardID: UInt64) -> Bool
    func setIdleDimTime(_ seconds: Double, forKeyboard keyboardID: UInt64) -> Bool
    func idleDimTime(forKeyboard keyboardID: UInt64) -> Double
    func isBacklightDimmed(onKeyboard keyboardID: UInt64) -> Bool
    func isBacklightSuppressed(onKeyboard keyboardID: UInt64) -> Bool

    // --- Discovered on macOS 26 via `dump`, TYPES VERIFIED via `sig` (2026-07-19).
    //     Real signature: setBrightness:(float) fadeSpeed:(int) commit:(BOOL)
    //     forKeyboard:(unsigned long long). `fadeSpeed` is a 32-bit INT — almost
    //     certainly an enumerated fade-speed selector (0 = likely instant/none),
    //     NOT a duration. It MUST be Int32, not a floating-point type: on arm64,
    //     floats travel in v-registers and ints in x-registers, so declaring
    //     fadeSpeed as Double/Float would misalign every argument after it. If a
    //     future macOS changes these types, `sig` will show it — re-check there.
    func setBrightness(_ brightness: Float, fadeSpeed: Int32, commit: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func backlightLevel(forKeyboard keyboardID: UInt64) -> Float
    func suspendIdleDimming(_ suspend: Bool, forKeyboard keyboardID: UInt64) -> Bool
    func isIdleDimmingSuspended(onKeyboard keyboardID: UInt64) -> Bool
    func isAmbientFeatureAvailable(onKeyboard keyboardID: UInt64) -> Bool
    func isBacklightSaturated(onKeyboard keyboardID: UInt64) -> Bool

    // Change-notification API (yield-to-manual spike). The block's true argument
    // signature is unknown, so we register a ZERO-ARG block: safe because any
    // extra args the system passes sit in registers the block never reads.
    func registerNotificationForKeys(_ keys: Any?, keyboardID: UInt64, block: @escaping () -> Void)
    func unregisterKeyboardNotificationBlock()
}

public final class KeyboardBrightnessBridge {

    public enum BridgeError: Error, CustomStringConvertible {
        case frameworkNotLoadable
        case classNotFound
        case coreSelectorsMissing([String])
        case noBacklitKeyboard

        public var description: String {
            switch self {
            case .frameworkNotLoadable:
                return "Could not dlopen CoreBrightness.framework. Are you on macOS? (This tool is macOS/Apple Silicon only.)"
            case .classNotFound:
                return "CoreBrightness loaded, but KeyboardBrightnessClient was not found. Apple may have renamed it — run `sublight-cli dump` on a working build, or check recent class dumps."
            case .coreSelectorsMissing(let missing):
                return "KeyboardBrightnessClient exists but is missing core selectors: \(missing.joined(separator: ", ")). The selector table has drifted — run `sublight-cli dump` and update the bridge."
            case .noBacklitKeyboard:
                return "No backlit keyboard was found. External keyboards without backlight are not supported."
            }
        }
    }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    /// The live `KeyboardBrightnessClient` instance (typed as NSObject; all
    /// calls go through guarded dynamic dispatch).
    private let client: NSObject

    // MARK: - Init

    public init() throws {
        self.client = try EngineQueue.run {
            guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else {
                throw BridgeError.frameworkNotLoadable
            }
            guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
                throw BridgeError.classNotFound
            }
            return cls.init()
        }

        // Fail fast if the two selectors the whole project rests on are gone.
        let core = ["setBrightness:forKeyboard:", "brightnessForKeyboard:"]
        let missing = core.filter { !responds($0) }
        guard missing.isEmpty else {
            throw BridgeError.coreSelectorsMissing(missing)
        }
    }

    // MARK: - Selector plumbing

    private func responds(_ selectorName: String) -> Bool {
        client.responds(to: NSSelectorFromString(selectorName))
    }

    private var dyn: AnyObject { client as AnyObject }

    // MARK: - Command truth

    private static let signposter = OSSignposter(subsystem: Log.subsystem, category: "engine")

    /// Time, signpost, log and count ONE backlight-mutating daemon call.
    ///
    /// The measured span is the synchronous dynamic dispatch itself — the whole
    /// hop into CoreBrightness and back — which is what the engine's edge
    /// handler actually pays for and what a stalled daemon shows up in. The log
    /// line carries the monotonic timestamp of the call, what was requested,
    /// whether the daemon accepted it, and the round trip in ms.
    ///
    /// The formatting all happens inside os.Logger autoclosures, so when debug
    /// logging is off the cost is a lock, a subtraction and two counters.
    @discardableResult
    private func timedMutation(_ kind: String,
                               value: Float? = nil,
                               fadeSpeed: Int32? = nil,
                               commit: Bool? = nil,
                               flag: Bool? = nil,
                               seconds: Double? = nil,
                               _ keyboardID: UInt64,
                               _ body: () -> Bool) -> Bool {
        let state = Self.signposter.beginInterval("XPC", id: Self.signposter.makeSignpostID())
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ok = body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        Self.signposter.endInterval("XPC", state)

        let ms = Double(t1 &- t0) / 1e6
        EngineDiagnostics.shared.noteCommand(kind: kind, value: value, atNanos: t0, latencyMs: ms)
        Log.engine.debug("""
            cmd \(kind, privacy: .public) \
            t=\(Double(t0) / 1e6, format: .fixed(precision: 3), privacy: .public)ms \
            value=\(value.map { String(format: "%.4f", $0) } ?? "-", privacy: .public) \
            fade=\(fadeSpeed.map { String($0) } ?? "default", privacy: .public) \
            commit=\(commit.map { String($0) } ?? "-", privacy: .public) \
            flag=\(flag.map { String($0) } ?? "-", privacy: .public) \
            seconds=\(seconds.map { String(format: "%.3f", $0) } ?? "-", privacy: .public) \
            kbd=\(keyboardID, privacy: .public) \
            ok=\(ok, privacy: .public) \
            rt=\(ms, format: .fixed(precision: 3), privacy: .public)ms
            """)
        return ok
    }

    // MARK: - Keyboard enumeration

    /// All keyboard backlight IDs known to the system.
    public func keyboardIDs() -> [UInt64] {
        EngineQueue.run {
            guard responds("copyKeyboardBacklightIDs"),
                  let arr = dyn.copyKeyboardBacklightIDs?() as? [NSNumber]
            else { return [] }
            return arr.map { $0.uint64Value }
        }
    }

    public func isBuiltIn(_ keyboardID: UInt64) -> Bool {
        EngineQueue.run {
            guard responds("isKeyboardBuiltIn:") else { return false }
            return dyn.isKeyboardBuiltIn?(keyboardID) ?? false
        }
    }

    /// Best-effort resolution of the built-in keyboard's backlight ID.
    ///
    /// Order of preference:
    ///   1. An enumerated ID that reports built-in.
    ///   2. The first enumerated ID.
    ///   3. Heuristic fallback: ID 1, which public code samples report as the
    ///      built-in keyboard on Apple Silicon laptops. Setting brightness on
    ///      a nonexistent ID is expected to return false, so the fallback is
    ///      harmless — but treat any behavior under fallback as unverified.
    public func resolveBuiltInKeyboard() -> UInt64 {
        EngineQueue.run {
            let ids = keyboardIDs()
            if let builtin = ids.first(where: { isBuiltIn($0) }) { return builtin }
            if let first = ids.first { return first }
            return 1
        }
    }

    // MARK: - Brightness

    /// Read the current brightness as reported by the daemon, in [0, 1].
    ///
    /// CAUTION (SPEC §6.4): the read-back may report the *target* of an
    /// in-flight fade, not the instantaneous LED output. Never use read-back
    /// alone as proof that a level is physically displayed — the same lesson
    /// as the CoreGraphics gamma regression, where the API reported success
    /// while the hardware ignored it.
    ///
    /// MEASURED, 2026-08-23 (directive #3-B): worse than "may". Over 600
    /// samples it matched the last commanded level only 84.7 % of the time,
    /// and EVERY mismatch returned the same value, 0.1248 — step 2 of the
    /// 16-step ladder, which the engine never commands, and which was also
    /// observed before the first command of an unrelated run. So the getter
    /// intermittently serves a persistent system-side setting rather than the
    /// live level. It is also expensive: p50 0.6 ms against 0.15 ms for a
    /// setter, with a 21 ms outlier — longer than the ON window at 9 Hz /
    /// duty 0.15, so polling it on the engine queue can stall an edge.
    public func brightness(_ keyboardID: UInt64) -> Float? {
        EngineQueue.run {
            guard responds("brightnessForKeyboard:") else { return nil }
            return dyn.brightness?(forKeyboard: keyboardID)
        }
    }

    /// Command a brightness level in [0, 1]. The daemon applies its own fade
    /// ramp toward the target; values below the system floor are expected to
    /// be clamped (that clamp is the whole reason this project exists).
    @discardableResult
    public func setBrightness(_ value: Float, _ keyboardID: UInt64) -> Bool {
        EngineQueue.run {
            guard responds("setBrightness:forKeyboard:") else { return false }
            return timedMutation("brightness", value: value, keyboardID) {
                dyn.setBrightness?(value, forKeyboard: keyboardID) ?? false
            }
        }
    }

    // MARK: - Discovered: fade-controlled set + second read-back (verify with `sig`)

    /// The whole reason we paused to upgrade: a setter with EXPLICIT fade
    /// control and a commit flag. If this can hold a sub-floor value
    /// statically (with fadeSpeed 0 = instant and/or commit false), the dither
    /// engine becomes unnecessary. `fadeSpeed` is a 32-bit int enum (verified
    /// via `sig`); pass small integers (0, 1, 2, …).
    @discardableResult
    public func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool, _ keyboardID: UInt64) -> Bool {
        EngineQueue.run {
            guard responds("setBrightness:fadeSpeed:commit:forKeyboard:") else { return false }
            return timedMutation("brightness-fade", value: value, fadeSpeed: fadeSpeed,
                                 commit: commit, keyboardID) {
                dyn.setBrightness?(value, fadeSpeed: fadeSpeed, commit: commit, forKeyboard: keyboardID) ?? false
            }
        }
    }

    public var supportsFadeControl: Bool {
        EngineQueue.run {
            responds("setBrightness:fadeSpeed:commit:forKeyboard:")
        }
    }

    /// A SECOND read-back, distinct from `brightness(_:)`.
    ///
    /// MEASURED, 2026-08-23 (directive #3-B, 601 samples at 20 Hz during a 9 Hz
    /// dither on Mac16,12 / macOS 26.6.1):
    ///
    ///   1. It is NOT normalized [0, 1]. It reports on a ~16x larger scale
    ///      consistent with the 16-step ladder — commanded 0.0625 reads back
    ///      1.0100, commanded 0.1248 reads back 1.9177 — i.e. roughly the step
    ///      index. Do not compare it against a [0, 1] value without scaling.
    ///   2. It is NOT an output oracle. It moves in lockstep with
    ///      `brightness(_:)` (the two agree on every sample bar the ~0.5 ms
    ///      between the two calls) and is completely blind to real LED output:
    ///      across 30 s in which the keys visibly went fully dark 10-30 times,
    ///      the longest run of zero read-back was 300 ms and the per-second
    ///      zero-fraction never left 0.70-0.75.
    ///
    /// The hypothesis this method was added to test — that one getter reports
    /// the target and the other the actual LED — is REFUTED. Neither does.
    /// `probe` still compares them side by side.
    public func backlightLevel(_ keyboardID: UInt64) -> Float? {
        EngineQueue.run {
            guard responds("backlightLevelForKeyboard:") else { return nil }
            return dyn.backlightLevel?(forKeyboard: keyboardID)
        }
    }

    // MARK: - Auto-brightness (ambient light sensor)

    public var supportsAutoBrightnessControl: Bool {
        EngineQueue.run {
            responds("enableAutoBrightness:forKeyboard:") && responds("isAutoBrightnessEnabledForKeyboard:")
        }
    }

    public func isAutoBrightnessEnabled(_ keyboardID: UInt64) -> Bool? {
        EngineQueue.run {
            guard responds("isAutoBrightnessEnabledForKeyboard:") else { return nil }
            return dyn.isAutoBrightnessEnabled?(forKeyboard: keyboardID)
        }
    }

    @discardableResult
    public func setAutoBrightness(_ enabled: Bool, _ keyboardID: UInt64) -> Bool {
        EngineQueue.run {
            guard responds("enableAutoBrightness:forKeyboard:") else { return false }
            return timedMutation("auto-brightness", flag: enabled, keyboardID) {
                dyn.enableAutoBrightness?(enabled, forKeyboard: keyboardID) ?? false
            }
        }
    }

    // MARK: - Idle dim

    public func idleDimTime(_ keyboardID: UInt64) -> Double? {
        EngineQueue.run {
            guard responds("idleDimTimeForKeyboard:") else { return nil }
            return dyn.idleDimTime?(forKeyboard: keyboardID)
        }
    }

    @discardableResult
    public func setIdleDimTime(_ seconds: Double, _ keyboardID: UInt64) -> Bool {
        EngineQueue.run {
            guard responds("setIdleDimTime:forKeyboard:") else { return false }
            return timedMutation("idle-dim-time", seconds: seconds, keyboardID) {
                dyn.setIdleDimTime?(seconds, forKeyboard: keyboardID) ?? false
            }
        }
    }

    // MARK: - State flags

    public func isBacklightDimmed(_ keyboardID: UInt64) -> Bool? {
        EngineQueue.run {
            guard responds("isBacklightDimmedOnKeyboard:") else { return nil }
            return dyn.isBacklightDimmed?(onKeyboard: keyboardID)
        }
    }

    public func isBacklightSuppressed(_ keyboardID: UInt64) -> Bool? {
        EngineQueue.run {
            guard responds("isBacklightSuppressedOnKeyboard:") else { return nil }
            return dyn.isBacklightSuppressed?(onKeyboard: keyboardID)
        }
    }

    public func isBacklightSaturated(_ keyboardID: UInt64) -> Bool? {
        EngineQueue.run {
            guard responds("isBacklightSaturatedOnKeyboard:") else { return nil }
            return dyn.isBacklightSaturated?(onKeyboard: keyboardID)
        }
    }

    public func isAmbientFeatureAvailable(_ keyboardID: UInt64) -> Bool? {
        EngineQueue.run {
            guard responds("isAmbientFeatureAvailableOnKeyboard:") else { return nil }
            return dyn.isAmbientFeatureAvailable?(onKeyboard: keyboardID)
        }
    }

    // MARK: - Discovered: idle-dim suspension (clean replacement for setIdleDimTime policy)

    /// A direct boolean to stop idle-dimming on a keyboard — much cleaner than
    /// juggling `setIdleDimTime:`. During a sub-minimum hold this resolves the
    /// idle-dim conflict described in SPEC §6.2 in one call.
    @discardableResult
    public func setIdleDimmingSuspended(_ suspend: Bool, _ keyboardID: UInt64) -> Bool {
        EngineQueue.run {
            guard responds("suspendIdleDimming:forKeyboard:") else { return false }
            return timedMutation("idle-dim-suspend", flag: suspend, keyboardID) {
                dyn.suspendIdleDimming?(suspend, forKeyboard: keyboardID) ?? false
            }
        }
    }

    public func isIdleDimmingSuspended(_ keyboardID: UInt64) -> Bool? {
        EngineQueue.run {
            guard responds("isIdleDimmingSuspendedOnKeyboard:") else { return nil }
            return dyn.isIdleDimmingSuspended?(onKeyboard: keyboardID)
        }
    }

    // MARK: - Discovered: change notifications (spike; block signature unknown)

    public var supportsChangeNotifications: Bool {
        EngineQueue.run {
            responds("registerNotificationForKeys:keyboardID:block:")
        }
    }

    /// Register a zero-argument callback for keyboard-backlight changes. SAFE
    /// despite the unknown real block signature: a () -> Void block ignores any
    /// args the system passes (they occupy registers the block never reads).
    @discardableResult
    public func registerChangeNotification(keys: Any?, _ keyboardID: UInt64, _ block: @escaping () -> Void) -> Bool {
        EngineQueue.run {
            guard responds("registerNotificationForKeys:keyboardID:block:") else { return false }
            dyn.registerNotificationForKeys?(keys, keyboardID: keyboardID, block: block)
            return true
        }
    }

    public func unregisterChangeNotification() {
        EngineQueue.run {
            guard responds("unregisterKeyboardNotificationBlock") else { return }
            dyn.unregisterKeyboardNotificationBlock?()
        }
    }

    // MARK: - Runtime introspection

    /// The actual instance-method selector list of the class on THIS machine,
    /// straight from the Objective-C runtime. This is the ground truth that
    /// the table at the top of this file must be reconciled against whenever
    /// macOS updates. Exposed as `sublight-cli dump`.
    public func runtimeSelectorDump() -> [String] {
        EngineQueue.run {
            var result: [String] = []
            var count: UInt32 = 0
            if let methods = class_copyMethodList(type(of: client), &count) {
                for i in 0..<Int(count) {
                    result.append(String(cString: sel_getName(method_getName(methods[i]))))
                }
                free(methods)
            }
            return result.sorted()
        }
    }

    /// The raw Objective-C type encoding of one selector on this class, or nil
    /// if the class does not implement it. This is how we learn the TRUE arg
    /// types of `setBrightness:fadeSpeed:commit:forKeyboard:` before daring to
    /// call it — the encoding never lies about the ABI, whereas our guessed
    /// Swift signature might. Exposed as `sublight-cli sig`.
    public func methodSignature(_ selectorName: String) -> String? {
        EngineQueue.run {
            let sel = NSSelectorFromString(selectorName)
            guard let m = class_getInstanceMethod(type(of: client), sel) else { return nil }
            return method_getTypeEncoding(m).map { String(cString: $0) }
        }
    }

    /// Best-effort human-readable decode of an ObjC method type encoding.
    /// NOT a full parser — it skips stack-offset digits and type qualifiers
    /// and maps primitive type chars in order. Good enough for the scalar
    /// selectors we care about (it does not handle struct/block args, which
    /// none of the probed selectors use). The encoding layout is:
    ///   <return><self:@><cmd::><arg1><arg2>...
    public func decodeSignature(_ encoding: String) -> String {
        let typeNames: [Character: String] = [
            "c": "BOOL", "i": "int", "s": "short", "l": "long", "q": "long long",
            "C": "unsigned char", "I": "unsigned int", "S": "unsigned short",
            "L": "unsigned long", "Q": "unsigned long long", "f": "float",
            "d": "double", "B": "bool", "v": "void", "*": "char*", "@": "id",
            "#": "Class", ":": "SEL", "?": "block/unknown"
        ]
        let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V"]
        var tokens: [String] = []
        for ch in encoding {
            if ch.isNumber || qualifiers.contains(ch) { continue }
            if let name = typeNames[ch] { tokens.append(name) }
        }
        guard tokens.count >= 3 else { return encoding }
        let ret = tokens[0]
        let args = Array(tokens.dropFirst(3)) // drop return, self(@), _cmd(:)
        return "returns \(ret); args: " + (args.isEmpty ? "(none)" : args.joined(separator: ", "))
    }
}
