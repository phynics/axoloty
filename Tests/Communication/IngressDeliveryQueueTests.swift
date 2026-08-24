// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

@Suite
struct IngressDeliveryQueueTests {

    @Test
    func shedsNewestJobsWhenDrainerFallsBehind() async throws {
        let queue = IngressDeliveryQueue(capacity: 2)
        let executed = LockedIntArray()
        let startedPhase = OneShotPhase()
        let releasePhase = OneShotPhase()
        defer { releasePhase.signal() }

        // Occupy the single drain task with a slow job, signalling exactly
        // when it has started so the bounded buffer below is guaranteed empty
        // and the drainer is guaranteed busy for the duration of the flood.
        queue.enqueue {
            startedPhase.signal()
            guard await releasePhase.wait() else { return }
            executed.append(0)
        }
        try await waitUntil("ingress drainer to start its blocking job", timeout: .seconds(2)) {
            startedPhase.isSignaled
        }

        // Burst far past the capacity while the drainer is still busy with
        // job 0. `.bufferingOldest(2)` retains the two oldest pending jobs and
        // sheds the newest arrivals from that point on.
        var shed = 0
        for index in 1 ... 20 {
            if !queue.enqueue({ executed.append(index) }) {
                shed += 1
            }
        }

        // Jobs 1 and 2 are retained; jobs 3 ... 20 are shed.
        #expect(shed == 18)
        #expect(queue.droppedCount == 18)

        // After the slow job finishes, the retained jobs drain in submission
        // order — shedding never reorders what survives.
        do {
            try await waitUntil("retained ingress jobs to finish", timeout: .seconds(2)) {
                executed.values.count == 3
            }
        } catch {
            Issue.record(
                "Ingress drain phase timed out; executed: \(executed.values), dropped: \(queue.droppedCount)"
            )
            throw error
        }
        #expect(executed.values == [0, 1, 2])
    }

    @Test
    func deliversAcceptedJobsInSubmissionOrder() async throws {
        // Capacity at least as large as the submitted batch guarantees nothing
        // is shed, so ordering can be asserted without load-timing races.
        let queue = IngressDeliveryQueue(capacity: 128)
        let executed = LockedIntArray()

        for index in 0 ..< 100 {
            queue.enqueue { executed.append(index) }
        }

        try await waitUntil("all 100 jobs to finish") {
            executed.values.count == 100
        }
        #expect(executed.values == Array(0 ..< 100))
        #expect(queue.droppedCount == 0)
    }

    @Test
    func clampsCapacityBelowOneToOne() async throws {
        let queue = IngressDeliveryQueue(capacity: 0)
        let executed = LockedIntArray()

        // The clamp to one retains a single pending job rather than shedding
        // every submission, so the queue remains usable for any input.
        queue.enqueue { executed.append(1) }

        try await waitUntil("the clamped-capacity job to finish") {
            executed.values == [1]
        }
        #expect(queue.droppedCount == 0)
    }
}

/// Thread-safe append-only `[Int]` for asserting drain order from jobs that
/// run on the queue's single drain task.
private final class LockedIntArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [Int]()

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class OneShotPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private let continuation: AsyncStream<Void>.Continuation
    let stream: AsyncStream<Void>

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    var isSignaled: Bool {
        lock.withLock { signaled }
    }

    func signal() {
        let shouldSignal = lock.withLock {
            guard !signaled else { return false }
            signaled = true
            return true
        }
        if shouldSignal {
            continuation.yield(())
            continuation.finish()
        }
    }

    func wait() async -> Bool {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
    }
}
