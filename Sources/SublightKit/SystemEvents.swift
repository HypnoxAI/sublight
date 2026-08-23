// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SystemEvents.swift
//  SublightKit
//
//  Suspend/resume around sleep, display sleep, and session switches. Two
//  obligations:
//    1. On suspend: hand the backlight back to the system (a real restore,
//       not merely cancelling the timers) — don't fight the power-down path,
//       don't leave auto-brightness disabled for the next session, don't
//       hold wakeful timers.
//    2. On resume: wait a settle delay, then let the caller re-engage if the
//       user had it enabled — backlightd restores its own idea of brightness
//       on wake, which would stomp a sub-minimum hold. The delay is
//       empirical; 1.5 s is a conservative placeholder.
//
//  The caller models the decision (userEnabled && !systemSuspended) — see
//  DimmingPolicy; this type only reports the transitions.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import AppKit

/// `@unchecked Sendable`: every stored property is touched only on the main
/// queue. The observers are registered with `queue: .main`, the settle-delayed
/// resume is scheduled with `DispatchQueue.main.asyncAfter`, and `deinit` runs
/// wherever the last reference is dropped — which is why this is not simply
/// `@MainActor`: a main-actor class cannot have a `deinit` that touches its own
/// isolated state, and this one must cancel a pending work item there.
public final class SleepWakeObserver: @unchecked Sendable {

    public enum Transition: String, Sendable {
        case willSleep, screensDidSleep, sessionDidResignActive
        case didWake, screensDidWake, sessionDidBecomeActive

        public var isSuspend: Bool {
            switch self {
            case .willSleep, .screensDidSleep, .sessionDidResignActive: return true
            case .didWake, .screensDidWake, .sessionDidBecomeActive: return false
            }
        }
    }

    public let wakeSettleDelay: TimeInterval

    private var tokens: [NSObjectProtocol] = []
    /// The pending settle-delayed resume, if any. A suspend that arrives inside
    /// the settle window cancels it — otherwise a stale resume would re-engage
    /// the engine while the machine is on its way to sleep.
    private var pendingResume: DispatchWorkItem?

    /// Both callbacks are delivered on the main queue; `onResume` after
    /// `wakeSettleDelay`.
    public init(
        wakeSettleDelay: TimeInterval = 1.5,
        onSuspend: @escaping @Sendable (Transition) -> Void,
        onResume: @escaping @Sendable (Transition) -> Void
    ) {
        self.wakeSettleDelay = wakeSettleDelay
        let center = NSWorkspace.shared.notificationCenter
        let delay = wakeSettleDelay

        let pairs: [(Notification.Name, Transition)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        ]
        for (name, transition) in pairs {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    guard let self else { return }
                    if transition.isSuspend {
                        // Cancel any resume still waiting out its settle delay: the
                        // machine is suspending again, so that resume is stale.
                        self.pendingResume?.cancel()
                        self.pendingResume = nil
                        onSuspend(transition)
                    } else {
                        self.pendingResume?.cancel()
                        let work = DispatchWorkItem { [weak self] in
                            self?.pendingResume = nil
                            onResume(transition)
                        }
                        self.pendingResume = work
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + delay, execute: work)
                    }
                })
        }
    }

    deinit {
        pendingResume?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
    }
}
