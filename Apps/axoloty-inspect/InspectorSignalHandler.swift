// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorRuntime
import Foundation
import Synchronization

/// A ``InspectorSignalHandling`` implementation using `DispatchSourceSignal`.
///
/// Signals are intercepted via a dispatch source on the main queue, so the
/// handler runs on the main actor without triggering process termination.
final class InspectorSignalHandler: InspectorSignalHandling, Sendable {
    // @unchecked: DispatchSourceProtocol is non-Sendable; this state is accessed only through its mutex.
    private struct State: @unchecked Sendable {
        var interrupted = false
        var sources: [DispatchSourceProtocol] = []
    }
    private let state = Mutex(State())

    var wasInterrupted: Bool {
        state.withLock { $0.interrupted }
    }

    func install() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in
            self?.interrupt()
        }
        intSource.resume()

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            self?.interrupt()
        }
        termSource.resume()

        state.withLock { $0.sources = [intSource, termSource] }
    }

    private func interrupt() {
        state.withLock { $0.interrupted = true }
    }
}
