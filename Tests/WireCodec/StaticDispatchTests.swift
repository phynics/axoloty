// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

/// A mutable box for capturing values in @Sendable test closures.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Tests for the static dispatch infrastructure that will replace
/// Broadcast/BroadcastFamily actors in the embedded routing path.
@Suite
struct StaticDispatchTests {

    // MARK: - StaticDispatchTable

    @Test
    func dispatchTableDeliversToActiveSubscribers() throws {
        var table = StaticDispatchTable(capacity: 4)
        let received = Box<[String]>([])

        let token1 = table.subscribe { msg in
            received.value.append("handler1")
        }
        let token2 = table.subscribe { msg in
            received.value.append("handler2")
        }

        #expect(token1 != nil)
        #expect(token2 != nil)
        #expect(table.subscriberCount == 2)

        let msg = makeTestMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111")
        table.dispatch(msg)

        #expect(received.value.count == 2)
        #expect(received.value.contains("handler1"))
        #expect(received.value.contains("handler2"))
    }

    @Test
    func dispatchTableRespectsUnsubscribe() throws {
        var table = StaticDispatchTable(capacity: 4)
        let received = Box(0)

        let token = table.subscribe { _ in received.value += 1 }
        table.unsubscribe(try #require(token))

        #expect(table.subscriberCount == 0)

        let msg = makeTestMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111")
        table.dispatch(msg)

        #expect(received.value == 0)
    }

    @Test
    func dispatchTableRejectsOverflow() throws {
        var table = StaticDispatchTable(capacity: 2)
        let t1 = table.subscribe { _ in }
        let t2 = table.subscribe { _ in }
        let t3 = table.subscribe { _ in }

        #expect(t1 != nil)
        #expect(t2 != nil)
        #expect(t3 == nil)
        #expect(table.subscriberCount == 2)
    }

    @Test
    func dispatchTableReusesFreedSlots() throws {
        var table = StaticDispatchTable(capacity: 2)
        let received = Box(0)

        let t1 = table.subscribe { _ in received.value += 1 }
        table.unsubscribe(try #require(t1))

        let t2 = table.subscribe { _ in received.value += 1 }
        #expect(t2 != nil)
        #expect(table.subscriberCount == 1)

        let msg = makeTestMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111")
        table.dispatch(msg)
        #expect(received.value == 1)
    }

    // MARK: - StaticFamilyTable

    @Test
    func familyTableDispatchesByKey() throws {
        var table = StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)
        let fooReceived = Box(0)
        let barReceived = Box(0)

        let fooToken = table.subscribe(key: "foo") { _ in fooReceived.value += 1 }
        let barToken = table.subscribe(key: "bar") { _ in barReceived.value += 1 }
        #expect(fooToken != nil)
        #expect(barToken != nil)

        let msg = makeTestMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111")

        table.dispatch(key: "foo", msg)
        #expect(fooReceived.value == 1)
        #expect(barReceived.value == 0)

        table.dispatch(key: "bar", msg)
        #expect(fooReceived.value == 1)
        #expect(barReceived.value == 1)
    }

    @Test
    func familyTableDispatchAll() throws {
        var table = StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)
        let total = Box(0)

        _ = table.subscribe(key: "a") { _ in total.value += 1 }
        _ = table.subscribe(key: "b") { _ in total.value += 1 }
        _ = table.subscribe(key: "c") { _ in total.value += 1 }

        let msg = makeTestMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111")
        table.dispatchAll(msg)
        #expect(total.value == 3)
    }

    @Test
    func familyTableFreesEntryOnLastUnsubscribe() throws {
        var table = StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)

        let token = table.subscribe(key: "foo") { _ in }
        #expect(table.entryCount == 1)

        table.unsubscribe(try #require(token))
        #expect(table.entryCount == 0)

        let token2 = table.subscribe(key: "bar") { _ in }
        #expect(token2 != nil)
        #expect(table.entryCount == 1)
    }

    @Test
    func familyTableMultipleSubscribersPerKey() throws {
        var table = StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 3)
        let received = Box(0)

        _ = table.subscribe(key: "ch") { _ in received.value += 1 }
        _ = table.subscribe(key: "ch") { _ in received.value += 1 }

        let msg = makeTestMessage(topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111")
        table.dispatch(key: "ch", msg)
        #expect(received.value == 2)
    }

    // MARK: - BorrowedMessage

    @Test
    func borrowedMessageParsesEventType() throws {
        let msg = makeTestMessage(topic: "coaty/3/test/ADV:sensors/33333333-3333-4333-8333-333333333333")
        #expect(msg.eventType == .advertise)
        #expect(msg.isRawTopic == false)
    }

    @Test
    func borrowedMessageIdentifiesRawTopic() throws {
        let msg = makeTestMessage(topic: "external/test/route", payload: "{}")
        #expect(msg.isRawTopic == true)
        #expect(msg.eventType == nil)
    }

    @Test
    func borrowedMessageReaderAccessesPayload() throws {
        let payload = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333"}"#
        let msg = makeTestMessage(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: payload
        )
        let reader = msg.reader()
        let sourceId = reader.readUUID("ioSourceId")
        #expect(sourceId != nil)
    }

    @Test
    func borrowedMessageDispatchFlow() throws {
        var table = StaticDispatchTable(capacity: 4)
        let capturedEvent = Box<WireEventType?>(nil)

        _ = table.subscribe { msg in
            capturedEvent.value = msg.eventType
        }

        let payload = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/test/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#
        let msg = makeTestMessage(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: payload
        )

        table.dispatch(msg)
        #expect(capturedEvent.value == .associate)
    }
}

// MARK: - Test helpers

/// Creates a BorrowedMessage from string topic and payload, keeping the
/// bytes alive for the duration of the test.
private func makeTestMessage(topic: String, payload: String = "{}") -> BorrowedMessage {
    let topicBytes = Array(topic.utf8)
    let payloadBytes = Array(payload.utf8)
    return topicBytes.withUnsafeBufferPointer { topicBuf in
        payloadBytes.withUnsafeBufferPointer { payloadBuf in
            BorrowedMessage(
                topicBytes: topicBuf.baseAddress!,
                topicLength: topicBuf.count,
                payloadBytes: payloadBuf.baseAddress!,
                payloadLength: payloadBuf.count
            )
        }
    }
}
