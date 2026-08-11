// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation
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

        dispatchBorrowed(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444"}"#,
            to: router
        )

        #expect(received.value == .associate)
    }

    @Test
    func embeddedRouterDispatchesRawToRawSubscribers() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(false)

        router.subscribeRaw { _ in
            received.value = true
        }

        dispatchBorrowed(topic: "external/test/route", payload: "raw", to: router)

        #expect(received.value == true)
    }

    @Test
    func embeddedRouterDispatchesIoValueSeparately() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let ioReceived = Box(false)
        let associateReceived = Box(false)

        router.subscribeIoValue { _ in ioReceived.value = true }
        router.subscribe(.associate) { _ in associateReceived.value = true }

        dispatchBorrowed(
            topic: "coaty/3/test/IOV/33333333-3333-4333-8333-333333333333",
            payload: "42",
            to: router
        )
        #expect(ioReceived.value == true)
        #expect(associateReceived.value == false)
    }

    @Test
    func embeddedRouterUnsubscribeStopsDelivery() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(0)

        let token = router.subscribe(.discover) { _ in received.value += 1 }
        router.unsubscribe(.discover, try #require(token))

        dispatchBorrowed(
            topic: "coaty/3/test/DSC/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(received.value == 0)
    }

    @Test
    func embeddedRouterAdvertiseFamilyDispatchesByFilter() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let fooReceived = Box(false)
        let barReceived = Box(false)

        router.subscribeAdvertise(filter: "sensors") { _ in fooReceived.value = true }
        router.subscribeAdvertise(filter: "things") { _ in barReceived.value = true }

        dispatchBorrowed(
            topic: "coaty/3/test/ADV:sensors/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(fooReceived.value == true)
        #expect(barReceived.value == false)
    }

    @Test
    func embeddedRouterChannelFamilyDispatchesByChannelId() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let ch42Received = Box(false)

        router.subscribeChannel(channelId: "42") { _ in ch42Received.value = true }

        dispatchBorrowed(
            topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(ch42Received.value == true)
    }

    @Test
    func embeddedRouterDeadvertiseNotifiesAllAdvertiseSubscribers() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let fooReceived = Box(false)
        let barReceived = Box(false)

        router.subscribeAdvertise(filter: "sensors") { _ in fooReceived.value = true }
        router.subscribeAdvertise(filter: "things") { _ in barReceived.value = true }

        dispatchBorrowed(
            topic: "coaty/3/test/DAD/11111111-1111-4111-8111-111111111111",
            to: router
        )
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
        dispatchBorrowed(topic: "unknown/topic", payload: "{}", to: router)
        #expect(received.value == false)
    }

    @Test
    func embeddedRouterMultipleSubscribersAllReceive() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let count = Box(0)

        _ = router.subscribe(.query) { _ in count.value += 1 }
        _ = router.subscribe(.query) { _ in count.value += 1 }
        _ = router.subscribe(.query) { _ in count.value += 1 }

        dispatchBorrowed(
            topic: "coaty/3/test/QRY/55555555-5555-4555-8555-555555555555/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            to: router
        )
        #expect(count.value == 3)
    }

    // MARK: - Protocol polymorphism

    @Test
    func embeddedRouterConformsToMessageRouter() throws {
        let embedded: MessageRouter = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(false)

        if let emb = embedded as? EmbeddedMessageRouter {
            // Advertise events route through the family table, keyed by filter
            emb.subscribeAdvertise(filter: "foo") { _ in received.value = true }
        }

        dispatchBorrowed(
            topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111",
            to: embedded
        )
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

        dispatchBorrowed(
            topic: "coaty/3/test/ASC:ctx/55555555-5555-4555-8555-555555555555",
            payload: #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/test/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}"#,
            to: router
        )

        #expect(decodedSourceId.value == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
    }

    // MARK: - BorrowedMessage size-limit enforcement (#234)

    @Test
    func validatedRejectsOversizeTopic() throws {
        let topic = String(repeating: "a", count: WireBufferConfig.maxTopicLength + 1)
        let topicBytes = Array(topic.utf8)
        let payloadBytes = Array("{}".utf8)

        var caught: Error?
        topicBytes.withUnsafeBufferPointer { topicBuf in
            payloadBytes.withUnsafeBufferPointer { payloadBuf in
                do {
                    _ = try BorrowedMessage.validated(
                        topicBytes: topicBuf.baseAddress!,
                        topicLength: topicBuf.count,
                        payloadBytes: payloadBuf.baseAddress!,
                        payloadLength: payloadBuf.count
                    )
                } catch { caught = error }
            }
        }
        let err = try #require(caught as? WireDecodeError)
        if case .topicExceedsLimit = err.reason {} else { Issue.record("expected .topicExceedsLimit, got \(err.reason)") }
        #expect(err.byteOffset == topicBytes.count)
    }

    @Test
    func validatedRejectsOversizePayload() throws {
        let topic = "coaty/3/test/ADV:sensors/33333333-3333-4333-8333-333333333333"
        let topicBytes = Array(topic.utf8)
        let payloadBytes = [UInt8](repeating: 0x20, count: WireBufferConfig.maxPayloadSize + 1)

        var caught: Error?
        topicBytes.withUnsafeBufferPointer { topicBuf in
            payloadBytes.withUnsafeBufferPointer { payloadBuf in
                do {
                    _ = try BorrowedMessage.validated(
                        topicBytes: topicBuf.baseAddress!,
                        topicLength: topicBuf.count,
                        payloadBytes: payloadBuf.baseAddress!,
                        payloadLength: payloadBuf.count
                    )
                } catch { caught = error }
            }
        }
        let err = try #require(caught as? WireDecodeError)
        if case .payloadExceedsLimit = err.reason {} else { Issue.record("expected .payloadExceedsLimit, got \(err.reason)") }
        #expect(err.byteOffset == payloadBytes.count)
    }

    @Test
    func validatedRejectsNegativeLengths() throws {
        let topicBytes = Array("topic".utf8)
        let payloadBytes = Array("{}".utf8)
        var topicError: WireDecodeError?
        var payloadError: WireDecodeError?

        topicBytes.withUnsafeBufferPointer { topicBuf in
            payloadBytes.withUnsafeBufferPointer { payloadBuf in
                do {
                    _ = try BorrowedMessage.validated(
                        topicBytes: topicBuf.baseAddress!, topicLength: -1,
                        payloadBytes: payloadBuf.baseAddress!, payloadLength: payloadBuf.count
                    )
                } catch { topicError = error as? WireDecodeError }
                do {
                    _ = try BorrowedMessage.validated(
                        topicBytes: topicBuf.baseAddress!, topicLength: topicBuf.count,
                        payloadBytes: payloadBuf.baseAddress!, payloadLength: -1
                    )
                } catch { payloadError = error as? WireDecodeError }
            }
        }

        if case .malformedTopic = try #require(topicError).reason {} else {
            Issue.record("expected .malformedTopic")
        }
        if case .unexpectedEndOfInput = try #require(payloadError).reason {} else {
            Issue.record("expected .unexpectedEndOfInput")
        }
    }

    @Test
    func validatedAcceptsAtLimit() throws {
        // A topic and payload exactly at the limits must be accepted.
        let topic = String(repeating: "a", count: WireBufferConfig.maxTopicLength)
        let topicBytes = Array(topic.utf8)
        let payloadBytes = [UInt8](repeating: 0x20, count: WireBufferConfig.maxPayloadSize)

        try topicBytes.withUnsafeBufferPointer { topicBuf in
            try payloadBytes.withUnsafeBufferPointer { payloadBuf in
                let message = try BorrowedMessage.validated(
                    topicBytes: topicBuf.baseAddress!,
                    topicLength: topicBuf.count,
                    payloadBytes: payloadBuf.baseAddress!,
                    payloadLength: payloadBuf.count
                )
                #expect(message.payload.length == WireBufferConfig.maxPayloadSize)
            }
        }
    }
}

