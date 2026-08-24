// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Test("nextValue returns a delivered stream element")
func nextValueReturnsDeliveredElement() async throws {
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    var iterator = stream.makeAsyncIterator()
    continuation.yield(7)

    #expect(try await nextValue(&iterator, timeout: .seconds(1)) == 7)
    continuation.finish()
}

@Test("nextValue reports a finished stream as cancellation")
func nextValueReportsFinishedStream() async throws {
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    var iterator = stream.makeAsyncIterator()
    continuation.finish()

    do {
        _ = try await nextValue(&iterator, timeout: .seconds(1))
        Issue.record("expected the finished stream to throw CancellationError")
    } catch is CancellationError {
        // Expected.
    }
}

@Test("nextValue timeout names the awaited stream phase")
func nextValueTimeoutNamesStreamPhase() async throws {
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    var iterator = stream.makeAsyncIterator()

    do {
        _ = try await nextValue(&iterator, timeout: .milliseconds(50))
        Issue.record("expected nextValue to time out")
    } catch let error as AsyncWaitTimeoutError {
        #expect(error.description.contains("the next stream value"))
    }
    continuation.finish()
}

@Test("withTimeout returns a successful operation")
func withTimeoutReturnsSuccessfulOperation() async throws {
    let value = try await withTimeout("successful operation", timeout: .seconds(1)) {
        "ready"
    }

    #expect(value == "ready")
}

@Test("withTimeout forwards an operation error")
func withTimeoutForwardsOperationError() async throws {
    do {
        let _: Void = try await withTimeout("failing operation", timeout: .seconds(1)) {
            throw TestAsyncWaitingError.expected
        }
        Issue.record("expected the operation error to be forwarded")
    } catch is TestAsyncWaitingError {
        // Expected.
    }
}

@Test("withTimeout returns without joining a cancellation-resistant operation")
func withTimeoutDoesNotJoinCancellationResistantOperation() async throws {
    let gate = CancellationResistantGate()

    do {
        _ = try await withTimeout("hostile operation", timeout: .milliseconds(50)) {
            await gate.wait()
            return "released"
        }
        Issue.record("expected the hostile operation to time out")
    } catch let error as AsyncWaitTimeoutError {
        #expect(error.description.contains("hostile operation"))
    }

    #expect(await gate.entered)
    // The timed-out operation is intentionally still alive. Release its gate
    // explicitly so the test does not leave a hostile task behind.
    await gate.release()
    try await waitForAsyncWaitingProbe("hostile operation release") {
        await gate.resumed
    }
}

@Test("withTimeout preserves parent cancellation without joining its child")
func withTimeoutPreservesParentCancellation() async throws {
    let gate = CancellationResistantGate()
    let waiter = Task {
        do {
            _ = try await withTimeout("cancelled operation", timeout: .seconds(5)) {
                await gate.wait()
                return "released"
            }
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    try await waitForAsyncWaitingProbe("cancelled operation entry") {
        await gate.entered
    }
    waiter.cancel()
    #expect(await waiter.value)

    // Cancellation must return promptly, but the cancellation-resistant
    // operation still owns the gate until the test releases it.
    await gate.release()
    try await waitForAsyncWaitingProbe("cancelled operation release") {
        await gate.resumed
    }
}

@Test("nextValue preserves parent cancellation")
func nextValuePreservesParentCancellation() async throws {
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    let iteratorBox = AsyncStreamBox(stream.makeAsyncIterator())
    let waiter = Task {
        do {
            _ = try await nextValue(&iteratorBox.iterator, timeout: .seconds(5))
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    waiter.cancel()
    #expect(await waiter.value)
    continuation.finish()
}

@Test("withTimeout accepts only the first race resolution")
func withTimeoutAcceptsOnlyFirstResolution() async throws {
    let gate = CancellationResistantGate()

    do {
        _ = try await withTimeout("first resolution", timeout: .milliseconds(50)) {
            await gate.wait()
            return "late operation"
        }
        Issue.record("expected the timeout to win the race")
    } catch is AsyncWaitTimeoutError {
        // Expected.
    }

    await gate.release()
    try await waitForAsyncWaitingProbe("late operation release") {
        await gate.resumed
    }
}

private enum TestAsyncWaitingError: Error {
    case expected
}

private actor CancellationResistantGate {
    private(set) var entered = false
    private(set) var resumed = false
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if isReleased {
            resumed = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        resumed = true
    }

    func release() {
        isReleased = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct AsyncWaitingProbeTimeout: Error, CustomStringConvertible {
    let description: String
}

private func waitForAsyncWaitingProbe(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline {
            throw AsyncWaitingProbeTimeout(description: description)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
