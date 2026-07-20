// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// Thrown by ``waitUntil(_:timeout:pollInterval:condition:)`` and
/// ``nextValue(from:timeout:)`` when their deadline elapses first.
///
/// The message always names the condition that was being awaited, so a
/// failing broker-backed test reads as "timed out waiting for X" rather than
/// an unexplained hang or a bare assertion failure.
struct AsyncWaitTimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it returns `true`, or throws once `timeout` has
/// elapsed since the call started.
///
/// Uses `ContinuousClock`, which does not observe wall-clock adjustments, so
/// the deadline reflects elapsed test time even if the system clock changes
/// mid-run. Prefer this over a fixed `Task.sleep` whenever a test is waiting
/// for a broker-backed side effect (delivery, subscription state, container
/// readiness): a fixed sleep either wastes time when the condition is met
/// early or flakes under load when it isn't met in time.
///
/// - Parameters:
///   - description: What is being awaited, used in the timeout error so
///     failures are self-explanatory.
///   - timeout: The maximum time to wait before giving up.
///   - pollInterval: How often to re-check `condition`.
///   - condition: Returns `true` once the awaited state has been observed.
/// - Throws: ``AsyncWaitTimeoutError`` if `condition` never returns `true`
///   before the deadline, or whatever `condition` itself throws.
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(20),
    condition: @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if try await condition() {
            return
        }
        if clock.now >= deadline {
            throw AsyncWaitTimeoutError(
                description: "Timed out after \(timeout) waiting for: \(description)"
            )
        }
        try await _Concurrency.Task.sleep(for: pollInterval)
    }
}

/// Awaits the next element from an `AsyncStream` iterator, failing with a
/// named timeout rather than hanging forever if the awaited stream never
/// delivers.
///
/// The box is generic over `Element: Sendable` (not over the iterator type),
/// so the `@Sendable` task-group closure captures `Element.Type` — which is
/// `Sendable` — rather than the non-`Sendable` iterator metatype that a
/// generic `I: AsyncIteratorProtocol` parameter would introduce.
///
/// - Throws: ``AsyncWaitTimeoutError`` if no value arrives before `timeout`,
///   or `CancellationError` if the stream finishes first.
func nextValue<E: Sendable>(
    _ iterator: inout AsyncStream<E>.Iterator,
    timeout: Duration = .seconds(5)
) async throws -> E {
    let box = AsyncStreamBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: E.self) { group in
        group.addTask {
            guard let value = await box.iterator.next() else {
                throw CancellationError()
            }
            return value
        }
        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw AsyncWaitTimeoutError(
                description: "Timed out after \(timeout) waiting for the next stream value"
            )
        }

        guard let value = try await group.next() else {
            throw AsyncWaitTimeoutError(
                description: "Timed out after \(timeout) waiting for the next stream value"
            )
        }
        group.cancelAll()
        return value
    }
}

/// Runs `operation`, failing with a named timeout instead of hanging forever
/// if it never returns — e.g. `Container.startAndWaitUntilReady()` when no
/// broker is reachable, which otherwise waits on a state stream that never
/// emits `.online`.
///
/// - Throws: ``AsyncWaitTimeoutError`` if `operation` doesn't finish before
///   `timeout`, or whatever `operation` itself throws.
func withTimeout<T: Sendable>(
    _ description: String,
    timeout: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw AsyncWaitTimeoutError(
                description: "Timed out after \(timeout) waiting for: \(description)"
            )
        }
        guard let value = try await group.next() else {
            throw AsyncWaitTimeoutError(
                description: "Timed out after \(timeout) waiting for: \(description)"
            )
        }
        group.cancelAll()
        return value
    }
}

/// A `@unchecked Sendable` box for an `AsyncStream` iterator, generic over
/// `Element: Sendable` so the captured metatype is `Sendable`.
///
/// Shared by the timeout-racing `nextValue` overload above and by the
/// long-lived consumer tasks in `BroadcastTests`, `SensorThingsMocks`, and
/// `AxolotyLifecycleSubjectTests`, replacing the per-file `@unchecked
/// Sendable` box copies those files used to carry.
final class AsyncStreamBox<E: Sendable>: @unchecked Sendable {
    var iterator: AsyncStream<E>.Iterator
    init(_ iterator: AsyncStream<E>.Iterator) {
        self.iterator = iterator
    }
}
