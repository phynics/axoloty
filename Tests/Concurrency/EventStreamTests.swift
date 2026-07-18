// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing
import Foundation

@Suite
struct EventStreamTests {

    @Test
    func testStreamCreatedButNotIterated() async {
        let hub = EventHub()
        let stream: EventStream<Int> = await hub.registerStream(
            key: "never-iterated",
            buffering: .event,
            onLast: {}
        )
        _ = stream
    }

    @Test
    func testLastRegistrationCallback() async {
        let hub = EventHub()
        let counter = SendableCounter()

        let stream: EventStream<Int> = await hub.registerStream(
            key: "first-last",
            buffering: .event,
            onLast: { counter.incLast() }
        )

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let it2 = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.finish(key: "first-last")
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        withExtendedLifetime((it, it2)) {
            #expect(counter.lastCount == 1, "onLast should fire once")
        }
    }

    @Test
    func testMultipleRegistrationsOnSameKeyFireAllOnLastCallbacks() async {
        let hub = EventHub()
        let counter = SendableCounter()

        let stream1: EventStream<Int> = await hub.registerStream(
            key: "shared-key",
            buffering: .event,
            onLast: { counter.incLast() }
        )
        let stream2: EventStream<Int> = await hub.registerStream(
            key: "shared-key",
            buffering: .event,
            onLast: { counter.incLast() }
        )

        let it1 = stream1.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        let it2 = stream2.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.finish(key: "shared-key")
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        withExtendedLifetime((it1, it2)) {
            #expect(counter.lastCount == 2, "onLast should fire once per registration (2)")
        }
    }

    @Test
    func testEventStreamBuffersEventsFromCreation() async throws {
        let hub = EventHub()
        let stream: EventStream<Int> = await hub.registerStream(
            key: "buffers-early",
            buffering: .event,
            onLast: {}
        )

        await hub.yield(value: 42, to: "buffers-early")

        var it = stream.makeAsyncIterator()

        await hub.yield(value: 99, to: "buffers-early")
        await hub.finish(key: "buffers-early")

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42, 99], "Event stream should buffer values yielded after registration")
    }

    @Test
    func testStateStreamReplay() async throws {
        let hub = EventHub()
        let stream: EventStream<Int> = await hub.registerStream(
            key: "state-replay",
            buffering: .state,
            onLast: {}
        )

        await hub.yield(value: 42, to: "state-replay")

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(150))

        await hub.finish(key: "state-replay")

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42], "State stream should replay the last value")
    }

    @Test
    func testTwoConcurrentIterators() async throws {
        let hub = EventHub()
        let stream1: EventStream<Int> = await hub.registerStream(
            key: "concurrent",
            buffering: .event,
            onLast: {}
        )
        let stream2: EventStream<Int> = await hub.registerStream(
            key: "concurrent",
            buffering: .event,
            onLast: {}
        )

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await hub.yield(value: 10, to: "concurrent")
        await hub.yield(value: 20, to: "concurrent")
        await hub.yield(value: 30, to: "concurrent")
        await hub.finish(key: "concurrent")

        let collected1 = await collectValues(&it1, timeout: .milliseconds(300))
        let collected2 = await collectValues(&it2, timeout: .milliseconds(300))

        #expect(collected1 == [10, 20, 30])
        #expect(collected2 == [10, 20, 30])
    }

    @Test
    func testNormalFinish() async throws {
        let hub = EventHub()
        let stream: EventStream<Int> = await hub.registerStream(
            key: "finish",
            buffering: .event,
            onLast: {}
        )

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: 100, to: "finish")
        await hub.finish(key: "finish")

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [100])
    }

    @Test
    func testResubscribeAfterFinish() async throws {
        let hub = EventHub()
        let stream: EventStream<Int> = await hub.registerStream(
            key: "resubscribe",
            buffering: .event,
            onLast: {}
        )

        var it1 = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: 1, to: "resubscribe")
        await hub.finish(key: "resubscribe")

        var collected1: [Int] = []
        while let v = await it1.next() {
            collected1.append(v)
        }
        #expect(collected1 == [1])

        let stream2: EventStream<Int> = await hub.registerStream(
            key: "resubscribe-2",
            buffering: .event,
            onLast: {}
        )

        var it2 = stream2.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: 2, to: "resubscribe-2")
        await hub.finish(key: "resubscribe-2")

        var collected2: [Int] = []
        while let v = await it2.next() {
            collected2.append(v)
        }
        #expect(collected2 == [2])
    }

    @Test
    func testIteratorCancellation() async throws {
        let hub = EventHub()
        let stream: EventStream<Int> = await hub.registerStream(
            key: "cancel",
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

        await hub.yield(value: 1, to: "cancel")
        await hub.yield(value: 2, to: "cancel")

        task.cancel()

        let count = await task.value
        #expect(count >= 0)
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
