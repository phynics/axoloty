// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorRuntime
import Foundation

/// A ``InspectorSignalHandling`` implementation using `DispatchSourceSignal`.
///
/// Signals are intercepted via a dispatch source on the main queue, so the
/// handler runs on the main actor without triggering process termination.
final class InspectorSignalHandler: InspectorSignalHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _interrupted = false
    private var sources: [DispatchSourceProtocol] = []

    var wasInterrupted: Bool {
        lock.withLock { _interrupted }
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

        sources = [intSource, termSource]
    }

    private func interrupt() {
        lock.withLock { _interrupted = true }
    }
}
