// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public struct EventStream<Element: Sendable>: Sendable, AsyncSequence {

    public typealias AsyncIterator = Iterator

    public struct Iterator: AsyncIteratorProtocol {
        private var storage: Storage
        private let continuation: AnySendableContinuation

        fileprivate init(
            inner: AsyncStream<Element>.AsyncIterator,
            continuation: AnySendableContinuation
        ) {
            self.storage = Storage(inner)
            self.continuation = continuation
        }

        public mutating func next() async -> Element? {
            let cancellation = continuation
            return await withTaskCancellationHandler {
                await storage.next()
            } onCancel: {
                cancellation.finish()
            }
        }

        private struct Storage {
            var inner: AsyncStream<Element>.AsyncIterator

            init(_ inner: AsyncStream<Element>.AsyncIterator) {
                self.inner = inner
            }

            mutating func next() async -> Element? {
                await inner.next()
            }
        }
    }

    private let hub: EventHub
    private let streamId: UUID
    private let buffering: EventStreamBuffering

    public init(
        hub: EventHub,
        streamId: UUID,
        buffering: EventStreamBuffering
    ) {
        self.hub = hub
        self.streamId = streamId
        self.buffering = buffering
    }

    public func makeAsyncIterator() -> Iterator {
        let policy: AsyncStream<Element>.Continuation.BufferingPolicy =
            buffering == .event ? .bufferingOldest(256) : .bufferingNewest(1)

        let (asyncStream, continuation) = AsyncStream<Element>.makeStream(
            bufferingPolicy: policy
        )

        let erased = AnySendableContinuation(continuation)

        hub.registerIteratorContinuation(erased, streamId: streamId)

        return Iterator(inner: asyncStream.makeAsyncIterator(), continuation: erased)
    }

    /// Creates an iterator after its EventHub registration has completed.
    ///
    /// Use this method during a startup barrier when the first event must not
    /// be published before the iterator is attached.
    public func makeAsyncIteratorAndWait() async -> Iterator {
        let policy: AsyncStream<Element>.Continuation.BufferingPolicy =
            buffering == .event ? .bufferingOldest(256) : .bufferingNewest(1)

        let (asyncStream, continuation) = AsyncStream<Element>.makeStream(
            bufferingPolicy: policy
        )
        let erased = AnySendableContinuation(continuation)
        await hub.registerIteratorContinuationAndWait(erased, streamId: streamId)
        return Iterator(inner: asyncStream.makeAsyncIterator(), continuation: erased)
    }
}
