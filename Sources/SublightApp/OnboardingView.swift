// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  OnboardingView.swift
//  SublightApp
//
//  First-run window. Previously a new user's very first sight of Sublight was
//  a seizure warning crammed into a menu bar popover, with no explanation of
//  what the app even was. This gives the warning room to be read, puts it in
//  context, and hands over with a concrete next step.
//
//  The acknowledgment is a real gate: the continue button stays disabled until
//  the checkbox is ticked. It is deliberately not pre-ticked.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import SwiftUI
import SublightKit

struct OnboardingView: View {

    @EnvironmentObject var state: AppState
    @State private var page = 0
    @State private var accepted = false

    var onFinish: (_ calibrateNow: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                pageDots
                Spacer()
                nextButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 400)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color.secondary : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of 3")
    }

    @ViewBuilder
    private var nextButton: some View {
        switch page {
        case 0:
            Button("Continue") { page = 1 }
                .keyboardShortcut(.defaultAction)
        case 1:
            Button("Continue") { page = 2 }
                .keyboardShortcut(.defaultAction)
                .disabled(!accepted)
        default:
            HStack(spacing: 8) {
                Button("Skip for now") { onFinish(false) }
                Button("Calibrate now") { onFinish(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0:  welcome
        case 1:  safety
        default: calibrate
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Sublight").font(.title2).bold()
            Text("macOS won't let the keyboard backlight go below one fixed step, which is still too bright in a genuinely dark room. Sublight goes below it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It does that by modulating the backlight faster than the eye resolves, so the light averages out dimmer than the hardware's own minimum. At the right speed this reads as a steady, dim glow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Apple Silicon MacBooks with a backlit keyboard", systemImage: "laptopcomputer")
                .font(.callout).foregroundStyle(.secondary)
            Text(state.hardware.summary)
                .font(.caption).monospaced().foregroundStyle(.tertiary)
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Photosensitive seizure warning", systemImage: "exclamationmark.triangle.fill")
                .font(.title3).bold()
                .foregroundStyle(.orange)

            Text("Because Sublight dims by flickering the backlight, it produces flicker in the 2–8 Hz range — a range that can trigger seizures in people with photosensitive epilepsy.")
                .fixedSize(horizontal: false, vertical: true)

            Text("The light is small, dim, and in peripheral vision, so the risk is low. But if you or anyone using this Mac has epilepsy or any history of photosensitivity, do not use this app. Stop immediately if you feel dizzy, disoriented, or notice any involuntary movement.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Sublight also makes no health claims. Flickering light produces a measurable response in the visual cortex, but there is no reliable evidence it improves mood, focus, or sleep.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("I've read and understood this", isOn: $accepted)
                .padding(.top, 4)
        }
    }

    private var calibrate: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One last thing").font(.title2).bold()
            Text("Two numbers differ from Mac to Mac and person to person: where your keyboard's backlight actually bottoms out, and how fast it has to flicker before *you* stop seeing it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Calibration finds both in about a minute. Without it Sublight uses defaults measured on a different machine, which may be wrong for yours — so it's worth doing, ideally with the lights off.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can always run it later from Settings → General.")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }
}
