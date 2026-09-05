// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public final class AxolotyCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// Creates a cancellation token.
    public init() {}

    /// Requests cancellation of the currently running command.
    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let callbacks = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    /// Whether cancellation has been requested.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func observe(_ callback: @escaping @Sendable () -> Void) -> AxolotyCancellationObservation {
        let id = UUID()
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled {
            observers[id] = callback
        }
        lock.unlock()
        if alreadyCancelled {
            callback()
        }
        return AxolotyCancellationObservation { [weak self] in
            self?.removeObserver(id)
        }
    }

    private func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}

final class AxolotyCancellationObservation: @unchecked Sendable {
    private let release: @Sendable () -> Void
    private let lock = NSLock()
    private var released = false

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    func cancel() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        release()
    }

    deinit { cancel() }
}
