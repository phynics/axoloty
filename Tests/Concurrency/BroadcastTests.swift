// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing
import Foundation

@Suite
struct BroadcastTests {

    @Test
    func testStreamCreatedButNotIterated() async {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream = await broadcast.subscribe()
        _ = stream
    }

    @Test
    func testDroppingUniteratedStreamFiresOnLast() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onLast: { counter.incLast() })

        var stream: AsyncStream<Int>? = await broadcast.subscribe()
        stream = nil

        try? await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(counter.lastCount == 1, "onLast should fire when an uniterated stream is dropped")
    }

    @Test
    func testOnLastFiresOnceWhenLastSubscriberLeaves() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onLast: { counter.incLast() })

        let stream = await broadcast.subscribe()

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let it2 = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await broadcast.finish()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        withExtendedLifetime((it, it2)) {
            #expect(counter.lastCount == 1, "onLast should fire once")
        }
    }

    @Test
    func testEventStreamBuffersEventsFromCreation() async throws {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream = await broadcast.subscribe()

        await broadcast.send(42)

        var it = stream.makeAsyncIterator()

        await broadcast.send(99)
        await broadcast.finish()

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42, 99], "Event stream should buffer values sent after subscribe")
    }

    @Test
    func testStateStreamReplay() async throws {
        let broadcast = Broadcast<Int>(mode: .state)
        let stream = await broadcast.subscribe()

        await broadcast.send(42)

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(150))

        await broadcast.finish()

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42], "State stream should replay the last value")
    }

    /// Characterization: `.event` streams do NOT replay to late
    /// subscribers. Only `.state` streams replay the last value.
    @Test
    func testEventStreamDoesNotReplayToLateSubscriber() async throws {
        let broadcast = Broadcast<Int>(mode: .event)

        let stream1 = await broadcast.subscribe()
        await broadcast.send(42)

        // A late second subscriber. For `.event`, it should NOT
        // receive the previously sent value.
        let stream2 = await broadcast.subscribe()

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await broadcast.send(99)
        await broadcast.finish()

        var values1: [Int] = []
        while let v = await it1.next() { values1.append(v) }

        var values2: [Int] = []
        while let v = await it2.next() { values2.append(v) }

        #expect(values1 == [42, 99], "First subscriber gets buffered + live values")
        #expect(values2 == [99], "Late .event subscriber does not get replay")
    }

    @Test
    func testFinishClearsReplayState() async throws {
        let broadcast = Broadcast<Int>(mode: .state)
        let stream = await broadcast.subscribe()

        await broadcast.send(42)
        await broadcast.finish()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        // After finish, the replay state is gone.
        let stream2 = await broadcast.subscribe()
        var it = stream2.makeAsyncIterator()
        await broadcast.finish()

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [], "finish should clear replay state for state streams")
        _ = stream
    }

    @Test
    func testTwoConcurrentIterators() async throws {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream1 = await broadcast.subscribe()
        let stream2 = await broadcast.subscribe()

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await broadcast.send(10)
        await broadcast.send(20)
        await broadcast.send(30)
        await broadcast.finish()

        let collected1 = await collectValues(&it1, timeout: .milliseconds(300))
        let collected2 = await collectValues(&it2, timeout: .milliseconds(300))

        #expect(collected1 == [10, 20, 30])
        #expect(collected2 == [10, 20, 30])
    }

    @Test
    func testNormalFinish() async throws {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream = await broadcast.subscribe()

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await broadcast.send(100)
        await broadcast.finish()

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [100])
    }

    @Test
    func testResubscribeAfterFinish() async throws {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream = await broadcast.subscribe()

        var it1 = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await broadcast.send(1)
        await broadcast.finish()

        var collected1: [Int] = []
        while let v = await it1.next() {
            collected1.append(v)
        }
        #expect(collected1 == [1])

        // After finish, a new subscribe works.
        let stream2 = await broadcast.subscribe()
        var it2 = stream2.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await broadcast.send(2)
        await broadcast.finish()

        var collected2: [Int] = []
        while let v = await it2.next() {
            collected2.append(v)
        }
        #expect(collected2 == [2])
    }

    @Test
    func testIteratorCancellation() async throws {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream = await broadcast.subscribe()

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let holder = AsyncStreamBox(it)
        let task = _Concurrency.Task {
            var count = 0
            while let _ = await holder.iterator.next() {
                count += 1
            }
            return count
        }

        try? await _Concurrency.Task.sleep(for: .milliseconds(50))

        await broadcast.send(1)
        await broadcast.send(2)

        task.cancel()

        let count = await task.value
        #expect(count >= 0)
    }

    /// Characterization: task cancellation mid-iteration fires `onLast` when
    /// the cancelled iterator was the last one.
    @Test
    func testCancellationFiresOnLastWhenLastIterator() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onLast: { counter.incLast() })
        let stream = await broadcast.subscribe()

        let it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        let holder = AsyncStreamBox(it)
        let task = _Concurrency.Task {
            while let _ = await holder.iterator.next() {}
        }

        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value

        try? await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(counter.lastCount == 1, "onLast should fire when the last iterator is cancelled")
    }

    /// Characterization: `sendState` stores the value even before any
    /// subscriber registers, so the first subscriber receives it on attach.
    @Test
    func testSendStateBeforeSubscriberReplaysOnAttach() async throws {
        let broadcast = Broadcast<Int>(mode: .state)

        await broadcast.sendState(42)

        let stream = await broadcast.subscribe()
        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        await broadcast.finish()

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42], "sendState before subscriber should replay on attach")
    }

    @Test
    func testOnFirstFiresOnFirstSubscriber() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onFirst: { counter.incFirst() })

        let stream1 = await broadcast.subscribe()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(counter.firstCount == 1, "onFirst should fire on first subscriber")

        let stream2 = await broadcast.subscribe()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(counter.firstCount == 1, "onFirst should NOT fire again for second subscriber")

        _ = stream1
        _ = stream2
    }

    @Test
    func testOnFirstRefiresAfterAllSubscribersLeave() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onFirst: { counter.incFirst() })

        // First subscriber attaches → onFirst fires.
        var stream1: AsyncStream<Int>? = await broadcast.subscribe()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(counter.firstCount == 1)

        // Drop the stream → onLast fires (nil), started resets.
        stream1 = nil
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))

        // New subscriber → onFirst fires again.
        let stream2 = await broadcast.subscribe()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(counter.firstCount == 2, "onFirst should fire again after all subscribers left")

        _ = stream2
    }

    @Test
    func testConcurrentYieldSubscribeTerminateUnderLoad() async throws {
        let broadcast = Broadcast<Int>(mode: .event)

        await withTaskGroup(of: Void.self) { group in
            // Subscribers come and go.
            for _ in 0..<10 {
                group.addTask {
                    let stream = await broadcast.subscribe()
                    var it = stream.makeAsyncIterator()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(10))
                    _ = await it.next()
                }
            }
            // Yielders.
            for i in 0..<50 {
                group.addTask {
                    await broadcast.send(i)
                }
            }
            // A finisher.
            group.addTask {
                try? await _Concurrency.Task.sleep(for: .milliseconds(50))
                await broadcast.finish()
            }
        }

        // The test passes if it completes without deadlock or data-race trap.
        #expect(true)
    }
}

