// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  StatusGlyph.swift
//  SublightKit
//
//  Lives in the KIT, not the app, so the legend in the README can be rendered
//  from this exact code (`sublight-cli glyph render`). Documentation that
//  describes an icon by hand drifts from the icon; documentation generated
//  from the drawing cannot. AppKit in the kit is fine here — the package is
//  macOS-only by construction and AppKit is inside the zero-dependency policy.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import AppKit

/// Sublight's stateful menu bar glyph: a keyboard whose keys are hollow while
/// the backlight is under system control and fill from the right as Sublight
/// takes over. Rendered as a template image so macOS tints it correctly for
/// light menu bars, dark menu bars, and reduced-transparency modes.
///
/// Geometry is defined in points on an 18x18 canvas (the standard status item
/// size); AppKit renders it at the display's native scale, so it stays crisp
/// on Retina.
public enum StatusGlyph {

    /// One NSImage per discrete fill level. The MenuBarExtra label is
    /// re-evaluated on every AppState change (slider drags included), so
    /// memoizing lets it swap between stable instances instead of building a
    /// fresh image each time.
    private static var cache: [CGFloat: NSImage] = [:]

    /// Total keys on the deck. The fill levels are chosen so each preset
    /// lands on a whole number of these: 0 / 3 / 5 / 8 of 10.
    public static let keyCount = 10

    /// How many keys are drawn filled at this level. Public because the legend
    /// and the README quote these counts, and a number quoted by hand is a
    /// number that will eventually be wrong.
    public static func litKeyCount(litFraction: CGFloat) -> Int {
        let clamped = max(0.0, min(1.0, litFraction))
        return Int((clamped * CGFloat(keyCount)).rounded())
    }

    /// litFraction 0.0 = all keys hollow (Off), 1.0 = all keys filled.
    /// Mode mapping: Off 0.0, Low 0.3, Medium 0.5, High 0.8.
    public static func image(litFraction: CGFloat) -> NSImage {
        let clamped = max(0.0, min(1.0, litFraction))
        if let cached = cache[clamped] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(litFraction: clamped)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sublight"
        cache[clamped] = image
        return image
    }

    private static func keyRects() -> [NSRect] {
        var rects: [NSRect] = []
        for y in [CGFloat(4.7), 7.85] {
            var x: CGFloat = 2.8
            for _ in 0..<4 {
                rects.append(NSRect(x: x, y: y, width: 2.85, height: 2.5))
                x += 2.85 + 0.6
            }
        }
        rects.append(NSRect(x: 2.8, y: 11.0, width: 10.0, height: 2.5))
        rects.append(NSRect(x: 13.4, y: 11.0, width: 2.6, height: 2.5))
        return rects
    }

    private static func draw(litFraction: CGFloat) {
        NSColor.black.set()

        let deck = NSBezierPath(
            roundedRect: NSRect(x: 1.0, y: 3.0, width: 16.0, height: 12.0),
            xRadius: 2.4, yRadius: 2.4
        )
        deck.lineWidth = 1.1
        deck.stroke()

        let rects = keyRects()
        let litCount = litKeyCount(litFraction: litFraction)
        let rightmostFirst = rects.indices.sorted { rects[$0].midX > rects[$1].midX }
        let lit = Set(rightmostFirst.prefix(litCount))

        for (index, rect) in rects.enumerated() {
            let key = NSBezierPath(roundedRect: rect, xRadius: 0.6, yRadius: 0.6)
            if lit.contains(index) {
                key.fill()
            } else {
                key.lineWidth = 0.6
                key.stroke()
            }
        }
    }
}
