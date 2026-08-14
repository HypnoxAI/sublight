// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  CalibrationView.swift
//  SublightApp
//
//  The guided calibration sheet. Deliberately sparse and dark: this is a
//  perceptual test of a dim light, so the screen itself is a confounder —
//  every step tells the person to look at the KEYBOARD, not here.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import SwiftUI
import SublightKit

struct CalibrationView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cal: CalibrationController

    init(controller: BacklightController) {
        _cal = StateObject(wrappedValue: CalibrationController(controller: controller))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch cal.step {
            case .intro:     introStep
            case .floor:     floorStep
            case .frequency: frequencyStep
            case .level:     levelStep
            case .summary:   summaryStep
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 440, height: 380)
        .onDisappear { cal.cancel() }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cal.step.title).font(.headline)
            if cal.step != .intro && cal.step != .summary {
                ProgressView(value: cal.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Calibration progress")
            }
        }
    }

    private var footer: some View {
        HStack {
            if cal.step == .summary {
                Button("Discard") {
                    cal.discardAndRestore()
                    dismiss()
                }
                Spacer()
                Button("Save calibration") {
                    if let r = cal.result {
                        state.adoptCalibration(r)
                        cal.markSaved()
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else if cal.step == .intro {
                Spacer()
                Button("Start") { cal.begin() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") {
                    cal.cancel()
                    dismiss()
                }
                Spacer()
            }
        }
    }

    // MARK: Steps

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sublight's defaults were measured on one machine. This finds the numbers that are right for **your** Mac and **your** eyes — where the backlight actually bottoms out, and how fast it has to flicker before you stop seeing it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Takes about a minute", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
            Label("Best in a dark room — turn off the lights first", systemImage: "moon.stars")
                .font(.caption).foregroundStyle(.secondary)
            Label("Watch the keyboard, not the screen", systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)

            Text("Calibrating: \(state.hardware.summary)")
                .font(.caption2).monospaced().foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private var floorStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The keyboard will switch back and forth between two levels. Watch it and tell me whether the light **changes at all**, or stays completely steady.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            playbackIndicator

            HStack(spacing: 10) {
                Button("It flickers") { cal.answerFloor(flickered: true) }
                    .disabled(cal.isPlaying)
                    .accessibilityHint("Answer that the backlight visibly changed.")
                Button("Completely steady") { cal.answerFloor(flickered: false) }
                    .disabled(cal.isPlaying)
                    .accessibilityHint("Answer that the backlight did not change at all.")
            }

            Button("Play again") { cal.playFloorComparison() }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(cal.isPlaying)
                .accessibilityHint("Repeats the two-level comparison on the keyboard.")

            Text("Question \(cal.round + 1) of \(CalibrationController.rounds)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var frequencyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Now the keyboard is dimmed by flickering it. Watch it for a few seconds. Does the light look **steady**, or can you see it **pulsing**?")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            playbackIndicator

            HStack(spacing: 10) {
                Button("Looks steady") { cal.answerFrequency(steady: true) }
                    .accessibilityHint("Answer that the dimmed backlight looks steady.")
                Button("I can see it pulsing") { cal.answerFrequency(steady: false) }
                    .accessibilityHint("Answer that the backlight is visibly pulsing.")
            }

            Button("Play again") { cal.playFrequency() }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityHint("Repeats the flicker test on the keyboard.")

            Text("Question \(cal.round + 1) of \(CalibrationController.rounds)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var levelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Last one. Set the keyboard where you'd actually want it in the dark — dim enough to be comfortable, bright enough to be useful.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $cal.previewLevel, in: 0.1...0.95)
                    .onChange(of: cal.previewLevel) { _, _ in cal.applyPreview() }
                    .accessibilityLabel("Preferred brightness")
                    .accessibilityValue("\(Int((cal.previewLevel * 100).rounded())) percent")
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text("This becomes your default brightness.")
                .font(.caption2).foregroundStyle(.tertiary)

            Button("Use this level") { cal.finishLevel() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here's what your Mac and your eyes came out at:")
                .font(.callout).foregroundStyle(.secondary)

            if let r = cal.result {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        Text("Brightness floor").foregroundStyle(.secondary)
                        Text(String(format: "%.3f", r.floor)).monospacedDigit()
                    }
                    GridRow {
                        Text("Flicker-free at").foregroundStyle(.secondary)
                        Text(String(format: "%.1f Hz", r.frequency)).monospacedDigit()
                    }
                    GridRow {
                        Text("Preferred level").foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", r.brightness * 100)).monospacedDigit()
                    }
                }
                .font(.callout)
            }

            if cal.frequencyHitCeiling {
                Text("Note: your steady point landed at the top of the range. Above roughly 10 Hz macOS starts merging the commands, so the light can look steady because it has stopped flickering altogether — which also means it stops going below the floor. If dimming seems weak, try a lower frequency by hand.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Saved for \(state.hardware.modelIdentifier). A different Mac will ask to calibrate again.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playbackIndicator: some View {
        HStack(spacing: 7) {
            if cal.isPlaying {
                ProgressView().controlSize(.small)
                Text("Watch the keyboard…").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("Ready for your answer").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}