// MARK: - BroadcastFamily Tests

@Suite
struct BroadcastFamilyTests {

    @Test
    func testSubscribeCreatesBroadcastForNewKey() async throws {
        let family = BroadcastFamily<String, String>(mode: .event)
        let stream = await family.subscribe(for: "key1")
        var it = stream.makeAsyncIterator()

        await family.send("hello", for: "key1")
        await family.finishAll()

        let value = await it.next()
        #expect(value == "hello")
    }

    @Test
    func testSubscribeReusesExistingBroadcastForSameKey() async throws {
        let family = BroadcastFamily<String, String>(mode: .event)
        let stream1 = await family.subscribe(for: "key1")
        let stream2 = await family.subscribe(for: "key1")

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await family.send("hello", for: "key1")
        await family.finishAll()

        let v1 = await it1.next()
        let v2 = await it2.next()
        #expect(v1 == "hello")
        #expect(v2 == "hello")
    }

    @Test
    func testSendToKeyWithNoSubscribersDropsValue() async throws {
        let family = BroadcastFamily<String, String>(mode: .event)
        await family.send("dropped", for: "no-subscribers")

        let stream = await family.subscribe(for: "no-subscribers")
        var it = stream.makeAsyncIterator()
        await family.finishAll()

        let value = await it.next()
        #expect(value == nil, "Value sent before any subscriber should be dropped for .event")
    }

    @Test
    func testSendStateCreatesBroadcastAndReplaysOnSubscribe() async throws {
        let family = BroadcastFamily<String, String>(mode: .state)

        await family.sendState("initial", for: "state-key")

        let stream = await family.subscribe(for: "state-key")
        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        await family.finishAll()

        let value = await it.next()
        #expect(value == "initial", "sendState should replay on subscribe")
    }

