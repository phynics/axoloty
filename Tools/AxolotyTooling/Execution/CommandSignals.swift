// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyProcessLauncher

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class AxolotySignalLease: @unchecked Sendable {
    private let release: @Sendable () -> Void
    private var released = false
    private let lock = NSLock()

    init(release: @escaping @Sendable () -> Void) { self.release = release }

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

final class AxolotySignalMultiplexer: @unchecked Sendable {
    static let shared = AxolotySignalMultiplexer()
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var handler: ServiceSignalHandler?
    private var savedSignalDispositions: (int: UnsafeMutableRawPointer?, term: UnsafeMutableRawPointer?)?

    func acquire(callback: @escaping @Sendable () -> Void) -> AxolotySignalLease {
        let id = UUID()
        lock.lock()
        callbacks[id] = callback
        if handler == nil {
            savedSignalDispositions = (
                axoloty_capture_signal_disposition(SIGINT),
                axoloty_capture_signal_disposition(SIGTERM)
            )
            let signalHandler = ServiceSignalHandler(onInterrupt: { [weak self] in self?.notify() })
            signalHandler.install()
            handler = signalHandler
        }
        lock.unlock()
        return AxolotySignalLease { [weak self] in self?.release(id: id) }
    }

    private func notify() {
        lock.lock()
        let currentCallbacks = Array(callbacks.values)
        lock.unlock()
        currentCallbacks.forEach { $0() }
    }

    #if DEBUG
    func notifyForTesting() {
        notify()
    }
    #endif

    private func release(id: UUID) {
        lock.lock()
        callbacks.removeValue(forKey: id)
        if callbacks.isEmpty, let handler {
            self.handler = nil
            handler.uninstall()
            if let savedSignalDispositions {
                _ = axoloty_restore_signal_disposition(SIGINT, savedSignalDispositions.int)
                _ = axoloty_restore_signal_disposition(SIGTERM, savedSignalDispositions.term)
                axoloty_release_signal_disposition(savedSignalDispositions.int)
                axoloty_release_signal_disposition(savedSignalDispositions.term)
                self.savedSignalDispositions = nil
            }
        }
        lock.unlock()
    }
}
