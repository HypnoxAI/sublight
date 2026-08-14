// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  AppState.swift
//  SublightApp
//
//  Owns the BacklightController and app state.
//
//  Frequency: continuous, sub-floor dithering (SPEC §3/§5).
//    Simple   → on/off + brightness, fixed 9 Hz.
//    Advanced → 3/6/9 Hz presets + 2–12 Hz custom slider + separate brightness.
//  All mode use gated behind a one-time photosensitivity acknowledgment.
//
//  Schedule (manual time; sunset/sunrise is a later addition): transition-based
//  auto-dim between a start and end time. Acts only on window ENTER/EXIT so the
//  user can still override manually between transitions. In Simple it toggles
//  the 9 Hz dim; in Advanced it also applies `scheduleFrequency`.
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
    static let freqMax = 12.0
    static let simpleFreq = 9.0
    static let presets: [(label: String, hz: Double)] = [("Low", 3), ("Medium", 6), ("High", 9)]

    // MARK: Published UI state

    @Published var isEnabled: Bool = false { didSet { apply() } }
    @Published var frequencyHz: Double = 9.0 { didSet { scheduleApply() } }
    @Published var brightness: Double = 0.5 { didSet { scheduleApply() } }
    @Published var advancedMode: Bool = false { didSet { onAdvancedChanged() } }
    @Published var acknowledged: Bool = false
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
    @Published var scheduleFrequency: Double = 9.0 { didSet { defaults.set(scheduleFrequency, forKey: Keys.schedFreq) } }
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
    private var napActivity: NSObjectProtocol?
    private var watchdog: Timer?
    private var scheduleTimer: Timer?
    private var fadeTask: Task<Void, Never>?
    private var applyDebounce: Task<Void, Never>?
    private let hotKeyManager = HotKeyManager()
    private var onboardingWindow: NSWindow?
    /// Tracks the enabled state across applies so we only fade on an actual
    /// transition — not on every slider tick.
    private var wasEnabled = false
    /// Last level we commanded, so a fade starts from where the light is.
    private var lastLevel: Float = 0.4
    private var lastInWindow: Bool?
    private var isUpdatingLoginItem = false

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let brightness = "sublight.brightness"
        static let floor = "sublight.floor"
        static let advanced = "sublight.advanced"
        static let ack = "sublight.acknowledged"
        static let freq = "sublight.frequency"
        static let schedEnabled = "sublight.schedule.enabled"
        static let schedStart = "sublight.schedule.start"
        static let schedEnd = "sublight.schedule.end"
        static let schedFreq = "sublight.schedule.frequency"
        /// Set while dimming is engaged, cleared on every clean restore. If
        /// it survives to the next launch, the previous run was killed
        /// mid-dither and the backlight needs rescuing.
        static let activeMarker = "sublight.active"
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
        acknowledged = defaults.bool(forKey: Keys.ack)
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

        do {
            let storedFloor = defaults.object(forKey: Keys.floor) as? Float ?? 0.0625
            let c = try BacklightController(floor: storedFloor)
            controller = c
            available = true

            // Crash recovery. The marker is written while dimming is engaged
            // and cleared on every clean restore, so if it is still set at
            // launch the previous run was killed mid-dither (kill -9, panic,
            // force quit) and the backlight was left wherever the dither
            // stopped — possibly off. Rescue it before doing anything else.
            if defaults.bool(forKey: Keys.activeMarker) {
                Log.lifecycle.warning("previous session did not restore cleanly — restoring backlight")
                c.panicRestore(to: 0.4)
                defaults.removeObject(forKey: Keys.activeMarker)
            }

            if let b = defaults.object(forKey: Keys.brightness) as? Double {
                brightness = min(max(b, 0), 1)
            }
            if let f = defaults.object(forKey: Keys.freq) as? Double {
                frequencyHz = min(max(f, Self.freqMin), Self.freqMax)
            }

            sleepWake = SleepWakeObserver(
                onSleep: { [weak self] in
                    Task { @MainActor in self?.controller?.suspendHold() }
                },
                onWake: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.scheduleEnabled { self.lastInWindow = nil; self.reevaluateSchedule(force: true) }
                        else if self.isEnabled { self.apply() }
                    }
                }
            )

            terminateToken = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.fadeTask?.cancel()
                    self?.controller?.panicRestore()
                    self?.defaults.removeObject(forKey: Keys.activeMarker)
                    Log.lifecycle.info("terminating: backlight restored")
                }
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
        if hz >= 10 { s += " Near the top of the range it may smooth out or stop modulating." }
        return s
    }

    func setPreset(_ hz: Double) { frequencyHz = hz }

    /// The frequency actually in use: the custom value in Advanced mode, the
    /// calibrated flicker-free value in Simple mode, or the shipped default.
    var effectiveFrequency: Double {
        advancedMode ? frequencyHz : (calibratedFrequency ?? Self.simpleFreq)
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
            "Dimming: \(isEnabled ? "on" : "off")",
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

    func acknowledge() {
        acknowledged = true
        defaults.set(true, forKey: Keys.ack)
        // The gate is the "start here" moment, so always land on the calm
        // surface. A fresh install is already Simple; this also covers the
        // Safety › "Show again" path, where a saved Advanced state would
        // otherwise drop the reader straight back into the experimenter UI.
        if advancedMode { advancedMode = false }
    }

    /// Re-arm the first-run photosensitivity gate (from Settings › Safety).
    func showAcknowledgmentAgain() {
        acknowledged = false
        defaults.removeObject(forKey: Keys.ack)
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

    private func duty() -> Float { Float(0.15 + brightness * 0.70) }

    /// Coalesce rapid slider changes. Dragging a slider fires continuously,
    /// and every call restarts the dither timer — debouncing keeps the light
    /// smooth while dragging instead of stuttering on each tick.
    private func scheduleApply() {
        applyDebounce?.cancel()
        applyDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    private func apply() {
        guard let c = controller else { return }

        let enabling = isEnabled && !wasEnabled
        let disabling = !isEnabled && wasEnabled
        wasEnabled = isEnabled

        if isEnabled {
            let f = advancedMode ? frequencyHz : (calibratedFrequency ?? Self.simpleFreq)
            c.period = 1.0 / f
            let target = duty() * c.floor
            startKeepAlive()
            defaults.set(true, forKey: Keys.activeMarker)

            if enabling {
                Log.engine.info("dim on: \(f, privacy: .public) Hz")
                fade(from: lastLevel, to: target, duration: 0.35)
            } else {
                fadeTask?.cancel()
                c.setLevel(target)
                lastLevel = target
            }
        } else {
            if disabling {
                Log.engine.info("dim off")
                // Ramp back up, THEN hand control to the system. panicRestore
                // is still called unconditionally so the restore can't be
                // lost if the fade is interrupted.
                fade(from: lastLevel, to: 0.4, duration: 0.25) { [weak self] in
                    self?.finishDisable()
                }
            } else {
                finishDisable()
            }
        }

        defaults.set(brightness, forKey: Keys.brightness)
        defaults.set(frequencyHz, forKey: Keys.freq)
    }

    private func finishDisable() {
        stopKeepAlive()
        controller?.panicRestore(to: 0.4)
        lastLevel = 0.4
        defaults.removeObject(forKey: Keys.activeMarker)
    }

    /// Ramp between two levels instead of snapping. Purely cosmetic, so every
    /// restore path cancels it — a half-finished fade must never be able to
    /// strand the backlight.
    private func fade(from start: Float, to target: Float, duration: Double,
                      completion: (() -> Void)? = nil) {
        fadeTask?.cancel()
        let steps = 14
        fadeTask = Task { [weak self] in
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Float(i) / Float(steps)
                let level = start + (target - start) * t
                self?.controller?.setLevel(level)
                self?.lastLevel = level
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            completion?()
        }
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
        guard scheduleEnabled, acknowledged else { return }
        let now = inScheduleWindow()
        if force || now != lastInWindow {
            if now {
                if advancedMode { frequencyHz = scheduleFrequency }
                isEnabled = true
            } else {
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

    // MARK: Keep-alive

    private func startKeepAlive() {
        if napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Sublight keyboard backlight dither")
        }
        reassertSuppression()
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reassertSuppression() }
            }
        }
    }
    private func stopKeepAlive() {
        watchdog?.invalidate()
        watchdog = nil
        if let a = napActivity {
            ProcessInfo.processInfo.endActivity(a)
            napActivity = nil
        }
    }
    private func reassertSuppression() {
        guard let c = controller, isEnabled else { return }
        c.bridge.setAutoBrightness(false, c.keyboardID)
        _ = c.bridge.setIdleDimmingSuspended(true, c.keyboardID)
    }

    // MARK: Actions

    func restoreSystemControl() {
        fadeTask?.cancel()
        applyDebounce?.cancel()
        isEnabled = false
        wasEnabled = false
        finishDisable()
    }

    func restoreAndQuit() {
        fadeTask?.cancel()
        applyDebounce?.cancel()
        stopKeepAlive()
        controller?.panicRestore()
        defaults.removeObject(forKey: Keys.activeMarker)
        Log.lifecycle.info("quit: backlight restored")
        NSApp.terminate(nil)
    }

    // MARK: Global hotkey

    /// Toggle dimming from anywhere. Ignores the request when the engine is
    /// unavailable or the safety gate hasn't been cleared — a global shortcut
    /// must not be a way around the acknowledgment.
    func toggleDimming() {
        guard available, acknowledged else { return }
        isEnabled.toggle()
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

    // MARK: Onboarding

    /// Shown once, before anything touches the backlight. Built in AppKit
    /// rather than as a SwiftUI Window scene because an LSUIElement app has no
    /// natural moment to present a scene at launch.
    private func showOnboardingIfNeeded() {
        guard !acknowledged, onboardingWindow == nil else { return }

        let view = OnboardingView { [weak self] calibrateNow in
            guard let self else { return }
            self.acknowledge()
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

    /// Fresh-install state (re-shows the acknowledgment). Leaves the system
    /// login item alone.
    func resetToDefaults() {
        scheduleEnabled = false
        isEnabled = false
        controller?.panicRestore(to: 0.4)
        advancedMode = false
        brightness = 0.5
        frequencyHz = 9.0
        scheduleStartMinutes = 21 * 60
        scheduleEndMinutes = 7 * 60
        scheduleFrequency = 9.0
        acknowledged = false
        clearCalibration()
        for key in [Keys.ack, Keys.brightness, Keys.freq, Keys.advanced, Keys.floor,
                    Keys.schedEnabled, Keys.schedStart, Keys.schedEnd, Keys.schedFreq] {
            defaults.removeObject(forKey: key)
        }
    }
}
