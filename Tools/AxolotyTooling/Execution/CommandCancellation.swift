// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization

public final class AxolotyCommandCancellation: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var observers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    /// Creates a cancellation token.
    public init() {}

    /// Requests cancellation of the currently running command.
    public func cancel() {
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.cancelled else { return [] }
            state.cancelled = true
            let callbacks = Array(state.observers.values)
            state.observers.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }

    /// Whether cancellation has been requested.
    public var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    @discardableResult
    func observe(_ callback: @escaping @Sendable () -> Void) -> AxolotyCancellationObservation {
        let id = UUID()
        let alreadyCancelled = state.withLock { state in
            if state.cancelled { return true }
            state.observers[id] = callback
            return false
        }
        if alreadyCancelled {
            callback()
        }
        return AxolotyCancellationObservation { [weak self] in
            self?.removeObserver(id)
        }
    }

    private func removeObserver(_ id: UUID) {
        _ = state.withLock { $0.observers.removeValue(forKey: id) }
    }
}

final class AxolotyCancellationObservation: Sendable {
    private let release: @Sendable () -> Void
    private let released = Mutex(false)

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    func cancel() {
        guard released.withLock({ released in
            guard !released else { return false }
            released = true
            return true
        }) else { return }
        release()
    }

    deinit { cancel() }
}
