// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorRuntime
import Foundation
import Testing

@MainActor
final class StatusSession: InspectorSession {
    var state: InspectorTransportState = .online

    func connect() async throws {}
    func transportState() async -> InspectorTransportState { state }
    func advertiseEvents() async -> AsyncStream<InspectorAdvertiseEvent> {
        AsyncStream { $0.finish() }
    }
    func deadvertiseEvents() async -> AsyncStream<InspectorDeadvertiseEvent> {
        AsyncStream { $0.finish() }
    }
    func discover(_ event: InspectorDiscoverRequest) async -> AsyncStream<InspectorResponseEvent> {
        AsyncStream { _ in }
    }
    func stop() {}
}

struct ForcedEncodingError: LocalizedError {
    let operation: String

    var errorDescription: String? { "forced \(operation) encoding failure" }
}

struct TestDeadlineExceeded: LocalizedError {
    let description: String

    init(description: String = "test phase") {
        self.description = description
    }

    var errorDescription: String? {
        "timed out waiting for \(description)"
    }
}

final class DeadlineResultBox<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case resolved(Result<Value, Error>)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?
    private var state: State = .pending

    func install(
        _ continuation: CheckedContinuation<Result<Value, Error>, Never>
    ) {
        lock.lock()
        if case let .resolved(result) = state {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return
        }
        state = .resolved(result)
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            lock.unlock()
        }
    }
}

/// Races an unstructured operation against a deadline without joining a child
/// that ignores cancellation. Test operations remain responsible for cleaning
/// up any resources they own after this function reports a timeout.
func withDeadline<Value: Sendable>(
    _ description: String,
    timeout: Duration = .seconds(5),
    recordTimeout: Bool = true,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let resultBox = DeadlineResultBox<Value>()
    let operationTask = Task {
        do {
            resultBox.resolve(.success(try await operation()))
        } catch {
            resultBox.resolve(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
            resultBox.resolve(.failure(TestDeadlineExceeded(description: description)))
        } catch {
            // The operation won the race or the parent task was cancelled.
        }
    }

    let result: Result<Value, Error> = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            resultBox.install(continuation)
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        resultBox.resolve(.failure(CancellationError()))
    }

    timeoutTask.cancel()
    if case .failure(let error) = result,
       error is TestDeadlineExceeded {
        operationTask.cancel()
        if recordTimeout {
            Issue.record("Timed out waiting for \(description)")
        }
    }
    return try result.get()
}

func waitForCondition(
    _ description: String,
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    try await withDeadline(description, timeout: timeout) {
        while !(await condition()) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
