// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyProtocol
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
        var table = try! StaticDispatchTable(capacity: 4)
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
        var table = try! StaticDispatchTable(capacity: 4)
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
        var table = try! StaticDispatchTable(capacity: 2)
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
        var table = try! StaticDispatchTable(capacity: 2)
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

    @Test
    func dispatchTableRejectsStaleTokenAfterSlotReuse() throws {
        var table = try! StaticDispatchTable(capacity: 1)
        let currentReceived = Box(0)

        let staleToken = try #require(table.subscribe { _ in })
        table.unsubscribe(staleToken)
        let currentToken = try #require(table.subscribe { _ in currentReceived.value += 1 })

        table.unsubscribe(staleToken)
        #expect(table.subscriberCount == 1)

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(message)
        }
        #expect(currentReceived.value == 1)

        table.unsubscribe(currentToken)
    }

    @Test
    func dispatchTableRejectsForeignToken() throws {
        var first = try! StaticDispatchTable(capacity: 1)
        var second = try! StaticDispatchTable(capacity: 1)
        let firstReceived = Box(0)
        let secondReceived = Box(0)

        let firstToken = try #require(first.subscribe { _ in firstReceived.value += 1 })
        _ = try #require(second.subscribe { _ in secondReceived.value += 1 })

        second.unsubscribe(firstToken)
        #expect(first.subscriberCount == 1)
        #expect(second.subscriberCount == 1)

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            first.dispatch(message)
            second.dispatch(message)
        }
        #expect(firstReceived.value == 1)
        #expect(secondReceived.value == 1)
    }

    @Test
    func populatedDispatchTableCopyAcceptsInheritedTokenInEitherMutationOrder() throws {
        var firstOriginal = try! StaticDispatchTable(capacity: 1)
        let firstToken = try #require(firstOriginal.subscribe { _ in })
        var firstCopy = firstOriginal

        firstCopy.unsubscribe(firstToken)
        firstOriginal.unsubscribe(firstToken)

        #expect(firstOriginal.subscriberCount == 0)
        #expect(firstCopy.subscriberCount == 0)

        var secondOriginal = try! StaticDispatchTable(capacity: 1)
        let secondToken = try #require(secondOriginal.subscribe { _ in })
        var secondCopy = secondOriginal

        secondOriginal.unsubscribe(secondToken)
        secondCopy.unsubscribe(secondToken)

        #expect(secondOriginal.subscriberCount == 0)
        #expect(secondCopy.subscriberCount == 0)
    }

    @Test
    func emptyDispatchTableCopiesIssueIndependentTokens() throws {
        var original = try! StaticDispatchTable(capacity: 1)
        var copy = original
        let originalToken = try #require(original.subscribe { _ in })
        let copyToken = try #require(copy.subscribe { _ in })

        original.unsubscribe(copyToken)
        copy.unsubscribe(originalToken)

        #expect(original.subscriberCount == 1)
        #expect(copy.subscriberCount == 1)

        original.unsubscribe(originalToken)
        copy.unsubscribe(copyToken)
        #expect(original.subscriberCount == 0)
        #expect(copy.subscriberCount == 0)
    }

    @Test
    func populatedDispatchTableCopiesIssueNoncollidingNewTokens() throws {
        var original = try! StaticDispatchTable(capacity: 2)
        let inheritedToken = try #require(original.subscribe { _ in })
        var copy = original
        let originalToken = try #require(original.subscribe { _ in })
        let copyToken = try #require(copy.subscribe { _ in })

        original.unsubscribe(copyToken)
        copy.unsubscribe(originalToken)

        #expect(original.subscriberCount == 2)
        #expect(copy.subscriberCount == 2)

        original.unsubscribe(inheritedToken)
        copy.unsubscribe(inheritedToken)
        original.unsubscribe(originalToken)
        copy.unsubscribe(copyToken)
        #expect(original.subscriberCount == 0)
        #expect(copy.subscriberCount == 0)
    }

    @Test
    func dispatchTableRejectsNegativeAndOversizedTokenIndices() throws {
        var table = try! StaticDispatchTable(capacity: 1)
        let token = try #require(table.subscribe { _ in })

        table.unsubscribe(token.replacingIndexForTesting(-1))
        table.unsubscribe(token.replacingIndexForTesting(Int.max))

        #expect(table.subscriberCount == 1)
        table.unsubscribe(token)
    }

    @Test
    func dispatchTableRetiresSlotAtGenerationExhaustion() throws {
        var table = try StaticDispatchTable(
            capacity: 1,
            initialGenerationForTesting: UInt16.max - 1
        )

        let finalToken = try #require(table.subscribe { _ in })
        table.unsubscribe(finalToken)

        #expect(table.subscribe { _ in } == nil)
        #expect(table.subscriberCount == 0)
    }

    @Test
    func subscriptionTokensAreSendable() {
        requireSendable(StaticDispatchTable.Token.self)
        requireSendable(StaticFamilyTable<String>.Token.self)
    }

    @Test
    func subscriptionTokenProtectionFitsHostLayoutBudget() {
        let legacySlotStride = MemoryLayout<LegacyDispatchSlot>.stride
        let currentSlotStride = StaticDispatchTable.slotStrideForTesting
        let legacyFlatTokenStride = MemoryLayout<Int>.stride
        let currentFlatTokenStride = MemoryLayout<StaticDispatchTable.Token>.stride
        let legacyFamilyTokenStride = MemoryLayout<(Int, Int)>.stride
        let currentFamilyTokenStride = MemoryLayout<StaticFamilyTable<String>.Token>.stride

        #expect(currentSlotStride - legacySlotStride == 8)
        #expect(currentFlatTokenStride - legacyFlatTokenStride == 16)
        #expect(currentFamilyTokenStride - legacyFamilyTokenStride == 16)
    }

    // MARK: - StaticFamilyTable

    @Test
    func familyTableDispatchesByKey() throws {
        var table = try! StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)
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
        var table = try! StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)
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
        var table = try! StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 2)

        let token = table.subscribe(key: "foo") { _ in }
        #expect(table.entryCount == 1)

        table.unsubscribe(try #require(token))
        #expect(table.entryCount == 0)

        let token2 = table.subscribe(key: "bar") { _ in }
        #expect(token2 != nil)
        #expect(table.entryCount == 1)
    }

    @Test
    func familyTableRejectsForeignToken() throws {
        var first = try! StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: 1)
        var second = try! StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: 1)
        let secondReceived = Box(0)

        let firstToken = try #require(first.subscribe(key: "first") { _ in })
        _ = try #require(second.subscribe(key: "second") { _ in secondReceived.value += 1 })

        second.unsubscribe(firstToken)
        #expect(first.entryCount == 1)
        #expect(second.entryCount == 1)

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            second.dispatch(key: "second", message)
        }
        #expect(secondReceived.value == 1)
    }

    @Test
    func familyTableRejectsStaleTokenAfterEntryReuse() throws {
        var table = try! StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: 1)
        let currentReceived = Box(0)

        let staleToken = try #require(table.subscribe(key: "stale") { _ in })
        table.unsubscribe(staleToken)
        let currentToken = try #require(
            table.subscribe(key: "current") { _ in currentReceived.value += 1 }
        )

        table.unsubscribe(staleToken)
        #expect(table.entryCount == 1)

        withBorrowedMessage(topic: "coaty/3/test/ADV:foo/11111111-1111-4111-8111-111111111111") { message in
            table.dispatch(key: "current", message)
        }
        #expect(currentReceived.value == 1)

        table.unsubscribe(currentToken)
    }

    @Test
    func populatedFamilyTableCopyAcceptsInheritedTokenInEitherMutationOrder() throws {
        var firstOriginal = try! StaticFamilyTable<String>(
            maxEntries: 1,
            maxSubscribersPerEntry: 1
        )
        let firstToken = try #require(firstOriginal.subscribe(key: "key") { _ in })
        var firstCopy = firstOriginal

        firstCopy.unsubscribe(firstToken)
        firstOriginal.unsubscribe(firstToken)

        #expect(firstOriginal.entryCount == 0)
        #expect(firstCopy.entryCount == 0)

        var secondOriginal = try! StaticFamilyTable<String>(
            maxEntries: 1,
            maxSubscribersPerEntry: 1
        )
        let secondToken = try #require(secondOriginal.subscribe(key: "key") { _ in })
        var secondCopy = secondOriginal

        secondOriginal.unsubscribe(secondToken)
        secondCopy.unsubscribe(secondToken)

        #expect(secondOriginal.entryCount == 0)
        #expect(secondCopy.entryCount == 0)
    }

    @Test
    func emptyFamilyTableCopiesIssueIndependentTokens() throws {
        var original = try! StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: 1)
        var copy = original
        let originalToken = try #require(original.subscribe(key: "key") { _ in })
        let copyToken = try #require(copy.subscribe(key: "key") { _ in })

        original.unsubscribe(copyToken)
        copy.unsubscribe(originalToken)

        #expect(original.entryCount == 1)
        #expect(copy.entryCount == 1)

        original.unsubscribe(originalToken)
        copy.unsubscribe(copyToken)
        #expect(original.entryCount == 0)
        #expect(copy.entryCount == 0)
    }

    @Test
    func populatedFamilyTableCopiesIssueNoncollidingNewTokens() throws {
        var original = try! StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: 2)
        let inheritedToken = try #require(original.subscribe(key: "key") { _ in })
        var copy = original
        let originalToken = try #require(original.subscribe(key: "key") { _ in })
        let copyToken = try #require(copy.subscribe(key: "key") { _ in })

        original.unsubscribe(copyToken)
        copy.unsubscribe(originalToken)

        #expect(original.entryCount == 1)
        #expect(copy.entryCount == 1)

        original.unsubscribe(inheritedToken)
        copy.unsubscribe(inheritedToken)
        #expect(original.entryCount == 1)
        #expect(copy.entryCount == 1)

        original.unsubscribe(originalToken)
        copy.unsubscribe(copyToken)
        #expect(original.entryCount == 0)
        #expect(copy.entryCount == 0)
    }

    @Test
    func familyTableRejectsNegativeAndOversizedEntryIndices() throws {
        var table = try! StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: 1)
        let token = try #require(table.subscribe(key: "key") { _ in })

        table.unsubscribe(token.replacingEntryIndexForTesting(-1))
        table.unsubscribe(token.replacingEntryIndexForTesting(Int.max))

        #expect(table.entryCount == 1)
        table.unsubscribe(token)
    }

    @Test
    func familyTableMultipleSubscribersPerKey() throws {
        var table = try! StaticFamilyTable<String>(maxEntries: 4, maxSubscribersPerEntry: 3)
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
        var table = try! StaticDispatchTable(capacity: 4)
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

// MARK: - Caller-controlled capacity bounds

@Suite("Caller-controlled capacity bounds")
struct CallerControlledCapacityTests {

    /// Asserts that a throwing-capacity expression throws the expected reason.
    private func expectCapacityError(
        reason: ProtocolCapacityError.Reason,
        body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("Expected ProtocolCapacityError, got success")
        } catch let error as ProtocolCapacityError {
            #expect(error.reason == reason)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - StaticDispatchTable

    @Test
    func dispatchTableRejectsNegativeCapacity() {
        expectCapacityError(reason: .negativeCapacity) {
            _ = try StaticDispatchTable(capacity: -1)
        }
    }

    @Test
    func dispatchTableAcceptsZeroCapacity() {
        var table = try! StaticDispatchTable(capacity: 0)
        #expect(table.subscribe { _ in } == nil)
    }

    @Test
    func dispatchTableRejectsOversizedCapacity() {
        expectCapacityError(reason: .exceedsMaximum) {
            _ = try StaticDispatchTable(capacity: ProtocolBufferConfig.maxSubscribers + 1)
        }
    }

    // MARK: - StaticFamilyTable

    @Test
    func familyTableRejectsNegativeEntryCapacity() {
        expectCapacityError(reason: .negativeCapacity) {
            _ = try StaticFamilyTable<String>(maxEntries: -1)
        }
    }

    @Test
    func familyTableRejectsNegativePerEntryCapacity() {
        expectCapacityError(reason: .negativeCapacity) {
            _ = try StaticFamilyTable<String>(maxEntries: 1, maxSubscribersPerEntry: -1)
        }
    }

    @Test
    func familyTableRejectsOversizedEntryCapacity() {
        expectCapacityError(reason: .exceedsMaximum) {
            _ = try StaticFamilyTable<String>(
                maxEntries: ProtocolBufferConfig.maxFamilyEntries + 1
            )
        }
    }

    @Test
    func familyTableRejectsOversizedPerEntryCapacity() {
        expectCapacityError(reason: .exceedsMaximum) {
            _ = try StaticFamilyTable<String>(
                maxEntries: 1,
                maxSubscribersPerEntry: ProtocolBufferConfig.maxFamilySubscribers + 1
            )
        }
    }

    // MARK: - EmbeddedMessageRouter

    @Test
    func routerRejectsNegativeSubscriberCapacity() {
        expectCapacityError(reason: .negativeCapacity) {
            _ = try EmbeddedMessageRouter(maxSubscribers: -1)
        }
    }

    @Test
    func routerRejectsOversizedFamilyEntries() {
        expectCapacityError(reason: .exceedsMaximum) {
            _ = try EmbeddedMessageRouter(
                maxFamilyEntries: ProtocolBufferConfig.maxFamilyEntries + 1
            )
        }
    }

    @Test
    func routerRejectsOversizedFamilySubscribers() {
        expectCapacityError(reason: .exceedsMaximum) {
            _ = try EmbeddedMessageRouter(
                maxFamilySubscribers: ProtocolBufferConfig.maxFamilySubscribers + 1
            )
        }
    }

    // MARK: - StaticIoEndpoints

    @Test
    func ioEndpointsRejectsOversizedSourceCount() {
        let descriptors = (0..<(ProtocolBufferConfig.maxFamilyEntries + 1)).map { _ in
            StaticIoEndpointDescriptor(id: .zero, valueType: "test.Value", mode: .raw)
        }
        expectCapacityError(reason: .exceedsMaximum) {
            _ = try StaticIoEndpoints(sources: descriptors, actors: [], actorHandlers: [])
        }
    }

    @Test
    func ioEndpointsRejectsActorHandlerCountMismatch() {
        let actor = StaticIoEndpointDescriptor(id: .zero, valueType: "test.Value", mode: .raw)
        expectCapacityError(reason: .countMismatch) {
            _ = try StaticIoEndpoints(sources: [], actors: [actor], actorHandlers: [])
        }
    }
}

// MARK: - Test helpers

private struct LegacyDispatchSlot {
    var active: Bool
    var handler: (@Sendable (BorrowedMessage) -> Void)?
}

private func requireSendable<T: Sendable>(_: T.Type) {}

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
