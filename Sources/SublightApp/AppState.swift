// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  AppState.swift
//  SublightApp
//
//  Owns the BacklightController and app state — as a FORWARDER. AppState
//  holds intent and policy and calls DitherEngine; it contains no backlight
//  timing and issues no CoreBrightness calls itself. Engine state comes back
//  through onStateChange on the main actor. The one timer that remains here
//  is the 60 s time-of-day schedule — wall-clock policy, not backlight timing.
//
//  Running decision, in ONE place (`effectiveRunning`, via DimmingPolicy):
//
//      effectiveRunning = isEnabled && !systemSuspended
//
//  `isEnabled` is the user's intent (toggle, hotkey, schedule);
//  `systemSuspended` is the machine's state (sleep, screens off, session
//  inactive). Suspension never clears the intent, so resume re-engages.
//
//  Frequency: continuous, sub-floor dithering (SPEC §3/§5).
//    Simple   → on/off + brightness, fixed 8 Hz.
//    Advanced → 3/6/8 Hz presets + 2–8 Hz custom slider + separate brightness.
//  8 Hz is the measured stability ceiling, not a taste call — see
//  DitherEngine.maxStableFrequencyHz. Nothing in the app can exceed it.
//  Nothing dims until the versioned consent modal has been accepted (see
//  ConsentMarker); the first-run onboarding window informs but records nothing.
//
//  Schedule (manual time; sunset/sunrise is a later addition): transition-based
//  auto-dim between a start and end time. Acts only on window ENTER/EXIT so the
//  user can still override manually between transitions. In Simple it toggles
//  the 8 Hz dim; in Advanced it also applies `scheduleFrequency`.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import SwiftUI
import AppKit
import ServiceManagement
import os
import SublightKit

