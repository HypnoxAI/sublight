// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SocialPreview.swift
//  sublight-cli
//
//  The 1280x640 card GitHub shows when the repository is linked anywhere.
//
//  Composed in code for the same reason the menu bar legend is (see
//  GlyphLegend.swift): a hand-made image drifts from the thing it depicts and
//  nobody notices. Same discipline — an explicit NSBitmapImageRep at a fixed
//  pixel size in device RGB, never lockFocus(), so a re-render of unchanged
//  inputs produces identical bytes and a diff means something really changed.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import AppKit
import Foundation

/// `@MainActor` for the same reason as GlyphLegend: AppKit drawing invoked from
/// main-actor top-level code.
@MainActor
enum SocialPreview {

    static let fileName = "social-preview.png"
    /// GitHub's social preview is displayed at 1280x640.
    static let size = NSSize(width: 1280, height: 640)
    static let tagline = "Dim your keyboard below the macOS minimum."

    private static func bitmap(_ size: NSSize, scale: Int, _ draw: () -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        draw()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func render(iconURL: URL, scale: Int = 1) -> Data? {
        guard let icon = NSImage(contentsOf: iconURL) else { return nil }

        return bitmap(size, scale: scale) {
            // A black field, because the product only makes sense in a dark
            // room and the mark is drawn for one.
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()

            let markSide: CGFloat = 300
            let markX: CGFloat = 96
            icon.draw(in: NSRect(x: markX, y: (size.height - markSide) / 2,
                                 width: markSide, height: markSide))

            let textX = markX + markSide + 72
            let word = NSAttributedString(string: "Sublight", attributes: [
                .font: NSFont.systemFont(ofSize: 104, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let line = NSAttributedString(string: tagline, attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .regular),
                .foregroundColor: NSColor(white: 0.68, alpha: 1),
            ])

            // Optically centre the pair as a block rather than centring each
            // line independently.
            let wordH = word.size().height, lineH = line.size().height
            let gap: CGFloat = 18
            let blockH = wordH + gap + lineH
            let top = (size.height + blockH) / 2

            word.draw(at: NSPoint(x: textX, y: top - wordH))
            line.draw(at: NSPoint(x: textX, y: top - wordH - gap - lineH))
        }?.representation(using: .png, properties: [:])
    }
}
