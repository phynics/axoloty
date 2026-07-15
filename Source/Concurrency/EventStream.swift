// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public struct EventStream<Element: Sendable>: Sendable, AsyncSequence {

    public typealias AsyncIterator = Iterator

    public struct Iterator: AsyncIteratorProtocol {
        private var inner: AsyncStream<Element>.AsyncIterator

        fileprivate init(inner: AsyncStream<Element>.AsyncIterator) {
            self.inner = inner
        }

        public mutating func next() async -> Element? {
            await inner.next()
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

        return Iterator(inner: asyncStream.makeAsyncIterator())
    }
}