extension MessageRouterTests {
    @Test
    func embeddedRouterResponseFamilyDispatchesByEventTypeAndCorrelationId() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let correlationId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let received = Box<[WireEventType]>([])
        let flatCompleteReceived = Box(false)
        let otherCorrelationReceived = Box(false)
        let responseTypes: [WireEventType] = [.complete, .resolve, .retrieve, .returnEvent]

        let completeToken = try #require(router.subscribeResponse(
            eventType: .complete,
            correlationId: correlationId
        ) { _ in
            received.value.append(.complete)
        })
        for eventType in responseTypes.dropFirst() {
            router.subscribeResponse(eventType: eventType, correlationId: correlationId) { _ in
                received.value.append(eventType)
            }
        }
        router.subscribe(.complete) { _ in flatCompleteReceived.value = true }
        router.subscribeResponse(
            eventType: .complete,
            correlationId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        ) { _ in otherCorrelationReceived.value = true }

        for eventType in responseTypes {
            dispatchBorrowed(
                topic: "coaty/3/test/\(eventType.rawValue)/11111111-1111-4111-8111-111111111111/\(correlationId)",
                to: router
            )
        }

        #expect(received.value == responseTypes)
        #expect(flatCompleteReceived.value == false)
        #expect(otherCorrelationReceived.value == false)

        router.unsubscribeResponse(completeToken)
        dispatchBorrowed(
            topic: "coaty/3/test/CPL/11111111-1111-4111-8111-111111111111/\(correlationId)",
            to: router
        )
        #expect(received.value == responseTypes)
    }
}