/// How the schedule decides when to dim.
enum ScheduleMode: String, CaseIterable, Identifiable {
    case fixed, solar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fixed: return "Fixed times"
        case .solar: return "Sunset → sunrise"
        }
    }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: Constants

    static let freqMin = 2.0
    /// The custom slider stops AT the measured stability ceiling. The engine
    /// would clamp anyway, but a slider that reads 12 Hz while the hardware
    /// runs 8 is a lie the UI must not tell.
    static let freqMax = DitherEngine.maxStableFrequencyHz
    /// Simple mode's fixed frequency when the user has not calibrated: the
    /// High preset, i.e. the ceiling — dimmest and steadiest we can hold.
    static let simpleFreq = FrequencyPreset.high
    static let presets = FrequencyPreset.all

    // MARK: Published UI state

    @Published var isEnabled: Bool = false { didSet { apply() } }
    @Published var frequencyHz: Double = FrequencyPreset.high { didSet { apply() } }
    @Published var brightness: Double = 0.5 { didSet { apply() } }
    /// The machine is asleep, its screens are off, or the login session is
    /// inactive. Set only by SleepWakeObserver transitions.
    @Published private(set) var systemSuspended: Bool = false { didSet { apply() } }
    /// Mirror of the engine's state, delivered on the main actor.
    @Published private(set) var engineState: EngineState = .stopped
    @Published var advancedMode: Bool = false { didSet { onAdvancedChanged() } }
    /// Whether the first-run onboarding window has already been shown.
    ///
    /// This used to be an acknowledgment that GATED every feature. It no
    /// longer gates anything: the versioned consent modal (ConsentMarker) is
    /// the sole recorded acknowledgment, and it fires before the first
    /// backlight command rather than at launch. The stored key keeps its
    /// original name so that anyone who already went through onboarding is
    /// not shown it again — their data is reinterpreted, not discarded.
    @Published var onboardingSeen: Bool = false
    /// Mirror of the shared consent marker (see ConsentMarker). Nothing may
    /// command the backlight until this is true.
    @Published private(set) var consentGranted: Bool = false
    /// A scheduled dim was skipped for lack of consent and nobody has been
    /// told yet. Drives the popover's inline notice.
    @Published private(set) var consentPending: Bool = false
    @Published var launchAtLogin: Bool = false { didSet { updateLoginItem() } }
    @Published var hotKey: HotKeyChoice = .off { didSet { applyHotKey() } }
    /// Set when a shortcut could not be claimed — almost always because
    /// another app already owns it. Surfaced in Settings rather than failing
    /// silently, which would look like the feature is broken.
    @Published var hotKeyConflict = false

    // Schedule
    @Published var scheduleEnabled: Bool = false { didSet { onScheduleChanged() } }
    @Published var scheduleStartMinutes: Int = 21 * 60 { didSet { persistSchedule(); reevaluateSchedule(force: true) } }
    @Published var scheduleEndMinutes: Int = 7 * 60 { didSet { persistSchedule(); reevaluateSchedule(force: true) } }
    @Published var scheduleFrequency: Double = FrequencyPreset.high { didSet { defaults.set(scheduleFrequency, forKey: Keys.schedFreq) } }
    @Published var scheduleMode: ScheduleMode = .fixed { didSet { onScheduleModeChanged() } }
    /// Coordinates for solar scheduling. Entered by hand, used only for local
    /// arithmetic — see Solar.swift for why this isn't CoreLocation.
    @Published var latitude: Double = 0 { didSet { onLocationChanged() } }
    @Published var longitude: Double = 0 { didSet { onLocationChanged() } }
    /// Chosen city, or `CityDirectory.customID` when coordinates were typed in
    /// by hand. Kept alongside lat/long rather than replacing them, so the
    /// resolved numbers stay visible and verifiable.
    @Published var cityID: String = CityDirectory.customID { didSet { onCityChanged() } }

    @Published var available: Bool = false
    @Published var statusText: String = ""
    /// The launch-time private-API probe. Controls are disabled when it
    /// fails; the text is what the user is asked to paste into an issue.
    @Published private(set) var probeReport: ValidationReport?

    /// Per-machine calibration. nil until the guided flow has been run on
    /// THIS hardware model — defaults are only known-good on one machine.
    @Published private(set) var calibratedFrequency: Double?
    @Published private(set) var calibratedDate: Date?

    let hardware = HardwareInfo.current

    var isCalibrated: Bool { calibratedFrequency != nil }

    // MARK: Internals

    private(set) var controller: BacklightController?
    private var sleepWake: SleepWakeObserver?
    private var terminateToken: NSObjectProtocol?
    private var signalRestore: SignalRestore?
    private var scheduleTimer: Timer?
    private let hotKeyManager = HotKeyManager()
    private var onboardingWindow: NSWindow?
    private var lastInWindow: Bool?
    private var isUpdatingLoginItem = false

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let brightness = "sublight.brightness"
        static let floor = "sublight.floor"
        static let advanced = "sublight.advanced"
        /// Historically "the user accepted the safety warning"; now simply
        /// "the onboarding window has been shown". The key name is kept so
        /// existing installs are not walked through onboarding a second
        /// time — the stored value is reinterpreted, never discarded.
        static let ack = "sublight.acknowledged"
        static let freq = "sublight.frequency"
        static let schedEnabled = "sublight.schedule.enabled"
        static let schedStart = "sublight.schedule.start"
        static let schedEnd = "sublight.schedule.end"
        static let schedFreq = "sublight.schedule.frequency"
        static let hotKey = "sublight.hotkey"
        static let schedMode = "sublight.schedule.mode"
        static let latitude = "sublight.location.latitude"
        static let longitude = "sublight.location.longitude"
        static let city = "sublight.location.city"
    }

    /// Calibration is keyed by hardware model, so moving to a different Mac
    /// transparently falls back to defaults instead of using numbers measured
    /// on someone else's machine.
    private func calKey(_ suffix: String) -> String {
        "sublight.cal.\(hardware.modelIdentifier).\(suffix)"
    }

    // MARK: Init

    init() {
        advancedMode = defaults.bool(forKey: Keys.advanced)
        onboardingSeen = defaults.bool(forKey: Keys.ack)
        consentGranted = consent.isGranted
        consentPending = consent.isPending
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        scheduleEnabled = defaults.bool(forKey: Keys.schedEnabled)
        if let m = defaults.object(forKey: Keys.schedStart) as? Int { scheduleStartMinutes = m }
        if let m = defaults.object(forKey: Keys.schedEnd) as? Int { scheduleEndMinutes = m }
        if let f = defaults.object(forKey: Keys.schedFreq) as? Double {
            scheduleFrequency = min(max(f, Self.freqMin), Self.freqMax)
        }
        if let raw = defaults.string(forKey: Keys.schedMode),
           let mode = ScheduleMode(rawValue: raw) {
            scheduleMode = mode
        }
        latitude = defaults.object(forKey: Keys.latitude) as? Double ?? 0
        longitude = defaults.object(forKey: Keys.longitude) as? Double ?? 0
        cityID = defaults.string(forKey: Keys.city) ?? CityDirectory.customID

        // First run: pre-fill from the Mac's own time zone. IANA identifiers
        // are city-named, so this usually lands on something sensible without
        // asking for anything — no permission, no network, no typing.
        if !Solar.isValidLocation(latitude: latitude, longitude: longitude),
           let guess = CityDirectory.currentGuess() {
            latitude = guess.latitude
            longitude = guess.longitude
            cityID = guess.id
            Log.lifecycle.info("location pre-filled from time zone")
        }

        if let hz = defaults.object(forKey: calKey("frequency")) as? Double {
            calibratedFrequency = min(max(hz, Self.freqMin), Self.freqMax)
        }
        calibratedDate = defaults.object(forKey: calKey("date")) as? Date
        if let raw = defaults.string(forKey: Keys.hotKey),
           let choice = HotKeyChoice(rawValue: raw) {
            hotKey = choice
        }

        guard hardware.isAppleSilicon else {
            available = false
            statusText = "Sublight requires an Apple Silicon MacBook with a backlit keyboard."
            return
        }

        // Capability probe BEFORE any engine use. A drifted private API is
        // undefined behavior at the ABI level (a misdeclared register-class
        // argument silently corrupts every later argument), so on failure the
        // app disables itself rather than guess.
        let report = validateAPISurface()
        probeReport = report
        guard report.passed else {
            available = false
            statusText = "Private API changed on this macOS build (\(report.macOSBuild)); Sublight disabled itself."
            Log.probe.error("API surface validation failed: \(report.text, privacy: .public)")
            showProbeFailureAlert(report)
            return
        }

        do {
            let storedFloor = defaults.object(forKey: Keys.floor) as? Float ?? 0.0625
            let c = try BacklightController(floor: storedFloor)
            c.engine.restoreLevel = 0.4
            controller = c
            available = true

            // Crash recovery: if the previous process died mid-dither
            // (kill -9, panic, force quit) the dirty flag — or the legacy
            // UserDefaults marker — is still present; restore before anything
            // else touches the backlight.
            let recovery = c.recoverFromCrashIfNeeded()
            if recovery != .clean {
                Log.lifecycle.warning("crash recovery at launch: \(String(describing: recovery), privacy: .public)")
            }

            c.engine.onStateChange = { [weak self] s in
                MainActor.assumeIsolated { self?.engineState = s }
            }

            if let b = defaults.object(forKey: Keys.brightness) as? Double {
                brightness = min(max(b, 0), 1)
            }
            if let f = defaults.object(forKey: Keys.freq) as? Double {
                frequencyHz = min(max(f, Self.freqMin), Self.freqMax)
            }

            sleepWake = SleepWakeObserver(
                onSuspend: { [weak self] t in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        Log.lifecycle.info("suspend (\(t.rawValue, privacy: .public))")
                        self.systemSuspended = true
                    }
                },
                onResume: { [weak self] t in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        Log.lifecycle.info("resume (\(t.rawValue, privacy: .public))")
                        self.systemSuspended = false
                        if self.scheduleEnabled { self.lastInWindow = nil; self.reevaluateSchedule(force: true) }
                    }
                }
            )

            // Normal exit: a SYNCHRONOUS restore on the engine queue. The
            // notification is posted on the main thread during terminate, so
            // this closure runs before the process exits; an async Task here
            // would not be guaranteed to.
            terminateToken = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Forces once we HAVE touched the hardware — calibration
                    // disables auto-brightness with a direct bridge write that
                    // never engages the engine, so a plain restoreNow() (gated
                    // on `engaged`) could leave the ALS off. But it commands
                    // NOTHING if this session never touched the backlight:
                    // launching, not dimming, and quitting must not overwrite
                    // the level and auto-brightness the user already had.
                    self?.controller?.restoreOnExit(to: 0.4)
                    Log.lifecycle.info("terminating: exit restore evaluated")
                }
            }

            // SIGTERM / SIGINT / SIGHUP: restore on the engine queue, then
            // exit. Same gate as terminate — unlike the CLI, the app installs
            // these handlers at launch whether or not it ever dims, so an
            // unconditional force would have the same quiet-case bug.
            signalRestore = SignalRestore { [weak c] in
                c?.restoreOnExit(to: 0.4)
            }

            if scheduleEnabled {
                startScheduleTimer()
                reevaluateSchedule(force: true)
            }

            applyHotKey()
            showOnboardingIfNeeded()
        } catch {
            available = false
            statusText = "\(error)"
            Log.bridge.error("backlight engine unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Derived

    var floor: Double { Double(controller?.floor ?? 0.0625) }

    var associationText: String {
        let hz = frequencyHz
        let band: String
        if hz <= 4 { band = "associated with deep, drowsy relaxation" }
        else if hz <= 7 { band = "associated with calm, relaxed states" }
        else { band = "associated with alert, focused states" }
        var s = String(format: "%.1f Hz — %@ in entrainment research. Effects unproven.", hz, band)
        if hz >= AppState.freqMax - 0.001 {
            s += " This is the top of the range: above it macOS stops honouring the dither and the light drops out in multi-second gaps."
        }
        return s
    }

    // MARK: Consent

    /// Shared with the CLI, beside the dirty flag. See ConsentMarker.
    private let consent = ConsentMarker()

    /// The consent copy, verbatim. Changing a word here means bumping
    /// `ConsentMarker.currentVersion` so everyone is asked again.
    static let consentBody = """
        Sublight dims your keyboard backlight below the system minimum by \
        switching it on and off several times per second (3-8 Hz). Every mode \
        produces visible flicker in the 3-30 Hz range. Flashing light in this \
        range can trigger seizures in people with photosensitive epilepsy.

        Do not enable Sublight if you - or anyone who can see your keyboard - \
        has photosensitive epilepsy or is sensitive to flashing light. Stop \
        immediately if you notice discomfort, dizziness, nausea, eye strain, \
        or any unusual visual sensation.

        If the backlight ever appears stuck after a crash, press the keyboard \
        brightness keys or relaunch Sublight.
        """

    /// Ask once, before anything is commanded. Returns whether dimming may
    /// proceed. Declining records nothing and changes nothing — the point is
    /// that a decline is indistinguishable from never having asked.
    ///
    /// AppKit rather than a SwiftUI `.alert`: the popover this is triggered
    /// from is a MenuBarExtra window that dismisses when it loses focus, and
    /// an alert hosted inside it would go with it.
    private func requestConsentIfNeeded() -> Bool {
        if consentGranted { return true }
        let alert = NSAlert()
        alert.messageText = "Before you enable Sublight"
        alert.informativeText = Self.consentBody
        alert.alertStyle = .warning
        // First button added is the default (rightmost, Return-activated), so
        // the safe answer is the one you get by reflex.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "I Understand - Enable")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else {
            Log.lifecycle.notice("consent declined — dimming not enabled, nothing commanded")
            return false
        }
        consent.record()            // also clears any pending flag
        consentGranted = consent.isGranted
        consentPending = consent.isPending
        return consentGranted
    }

    /// The deferred path: the popover's "Review and enable". Raises the same
    /// alert the direct toggle would, and — because the whole point is that a
    /// scheduled dim was missed — engages immediately if that window is still
    /// open rather than making the user wait for the next transition.
    func reviewConsentAndEnable() {
        guard requestConsentIfNeeded() else {
            Log.lifecycle.notice("deferred consent: declined from the popover; pending flag kept")
            return
        }
        guard scheduleEnabled, inScheduleWindow() else {
            Log.lifecycle.notice("deferred consent: granted, but the schedule window is no longer active")
            return
        }
        if advancedMode { frequencyHz = scheduleFrequency }
        isEnabled = true
        lastInWindow = true
        Log.lifecycle.notice("deferred consent: granted and the schedule window is still active — engaging")
    }

    /// THE enable path. Every route that turns dimming on for a person present
    /// at the machine goes through here so the gate cannot be walked around.
    func setEnabled(_ on: Bool) {
        guard on else { isEnabled = false; return }
        guard requestConsentIfNeeded() else { return }
        isEnabled = true
    }

    func setPreset(_ hz: Double) {
        guard requestConsentIfNeeded() else { return }
        frequencyHz = hz
    }

    /// The frequency actually in use: the custom value in Advanced mode, the
    /// calibrated steadiest value in Simple mode, or the shipped default.
    var effectiveFrequency: Double {
        advancedMode ? frequencyHz : (calibratedFrequency ?? Self.simpleFreq)
    }

    /// THE running decision: the user wants dimming AND the machine is awake
    /// with an active session. Every start/stop flows from this one value
    /// (see the header comment and DimmingPolicy).
    var effectiveRunning: Bool {
        DimmingPolicy.effectiveRunning(userEnabled: isEnabled, systemSuspended: systemSuspended)
    }

    /// Fill level for the menu bar glyph (StatusGlyph): hollow unless
    /// effectively running — so suspended reads as hollow even while the
    /// toggle is on — otherwise the frequency in use bucketed to the nearest
    /// preset: Low 3 Hz → 0.3, Medium 6 Hz → 0.5, High 8 Hz → 0.8.
    var glyphFraction: CGFloat {
        CGFloat(DimmingPolicy.glyphFraction(userEnabled: isEnabled, systemSuspended: systemSuspended,
                                            frequencyHz: effectiveFrequency))
    }

    /// A plain-text report for bug reports and support threads.
    ///
    /// PRIVACY: deliberately reports the chosen *city* — or merely the fact
    /// that custom coordinates are set — never the coordinates themselves.
    /// This text is written to be pasted into public issue trackers, and
    /// someone's latitude and longitude to four decimal places locates their
    /// home to within about ten metres. Nothing here identifies a person or a
    /// machine.
    var diagnosticsReport: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"

        let locationDescription: String
        if let city = selectedCity {
            locationDescription = city.displayName
        } else if hasLocation {
            locationDescription = "custom coordinates (withheld)"
        } else {
            locationDescription = "not set"
        }

        var lines: [String] = [
            "Sublight \(version) (\(build))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Hardware: \(hardware.summary)",
            "Apple Silicon: \(hardware.isAppleSilicon ? "yes" : "no")",
            "",
            "Engine: \(available ? "available" : "UNAVAILABLE")",
        ]
        if !statusText.isEmpty {
            lines.append("Engine error: \(statusText)")
        }
        if let c = controller {
            lines.append("Keyboard ID: \(c.keyboardID)")
            lines.append(String(format: "Floor: %.4f%@", c.floor,
                                isCalibrated ? " (calibrated)" : " (default — not calibrated)"))
        }

        lines += [
            "",
            "Mode: \(advancedMode ? "advanced" : "simple")",
            "Dimming: \(isEnabled ? "on" : "off")\(systemSuspended ? " (suspended by system)" : "")",
            "Engine: \(engineState.isRunning ? "running" : "stopped")",
            String(format: "Effective frequency: %.1f Hz", effectiveFrequency),
            String(format: "Brightness: %.0f%%", brightness * 100),
            "Calibrated: \(isCalibrated ? String(format: "yes, %.1f Hz", calibratedFrequency ?? 0) : "no")",
            "",
            "Schedule: \(scheduleEnabled ? scheduleMode.label : "off")",
        ]
        if scheduleEnabled, scheduleMode == .solar {
            lines.append("Location: \(locationDescription)")
            if let t = solarTimes {
                switch t.condition {
                case .normal:
                    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
                    lines.append("Sunset/sunrise: \(t.sunset.map(f.string(from:)) ?? "—") / \(t.sunrise.map(f.string(from:)) ?? "—")")
                case .polarDay:   lines.append("Solar: polar day")
                case .polarNight: lines.append("Solar: polar night")
                }
            }
        }

        lines += [
            "Shortcut: \(hotKey == .off ? "off" : hotKey.label)\(hotKeyConflict ? " (CONFLICT)" : "")",
            "Launch at login: \(launchAtLogin ? "on" : "off")",
        ]
        return lines.joined(separator: "\n")
    }

    func markOnboardingSeen() {
        onboardingSeen = true
        defaults.set(true, forKey: Keys.ack)
        // The gate is the "start here" moment, so always land on the calm
        // surface. A fresh install is already Simple; this also covers the
        // Safety › "Show again" path, where a saved Advanced state would
        // otherwise drop the reader straight back into the experimenter UI.
        if advancedMode { advancedMode = false }
    }

    /// Show the first-run walkthrough again (from Settings › Safety).
    func showOnboardingAgain() {
        onboardingSeen = false
        defaults.removeObject(forKey: Keys.ack)
        showOnboardingIfNeeded()
    }

    /// One-line state for the popover header.
    var statusLine: String {
        guard available else { return "Unavailable" }
        let viaSchedule = scheduleEnabled && (lastInWindow ?? false) && isEnabled
        if isEnabled {
            var s = "Dimming"
            if advancedMode { s += String(format: " · %.1f Hz", frequencyHz) }
            if viaSchedule, let (_, end) = scheduleWindow() {
                s += " · until " + Self.shortTime(end)
            }
            return s
        }
        if scheduleEnabled {
            guard let (start, _) = scheduleWindow() else {
                return scheduleMode == .solar && !hasLocation
                    ? "Schedule needs a location"
                    : "Scheduled"
            }
            return "Scheduled · from " + Self.shortTime(start)
        }
        return "Off"
    }

    private static func shortTime(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let suffix = h < 12 ? "AM" : "PM"
        var hour = h % 12; if hour == 0 { hour = 12 }
        return m == 0 ? "\(hour) \(suffix)" : String(format: "%d:%02d %@", hour, m, suffix)
    }

    // Time-of-day <-> Date bridges for the DatePickers.
    var scheduleStartDate: Date {
        get { minutesToDate(scheduleStartMinutes) }
        set { scheduleStartMinutes = dateToMinutes(newValue) }
    }
    var scheduleEndDate: Date {
        get { minutesToDate(scheduleEndMinutes) }
        set { scheduleEndMinutes = dateToMinutes(newValue) }
    }

    // MARK: Apply

    /// Slider position → duty fraction. 0.15…0.85 is the range the engine
    /// can hold (DitherSchedule.dutyRange); brightness IS duty.
    private func duty() -> Double { 0.15 + brightness * 0.70 }

    /// Forward intent to the engine. Start and stop (with their cosmetic
    /// duty ramps) happen only on a transition of `effectiveRunning`; while
    /// running, frequency and duty changes are retunes — setDuty is
    /// phase-continuous and issues no XPC of its own, so slider drags need
    /// no debouncing.
    private func apply() {
        guard let c = controller else { return }

        // Backstop. Every enable path is gated above; if one ever is not,
        // this is what stops it reaching the hardware.
        if effectiveRunning, !consentGranted {
            Log.lifecycle.error("dim requested without recorded consent — refusing to engage")
        }
        let running = effectiveRunning && consentGranted
        let f = effectiveFrequency
        let d = duty()
        // Source of truth is the ENGINE, not a shadow bool: calibration and
        // panicRestore can stop the engine out-of-band, and a stale shadow
        // would strand the UI "on but not dimming" (setFrequency/setDuty are
        // no-ops on a stopped engine).
        let engineRunning = c.engine.isRunning

        if running {
            c.frequencyHz = f
            // start() is idempotent on the engine queue: a full start when
            // stopped, an in-place retune (which also cancels any ramp-down)
            // when running. Calling it unconditionally makes apply() robust to
            // the engineRunning snapshot being stale — e.g. re-enabling during
            // the 0.25 s disable ramp, where the ramp may complete between the
            // sync read and this async call. rampFrom (the enable fade) only
            // takes effect on a true start; it is ignored on a retune.
            if !engineRunning { Log.engine.info("dim on: \(f, privacy: .public) Hz") }
            c.engine.start(frequencyHz: f, duty: d,
                           rampFrom: engineRunning ? nil : DitherEngine.rampEndpointDuty)
        } else {
            if engineRunning {
                if systemSuspended { Log.engine.info("dim suspended") } else { Log.engine.info("dim off") }
            }
            // Idempotent: a no-op if the engine is already stopped. Sleep/
            // session suspend restores immediately — the display is going away
            // and a ramp would just delay the hand-back.
            c.engine.stopAndRestore(ramp: systemSuspended ? 0 : 0.25)
        }

        defaults.set(brightness, forKey: Keys.brightness)
        defaults.set(frequencyHz, forKey: Keys.freq)
    }

    private func onAdvancedChanged() {
        defaults.set(advancedMode, forKey: Keys.advanced)
        apply()
    }

    // MARK: Schedule

    private func minutesToDate(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private func dateToMinutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private func currentMinutes() -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    /// True when the user has supplied plausible coordinates.
    var hasLocation: Bool {
        Solar.isValidLocation(latitude: latitude, longitude: longitude)
    }

    /// Today's solar times, or nil when no usable location is set.
    var solarTimes: SolarTimes? {
        guard hasLocation else { return nil }
        return Solar.times(latitude: latitude, longitude: longitude, date: Date())
    }

    /// The active dimming window as minutes-of-day, or nil if there isn't one.
    ///
    /// Solar mode reuses the same arithmetic as fixed mode. When the machine's
    /// time zone matches its coordinates — the normal case — (sunset, sunrise)
    /// wraps past midnight and `ScheduleWindow` takes the wrapping branch. If
    /// someone enters coordinates from a very different time zone the pair can
    /// arrive in the opposite order; that is handled too, and yields "dim while
    /// it is night *there*", which is a defensible reading of the request.
    private func scheduleWindow() -> (start: Int, end: Int)? {
        switch scheduleMode {
        case .fixed:
            return (scheduleStartMinutes, scheduleEndMinutes)
        case .solar:
            guard let t = solarTimes else { return nil }
            switch t.condition {
            case .polarNight:
                return (0, 24 * 60)          // never light — dim all day
            case .polarDay:
                return nil                   // never dark — never dim
            case .normal:
                guard let rise = t.sunrise, let set = t.sunset else { return nil }
                return (Solar.minutesOfDay(set), Solar.minutesOfDay(rise))
            }
        }
    }

    private func inScheduleWindow() -> Bool {
        guard let (s, e) = scheduleWindow() else { return false }
        return ScheduleWindow.contains(now: currentMinutes(), start: s, end: e)
    }

    private func persistSchedule() {
        defaults.set(scheduleStartMinutes, forKey: Keys.schedStart)
        defaults.set(scheduleEndMinutes, forKey: Keys.schedEnd)
    }

    private func onScheduleModeChanged() {
        defaults.set(scheduleMode.rawValue, forKey: Keys.schedMode)
        lastInWindow = nil
        reevaluateSchedule(force: true)
    }

    private func onCityChanged() {
        defaults.set(cityID, forKey: Keys.city)
        guard let city = CityDirectory.city(id: cityID) else { return }  // custom: leave as typed
        latitude = city.latitude
        longitude = city.longitude
    }

    /// The chosen city, or nil when coordinates were entered by hand.
    var selectedCity: CityLocation? { CityDirectory.city(id: cityID) }

    private func onLocationChanged() {
        defaults.set(latitude, forKey: Keys.latitude)
        defaults.set(longitude, forKey: Keys.longitude)
        guard scheduleEnabled, scheduleMode == .solar else { return }
        lastInWindow = nil
        reevaluateSchedule(force: true)
    }

    private func onScheduleChanged() {
        defaults.set(scheduleEnabled, forKey: Keys.schedEnabled)
        if scheduleEnabled {
            startScheduleTimer()
            lastInWindow = nil
            reevaluateSchedule(force: true)
        } else {
            stopScheduleTimer()
            lastInWindow = nil
            // Removing the schedule retires the question it raised.
            if consentPending {
                consent.clearPending()
                consentPending = false
            }
        }
    }

    private func startScheduleTimer() {
        guard scheduleTimer == nil else { return }
        // 60 s cadence; timing is approximate (±a few minutes) if the app has
        // been idle and napped — fine for a dimming schedule.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluateSchedule(force: false) }
        }
    }
    private func stopScheduleTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
    }

    /// Act on window transitions only (enter → dim on, exit → dim off), so the
    /// user can override manually between transitions.
    private func reevaluateSchedule(force: Bool) {
        guard scheduleEnabled else { return }
        let now = inScheduleWindow()
        if force || now != lastInWindow {
            // Deliberately NOT the consent alert: the schedule fires
            // unattended, and a modal nobody is there to answer would block the
            // app until they came back. Automation does not get to be the first
            // thing that turns dimming on — but it does not get to fail
            // silently either, so the skip is recorded and the popover asks.
            switch DimmingPolicy.scheduleTransition(enteringWindow: now, consentGranted: consentGranted) {
            case .engage:
                if advancedMode { frequencyHz = scheduleFrequency }
                isEnabled = true
            case .deferForConsent:
                consent.setPending()
                consentPending = true
                Log.lifecycle.notice("schedule: window entered without consent — skipped and deferred to the popover")
            case .disengage:
                isEnabled = false
            }
        }
        lastInWindow = now
    }

    // MARK: Launch at login

    private func updateLoginItem() {
        guard !isUpdatingLoginItem else { return }
        isUpdatingLoginItem = true
        defer { isUpdatingLoginItem = false }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            print("Sublight: login item update failed: \(error)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: Actions

    func restoreSystemControl() {
        isEnabled = false
        // The toggle's apply() already ramps and restores; this is the
        // explicit button, so make the hand-back immediate and certain.
        controller?.engine.restoreNow()
    }

    func restoreAndQuit() {
        controller?.engine.restoreNow()
        Log.lifecycle.info("quit: backlight restored")
        NSApp.terminate(nil)
    }

    // MARK: Global hotkey

    /// Toggle dimming from anywhere. Ignores the request when the engine is
    /// unavailable. It is NOT a way around the consent gate — it routes through
    /// setEnabled, which raises the modal if consent has never been given.
    func toggleDimming() {
        guard available else { return }
        setEnabled(!isEnabled)
        Log.lifecycle.info("hotkey toggled dimming")
    }

    private func applyHotKey() {
        defaults.set(hotKey.rawValue, forKey: Keys.hotKey)
        hotKeyManager.unregister()
        hotKeyConflict = false
        guard let code = hotKey.keyCode, let mods = hotKey.modifiers else { return }
        let ok = hotKeyManager.register(keyCode: code, modifiers: mods) { [weak self] in
            Task { @MainActor in self?.toggleDimming() }
        }
        hotKeyConflict = !ok
    }

    // MARK: Capability probe failure

    /// Shown once at launch when the private-API surface does not match the
    /// build Sublight was verified against. Deferred one turn so the alert
    /// appears after the app has finished launching.
    private func showProbeFailureAlert(_ report: ValidationReport) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Sublight disabled itself on \(report.macOSBuild)"
            alert.informativeText = """
            The private CoreBrightness interface Sublight depends on does not match \
            what it was verified against, so driving it could cause undefined behavior. \
            Sublight will not touch the keyboard backlight on this build.

            Please file an issue at github.com/HypnoxAI/sublight and include this report:

            \(report.text)
            """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Onboarding

    /// Shown once, before anything touches the backlight. Built in AppKit
    /// rather than as a SwiftUI Window scene because an LSUIElement app has no
    /// natural moment to present a scene at launch.
    private func showOnboardingIfNeeded() {
        guard !onboardingSeen, onboardingWindow == nil else { return }

        let view = OnboardingView { [weak self] calibrateNow in
            guard let self else { return }
            self.markOnboardingSeen()
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            if calibrateNow {
                self.requestCalibration = true
                self.openSettingsWindow()
            }
        }
        .environmentObject(self)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Sublight"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Set when onboarding ends with "Calibrate now"; Settings observes this
    /// and opens the calibration sheet.
    @Published var requestCalibration = false

    /// Open Settings from outside the view hierarchy. The SwiftUI
    /// `openSettings` action is only reachable from a View's environment, so
    /// this goes through the responder chain instead. The selector was
    /// renamed in macOS 13, hence the fallback.
    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.orderFrontRegardless()
        }
    }

    /// Persist a finished calibration and adopt it immediately.
    func adoptCalibration(_ r: CalibrationController.Result) {
        controller?.floor = r.floor
        defaults.set(r.floor, forKey: Keys.floor)

        calibratedFrequency = min(max(r.frequency, Self.freqMin), Self.freqMax)
        defaults.set(calibratedFrequency, forKey: calKey("frequency"))
        defaults.set(r.floor, forKey: calKey("floor"))

        let now = Date()
        calibratedDate = now
        defaults.set(now, forKey: calKey("date"))

        brightness = min(max(r.brightness, 0), 1)
        if !advancedMode { frequencyHz = calibratedFrequency ?? frequencyHz }
        apply()
    }

    func clearCalibration() {
        calibratedFrequency = nil
        calibratedDate = nil
        for k in ["frequency", "floor", "date"] { defaults.removeObject(forKey: calKey(k)) }
    }

    /// Fresh-install state (revokes consent and re-shows onboarding). Leaves the system
    /// login item alone.
    func resetToDefaults() {
        scheduleEnabled = false
        isEnabled = false
        controller?.panicRestore(to: 0.4)
        advancedMode = false
        brightness = 0.5
        frequencyHz = FrequencyPreset.high
        scheduleStartMinutes = 21 * 60
        scheduleEndMinutes = 7 * 60
        scheduleFrequency = FrequencyPreset.high
        onboardingSeen = false
        consent.clear()             // clears the pending flag too
        consentGranted = false
        consentPending = false
        clearCalibration()
        for key in [Keys.ack, Keys.brightness, Keys.freq, Keys.advanced, Keys.floor,
                    Keys.schedEnabled, Keys.schedStart, Keys.schedEnd, Keys.schedFreq] {
            defaults.removeObject(forKey: key)
        }
    }
}
