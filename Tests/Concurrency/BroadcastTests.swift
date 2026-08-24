// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing
import Foundation

@Suite
struct BroadcastTests {

    @Test
    func testStreamCreatedButNotIteratedRegistersSubscriber() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onFirst: {
            await counter.incFirst()
        }, onLast: {
            await counter.incLast()
        })
        let stream = await broadcast.subscribe()

        let countsAfterSubscribe = await counter.snapshot()
        #expect(countsAfterSubscribe.firstCount == 1,
                "creating a stream must register a subscriber before iteration")

        await broadcast.finish()
        let countsAfterFinish = await counter.snapshot()
        #expect(countsAfterFinish.lastCount == 1,
                "finishing an uniterated stream must release its subscriber")
        _ = stream
    }

    @Test
    func testDroppingUniteratedStreamFiresOnLast() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onLast: {
            await counter.incLast()
        })

        var stream: AsyncStream<Int>? = await broadcast.subscribe()
        _ = stream
        stream = nil

        try await withTimeout("uniterated stream termination") {
            guard await counter.waitForLastCount(1) else { throw CancellationError() }
        }

        let counts = await counter.snapshot()
        #expect(counts.lastCount == 1, "onLast should fire when an uniterated stream is dropped")
    }

    @Test
    func testOnLastFiresOnceWhenLastSubscriberLeaves() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onLast: {
            await counter.incLast()
        })

        let stream = await broadcast.subscribe()

        let it = stream.makeAsyncIterator()
        let it2 = stream.makeAsyncIterator()

        await broadcast.finish()

        _ = (it, it2)
        let counts = await counter.snapshot()
        #expect(counts.lastCount == 1, "onLast should fire once")
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

        var collected1: [Int] = []
        while let value = await it1.next() {
            collected1.append(value)
        }
        var collected2: [Int] = []
        while let value = await it2.next() {
            collected2.append(value)
        }

        #expect(collected1 == [10, 20, 30])
        #expect(collected2 == [10, 20, 30])
    }

    @Test
    func testNormalFinish() async throws {
        let broadcast = Broadcast<Int>(mode: .event)
        let stream = await broadcast.subscribe()

        var it = stream.makeAsyncIterator()

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
        let holder = AsyncStreamBox(it)
        let started = CountGate()
        let consumed = CountGate()
        let task = Task {
            var count = 0
            await started.mark()
            while await holder.iterator.next() != nil {
                count += 1
                if count == 2 {
                    await consumed.mark()
                }
            }
            return count
        }

        try await withTimeout("cancellable iterator start") {
            guard await started.waitForCount(1) else { throw CancellationError() }
        }

        await broadcast.send(1)
        await broadcast.send(2)
        try await withTimeout("cancellable iterator consumes two values") {
            guard await consumed.waitForCount(1) else { throw CancellationError() }
        }

        task.cancel()

        let count = try await withTimeout("iterator cancellation completion") {
            await task.value
        }
        #expect(count == 2, "cancellation should stop the iterator after the two delivered values")
    }

    /// Characterization: task cancellation mid-iteration fires `onLast` when
    /// the cancelled iterator was the last one.
    @Test
    func testCancellationFiresOnLastWhenLastIterator() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onLast: {
            await counter.incLast()
        })
        let stream = await broadcast.subscribe()

        let it = stream.makeAsyncIterator()
        let holder = AsyncStreamBox(it)
        let started = CountGate()
        let task = Task {
            await started.mark()
            while await holder.iterator.next() != nil {}
        }

        try await withTimeout("cancellable last iterator start") {
            guard await started.waitForCount(1) else { throw CancellationError() }
        }
        task.cancel()
        _ = try await withTimeout("cancelled last iterator completion") {
            await task.value
        }

        try await withTimeout("last iterator termination") {
            guard await counter.waitForLastCount(1) else { throw CancellationError() }
        }
        let counts = await counter.snapshot()
        #expect(counts.lastCount == 1, "onLast should fire when the last iterator is cancelled")
    }

    /// Characterization: `sendState` stores the value even before any
    /// subscriber registers, so the first subscriber receives it on attach.
    @Test
    func testSendStateBeforeSubscriberReplaysOnAttach() async throws {
        let broadcast = Broadcast<Int>(mode: .state)

        await broadcast.sendState(42)

        let stream = await broadcast.subscribe()
        var it = stream.makeAsyncIterator()
        await broadcast.finish()

        var values: [Int] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [42], "sendState before subscriber should replay on attach")
    }

    /// `send` on a `.state` broadcast caches `lastValue` just like
    /// `sendState`, so a late subscriber receives the value. This
    /// verifies the documented equivalence: "For `.state` mode, the
    /// value is cached for replay to future subscribers (equivalent to
    /// ``sendState(_:)``)."
    @Test
    func testSendOnStateBroadcastIsEquivalentToSendState() async throws {
        let broadcast = Broadcast<Int>(mode: .state)

        // send (not sendState) on a .state broadcast should cache lastValue.
        await broadcast.send(42)

        let stream = await broadcast.subscribe()
        var it = stream.makeAsyncIterator()
        await broadcast.finish()

        let value = await it.next()
        #expect(value == 42, "send on .state broadcast should cache and replay like sendState")
    }

    @Test
    func testOnFirstFiresOnFirstSubscriber() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onFirst: {
            await counter.incFirst()
        })

        let stream1 = await broadcast.subscribe()
        var counts = await counter.snapshot()
        #expect(counts.firstCount == 1, "onFirst should fire on first subscriber")

        let stream2 = await broadcast.subscribe()
        counts = await counter.snapshot()
        #expect(counts.firstCount == 1, "onFirst should NOT fire again for second subscriber")

        _ = stream1
        _ = stream2
    }

    @Test
    func testOnFirstRefiresAfterAllSubscribersLeave() async throws {
        let counter = SendableCounter()
        let broadcast = Broadcast<Int>(mode: .event, onFirst: {
            await counter.incFirst()
        }, onLast: {
            await counter.incLast()
        })

        // First subscriber attaches → onFirst fires.
        var stream1: AsyncStream<Int>? = await broadcast.subscribe()
        var counts = await counter.snapshot()
        #expect(counts.firstCount == 1)

        // Drop the stream → onLast fires (nil), started resets.
        _ = stream1
        stream1 = nil
        try await withTimeout("first subscriber termination") {
            guard await counter.waitForLastCount(1) else { throw CancellationError() }
        }

        // New subscriber → onFirst fires again.
        let stream2 = await broadcast.subscribe()
        counts = await counter.snapshot()
        #expect(counts.firstCount == 2, "onFirst should fire again after all subscribers left")

        _ = stream2
    }

    @Test
    func testConcurrentYieldSubscribeTerminateUnderLoad() async throws {
        let subscriberCount = 10
        let values = Array(0..<50)
        let lifecycle = SendableCounter()
        let subscribersReady = CountGate()
        let finishGate = CountGate()
        let received = LoadResults()
        let broadcast = Broadcast<Int>(mode: .event, onFirst: {
            await lifecycle.incFirst()
        }, onLast: {
            await lifecycle.incLast()
        })

        await withTaskGroup(of: Void.self) { group in
            for subscriberID in 0..<subscriberCount {
                group.addTask {
                    let stream = await broadcast.subscribe()
                    var iterator = stream.makeAsyncIterator()
                    await subscribersReady.mark()

                    var receivedValues: [Int] = []
                    for _ in values {
                        if let value = try? await nextValue(&iterator, timeout: .seconds(1)) {
                            receivedValues.append(value)
                        } else {
                            break
                        }
                    }
                    await finishGate.waitForCount(1)
                    await received.record(subscriberID, values: receivedValues)
                }
            }

            // Every subscriber must be registered before any producer starts.
            let allSubscribersRegistered = (try? await withTimeout("all load-test subscribers register") {
                guard await subscribersReady.waitForCount(subscriberCount) else {
                    throw CancellationError()
                }
            }) != nil
            #expect(allSubscribersRegistered, "all load-test subscribers must register before yielding")

            let firstHookCompleted = (try? await withTimeout("load-test first-subscriber hook") {
                guard await lifecycle.waitForFirstCount(1) else { throw CancellationError() }
            }) != nil
            #expect(firstHookCompleted, "the first-subscriber hook must complete during setup")

            // Yield concurrently after registration. The event buffer is large
            // enough for this bounded batch, so every subscriber has an exact
            // delivery invariant to assert below.
            await withTaskGroup(of: Void.self) { senders in
                for value in values {
                    senders.addTask {
                        await broadcast.send(value)
                    }
                }
            }

            // Finish only after every producer has returned. This makes the
            // completion count and per-subscriber delivery set deterministic.
            await broadcast.finish()
            await finishGate.mark()
        }

        let lifecycleCounts = await lifecycle.snapshot()
        #expect(lifecycleCounts.firstCount == 1,
                "concurrent registration must acquire one shared subscription")
        #expect(lifecycleCounts.lastCount == 1,
                "finish must release the shared subscription exactly once")

        let snapshots = await received.snapshot()
        #expect(snapshots.count == subscriberCount,
                "every load-test subscriber must observe termination")
        let expectedValues = Set(values)
        for snapshot in snapshots {
            #expect(snapshot.count == values.count,
                    "each subscriber must receive every bounded load value")
            #expect(Set(snapshot) == expectedValues,
                    "each subscriber must receive the same value set")
        }
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
        await family.finishAll()

        let value = await it.next()
        #expect(value == "initial", "sendState should replay on subscribe")
    }

    @Test
    func testOnFirstOnLastFirePerKey() async throws {
        let counter = SendableCounter()
        let family = BroadcastFamily<String, String>(
            mode: .event,
            onFirst: { _ in await counter.incFirst() },
            onLast: { _ in await counter.incLast() }
        )

        var stream: AsyncStream<String>? = await family.subscribe(for: "key1")
        _ = stream
        var counts = await counter.snapshot()
        #expect(counts.firstCount == 1, "onFirst should fire for key1")

        stream = nil
        try await withTimeout("family subscriber termination") {
            guard await counter.waitForLastCount(1) else { throw CancellationError() }
        }
        counts = await counter.snapshot()
        #expect(counts.lastCount == 1, "onLast should fire for key1")
    }

    @Test
    func testFinishAllClearsAllBroadcasts() async throws {
        let family = BroadcastFamily<String, String>(mode: .event)

        let stream1 = await family.subscribe(for: "key1")
        let stream2 = await family.subscribe(for: "key2")

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()

        await family.send("a", for: "key1")
        await family.send("b", for: "key2")

        await family.finishAll()

        // Consume buffered values, then expect nil (stream finished).
        var values1: [String] = []
        while let v = await it1.next() { values1.append(v) }
        var values2: [String] = []
        while let v = await it2.next() { values2.append(v) }

        #expect(values1 == ["a"], "Should receive buffered value before finish")
        #expect(values2 == ["b"], "Should receive buffered value before finish")

        // Sending after finishAll should be a no-op (no Broadcast exists).
        await family.send("c", for: "key1")
        await family.send("d", for: "key2")
    }

    /// `onFirst` is awaited inside `subscribe()` before the method returns.
    /// This guarantees MQTT topic acquisition completes before the caller
    /// receives the stream — the acquire-before-publish ordering the
    /// request/response path depends on (#70).
    @Test
    func testOnFirstCompletesBeforeSubscribeReturns() async throws {
        let recorder = OrderRecorder()

        let broadcast = Broadcast<Int>(mode: .event, onFirst: {
            await recorder.record("onFirst")
        })

        let stream = await broadcast.subscribe()
        await recorder.record("subscribeReturned")

        #expect(
            await recorder.events == ["onFirst", "subscribeReturned"],
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
        let counter = SendableCounter()
        let family = BroadcastFamily<String, String>(
            mode: .state,
            evictOnLast: true,
            onLast: { _ in await counter.incLast() }
        )

        // State replay makes retained broadcasts observable: a non-evicting
        // family would replay this retired value to the replacement below.
        do {
            let stream = await family.subscribe(for: "key1")
            var iterator = stream.makeAsyncIterator()
            await family.send("stale", for: "key1")
            #expect(await iterator.next() == "stale")
        }

        try await withTimeout("eviction after last subscriber leaves") {
            guard await counter.waitForLastCount(1) else { throw CancellationError() }
        }

        // A replacement state broadcast must not replay the retired value.
        let stream2 = await family.subscribe(for: "key1")
        var it = stream2.makeAsyncIterator()
        await family.send("value2", for: "key1")

        let value = await it.next()
        #expect(value == "value2", "new subscriber after eviction should not receive a retired value")
        await family.finishAll()
    }

    /// Simulates the response path: many unique correlation IDs are used
    /// over time, each with one subscriber that leaves after receiving
    /// the response. With `evictOnLast: true`, the family should not
    /// retain dead `Broadcast` instances.
    @Test
    func testResponseFamilyDoesNotRetainBroadcastsAcrossManyCorrelationIds() async throws {
        let counter = SendableCounter()
        let family = BroadcastFamily<String, String>(
            // State mode is intentional: replay turns a retained broadcast
            // into an externally observable stale response while exercising
            // the same family eviction dictionary.
            mode: .state,
            evictOnLast: true,
            onLast: { _ in await counter.incLast() }
        )

        for i in 0..<100 {
            let key = "corr-\(i)"
            do {
                let stream = await family.subscribe(for: key)
                var iterator = stream.makeAsyncIterator()

                await family.send("response-\(i)", for: key)

                let value = await iterator.next()
                #expect(value == "response-\(i)")
                // Iterator goes out of scope → onTermination → onLast → evict.
            }
        }

        try await withTimeout("all correlation broadcasts evict") {
            guard await counter.waitForLastCount(100) else { throw CancellationError() }
        }

        // If any old Broadcast remains in the family, this subscribe replays
        // its stale response before the fresh value is sent.
        let freshStream = await family.subscribe(for: "corr-0")
        var freshIterator = freshStream.makeAsyncIterator()
        await family.send("fresh-value", for: "corr-0")
        let freshValue = await freshIterator.next()
        #expect(freshValue == "fresh-value",
                "evicted response broadcasts must not replay stale values")
        await family.finishAll()
    }
}

