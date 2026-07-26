// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation
import Testing

/// A lock-guarded mutable box for capturing values in `@Sendable` test
/// closures. Every read and write is synchronized through an `NSLock`, so the
/// `@unchecked Sendable` conformance is truthful rather than merely asserted.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { self.stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
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

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(message)
        }

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

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(message)
        }

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

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(message)
        }
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

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(key: "foo", message)
            #expect(fooReceived.value == 1)
            #expect(barReceived.value == 0)

            table.dispatch(key: "bar", message)
            #expect(fooReceived.value == 1)
            #expect(barReceived.value == 1)
        }
    }

    @Test
    func familyTableDispatchAll() throws {
        var table = StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)
        let total = Box(0)

        _ = table.subscribe(key: "a") { _ in total.value += 1 }
        _ = table.subscribe(key: "b") { _ in total.value += 1 }
        _ = table.subscribe(key: "c") { _ in total.value += 1 }

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatchAll(message)
        }
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

        withBorrowedMessage(topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(key: "ch", message)
        }
        #expect(received.value == 2)
    }

    // MARK: - BorrowedMessage

    @Test
    func borrowedMessageParsesEventType() throws {
        withBorrowedMessage(topic: "coaty/3/test/ADV:sensors/33333333-3333-4333-8333-333333333333") { message in
            #expect(message.eventType == .advertise)
            #expect(message.isRawTopic == false)
        }
    }

    @Test
    func borrowedMessageIdentifiesRawTopic() throws {
        withBorrowedMessage(topic: "external/test/route", payload: "{}") { message in
            #expect(message.isRawTopic == true)
            #expect(message.eventType == nil)
        }
    }

    @Test
    func borrowedMessageReaderAccessesPayload() throws {
        let payload = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333"}"#
        withBorrowedMessage(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: payload
        ) { message in
            let reader = message.reader()
            let sourceId = reader.readUUID("ioSourceId")
            #expect(sourceId != nil)
        }
    }

    @Test
    func borrowedMessageDispatchFlow() throws {
        var table = StaticDispatchTable(capacity: 4)
        let capturedEvent = Box<WireEventType?>(nil)

        _ = table.subscribe { msg in
            capturedEvent.value = msg.eventType
        }

        let payload = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/test/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#
        withBorrowedMessage(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: payload
        ) { message in
            table.dispatch(message)
        }
        #expect(capturedEvent.value == .associate)
    }
}

// MARK: - Test helpers

/// Pins the topic and payload byte buffers for the synchronous duration of
/// `body`, so the `BorrowedMessage` and every value derived from it
/// (`ByteSlice`, `WireReader`, `TopicView`) never outlive their
/// `withUnsafeBufferPointer` scopes.
private func withBorrowedMessage<R>(
    topic: String,
    payload: String = "{}",
    _ body: (BorrowedMessage) throws -> R
) rethrows -> R {
    let topicBytes = Array(topic.utf8)
    let payloadBytes = Array(payload.utf8)
    return try topicBytes.withUnsafeBufferPointer { topicBuf in
        try payloadBytes.withUnsafeBufferPointer { payloadBuf in
            let message = BorrowedMessage(
                topicBytes: topicBuf.baseAddress!,
                topicLength: topicBuf.count,
                payloadBytes: payloadBuf.baseAddress!,
                payloadLength: payloadBuf.count
            )
            return try body(message)
        }
    }
}
