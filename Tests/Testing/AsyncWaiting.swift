// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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

/// Awaits the next element from `iterator`, failing with a named timeout
/// rather than hanging forever if the awaited stream never delivers.
///
/// Shared across suites that consume ``EventStream`` or `AsyncStream`
/// iterators (both conform to `AsyncIteratorProtocol`), so each test file
/// doesn't need its own copy of this task-group race.
///
/// - Throws: ``AsyncWaitTimeoutError`` if no value arrives before `timeout`,
///   or `CancellationError` if the stream finishes first.
func nextValue<I: AsyncIteratorProtocol>(
    _ iterator: inout I,
    timeout: Duration = .seconds(5)
) async throws -> I.Element where I.Element: Sendable {
    let box = SharedAsyncIteratorBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: I.Element.self) { group in
        // Note: this `@Sendable` closure captures `box: SharedAsyncIteratorBox<I>`,
        // which is generic over `I`, so the compiler captures the non-`Sendable`
        // metatype `I.Type` ("capture of non-Sendable type 'I.Type' in an
        // isolated closure"). Left intentionally:
        //  - Constraining `I: Sendable` breaks every caller, which passes
        //    `EventStream.Iterator` (wraps the non-`Sendable`
        //    `AsyncStream.AsyncIterator` in a `var`).
        //  - Type-erasing the box to non-generic loses the `defer { iterator =
        //    box.iterator }` restore that multi-call callers
        //    (`ObjectLifecycleControllerTests`, `EventHubTransportTests`) rely on.
        // A real fix needs an actor-based type-erasure refactor that preserves
        // the restore; tracked separately.
        group.addTask {
            guard let value = try await box.iterator.next() else {
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

/// Lets a non-`Sendable` iterator be captured by a `@Sendable` closure (e.g.
/// a spawned `Task`'s body) without tripping strict-concurrency checks.
/// `@unchecked` is safe here because callers only ever touch `iterator` from
/// one execution context at a time (this test target never shares one across
/// concurrent tasks).
final class SharedAsyncIteratorBox<I: AsyncIteratorProtocol>: @unchecked Sendable {
    var iterator: I
    init(_ iterator: I) {
        self.iterator = iterator
    }
}
