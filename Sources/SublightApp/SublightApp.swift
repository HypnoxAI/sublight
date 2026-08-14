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
//    2. The asset is a PNG, not a PDF. The glyph is built from an SVG mask,
//       and rsvg-convert flattens masks into PDF soft-masks that NSImage
//       does not reliably rasterise: the PDF loads fine (so no fallback
//       kicks in) and then draws nothing.
//    3. Size by HEIGHT with aspect preserved — the glyph is wider than tall,
//       and forcing it square squashes it.
//    4. State is opacity applied by SwiftUI, not a second NSImage built by
//       hand. Redrawing a template image into a new bitmap to fade it is
//       another way to end up with a blank icon; `.opacity()` on the view is
//       both simpler and safe. Opacity rather than colour, because a
//       coloured menu bar icon looks foreign on macOS and breaks in
//       high-contrast modes.
//
//  Falls back to an SF Symbol when the bundled resource is absent (e.g.
//  running the bare binary via `swift run` rather than the assembled .app).
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import SwiftUI
import AppKit
import SublightKit

@main
struct SublightApp: App {

    @StateObject private var state = AppState()

    private static let menuBarIcon: NSImage = {
        // 16pt, not 18: measured against macOS's own status icons, the
        // taller version was ~28pt wide and carried roughly three times
        // the ink of a typical outline glyph — it read as oversized.
        let height: CGFloat = 16

        if let url = Bundle.main.url(forResource: "sublight-menubar-Template", withExtension: "png"),
           let image = NSImage(contentsOf: url),
           image.size.height > 0, image.size.width > 0 {
            let aspect = image.size.width / image.size.height
            image.size = NSSize(width: (height * aspect).rounded(), height: height)
            image.isTemplate = true
            Log.lifecycle.info("menu bar glyph loaded from bundle")
            return image
        }

        Log.lifecycle.warning("menu bar glyph missing — using SF Symbol fallback")
        if let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Sublight") {
            symbol.isTemplate = true
            return symbol
        }

        let blank = NSImage(size: NSSize(width: height, height: height))
        blank.isTemplate = true
        return blank
    }()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            // One Image view, always. Only its opacity varies with state.
            Image(nsImage: Self.menuBarIcon)
                .opacity(state.isEnabled ? 1.0 : 0.55)
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
