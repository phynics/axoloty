// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging
import NIOConcurrencyHelpers

/// A bounded, single-consumer queue that serializes `@Sendable` asynchronous
/// jobs in arrival order.
///
/// mqtt-nio's publish listener fires synchronously per PUBLISH on its event
/// loop, but delivering each message into the async ``Broadcast`` graph is
/// `async`. Feeding one synchronous continuation and draining it from a single
/// long-lived task restores arrival ordering (see issue #56). This type adds
/// the bounded-ingress guarantee (issue #448): the continuation is backed by a
/// fixed-capacity buffer using
/// `AsyncStream.Continuation.BufferingPolicy.bufferingOldest(_:)`, so when the
/// single drain task falls behind the producer the *newest* queued jobs are
/// shed instead of being retained without limit. Jobs that survive are still
/// drained in their original arrival order.
///
/// Shedding is observable through ``enqueue(_:)``'s return value and
/// ``droppedCount``, so the owner can report overload through rate-limited
/// logging or structured telemetry.
final class IngressDeliveryQueue: @unchecked Sendable {

    /// Number of jobs retained in the buffer while the drain task falls
    /// behind. This is a scheduling bound, not an API contract: producers that
    /// consistently outpace the drain task shed the newest work beyond this
    /// many retained jobs.
    static let defaultCapacity = 1024

    /// Actual retained-job bound used by this queue. Equals
    /// ``IngressDeliveryQueue/defaultCapacity`` unless a custom (possibly
    /// below-`1`, hence clamped) value was supplied at initialization.
    let capacity: Int

    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private let task: Task<Void, Never>
    private let lock = NIOLock()
    private var droppedValue = 0

    /// Total number of jobs shed since this queue was created because the
    /// bounded buffer was already full. Jobs submitted after ``finish()`` are
    /// not counted as overload (they are dropped without incrementing).
    var droppedCount: Int {
        lock.withLock { droppedValue }
    }

    /// Creates a queue retaining at most `capacity` un-drained jobs before it
    /// starts shedding the newest arrivals.
    ///
    /// - Parameter capacity: number of queued (not yet started) jobs to retain.
    ///   Values below `1` are clamped to `1` so the queue always retains at
    ///   least one pending job under load.
    init(capacity: Int = IngressDeliveryQueue.defaultCapacity) {
        let clampedCapacity = max(capacity, 1)
        self.capacity = clampedCapacity
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream(
            bufferingPolicy: .bufferingOldest(clampedCapacity)
        )
        self.continuation = continuation
        self.task = Task<Void, Never>(priority: .userInitiated) {
            for await job in stream {
                await job()
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Enqueues `job` for serialized execution in submission order.
    ///
    /// - Parameter job: the asynchronous work to run.
    /// - Returns: `true` when the job was accepted, `false` when it was shed
    ///   because the bounded buffer was already full, or because the queue
    ///   has been ``finish()``-ed.
    @discardableResult
    func enqueue(_ job: @escaping @Sendable () async -> Void) -> Bool {
        switch continuation.yield(job) {
        case .enqueued:
            return true
        case .dropped:
            lock.withLock { droppedValue += 1 }
            return false
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Ends the stream of jobs. Any job submitted afterwards is not accepted.
    func finish() {
        continuation.finish()
    }
}

/// Rate-limits overload reporting for a bounded ingress queue.
///
/// Batches shedded-job accounting so a sustained flood logs at most once per
/// second instead of once per dropped message, while still carrying the batch
/// count, lifetime total, and queue capacity as structured metadata. The
/// logging concern is kept out of ``IngressDeliveryQueue`` so the queue stays a
/// pure scheduling primitive and the owner (``MQTTNIOClient``) supplies its own
/// subsystem logger.
final class IngressOverloadReporter: @unchecked Sendable {

    private let lock = NIOLock()
    private var droppedSinceLastLog = 0
    private var nextLogAt = DispatchTime.now()

    /// Records one shedded delivery job and, no more than once per second,
    /// emits a `notice` line with the batched and lifetime drop counts.
    func reportSheddedJob(totalDropped: Int, capacity: Int, log: Logger) {
        let batch = lock.withLock { () -> Int? in
            droppedSinceLastLog += 1
            let now = DispatchTime.now()
            guard now >= nextLogAt else { return nil }
            nextLogAt = now + .seconds(1)
            let dropped = droppedSinceLastLog
            droppedSinceLastLog = 0
            return dropped
        }
        guard let batch else { return }
        log.notice("MQTT ingress delivery queue overload; shedding inbound messages", metadata: [
            "droppedSinceLastReport": .stringConvertible(batch),
            "totalDropped": .stringConvertible(totalDropped),
            "capacity": .stringConvertible(capacity),
        ])
    }
}