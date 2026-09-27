// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization
import AxolotyProcessLauncher

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class AxolotySignalLease: Sendable {
    private let release: @Sendable () -> Void
    private let released = Mutex(false)

    init(release: @escaping @Sendable () -> Void) { self.release = release }

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

// @unchecked: signal disposition pointers and dispatch-source lifecycle use the mutex.
final class AxolotySignalMultiplexer: @unchecked Sendable {
    static let shared = AxolotySignalMultiplexer()
    private struct State {
        var callbacks: [UUID: @Sendable () -> Void] = [:]
        var handler: ServiceSignalHandler?
        var savedSignalDispositions: (int: UnsafeMutableRawPointer?, term: UnsafeMutableRawPointer?)?
    }
    private let state = Mutex(State())

    func acquire(callback: @escaping @Sendable () -> Void) -> AxolotySignalLease {
        let id = UUID()
        state.withLock { state in
          state.callbacks[id] = callback
          if state.handler == nil {
            state.savedSignalDispositions = (
                axoloty_capture_signal_disposition(SIGINT),
                axoloty_capture_signal_disposition(SIGTERM)
            )
            let signalHandler = ServiceSignalHandler(onInterrupt: { [weak self] in self?.notify() })
            signalHandler.install()
            state.handler = signalHandler
          }
        }
        return AxolotySignalLease { [weak self] in self?.release(id: id) }
    }

    private func notify() {
        let currentCallbacks = state.withLock { Array($0.callbacks.values) }
        currentCallbacks.forEach { $0() }
    }

    #if DEBUG
    func notifyForTesting() {
        notify()
    }
    #endif

    private func release(id: UUID) {
        state.withLock { state in
            state.callbacks.removeValue(forKey: id)
            guard state.callbacks.isEmpty, let handler = state.handler else { return }
            state.handler = nil
            let saved = state.savedSignalDispositions
            state.savedSignalDispositions = nil
            handler.uninstall()
            if let saved {
                _ = axoloty_restore_signal_disposition(SIGINT, saved.int)
                _ = axoloty_restore_signal_disposition(SIGTERM, saved.term)
                axoloty_release_signal_disposition(saved.int)
                axoloty_release_signal_disposition(saved.term)
            }
        }
    }
}
