// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing
import Foundation

@Suite
struct EventStreamTests {

    @Test
    func testStreamCreatedButNotIterated() async {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "never-iterated")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )
        _ = stream
    }

    @Test
    func testDroppingUniteratedStreamFiresOnLast() async throws {
        let hub = EventHub()
        let counter = SendableCounter()
        let key = EventKey<Int>(scope: "test", name: "uniterated-drop")

        var stream: EventStream<Int>? = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: { counter.incLast() }
        )
        stream = nil

        try? await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(counter.lastCount == 1, "onLast should fire when an uniterated stream is dropped")
    }

    @Test
    func testLastRegistrationCallback() async {
        let hub = EventHub()
        let counter = SendableCounter()
        let key = EventKey<Int>(scope: "test", name: "first-last")

        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: { counter.incLast() }
        )

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let it2 = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.finish(key: key)
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        withExtendedLifetime((it, it2)) {
            #expect(counter.lastCount == 1, "onLast should fire once")
        }
    }

    @Test
    func testMultipleRegistrationsOnSameKeyFireAllOnLastCallbacks() async {
        let hub = EventHub()
        let counter = SendableCounter()
        let key = EventKey<Int>(scope: "test", name: "shared-key")

        let stream1: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: { counter.incLast() }
        )
        let stream2: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: { counter.incLast() }
        )

        let it1 = stream1.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        let it2 = stream2.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.finish(key: key)
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        withExtendedLifetime((it1, it2)) {
            #expect(counter.lastCount == 2, "onLast should fire once per registration (2)")
        }
    }

    @Test
    func testEventStreamBuffersEventsFromCreation() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "buffers-early")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )

        await hub.yield(value: 42, to: key)

        var it = stream.makeAsyncIterator()

        await hub.yield(value: 99, to: key)
        await hub.finish(key: key)

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42, 99], "Event stream should buffer values yielded after registration")
    }

    @Test
    func testStateStreamReplay() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "state-replay")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .state,
            onLast: {}
        )

        await hub.yield(value: 42, to: key)

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(150))

        await hub.finish(key: key)

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42], "State stream should replay the last value")
    }

    /// Characterization: `.event` streams do NOT replay to late
    /// **subscribers** (new registrations). Only `.state` streams replay the
    /// last value to a newly registered continuation. Values yielded to an
    /// existing continuation before its iterator is created ARE buffered by
    /// the underlying `AsyncStream` (see `testEventStreamBuffersEventsFromCreation`).
    @Test
    func testEventStreamDoesNotReplayToLateSubscriber() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "no-replay")

        let stream1: EventStream<Int> = await hub.registerStream(
            key: key, buffering: .event, onLast: {}
        )
        await hub.yield(value: 42, to: key)

        // A late second subscriber registers. For `.event`, it should NOT
        // receive the previously yielded value (unlike `.state` which replays).
        let stream2: EventStream<Int> = await hub.registerStream(
            key: key, buffering: .event, onLast: {}
        )

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await hub.yield(value: 99, to: key)
        await hub.finish(key: key)

        var values1: [Int] = []
        while let v = await it1.next() { values1.append(v) }

        var values2: [Int] = []
        while let v = await it2.next() { values2.append(v) }

        #expect(values1 == [42, 99], "First subscriber gets buffered + live values")
        #expect(values2 == [99], "Late .event subscriber does not get replay")
    }

    /// Characterization: `finish(key:)` clears replay state. A new subscriber
    /// registered after `finish` does not receive the pre-finish state.
    @Test
    func testFinishClearsReplayState() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "finish-clears-state")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .state,
            onLast: {}
        )

        await hub.yield(value: 42, to: key)
        await hub.finish(key: key)
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        // After finish, the replay state is gone.
        let stream2: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .state,
            onLast: {}
        )
        var it = stream2.makeAsyncIterator()
        await hub.finish(key: key)

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [], "finish should clear replay state for state streams")
        _ = stream
    }

    @Test
    func testTwoConcurrentIterators() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "concurrent")
        let stream1: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )
        let stream2: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await hub.yield(value: 10, to: key)
        await hub.yield(value: 20, to: key)
        await hub.yield(value: 30, to: key)
        await hub.finish(key: key)

        let collected1 = await collectValues(&it1, timeout: .milliseconds(300))
        let collected2 = await collectValues(&it2, timeout: .milliseconds(300))

        #expect(collected1 == [10, 20, 30])
        #expect(collected2 == [10, 20, 30])
    }

    @Test
    func testNormalFinish() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "finish")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: 100, to: key)
        await hub.finish(key: key)

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [100])
    }

    @Test
    func testResubscribeAfterFinish() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "resubscribe")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )

        var it1 = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: 1, to: key)
        await hub.finish(key: key)

        var collected1: [Int] = []
        while let v = await it1.next() {
            collected1.append(v)
        }
        #expect(collected1 == [1])

        let key2 = EventKey<Int>(scope: "test", name: "resubscribe-2")
        let stream2: EventStream<Int> = await hub.registerStream(
            key: key2,
            buffering: .event,
            onLast: {}
        )

        var it2 = stream2.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: 2, to: key2)
        await hub.finish(key: key2)

        var collected2: [Int] = []
        while let v = await it2.next() {
            collected2.append(v)
        }
        #expect(collected2 == [2])
    }

    @Test
    func testIteratorCancellation() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "cancel")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: {}
        )

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let holder = EventStreamBox(it)
        let task = _Concurrency.Task {
            var count = 0
            while let _ = await holder.iterator.next() {
                count += 1
            }
            return count
        }

        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        await hub.yield(value: 1, to: key)
        await hub.yield(value: 2, to: key)

        task.cancel()

        let count = await task.value
        #expect(count >= 0)
    }

    /// Characterization: task cancellation mid-iteration fires `onLast` when
    /// the cancelled iterator was the last one.
    @Test
    func testCancellationFiresOnLastWhenLastIterator() async throws {
        let hub = EventHub()
        let counter = SendableCounter()
        let key = EventKey<Int>(scope: "test", name: "cancel-onlast")
        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .event,
            onLast: { counter.incLast() }
        )

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let holder = EventStreamBox(it)
        let task = _Concurrency.Task {
            while let _ = await holder.iterator.next() {}
        }

        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value

        try? await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(counter.lastCount == 1, "onLast should fire when the last iterator is cancelled")
    }

    /// Characterization: `yieldState` stores the value even before any
    /// subscriber registers, so the first subscriber receives it on attach.
    @Test
    func testYieldStateBeforeSubscriberReplaysOnAttach() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "state-before-sub")

        await hub.yieldState(value: 42, to: key)

        let stream: EventStream<Int> = await hub.registerStream(
            key: key,
            buffering: .state,
            onLast: {}
        )
        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        await hub.finish(key: key)

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42], "yieldState before subscriber should replay on attach")
    }

    /// The phantom element type links `yield` and `registerStream` at compile
    /// time. A wrong-typed yield (e.g. `yield(value: "string", to: intKey)`)
    /// does not compile — the type mismatch is caught at the call site, not
    /// silently dropped at runtime. This test verifies the happy path; the
    /// compile-fail case is documented rather than asserted, since Swift
    /// Testing has no compile-fail fixture mechanism.
    @Test
    func testTypedKeyYieldTypeChecks() async throws {
        let hub = EventHub()
        let intKey = EventKey<Int>(scope: "test", name: "typed-int")
        let stringKey = EventKey<String>(scope: "test", name: "typed-string")

        let intStream: EventStream<Int> = await hub.registerStream(
            key: intKey, buffering: .event, onLast: {}
        )
        let stringStream: EventStream<String> = await hub.registerStream(
            key: stringKey, buffering: .event, onLast: {}
        )

        var intIt = intStream.makeAsyncIterator()
        var stringIt = stringStream.makeAsyncIterator()

        await hub.yield(value: 42, to: intKey)
        await hub.yield(value: "hello", to: stringKey)
        await hub.finish(key: intKey)
        await hub.finish(key: stringKey)

        var intValues: [Int] = []
        while let v = await intIt.next() { intValues.append(v) }

        var stringValues: [String] = []
        while let v = await stringIt.next() { stringValues.append(v) }

        #expect(intValues == [42])
        #expect(stringValues == ["hello"])
    }

    @Test
    func testConcurrentYieldSubscribeTerminateUnderLoad() async throws {
        let hub = EventHub()
        let key = EventKey<Int>(scope: "test", name: "load")

        await withTaskGroup(of: Void.self) { group in
            // Subscribers come and go.
            for _ in 0..<10 {
                group.addTask {
                    let stream: EventStream<Int> = await hub.registerStream(
                        key: key, buffering: .event, onLast: {}
                    )
                    var it = stream.makeAsyncIterator()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(10))
                    _ = await it.next()
                }
            }
            // Yielders.
            for i in 0..<50 {
                group.addTask {
                    await hub.yield(value: i, to: key)
                }
            }
            // A finisher.
            group.addTask {
                try? await _Concurrency.Task.sleep(for: .milliseconds(50))
                await hub.finish(key: key)
            }
        }

        // The test passes if it completes without deadlock or data-race trap.
        #expect(true)
    }
}

// MARK: - Helpers

private final class SendableCounter: @unchecked Sendable {
    private(set) var lastCount = 0
    func incLast() { lastCount += 1 }
}

private func collectValues<T: Sendable>(
    _ iterator: inout EventStream<T>.Iterator,
    timeout: Duration
) async -> [T] {
    var values: [T] = []
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let v = await iterator.next() {
            values.append(v)
        } else {
            break
        }
    }
    return values
}
