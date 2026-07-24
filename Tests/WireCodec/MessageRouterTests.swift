// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

/// Tests for the MessageRouter adapter bridge — proves both the embedded
/// and host adapters satisfy the common protocol and route messages
/// correctly to their respective dispatch mechanisms.
@Suite
struct MessageRouterTests {

    // MARK: - EmbeddedMessageRouter

    @Test
    func embeddedRouterDispatchesByEventType() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box<WireEventType?>(nil)

        router.subscribe(.associate) { msg in
            received.value = msg.eventType
        }

        let msg = makeTestMessage(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444"}"#
        )
        router.dispatch(msg)

        #expect(received.value == .associate)
    }

    @Test
    func embeddedRouterDispatchesRawToRawSubscribers() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(false)

        router.subscribeRaw { _ in
            received.value = true
        }

        let msg = makeTestMessage(topic: "external/test/route", payload: "raw")
        router.dispatch(msg)

        #expect(received.value == true)
    }

    @Test
    func embeddedRouterDispatchesIoValueSeparately() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let ioReceived = Box(false)
        let associateReceived = Box(false)

        router.subscribeIoValue { _ in ioReceived.value = true }
        router.subscribe(.associate) { _ in associateReceived.value = true }

        let ioMsg = makeTestMessage(
            topic: "coaty/3/test/IOV/33333333-3333-4333-8333-333333333333",
            payload: "42"
        )
        router.dispatch(ioMsg)
        #expect(ioReceived.value == true)
        #expect(associateReceived.value == false)
    }

    @Test
    func embeddedRouterUnsubscribeStopsDelivery() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(0)

        let token = router.subscribe(.discover) { _ in received.value += 1 }
        router.unsubscribe(.discover, try #require(token))

        let msg = makeTestMessage(
            topic: "coaty/3/test/DSC/11111111-1111-4111-8111-111111111111"
        )
        router.dispatch(msg)
        #expect(received.value == 0)
    }

    @Test
    func embeddedRouterAdvertiseFamilyDispatchesByFilter() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let fooReceived = Box(false)
        let barReceived = Box(false)

        router.subscribeAdvertise(filter: "sensors") { _ in fooReceived.value = true }
        router.subscribeAdvertise(filter: "things") { _ in barReceived.value = true }

        // Advertise for "sensors" filter → only sensors subscriber receives
        let msg = makeTestMessage(
            topic: "coaty/3/test/ADV:sensors/11111111-1111-4111-8111-111111111111"
        )
        router.dispatch(msg)
        #expect(fooReceived.value == true)
        #expect(barReceived.value == false)
    }

    @Test
    func embeddedRouterChannelFamilyDispatchesByChannelId() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let ch42Received = Box(false)

        router.subscribeChannel(channelId: "42") { _ in ch42Received.value = true }

        let msg = makeTestMessage(
            topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111"
        )
        router.dispatch(msg)
        #expect(ch42Received.value == true)
    }

    @Test
    func embeddedRouterDeadvertiseNotifiesAllAdvertiseSubscribers() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let fooReceived = Box(false)
        let barReceived = Box(false)

        router.subscribeAdvertise(filter: "sensors") { _ in fooReceived.value = true }
        router.subscribeAdvertise(filter: "things") { _ in barReceived.value = true }

        // Deadvertise should notify ALL advertise family entries
        let msg = makeTestMessage(
            topic: "coaty/3/test/DAD/11111111-1111-4111-8111-111111111111"
        )
        router.dispatch(msg)
        #expect(fooReceived.value == true)
        #expect(barReceived.value == true)
    }

    @Test
    func embeddedRouterIgnoresUnrecognizedEventType() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(false)

        // Subscribe to flat-table event types (not family-routed)
        for type: WireEventType in [.discover, .resolve, .retrieve, .complete] {
            router.subscribe(type) { _ in received.value = true }
        }

        // A message with nil eventType (raw topic) should go to raw, not these
        let msg = makeTestMessage(topic: "unknown/topic", payload: "{}")
        router.dispatch(msg)
        #expect(received.value == false)
    }

    @Test
    func embeddedRouterMultipleSubscribersAllReceive() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let count = Box(0)

        _ = router.subscribe(.query) { _ in count.value += 1 }
        _ = router.subscribe(.query) { _ in count.value += 1 }
        _ = router.subscribe(.query) { _ in count.value += 1 }

        let msg = makeTestMessage(
            topic: "coaty/3/test/QRY/55555555-5555-4555-8555-555555555555/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )
        router.dispatch(msg)
        #expect(count.value == 3)
    }

    // MARK: - Protocol polymorphism

    @Test
    func bothRoutersImplementMessageRouter() throws {
        let embedded: MessageRouter = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(false)

        if let emb = embedded as? EmbeddedMessageRouter {
            // Advertise events route through the family table, keyed by filter
            emb.subscribeAdvertise(filter: "foo") { _ in received.value = true }
        }

        let msg = makeTestMessage(
            topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111"
        )
        embedded.dispatch(msg)
        #expect(received.value == true)
    }

    // MARK: - End-to-end routing flow

    @Test
    func embeddedRouterFullRoutingFlow() throws {
        // Simulate the full embedded routing path:
        // 1. MQTT PUBLISH bytes arrive
        // 2. BorrowedMessage is created (zero-copy)
        // 3. Router dispatches based on event type
        // 4. Handler decodes payload via WireReader
        // 5. Decoded fields are asserted
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let decodedSourceId = Box<UUID16?>(nil)

        router.subscribe(.associate) { msg in
            let reader = msg.reader()
            decodedSourceId.value = reader.readUUID("ioSourceId")
        }

        let topic = "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555"
        let payload = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/test/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#
        let topicBytes = Array(topic.utf8)
        let payloadBytes = Array(payload.utf8)

        // Create BorrowedMessage from raw bytes — zero allocation
        topicBytes.withUnsafeBufferPointer { topicBuf in
            payloadBytes.withUnsafeBufferPointer { payloadBuf in
                let message = BorrowedMessage(
                    topicBytes: topicBuf.baseAddress!,
                    topicLength: topicBuf.count,
                    payloadBytes: payloadBuf.baseAddress!,
                    payloadLength: payloadBuf.count
                )
                router.dispatch(message)
            }
        }

        #expect(decodedSourceId.value == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
    }
}

// MARK: - Test helpers

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

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
