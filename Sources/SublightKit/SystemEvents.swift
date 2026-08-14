// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SystemEvents.swift
//  SublightKit
//
//  Sleep/wake handling. Two obligations:
//    1. On sleep: stop issuing brightness commands (don't fight the
//       power-down path, don't hold wakeful timers).
//    2. On wake: wait a settle delay, then reassert — backlightd restores
//       its own idea of brightness on wake, which will stomp a sub-minimum
//       hold. The delay is empirical; 1.5 s is a conservative placeholder.
//
//  Screen wake (display sleep without system sleep) gets the same
//  treatment via screensDidWakeNotification.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import AppKit

public final class SleepWakeObserver {

    public var wakeSettleDelay: TimeInterval

    private var tokens: [NSObjectProtocol] = []

    public init(
        wakeSettleDelay: TimeInterval = 1.5,
        onSleep: @escaping () -> Void,
        onWake: @escaping () -> Void
    ) {
        self.wakeSettleDelay = wakeSettleDelay
        let center = NSWorkspace.shared.notificationCenter
        let delay = wakeSettleDelay

        tokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            onSleep()
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { onWake() }
        })

        tokens.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { onWake() }
        })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
    }
}
