// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  SignalRestore.swift
//  SublightKit
//
//  Restore-on-signal for both executables. A raw C signal handler may not
//  touch Objective-C (or allocate, or lock), so the signal is ignored at the
//  C level and re-delivered as a dispatch signal source ON THE ENGINE QUEUE,
//  where the handler can restore synchronously — the tick handlers are
//  serialized behind it, so no edge can slip in between restore and exit.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public final class SignalRestore {

    public static let defaultSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    private var sources: [DispatchSourceSignal] = []

    /// Install handlers. Keep the returned object alive for the process
    /// lifetime — dropping it cancels the sources.
    public init(signals: [Int32] = SignalRestore.defaultSignals,
                queue: DispatchQueue = EngineQueue.queue,
                restore: @escaping () -> Void) {
        for sig in signals {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler {
                Log.engine.info("signal \(sig, privacy: .public): restoring backlight and exiting")
                restore()
                exit(0)
            }
            src.resume()
            sources.append(src)
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}
