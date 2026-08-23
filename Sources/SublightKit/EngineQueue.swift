// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Hypnox Technologies LLC
//
//  EngineQueue.swift
//  SublightKit
//
//  The one serial queue on which every CoreBrightness call in the process
//  executes. The dither timers live on it, and every public
//  KeyboardBrightnessBridge method hops onto it — so the daemon only ever
//  sees one caller at a time, in order, and a tick can never interleave
//  with a restore.
//
//  Reentrancy: hopping onto a queue you are already on with `sync` deadlocks.
//  The tick handlers are already on this queue when they command the
//  backlight, and the signal handlers run here too, so `run` checks a
//  queue-specific key and executes inline in that case.
//
//  This queue never dispatches synchronously to the main queue — AppState
//  mirrors engine state with `DispatchQueue.main.async` only — which is what
//  makes `EngineQueue.run { … }` from the main thread deadlock-free.
//
//  Licensed under the Apache License 2.0 — see LICENSE.
//

import Foundation

public enum EngineQueue {

    /// Bundle-prefixed label; shows up in spindump and Instruments.
    public static let label = "com.hypnox.sublight.engine"

    private static let key = DispatchSpecificKey<Bool>()

    public static let queue: DispatchQueue = {
        let q = DispatchQueue(label: label, qos: .userInteractive)
        q.setSpecific(key: key, value: true)
        return q
    }()

    /// True when the calling code is already executing on the engine queue.
    public static var isCurrent: Bool {
        DispatchQueue.getSpecific(key: key) == true
    }

    /// Execute `body` on the engine queue and return its result: inline if
    /// already on the queue, otherwise a synchronous hop. Callable from any
    /// thread.
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        if isCurrent { return try body() }
        return try queue.sync(execute: body)
    }
}
