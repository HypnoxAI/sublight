// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  HotKey.swift
//  SublightKit
//
//  System-wide hotkey registration, dependency-free.
//
//  This wraps Carbon's RegisterEventHotKey, which despite the ancient
//  framework name is still the supported way to claim a global shortcut on
//  macOS — Apple never shipped a modern replacement. The popular
//  KeyboardShortcuts package wraps this same call; Sublight does it directly
//  rather than take on a runtime dependency for ~100 lines of code.
//
//  Notably this needs NO Accessibility permission, unlike the
//  NSEvent.addGlobalMonitorForEvents approach — the system delivers the event
//  to us rather than us watching every keystroke. That's better for the user
//  and better for a tool that already asks for trust by using private APIs.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation
import os
import Carbon.HIToolbox

public final class HotKeyManager {

    /// Carbon modifier masks, spelled out so callers don't need Carbon.
    public enum Modifier {
        public static let command: UInt32 = 0x0100
        public static let shift: UInt32 = 0x0200
        public static let option: UInt32 = 0x0800
        public static let control: UInt32 = 0x1000
    }

    /// Virtual key codes for the handful of keys we offer.
    public enum Key {
        public static let k: UInt32 = 0x28
        public static let b: UInt32 = 0x0B
        public static let d: UInt32 = 0x02
    }

    /// The Carbon event handler is a bare C function pointer and cannot capture
    /// context, so registered actions must live in a table keyed by hotkey id —
    /// global mutable state, which Swift 6 rightly refuses to accept unguarded.
    ///
    /// Guarded by a lock rather than isolated to an actor, because the two
    /// things that touch it *cannot* carry isolation: `unregister()` is called
    /// from `deinit`, which can never be actor-isolated, and the event handler
    /// is a C function pointer. A lock is the one mechanism both can use.
    ///
    /// `@unchecked Sendable` is therefore justified in the strict sense: every
    /// stored property is private and every access below is inside `lock`.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [UInt32: @Sendable () -> Void] = [:]
        private var nextID: UInt32 = 1
        private var handler: EventHandlerRef?

        func add(_ action: @escaping @Sendable () -> Void) -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            let id = nextID
            nextID += 1
            actions[id] = action
            return id
        }

        func remove(_ id: UInt32) {
            lock.lock(); defer { lock.unlock() }
            actions.removeValue(forKey: id)
        }

        func action(for id: UInt32) -> (@Sendable () -> Void)? {
            lock.lock(); defer { lock.unlock() }
            return actions[id]
        }

        /// True if this call installed the handler (so the caller should do the
        /// Carbon work); false if one was already installed.
        func claimHandlerInstall() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard handler == nil else { return false }
            return true
        }

        func storeHandler(_ ref: EventHandlerRef?) {
            lock.lock(); defer { lock.unlock() }
            handler = ref
        }
    }

    private static let registry = Registry()

    private var hotKeyRef: EventHotKeyRef?
    private var id: UInt32?

    public init() {}

    deinit { unregister() }

    /// Claim a system-wide shortcut. Replaces any shortcut this instance
    /// previously held. Returns false if the combination is already taken by
    /// another app — the caller should surface that rather than fail silently.
    @discardableResult
    public func register(keyCode: UInt32, modifiers: UInt32,
                         action: @escaping @Sendable () -> Void) -> Bool {
        unregister()
        Self.installSharedHandlerIfNeeded()

        let newID = Self.registry.add(action)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5355424C), id: newID) // 'SUBL'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.registry.remove(newID)
            Log.lifecycle.error("hotkey registration failed (status \(status, privacy: .public)) — likely already claimed by another app")
            return false
        }
        hotKeyRef = ref
        id = newID
        Log.lifecycle.info("global hotkey registered")
        return true
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let id {
            Self.registry.remove(id)
            self.id = nil
        }
    }

    private static func installSharedHandlerIfNeeded() {
        guard registry.claimHandlerInstall() else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            guard status == noErr, let action = HotKeyManager.registry.action(for: hkID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &spec, nil, &installed)
        registry.storeHandler(installed)
    }
}
