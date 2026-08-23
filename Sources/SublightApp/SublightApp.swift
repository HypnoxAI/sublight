// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SublightApp.swift
//  SublightApp
//
//  Thin SwiftUI veneer over SublightKit: a MenuBarExtra popover plus a
//  Settings window (⌘, / the gear).
//
//  MENU BAR ICON — four constraints, each one learned the hard way:
//
//    1. The label must resolve to a SINGLE static view. A conditional VIEW
//       (`if let … else …`) produces an invisible menu bar item — the click
//       target exists but nothing draws.
//    2. No PDF assets. An earlier glyph was built from an SVG mask, and
//       rsvg-convert flattens masks into PDF soft-masks that NSImage does
//       not reliably rasterise: the PDF loads fine (so no fallback kicks in)
//       and then draws nothing. The glyph is now drawn in code (StatusGlyph)
//       so there is no asset pipeline to get this wrong.
//    3. Size by HEIGHT with aspect preserved — the glyph is wider than tall,
//       and forcing it square squashes it. StatusGlyph draws on an 18×18 pt
//       canvas, the standard status item size, so no resizing happens here.
//    4. State is the FILL LEVEL of the keys, carried by one memoized
//       drawing-handler NSImage per discrete state (StatusGlyph.image).
//       This replaces the earlier opacity-on-the-view approach. The failure
//       mode that approach avoided was re-rasterising a template image into a
//       hand-built bitmap, which can yield a blank icon; a drawing-handler
//       NSImage is different — AppKit invokes the handler per backing scale,
//       so it stays crisp and renders reliably as a template. Memoizing per
//       state means slider drags swap between stable instances rather than
//       constructing fresh images. Fill rather than colour, because a
//       coloured menu bar icon looks foreign on macOS and breaks in
//       high-contrast modes.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import SwiftUI
import AppKit
import SublightKit

@main
struct SublightApp: App {

    @StateObject private var state = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            // One Image view, always. Only the keys' fill level varies with
            // state: hollow when idle, filling from the right with frequency.
            Image(nsImage: StatusGlyph.image(litFraction: state.glyphFraction))
                .accessibilityLabel("Sublight")
                .accessibilityValue(state.isEnabled ? "dimming" : "idle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
