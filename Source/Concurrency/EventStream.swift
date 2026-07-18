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

    private let asyncStream: AsyncStream<Element>
    private let continuation: AnySendableContinuation

    internal init(
        asyncStream: AsyncStream<Element>,
        continuation: AnySendableContinuation
    ) {
        self.asyncStream = asyncStream
        self.continuation = continuation
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
        Iterator(inner: asyncStream.makeAsyncIterator(), continuation: continuation)
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