// MARK: - Helpers

private actor SendableCounter {
    struct Snapshot: Sendable {
        let firstCount: Int
        let lastCount: Int
    }

    private(set) var firstCount = 0
    private(set) var lastCount = 0
    private let firstEvents: AsyncStream<Void>
    private let lastEvents: AsyncStream<Void>
    private let firstContinuation: AsyncStream<Void>.Continuation
    private let lastContinuation: AsyncStream<Void>.Continuation

    init() {
        let first = AsyncStream<Void>.makeStream()
        let last = AsyncStream<Void>.makeStream()
        firstEvents = first.stream
        firstContinuation = first.continuation
        lastEvents = last.stream
        lastContinuation = last.continuation
    }

    func incFirst() {
        firstCount += 1
        firstContinuation.yield()
    }

    func incLast() {
        lastCount += 1
        lastContinuation.yield()
    }

    func waitForFirstCount(_ expected: Int) async -> Bool {
        guard firstCount < expected else { return true }
        var iterator = firstEvents.makeAsyncIterator()
        while firstCount < expected {
            guard await iterator.next() != nil else { return false }
        }
        return true
    }

    func waitForLastCount(_ expected: Int) async -> Bool {
        guard lastCount < expected else { return true }
        var iterator = lastEvents.makeAsyncIterator()
        while lastCount < expected {
            guard await iterator.next() != nil else { return false }
        }
        return true
    }

    func snapshot() -> Snapshot {
        Snapshot(firstCount: firstCount, lastCount: lastCount)
    }
}

private actor CountGate {
    private var count = 0
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func mark() {
        count += 1
        continuation.yield()
    }

    func waitForCount(_ expected: Int) async -> Bool {
        guard count < expected else { return true }
        var iterator = events.makeAsyncIterator()
        while count < expected {
            guard await iterator.next() != nil else { return false }
        }
        return true
    }
}

private actor LoadResults {
    private var valuesBySubscriber: [Int: [Int]] = [:]

    func record(_ subscriberID: Int, values: [Int]) {
        valuesBySubscriber[subscriberID] = values
    }

    func snapshot() -> [[Int]] {
        valuesBySubscriber.keys.sorted().compactMap { valuesBySubscriber[$0] }
    }
}

private actor OrderRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}
