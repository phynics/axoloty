// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public struct EventStream<Element: Sendable>: Sendable, AsyncSequence {

    public typealias AsyncIterator = Iterator

    public struct Iterator: AsyncIteratorProtocol {
        private var storage: Storage
        private let continuation: AsyncStream<Element>.Continuation
        private let lifecycle: StreamLifecycle<Element>

        fileprivate init(
            inner: AsyncStream<Element>.AsyncIterator,
            continuation: AsyncStream<Element>.Continuation,
            lifecycle: StreamLifecycle<Element>
        ) {
            self.storage = Storage(inner)
            self.continuation = continuation
            self.lifecycle = lifecycle
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

    private let asyncStream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let lifecycle: StreamLifecycle<Element>

    internal init(
        asyncStream: AsyncStream<Element>,
        continuation: AsyncStream<Element>.Continuation
    ) {
        self.asyncStream = asyncStream
        self.continuation = continuation
        self.lifecycle = StreamLifecycle(continuation)
    }

    /// Creates and returns an iterator.
    ///
    /// The continuation is registered with the ``EventHub`` eagerly when the
    /// ``EventStream`` is created via
    /// ``EventHub/registerStream(key:buffering:onLast:)``, so values yielded
    /// after stream creation are buffered and delivered to the first iterator.
    /// This method is synchronous (required by `AsyncSequence` conformance)
    /// and safe — no registration race.
    public func makeAsyncIterator() -> Iterator {
        Iterator(
            inner: asyncStream.makeAsyncIterator(),
            continuation: continuation,
            lifecycle: lifecycle
        )
    }

    /// Creates an iterator.
    ///
    /// Registration is now eager (see ``makeAsyncIterator()``), so this
    /// method is equivalent and retained for source compatibility with
    /// callers that previously needed the registration-safe path.
    public func makeAsyncIteratorAndWait() async -> Iterator {
        makeAsyncIterator()
    }
}

/// Owns the lifetime of an ``EventStream``'s underlying continuation.
///
/// When an ``EventStream`` is dropped without being iterated (or while
/// iterators are still live), finishing the continuation here ensures the
/// hub's `onLast` callback fires and MQTT subscription refcounting unwinds.
private final class StreamLifecycle<Element: Sendable>: Sendable {
    private let continuation: AsyncStream<Element>.Continuation

    init(_ continuation: AsyncStream<Element>.Continuation) {
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }
}
