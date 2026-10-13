// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization
import AxolotyProcessLauncher

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The Core harness installs its own SIGINT/SIGTERM handler so a command can
// cancel cleanly. The runtime/debug services own an equivalent handler in the
// sibling AxolotyDebug package; the two are intentionally independent so the
// harness keeps no dependency on the library or on that package.

/// A signal handler that records and reports SIGINT or SIGTERM interruptions.
// @unchecked: signal sources and saved POSIX disposition pointers live behind this mutex.
final class ServiceSignalHandler: @unchecked Sendable {
    private struct State {
        var interrupted = false
        var sources: [DispatchSourceSignal] = []
        var savedDispositions: (int: UnsafeMutableRawPointer?, term: UnsafeMutableRawPointer?)?
    }
    private let state = Mutex(State())
    private let onInterrupt: (@Sendable () -> Void)?

    /// Creates a signal handler.
    ///
    /// - Parameter onInterrupt: An optional callback invoked once after the first
    ///   SIGINT or SIGTERM is received.
    init(onInterrupt: (@Sendable () -> Void)? = nil) {
        self.onInterrupt = onInterrupt
    }

    var isInterrupted: Bool {
        state.withLock { $0.interrupted }
    }

    func install() {
        state.withLock { state in
        guard state.sources.isEmpty else { return }
        state.savedDispositions = (
            axoloty_capture_signal_disposition(SIGINT),
            axoloty_capture_signal_disposition(SIGTERM)
        )
        _ = axoloty_ignore_signal(SIGINT)
        _ = axoloty_ignore_signal(SIGTERM)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        sigint.setEventHandler { self.setInterrupted() }
        sigint.resume()
        state.sources.append(sigint)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
        sigterm.setEventHandler { self.setInterrupted() }
        sigterm.resume()
        state.sources.append(sigterm)
        }
    }

    func uninstall() {
        let (currentSources, savedDispositions) = state.withLock { state in
            let currentSources = state.sources
            state.sources.removeAll()
            let savedDispositions = state.savedDispositions
            state.savedDispositions = nil
            return (currentSources, savedDispositions)
        }
        // Cancelling a dispatch signal source releases libdispatch's own
        // handler asynchronously. Restoring the saved dispositions before that
        // teardown finishes lets libdispatch reinstall SIG_DFL afterwards, so
        // the restored disposition is lost. A cancel handler runs only after
        // cancellation has completed, so wait for every source to enter one.
        if !currentSources.isEmpty {
            let teardown = DispatchGroup()
            for source in currentSources {
                teardown.enter()
                source.setCancelHandler { teardown.leave() }
                source.cancel()
            }
            teardown.wait()
        }
        if let savedDispositions {
            _ = axoloty_restore_signal_disposition(SIGINT, savedDispositions.int)
            _ = axoloty_restore_signal_disposition(SIGTERM, savedDispositions.term)
            axoloty_release_signal_disposition(savedDispositions.int)
            axoloty_release_signal_disposition(savedDispositions.term)
        }
    }

    private func setInterrupted() {
        let shouldNotify = state.withLock { state -> Bool in
            let shouldNotify = !state.interrupted
            state.interrupted = true
            return shouldNotify
        }

        if shouldNotify {
            onInterrupt?()
        }
    }
}