// MARK: - Synchronous lifecycle & bounded capacity (#283)

extension MessageRouterTests {
    /// Proves the synchronous subscribe → dispatch → unsubscribe lifecycle on a
    /// flat event-type table: a handler receives while subscribed, then stops
    /// receiving after unsubscribe, with no `await` or isolation hop.
    @Test
    func embeddedRouterFlatLifecycleSubscribeDispatchUnsubscribe() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(0)

        let token = try #require(router.subscribe(.discover) { _ in received.value += 1 })

        dispatchBorrowed(
            topic: "coaty/3/test/DSC/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(received.value == 1)

        router.unsubscribe(.discover, token)
        dispatchBorrowed(
            topic: "coaty/3/test/DSC/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(received.value == 1)
    }

    /// Proves the synchronous subscribe → dispatch → unsubscribe lifecycle on a
    /// keyed family table.
    @Test
    func embeddedRouterFamilyLifecycleSubscribeDispatchUnsubscribe() throws {
        let router = EmbeddedMessageRouter(maxSubscribers: 4)
        let received = Box(0)

        let token = try #require(router.subscribeChannel(channelId: "42") { _ in received.value += 1 })

        dispatchBorrowed(
            topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(received.value == 1)

        router.unsubscribeChannel(token)
        dispatchBorrowed(
            topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(received.value == 1)
    }

    /// Flat table rejects the (maxSubscribers + 1)-th subscriber without growing.
    @Test
    func embeddedRouterFlatTableRejectsBeyondCapacity() throws {
        let capacity = 3
        let router = EmbeddedMessageRouter(maxSubscribers: capacity)
        let received = Box(0)

        for _ in 0..<capacity {
            #expect(router.subscribe(.query) { _ in received.value += 1 } != nil)
        }
        // Next subscribe must be rejected — table is bounded, no heap growth.
        #expect(router.subscribe(.query) { _ in received.value += 1 } == nil)

        dispatchBorrowed(
            topic: "coaty/3/test/QRY/55555555-5555-4555-8555-555555555555/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            to: router
        )
        #expect(received.value == capacity)
    }

    /// Family table rejects new entries beyond `maxFamilyEntries` and extra
    /// subscribers beyond `maxFamilySubscribers` for an existing key.
    @Test
    func embeddedRouterFamilyTableRejectsBeyondCapacity() throws {
        let entryCapacity = 2
        let perEntryCapacity = 2
        let router = EmbeddedMessageRouter(
            maxSubscribers: 4,
            maxFamilyEntries: entryCapacity,
            maxFamilySubscribers: perEntryCapacity
        )
        let received = Box(0)

        // Fill per-entry subscriber capacity for a single channel.
        for _ in 0..<perEntryCapacity {
            #expect(router.subscribeChannel(channelId: "42") { _ in received.value += 1 } != nil)
        }
        // Next subscriber on the same key is rejected — per-entry table full.
        #expect(router.subscribeChannel(channelId: "42") { _ in received.value += 1 } == nil)

        // Fill remaining family entry capacity with a distinct key.
        #expect(router.subscribeChannel(channelId: "7") { _ in received.value += 1 } != nil)
        // Family entry table is now full (entryCapacity distinct keys).
        #expect(router.subscribeChannel(channelId: "99") { _ in received.value += 1 } == nil)

        // Only the channel "42" subscriber(s) receive on a "42" dispatch.
        dispatchBorrowed(
            topic: "coaty/3/test/CHN:42/11111111-1111-4111-8111-111111111111",
            to: router
        )
        #expect(received.value == perEntryCapacity)
    }
}

// MARK: - Test helpers

/// A lock-guarded mutable box for capturing values in `@Sendable` handler
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

/// Pins the topic and payload byte buffers for the synchronous duration of a
/// dispatch, so the `BorrowedMessage` and every value derived from it never
/// outlive their `withUnsafeBufferPointer` scopes.
private func dispatchBorrowed(
    topic: String,
    payload: String = "{}",
    to router: MessageRouter
) {
    let topicBytes = Array(topic.utf8)
    let payloadBytes = Array(payload.utf8)
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
}