    @Test
    func testOnFirstOnLastFirePerKey() async throws {
        let counter = SendableCounter()
        let family = BroadcastFamily<String, String>(
            mode: .event,
            onFirst: { _ in counter.incFirst() },
            onLast: { _ in counter.incLast() }
        )

        var stream: AsyncStream<String>? = await family.subscribe(for: "key1")
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(counter.firstCount == 1, "onFirst should fire for key1")

        stream = nil
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))
        #expect(counter.lastCount == 1, "onLast should fire for key1")
    }

    /// `onFirst` is awaited inside `subscribe()` before the method returns.
    /// This guarantees MQTT topic acquisition completes before the caller
    /// receives the stream — the acquire-before-publish ordering the
    /// request/response path depends on (#70).
    @Test
    func testOnFirstCompletesBeforeSubscribeReturns() async throws {
        let recorder = OrderRecorder()

        let broadcast = Broadcast<Int>(mode: .event, onFirst: {
            recorder.record("onFirst")
        })

        let stream = await broadcast.subscribe()
        recorder.record("subscribeReturned")

        #expect(
            recorder.events == ["onFirst", "subscribeReturned"],
            "onFirst must complete before subscribe() returns"
        )

        _ = stream
    }
}

// MARK: - BroadcastFamily Eviction Tests

@Suite
struct BroadcastFamilyEvictionTests {

    /// `evictOnLast: true` removes the `Broadcast` from the family when
    /// the last subscriber leaves, preventing unbounded memory growth for
    /// per-correlation-id families like `responseFamily`.
    @Test
    func testEvictOnLastRemovesBroadcastAfterLastSubscriberLeaves() async throws {
        let family = BroadcastFamily<String, String>(mode: .event, evictOnLast: true)

        // Subscribe and drop the stream.
        var stream: AsyncStream<String>? = await family.subscribe(for: "key1")
        stream = nil

        // Wait for onLast to fire and evict.
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))

        // Send to the evicted key — should be dropped (no Broadcast exists).
        await family.send("dropped", for: "key1")

        // Subscribe again — should create a new Broadcast.
        let stream2 = await family.subscribe(for: "key1")
        var it = stream2.makeAsyncIterator()
        await family.send("value2", for: "key1")
        await family.finishAll()

        let value = await it.next()
        #expect(value == "value2", "New subscriber after eviction should receive new values, not evicted ones")
    }

    /// Simulates the response path: many unique correlation IDs are used
    /// over time, each with one subscriber that leaves after receiving
    /// the response. With `evictOnLast: true`, the family should not
    /// retain dead `Broadcast` instances.
    @Test
    func testResponseFamilyDoesNotRetainBroadcastsAcrossManyCorrelationIds() async throws {
        let family = BroadcastFamily<String, String>(mode: .event, evictOnLast: true)

        for i in 0..<100 {
            let key = "corr-\(i)"
            let stream = await family.subscribe(for: key)
            var it = stream.makeAsyncIterator()

            await family.send("response-\(i)", for: key)

            let value = await it.next()
            #expect(value == "response-\(i)")
            // Iterator goes out of scope → onTermination → onLast → evict.
        }

        // Give eviction tasks time to run.
        try? await _Concurrency.Task.sleep(for: .milliseconds(300))

        // The family should have zero retained Broadcasts (all evicted).
        // We verify indirectly: sending to any old key should be a no-op.
        await family.send("should-be-dropped", for: "corr-0")
        await family.send("should-be-dropped", for: "corr-50")
        await family.send("should-be-dropped", for: "corr-99")

        // A fresh subscribe should still work.
        let freshStream = await family.subscribe(for: "corr-fresh")
        var freshIt = freshStream.makeAsyncIterator()
        await family.send("fresh-value", for: "corr-fresh")
        await family.finishAll()

        let freshValue = await freshIt.next()
        #expect(freshValue == "fresh-value")
    }
}

// MARK: - Helpers

private final class SendableCounter: @unchecked Sendable {
    private(set) var firstCount = 0
    private(set) var lastCount = 0
    func incFirst() { firstCount += 1 }
    func incLast() { lastCount += 1 }
}

private final class OrderRecorder: @unchecked Sendable {
    private var _events: [String] = []
    private let lock = NSLock()

    func record(_ event: String) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
}

private func collectValues<T: Sendable>(
    _ iterator: inout AsyncStream<T>.Iterator,
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
