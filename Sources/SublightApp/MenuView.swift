// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  MenuView.swift
//  SublightApp
//
//  The menu-bar popover. Slimmed to just the controls you touch often:
//  a status line, a Simple/Advanced switch, the dim controls, and the
//  schedule. Set-once plumbing (login item, reset, safety, about) lives in
//  the Settings window, reached via the gear.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import SwiftUI
import AppKit
import SublightKit

struct MenuView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            if !state.available {
                unavailableView
            } else if !state.acknowledged {
                acknowledgmentView
            } else {
                controls
            }
        }
        .padding(13)
        .frame(width: 288)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sublight").font(.headline)
                if state.available && state.acknowledged {
                    Text(state.statusLine)
                        .font(.caption)
                        .foregroundStyle(state.isEnabled ? Color.green : Color.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if state.available && state.acknowledged {
                Button {
                    showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Settings")
            }
        }
    }

    /// Open Settings and pull it to the front.
    ///
    /// Two things conspire against this. First, `openSettings()` builds the
    /// window asynchronously, so activating beforehand raises nothing —
    /// the raise has to happen on a later runloop pass. Second, Sublight is
    /// an LSUIElement accessory app and is never the "active" app while
    /// you're in the menu bar, so `activate()` alone still leaves the window
    /// behind whatever you were using; it needs an explicit
    /// `orderFrontRegardless()`.
    ///
    /// The Settings window is found by capability rather than by SwiftUI's
    /// private window identifier: the MenuBarExtra popover cannot become a
    /// main window, so the first visible `canBecomeMain` window is ours.
    private func showSettings() {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: {
                $0.canBecomeMain && $0.isVisible
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // MARK: Gates

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backlight engine unavailable").font(.subheadline)
            Text("Sublight requires an Apple Silicon MacBook with a backlit keyboard. It does not run on Intel Macs or with external keyboards.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !state.statusText.isEmpty {
                Text(state.statusText).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
    }

    private var acknowledgmentView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before you start").font(.subheadline).bold()
            Text("Sublight dims the keyboard below its normal minimum by rapidly modulating the backlight. This produces flicker in a frequency range that can trigger seizures in people with photosensitive epilepsy. The light is small, dim, and peripheral, so risk is low — but if you have any history of photosensitivity or epilepsy, do not use this app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Any effect on mood or focus is unproven. Provided as-is with no warranty.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("I understand — continue") { state.acknowledge() }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("", selection: $state.advancedMode) {
                Text("Simple").tag(false)
                Text("Advanced").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Mode")

            Divider()

            if state.advancedMode {
                advancedControls
            } else {
                simpleControls
            }

            if !state.isCalibrated {
                Divider()
                calibrationNudge
            }

            Divider()
            scheduleSection
            Divider()
            footer
        }
    }

    private var simpleControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Dim keyboard below minimum", isOn: $state.isEnabled)
                .accessibilityHint("Dims the built-in backlight below the system's lowest setting.")
            if state.isEnabled { brightnessSlider }
            Text("Dims the built-in backlight below the system's lowest setting.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Dim keyboard", isOn: $state.isEnabled)
                .accessibilityHint("Dims the backlight below the system minimum at the chosen frequency.")

            if state.isEnabled {
                HStack {
                    Text("Frequency").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f Hz", state.frequencyHz))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 6) {
                    ForEach(AppState.presets, id: \.hz) { preset in
                        Button(preset.label) { state.setPreset(preset.hz) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("\(preset.label) preset")
                            .accessibilityHint("Sets the frequency to \(Int(preset.hz)) hertz.")
                    }
                }
                Slider(value: $state.frequencyHz, in: AppState.freqMin...AppState.freqMax, step: 0.5)
                    .accessibilityLabel("Frequency")
                    .accessibilityValue(String(format: "%.1f hertz", state.frequencyHz))
                Text(state.associationText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Brightness").font(.caption).foregroundStyle(.secondary)
                brightnessSlider
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Schedule", isOn: $state.scheduleEnabled)
                .accessibilityHint("Dims automatically during the selected hours.")

            if state.scheduleEnabled {
                Picker("", selection: $state.scheduleMode) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Schedule type")

                if state.scheduleMode == .fixed {
                    fixedTimeRows
                } else {
                    solarRows
                }

                if state.advancedMode {
                    HStack {
                        Text("At").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f Hz", state.scheduleFrequency))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Slider(value: $state.scheduleFrequency, in: AppState.freqMin...AppState.freqMax, step: 0.5)
                        .accessibilityLabel("Schedule frequency")
                        .accessibilityValue(String(format: "%.1f hertz", state.scheduleFrequency))
                }

                Text("Dims automatically during these hours. You can still switch it on or off by hand at any time.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fixedTimeRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("From").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                DatePicker("", selection: Binding(get: { state.scheduleStartDate }, set: { state.scheduleStartDate = $0 }),
                           displayedComponents: .hourAndMinute).labelsHidden()
                    .accessibilityLabel("Dim from")
            }
            HStack {
                Text("To").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                DatePicker("", selection: Binding(get: { state.scheduleEndDate }, set: { state.scheduleEndDate = $0 }),
                           displayedComponents: .hourAndMinute).labelsHidden()
                    .accessibilityLabel("Dim until")
            }
        }
    }

    @ViewBuilder
    private var solarRows: some View {
        if !state.hasLocation {
            HStack(spacing: 7) {
                Image(systemName: "location.slash").foregroundStyle(.orange)
                Text("Set your location to use sunset times")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Set…") { showSettings() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Set location")
                    .accessibilityHint("Opens Settings, where the location is chosen.")
            }
        } else if let times = state.solarTimes {
            switch times.condition {
            case .normal:
                HStack {
                    Label(Self.time(times.sunset), systemImage: "sunset")
                    Spacer()
                    Label(Self.time(times.sunrise), systemImage: "sunrise")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sunset \(Self.time(times.sunset)), sunrise \(Self.time(times.sunrise))")
            case .polarDay:
                Text("The sun doesn't set at your location today — the schedule stays off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .polarNight:
                Text("The sun doesn't rise at your location today — dimming stays on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// Shown until calibration has run on this hardware. The shipped defaults
    /// were measured on one machine; on another they are a guess.
    private var calibrationNudge: some View {
        HStack(spacing: 7) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not calibrated for this Mac").font(.caption)
                Text("Takes about a minute").font(.caption2).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button { showSettings() } label: { Text("Calibrate").font(.caption) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Opens Settings, where calibration runs.")
        }
    }

    private var footer: some View {
        HStack {
            if state.isEnabled {
                Button("Restore system control") { state.restoreSystemControl() }
                    .controlSize(.small)
            }
            Spacer()
            Button("Quit") { state.restoreAndQuit() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }

    private var brightnessSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $state.brightness, in: 0...1)
                .accessibilityLabel("Brightness")
                .accessibilityValue("\(Int((state.brightness * 100).rounded())) percent")
            Image(systemName: "sun.max").foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
