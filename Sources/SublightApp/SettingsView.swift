// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SettingsView.swift
//  SublightApp
//
//  The Settings window (⌘,). Holds the set-once plumbing that used to clutter
//  the popover — login item, reset, the safety acknowledgment, and About.
//  Calibration and the global shortcut land here in later build parts.
//
//  Modified 2026-08-28: Diagnostics Copy is live and hardware-report shaped;
//  About shows build number (and short git SHA when stamped).
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import AppKit
import Combine
import SublightKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetyTab()
                .tabItem { Label("Safety", systemImage: "exclamationmark.shield") }
            DiagnosticsTab()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @State private var showCalibration = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $state.launchAtLogin) {
                    Text("Launch at login")
                    Text(
                        "Starts Sublight automatically. The app must live in /Applications for this to persist across restarts."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    Picker("", selection: $state.cityID) {
                        ForEach(CityDirectory.grouped, id: \.group) { section in
                            Section(section.group) {
                                ForEach(section.cities) { city in
                                    Text(city.displayName).tag(city.id)
                                }
                            }
                        }
                        Divider()
                        Text("Custom coordinates…").tag(CityDirectory.customID)
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .accessibilityLabel("Location")
                } label: {
                    Text("Location")
                    Text(locationSubtitle)
                        .font(.caption)
                        .foregroundStyle(
                            state.hasLocation ? Color.secondary : Color.orange)
                }

                // Coordinates stay visible either way: editable when custom,
                // shown read-only for a city so the resolved numbers can be
                // checked rather than taken on trust.
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField(
                            "Lat", value: $state.latitude,
                            format: .number.precision(.fractionLength(0...4))
                        )
                        .frame(width: 78)
                        .multilineTextAlignment(.trailing)
                        .disabled(state.selectedCity != nil)
                        .accessibilityLabel("Latitude")
                        TextField(
                            "Lon", value: $state.longitude,
                            format: .number.precision(.fractionLength(0...4))
                        )
                        .frame(width: 78)
                        .multilineTextAlignment(.trailing)
                        .disabled(state.selectedCity != nil)
                        .accessibilityLabel("Longitude")
                    }
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Coordinates").font(.callout)
                    Text(
                        state.selectedCity == nil
                            ? "Latitude and longitude, in degrees. Negative is south and west."
                            : "From the selected city. Choose Custom coordinates to edit."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    Picker("", selection: $state.hotKey) {
                        ForEach(HotKeyChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel("Global shortcut")
                } label: {
                    Text("Global shortcut")
                    Text(
                        state.hotKeyConflict
                            ? "That shortcut is already taken by another app — pick a different one."
                            : "Toggle dimming from anywhere, without opening the menu."
                    )
                    .font(.caption)
                    .foregroundStyle(
                        state.hotKeyConflict ? Color.orange : Color.secondary)
                }
            }

            Section {
                LabeledContent {
                    Button(state.isCalibrated ? "Recalibrate…" : "Calibrate…") {
                        showCalibration = true
                    }
                    .disabled(state.controller == nil)
                    .accessibilityHint(
                        "Runs the guided calibration for this Mac. Takes about a minute.")
                } label: {
                    Text("Calibrate for this Mac")
                    Text(calibrationSubtitle)
                        .font(.caption)
                        .foregroundStyle(
                            state.isCalibrated ? Color.secondary : Color.orange)
                }
            }

            Section {
                LabeledContent {
                    Button("Reset…") { state.resetToDefaults() }
                        .accessibilityLabel("Reset to defaults")
                        .accessibilityHint(
                            "Clears saved settings and shows the setup screen again.")
                } label: {
                    Text("Reset to defaults")
                    Text(
                        "Clears saved settings and shows the setup screen again. Your Launch-at-login choice is left unchanged."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.requestCalibration) { _, wants in
            if wants {
                showCalibration = true
                state.requestCalibration = false
            }
        }
        .sheet(isPresented: $showCalibration) {
            if let controller = state.controller {
                CalibrationView(controller: controller)
                    .environmentObject(state)
            }
        }
    }

    private var locationSubtitle: String {
        guard state.hasLocation else {
            return
                "Pick your city, or enter coordinates. Only needed for the Sunset → sunrise schedule."
        }
        if let t = state.solarTimes {
            switch t.condition {
            case .polarDay: return "Today the sun doesn't set at this location."
            case .polarNight: return "Today the sun doesn't rise at this location."
            case .normal:
                let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
                let rise = t.sunrise.map(f.string(from:)) ?? "—"
                let set = t.sunset.map(f.string(from:)) ?? "—"
                return
                    "Today: sunrise \(rise), sunset \(set). Computed on this Mac — never sent anywhere."
            }
        }
        return "Computed on this Mac — never sent anywhere."
    }

    private var calibrationSubtitle: String {
        if let hz = state.calibratedFrequency {
            var s = String(format: "Calibrated at %.1f Hz", hz)
            if let d = state.calibratedDate {
                s += " on " + Self.dateFormat.string(from: d)
            }
            return s
        }
        return
            "Not calibrated. Sublight is using defaults measured on a different Mac — they may be wrong for yours."
    }
}

// MARK: - Safety

private struct SafetyTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Text("Photosensitive seizure warning")
                    .font(.headline)
                Text(
                    "Sublight dims by rapidly modulating the backlight, producing flicker between roughly 2 and 8 Hz — a range that can trigger seizures in people with photosensitive epilepsy. The light is small, dim, and in peripheral vision, so risk is low, but if you have any history of photosensitivity or epilepsy, do not use this app."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent {
                    Button("Show again…") { state.showOnboardingAgain() }
                        .accessibilityLabel("Show the introduction again")
                } label: {
                    Text("Consent")
                    Text(
                        state.consentGranted
                            ? "Given — you accepted the safety notice before dimming was first enabled."
                            : "Not yet given — Sublight will ask before it first dims the keyboard."
                    )
                    .font(.caption)
                    .foregroundStyle(state.consentGranted ? Color.green : Color.orange)
                }
            }

            Section {
                Text("Effects are unproven")
                    .font(.subheadline).bold()
                Text(
                    "Flickering light produces a measurable response in the visual cortex, but there is no reliable evidence it improves mood, focus, or sleep. Sublight makes no such claim, and it is not a medical device."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics

/// What Sublight thinks is going on, in one copyable block.
///
/// Sublight drives an undocumented framework across hardware that behaves
/// differently machine to machine, so "it doesn't work" is close to useless as
/// a bug report. This exists so the answer to "what's your setup?" is one
/// button, and so the maintainers see the floor, the effective frequency,
/// the live skip counters and the build identity without a back-and-forth.
/// Copy is shaped for the Hardware report GitHub issue template.
///
/// Modified 2026-08-28: live engine fields; hardware-report-shaped Copy.
private struct DiagnosticsTab: View {
    @EnvironmentObject var state: AppState
    @State private var copied = false
    /// Forces a re-read of the live engine so the on-screen block is not a
    /// snapshot from when the tab first appeared.
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Include this when reporting a problem. Copy is paste-ready for "
                    + "a Hardware report issue. Coordinates are never included."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(state.diagnosticsReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id(tick)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )

            HStack {
                Text("Your coordinates are never included — only the city name.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        state.diagnosticsReport, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .disabled(copied)
                .accessibilityLabel(copied ? "Copied" : "Copy diagnostics report")
            }
        }
        .padding(18)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            tick += 1
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @EnvironmentObject var state: AppState

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version =
            (info?["CFBundleShortVersionString"] as? String) ?? SublightVersion.current
        let build = (info?["CFBundleVersion"] as? String) ?? SublightVersion.build
        var s = "Version \(version) (\(build))"
        let rev = SublightVersion.gitRevision
        if rev != "unknown" {
            s += " · \(rev.prefix(12))"
        }
        return s
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(
                nsImage: NSApp.applicationIconImage ?? NSImage(
                    systemSymbolName: "keyboard", accessibilityDescription: "Sublight")!
            )
            .resizable()
            .frame(width: 72, height: 72)
            .padding(.top, 18)
            .accessibilityHidden(true)

            Text("Sublight").font(.title2).bold()
            Text(versionLine)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()

            Text("Dims the built-in keyboard backlight below the macOS minimum.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .frame(maxWidth: 300)

            Text(state.hardware.summary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospaced()
                .padding(.top, 2)

            Spacer(minLength: 8)

            Text("© 2026 Hypnox Technologies LLC · Apache License 2.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Uses undocumented Apple interfaces. Provided as-is, without warranty.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
