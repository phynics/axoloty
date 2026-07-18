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

    internal init(
        hub: EventHub,
        streamId: UUID,
        buffering: EventStreamBuffering
    ) {
        self.hub = hub
        self.streamId = streamId
        self.buffering = buffering
    }

    /// Creates and returns an iterator, registering its continuation with the
    /// ``EventHub`` asynchronously.
    ///
    /// - Warning: The continuation is registered through a detached task (the
    ///   ``EventHub`` is an actor, so a non-`async` caller can't reach its
    ///   isolated state directly), so it is not yet visible to the hub when
    ///   this method returns. For ``EventStreamBuffering/event`` streams,
    ///   values yielded to the hub in the window between this method's return
    ///   and the detached task's completion are dropped — the hub has no
    ///   continuation to route them to. ``EventStreamBuffering/state`` streams
    ///   replay the last value to a late-registering iterator and are not
    ///   affected. This non-`async` signature is required by `AsyncSequence`
    ///   conformance, which is why the race can't be closed without a breaking
    ///   redesign (see #74). Callers that must not lose the first event should
    ///   use ``makeAsyncIteratorAndWait()`` instead, which awaits registration
    ///   before returning.
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
    /// be published before the iterator is attached. This is the safe
    /// alternative to ``makeAsyncIterator()`` (which `AsyncSequence`'s
    /// `for await` syntax uses): it awaits the hub's registration before
    /// returning, so no event yielded afterward can fall in the registration
    /// race window. See ``makeAsyncIterator()``'s warning for the race.
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
