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

private enum AsyncWaitResolution<Value> {
    case operation(Result<Value, Error>)
    case timeout(AsyncWaitTimeoutError)
    case cancelled
}

/// Stores exactly one result for an unstructured async wait race.
///
/// The continuation is deliberately resumed outside the lock. A late
/// operation or timer can still call ``resolve(_:)`` after the caller has
/// returned, but it is ignored once another phase has won the race.
private final class AsyncWaitResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AsyncWaitResolution<Value>, Never>?
    private var resolution: AsyncWaitResolution<Value>?

    func install(
        _ continuation: CheckedContinuation<AsyncWaitResolution<Value>, Never>
    ) {
        lock.lock()
        if let resolution {
            lock.unlock()
            continuation.resume(returning: resolution)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ resolution: AsyncWaitResolution<Value>) {
        lock.lock()
        guard self.resolution == nil else {
            lock.unlock()
            return
        }
        self.resolution = resolution
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: resolution)
    }

    func wait() async -> AsyncWaitResolution<Value> {
        await withCheckedContinuation { continuation in
            install(continuation)
        }
    }
}

private func timeoutError(
    _ phase: String,
    timeout: Duration
) -> AsyncWaitTimeoutError {
    AsyncWaitTimeoutError(
        description: "Timed out after \(timeout) waiting for: \(phase)"
    )
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
    condition: @MainActor @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if try await condition() {
            return
        }
        if clock.now >= deadline {
            throw timeoutError(description, timeout: timeout)
        }
        try await Task.sleep(for: pollInterval)
    }
}

/// Awaits the next element from an `AsyncStream` iterator, failing with a
/// named timeout rather than hanging forever if the awaited stream never
/// delivers.
///
/// The box is generic over `Element: Sendable` (not over the iterator type),
/// so the `@Sendable` operation closure captures `Element.Type` — which is
/// `Sendable` — rather than the non-`Sendable` iterator metatype that a
/// generic `I: AsyncIteratorProtocol` parameter would introduce.
///
/// - Throws: ``AsyncWaitTimeoutError`` if no value arrives before `timeout`,
///   or `CancellationError` if the stream finishes first.
///
/// If timeout or parent cancellation wins, the operation task is cancelled
/// but is not awaited. This is required to keep a cancellation-resistant
/// iterator from holding the caller's task open. In that case the passed
/// iterator is deliberately left untouched; its owner must release the
/// underlying stream/operation before attempting to use another iterator for
/// the same stream.
func nextValue<E: Sendable>(
    _ iterator: inout AsyncStream<E>.Iterator,
    timeout: Duration = .seconds(5)
) async throws -> E {
    try Task.checkCancellation()
    let box = AsyncStreamBox(iterator)
    let resultBox = AsyncWaitResultBox<E>()
    let operationTask = Task {
        guard let value = await box.iterator.next() else {
            resultBox.resolve(.operation(.failure(CancellationError())))
            return
        }
        resultBox.resolve(.operation(.success(value)))
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let timeoutTask = Task {
        do {
            try await clock.sleep(until: deadline)
            resultBox.resolve(
                .timeout(timeoutError("the next stream value", timeout: timeout))
            )
        } catch {
            // The operation won the race or the parent task was cancelled.
        }
    }

    let resolution = await withTaskCancellationHandler(operation: {
        await resultBox.wait()
    }, onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        resultBox.resolve(.cancelled)
    })

    timeoutTask.cancel()
    switch resolution {
    case let .operation(result):
        operationTask.cancel()
        // An operation resolution is emitted as the final operation-task
        // action. Awaiting it here makes copying the iterator back safe.
        await operationTask.value
        iterator = box.iterator
        return try result.get()
    case let .timeout(error):
        operationTask.cancel()
        throw error
    case .cancelled:
        operationTask.cancel()
        throw CancellationError()
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
    try Task.checkCancellation()
    let resultBox = AsyncWaitResultBox<T>()
    let operationTask = Task {
        do {
            resultBox.resolve(.operation(.success(try await operation())))
        } catch {
            resultBox.resolve(.operation(.failure(error)))
        }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let timeoutTask = Task {
        do {
            try await clock.sleep(until: deadline)
            resultBox.resolve(.timeout(timeoutError(description, timeout: timeout)))
        } catch {
            // The operation won the race or the parent task was cancelled.
        }
    }

    let resolution = await withTaskCancellationHandler(operation: {
        await resultBox.wait()
    }, onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        resultBox.resolve(.cancelled)
    })

    timeoutTask.cancel()
    operationTask.cancel()
    switch resolution {
    case let .operation(result):
        await operationTask.value
        return try result.get()
    case let .timeout(error):
        throw error
    case .cancelled:
        throw CancellationError()
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
