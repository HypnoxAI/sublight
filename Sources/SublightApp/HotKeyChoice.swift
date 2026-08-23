// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  HotKeyChoice.swift
//  SublightApp
//
//  A short menu of preset shortcuts rather than a full recorder control.
//
//  A recorder ("press the keys you want") is the nicer interaction, but it is
//  also the bulk of what a hotkey library provides — conflict detection, live
//  capture, a custom NSView. For a single toggle, offering four combinations
//  that are unlikely to collide gets ~90% of the value for ~5% of the code,
//  and keeps Sublight dependency-free. If this ever needs to be arbitrary,
//  the registration layer (HotKeyManager) already accepts any keycode.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import SublightKit

enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off
    case optionCommandK
    case controlOptionK
    case shiftCommandD
    case controlCommandB

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .optionCommandK: return "⌥⌘K"
        case .controlOptionK: return "⌃⌥K"
        case .shiftCommandD: return "⇧⌘D"
        case .controlCommandB: return "⌃⌘B"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .off: return nil
        case .optionCommandK: return HotKeyManager.Key.k
        case .controlOptionK: return HotKeyManager.Key.k
        case .shiftCommandD: return HotKeyManager.Key.d
        case .controlCommandB: return HotKeyManager.Key.b
        }
    }

    var modifiers: UInt32? {
        switch self {
        case .off:
            return nil
        case .optionCommandK:
            return HotKeyManager.Modifier.option | HotKeyManager.Modifier.command
        case .controlOptionK:
            return HotKeyManager.Modifier.control | HotKeyManager.Modifier.option
        case .shiftCommandD:
            return HotKeyManager.Modifier.shift | HotKeyManager.Modifier.command
        case .controlCommandB:
            return HotKeyManager.Modifier.control | HotKeyManager.Modifier.command
        }
    }
}
