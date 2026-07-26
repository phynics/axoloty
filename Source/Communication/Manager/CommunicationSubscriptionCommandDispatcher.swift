// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Serializes subscription commands before forwarding them to a communication
/// client.
///
/// Commands are drained one at a time: each subscribe/unsubscribe is awaited to
/// completion before the next begins. This serializes *completion*, not only
/// actor entry, so a later `.unsubscribe` cannot begin (and possibly complete)
/// before an earlier `.subscribe` -- the reentrancy that arose when the actor
/// suspended on `await client.subscribe(...)` and let a second `deliver` run.
@MainActor
final class CommunicationSubscriptionCommandDispatcher {

    private let client: CommunicationClient

    /// Commands waiting to execute, paired with the continuation to resume when
    /// each finishes. Drained in arrival order by ``drainLoop()``.
    private var pending: [(command: SubscriptionCommand,
                           resume: CheckedContinuation<Void, Error>)] = []

    /// Whether ``drainLoop()`` is running, so at most one drain task exists.
    private var isDraining = false

    init(client: CommunicationClient) {
        self.client = client
    }

    func deliver(_ command: SubscriptionCommand) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending.append((command, continuation))
            if !isDraining {
                isDraining = true
                _Concurrency.Task<Void, Never> { @MainActor in
                    await self.drainLoop()
                }
            }
        }
    }

    /// Executes pending commands one at a time, awaiting each before starting
    /// the next. FIFO ordering is guaranteed because there is a single drainer;
    /// a command that suspends on `await client.subscribe(...)` blocks the
    /// drain, so a subsequent `.unsubscribe` waits in ``pending`` until the
    /// subscribe resolves.
    private func drainLoop() async {
        while let next = pending.first {
            pending.removeFirst()
            do {
                switch next.command {
                case .subscribe(let topic):
                    try await client.subscribe(topic)
                case .unsubscribe(let topic):
                    try await client.unsubscribe(topic)
                }
                next.resume.resume()
            } catch {
                next.resume.resume(throwing: error)
            }
        }
        isDraining = false
    }
}
