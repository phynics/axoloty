// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Identifies a correlated response subscription in ``EmbeddedMessageRouter``.
public struct EmbeddedResponseKey: Hashable, Sendable {
    /// The response event type.
    public let eventType: WireEventType
    /// The correlation ID identifying the originating request.
    public let correlationId: String

    /// Creates a response-subscription key.
    ///
    /// - Parameters:
    ///   - eventType: The response event type.
    ///   - correlationId: The correlation ID identifying the originating request.
    public init(eventType: WireEventType, correlationId: String) {
        self.eventType = eventType
        self.correlationId = correlationId
    }

    @inline(__always)
    func matches(eventType: WireEventType, correlationId: ByteSlice) -> Bool {
        guard self.eventType == eventType else { return false }
        let utf8 = self.correlationId.utf8
        guard utf8.count == correlationId.length else { return false }
        var index = utf8.startIndex
        for offset in 0..<correlationId.length {
            if utf8[index] != correlationId.byte(at: offset) { return false }
            utf8.formIndex(after: &index)
        }
        return true
    }
}

/// Embedded-runtime adapter that dispatches `BorrowedMessage` through
/// `StaticDispatchTable` and `StaticFamilyTable` with no heap allocation in
/// the steady-state dispatch path.
///
/// Construction allocates a bounded, fixed-capacity set of dispatch and family
/// tables (sized by `WireBufferConfig`); after construction the synchronous
/// `dispatch`/`subscribe` hot path performs no allocation, satisfying the
/// embedded target's `hotPathAllocations` gate (exact-zero in steady state).
///
/// Each event type has its own dispatch table. Keyed families (Advertise by
/// filter, Channel by channel ID, IoState by source ID, Call/Update by
/// correlation ID, Response by event type and correlation ID) use
/// `StaticFamilyTable` for selective dispatch.
///
/// Subscribers register through the subscription methods and receive a token
/// for later unsubscribe. The subscriber count per event type is bounded by
/// `WireBufferConfig.maxSubscribers`.
///
/// This router is intentionally non-`Sendable`: it owns mutable dispatch
/// and family tables safe to mutate from a single execution context.
/// ``subscribe(_:_:)``, ``unsubscribe(_:_:)``, the keyed
/// family subscribe/unsubscribe methods, and ``dispatch(_:)`` are all
/// synchronous and share the owning thread/isolation domain with no internal
/// synchronization (no actor, lock, or queue); embedded routing is
/// bounded and single-threaded, and host-side sync belongs in a host adapter.
///
/// Handler closures remain `@Sendable` so they can be captured by embedded
/// composition, but the ``BorrowedMessage`` they receive — and any values
/// derived from it — are valid only for the synchronous duration of the
/// callback and must be copied before crossing an `await` or any
/// isolation-domain boundary.
public final class EmbeddedMessageRouter: MessageRouter {
    private var tables: [WireEventType: StaticDispatchTable]
    private var rawTable: StaticDispatchTable
    private var ioValueTable: StaticDispatchTable

    // Keyed families mirroring CommunicationStreams
    private var ioStateFamily: StaticFamilyTable<String>
    private var advertiseFamily: StaticFamilyTable<String>
    private var channelFamily: StaticFamilyTable<String>
    private var callFamily: StaticFamilyTable<String>
    private var updateFamily: StaticFamilyTable<String>
    private var responseFamily: StaticFamilyTable<EmbeddedResponseKey>

    /// Creates a router with bounded subscriber and family capacities.
    ///
    /// Each capacity must be non-negative and no greater than its
    /// ``WireBufferConfig`` maximum.
    ///
    /// - Parameters:
    ///   - maxSubscribers: Maximum subscribers per flat event-type table.
    ///   - maxFamilyEntries: Maximum keyed entries per family table.
    ///   - maxFamilySubscribers: Maximum subscribers per family entry.
    /// - Throws: ``WireCapacityError`` if any capacity is negative or exceeds its
    ///   configured maximum.
    public init(
        maxSubscribers: Int = WireBufferConfig.maxSubscribers,
        maxFamilyEntries: Int = WireBufferConfig.maxFamilyEntries,
        maxFamilySubscribers: Int = WireBufferConfig.maxFamilySubscribers
    ) throws(WireCapacityError) {
        try StaticDispatchTable.validateCapacityForRouter(
            maxSubscribers, maxFamilyEntries, maxFamilySubscribers
        )
        var tables: [WireEventType: StaticDispatchTable] = [:]
        let allTypes: [WireEventType] = [
            .advertise, .deadvertise, .channel, .associate,
            .discover, .resolve, .query, .retrieve,
            .update, .complete, .call, .returnEvent
        ]
        for type in allTypes {
            tables[type] = StaticDispatchTable(prevalidated: maxSubscribers)
        }
        self.tables = tables
        self.rawTable = StaticDispatchTable(prevalidated: maxSubscribers)
        self.ioValueTable = StaticDispatchTable(prevalidated: maxSubscribers)
        self.ioStateFamily = Self.staticFamily(maxEntries: maxFamilyEntries, perEntry: maxFamilySubscribers)
        self.advertiseFamily = Self.staticFamily(maxEntries: maxFamilyEntries, perEntry: maxFamilySubscribers)
        self.channelFamily = Self.staticFamily(maxEntries: maxFamilyEntries, perEntry: maxFamilySubscribers)
        self.callFamily = Self.staticFamily(maxEntries: maxFamilyEntries, perEntry: maxFamilySubscribers)
        self.updateFamily = Self.staticFamily(maxEntries: maxFamilyEntries, perEntry: maxFamilySubscribers)
        self.responseFamily = StaticFamilyTable<EmbeddedResponseKey>(
            prevalidatedMaxEntries: maxFamilyEntries,
            prevalidatedMaxSubscribers: maxFamilySubscribers
        )
    }

    private static func staticFamily(
        maxEntries: Int, perEntry: Int
    ) -> StaticFamilyTable<String> {
        StaticFamilyTable<String>(
            prevalidatedMaxEntries: maxEntries,
            prevalidatedMaxSubscribers: perEntry
        )
    }

    // MARK: - Flat subscribers (per event type)

    /// Subscribes a handler for a specific event type.
    ///
    /// - Parameters:
    ///   - eventType: The event type to observe.
    ///   - handler: A closure invoked synchronously for each matching message.
    /// - Returns: A token for later unsubscribe, or nil if the table is full.
    @discardableResult
    public func subscribe(
        _ eventType: WireEventType,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticDispatchTable.Token? {
        tables[eventType]?.subscribe(handler)
    }

    /// Removes the subscriber for the given event type identified by `token`.
    ///
    /// - Parameters:
    ///   - eventType: The event type the token was issued for.
    ///   - token: The token returned by ``subscribe(_:_:)``.
    public func unsubscribe(_ eventType: WireEventType, _ token: StaticDispatchTable.Token) {
        tables[eventType]?.unsubscribe(token)
    }

    /// Subscribes a handler for raw (non-Coaty) topics.
    ///
    /// - Parameter handler: A closure invoked synchronously for each raw message.
    /// - Returns: A token for later unsubscribe, or nil if the table is full.
    @discardableResult
    public func subscribeRaw(
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticDispatchTable.Token? {
        rawTable.subscribe(handler)
    }

    /// Removes the raw-topic subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeRaw(_:)``.
    public func unsubscribeRaw(_ token: StaticDispatchTable.Token) {
        rawTable.unsubscribe(token)
    }

    /// Subscribes a handler for IoValue events.
    ///
    /// - Parameter handler: A closure invoked synchronously for each IoValue message.
    /// - Returns: A token for later unsubscribe, or nil if the table is full.
    @discardableResult
    public func subscribeIoValue(
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticDispatchTable.Token? {
        ioValueTable.subscribe(handler)
    }

    /// Removes the IoValue subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeIoValue(_:)``.
    public func unsubscribeIoValue(_ token: StaticDispatchTable.Token) {
        ioValueTable.unsubscribe(token)
    }

    // MARK: - Keyed family subscribers

    /// Subscribes to Advertise events matching the given event-type filter.
    @discardableResult
    public func subscribeAdvertise(
        filter: String,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticFamilyTable<String>.Token? {
        advertiseFamily.subscribe(key: filter, handler)
    }

    /// Removes the Advertise-family subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeAdvertise(filter:_:)``.
    public func unsubscribeAdvertise(_ token: StaticFamilyTable<String>.Token) {
        advertiseFamily.unsubscribe(token)
    }

    /// Subscribes to Channel events matching the given channel ID.
    @discardableResult
    public func subscribeChannel(
        channelId: String,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticFamilyTable<String>.Token? {
        channelFamily.subscribe(key: channelId, handler)
    }

    /// Removes the Channel-family subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeChannel(channelId:_:)``.
    public func unsubscribeChannel(_ token: StaticFamilyTable<String>.Token) {
        channelFamily.unsubscribe(token)
    }

    /// Subscribes to IoState events for a given source ID.
    @discardableResult
    public func subscribeIoState(
        sourceId: String,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticFamilyTable<String>.Token? {
        ioStateFamily.subscribe(key: sourceId, handler)
    }

    /// Removes the IoState-family subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeIoState(sourceId:_:)``.
    public func unsubscribeIoState(_ token: StaticFamilyTable<String>.Token) {
        ioStateFamily.unsubscribe(token)
    }

    /// Subscribes to Call events matching the given correlation ID.
    @discardableResult
    public func subscribeCall(
        correlationId: String,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticFamilyTable<String>.Token? {
        callFamily.subscribe(key: correlationId, handler)
    }

    /// Removes the Call-family subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeCall(correlationId:_:)``.
    public func unsubscribeCall(_ token: StaticFamilyTable<String>.Token) {
        callFamily.unsubscribe(token)
    }

    /// Subscribes to Update events matching the given correlation ID.
    @discardableResult
    public func subscribeUpdate(
        correlationId: String,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticFamilyTable<String>.Token? {
        updateFamily.subscribe(key: correlationId, handler)
    }

    /// Removes the Update-family subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by ``subscribeUpdate(correlationId:_:)``.
    public func unsubscribeUpdate(_ token: StaticFamilyTable<String>.Token) {
        updateFamily.unsubscribe(token)
    }

    /// Subscribes to responses matching an event type and correlation ID.
    ///
    /// - Parameters:
    ///   - eventType: The response event type: Complete, Resolve, Retrieve, or Return.
    ///   - correlationId: The correlation ID identifying the originating request.
    ///   - handler: A closure invoked synchronously for each matching response.
    /// - Returns: A token for later unsubscribe, or nil if the event type is not a
    ///   response type or its family table is full.
    @discardableResult
    public func subscribeResponse(
        eventType: WireEventType,
        correlationId: String,
        _ handler: @Sendable @escaping (BorrowedMessage) -> Void
    ) -> StaticFamilyTable<EmbeddedResponseKey>.Token? {
        guard Self.responseEventTypes.contains(eventType) else { return nil }
        return responseFamily.subscribe(
            key: EmbeddedResponseKey(eventType: eventType, correlationId: correlationId),
            handler
        )
    }

    /// Removes a response-family subscriber identified by `token`.
    ///
    /// - Parameter token: The token returned by
    ///   ``subscribeResponse(eventType:correlationId:_:)``.
    public func unsubscribeResponse(_ token: StaticFamilyTable<EmbeddedResponseKey>.Token) {
        responseFamily.unsubscribe(token)
    }

    // MARK: - Dispatch

    /// Dispatches a message to matching subscribers.
    ///
    /// Routing logic:
    /// 1. Raw topics → rawTable
    /// 2. IoValue → ioValueTable
    /// 3. Advertise → advertiseFamily (by event-type filter from topic)
    /// 4. Channel → channelFamily (by channel ID from topic)
    /// 5. Deadvertise → advertiseFamily.dispatchAll (notify all advertise subscribers)
    /// 6. Call → callFamily (by correlation ID from topic)
    /// 7. Update → updateFamily (by correlation ID from topic)
    /// 8. Complete, Resolve, Retrieve, and Return → response family (by event
    ///    type and correlation ID from topic)
    /// 9. Other event types → flat table by event type
    public func dispatch(_ message: BorrowedMessage) {
        if message.isRawTopic {
            rawTable.dispatch(message)
            return
        }

        guard let eventType = message.eventType else { return }

        if eventType == .ioValue {
            ioValueTable.dispatch(message)
            return
        }

        dispatchKeyed(eventType, message)
    }

    private func dispatchKeyed(_ eventType: WireEventType, _ message: BorrowedMessage) {
        switch eventType {
        case .advertise:
            dispatchAdvertise(message)

        case .deadvertise:
            advertiseFamily.dispatchAll(message)

        case .channel:
            dispatchChannel(message)

        case .call:
            dispatchCall(message)

        case .update:
            dispatchUpdate(message)

        case .complete, .resolve, .retrieve, .returnEvent:
            dispatchResponse(eventType, message)

        default:
            tables[eventType]?.dispatch(message)
        }
    }

    private func dispatchAdvertise(_ message: BorrowedMessage) {
        if let filter = message.topic.eventTypeFilter {
            advertiseFamily.dispatch(byBytes: filter, message)
        } else {
            advertiseFamily.dispatchAll(message)
        }
    }

    private func dispatchChannel(_ message: BorrowedMessage) {
        if let filter = message.topic.eventTypeFilter {
            channelFamily.dispatch(byBytes: filter, message)
        }
    }

    private func dispatchCall(_ message: BorrowedMessage) {
        if let correlationId = message.topic.level(5) {
            callFamily.dispatch(byBytes: correlationId, message)
        }
    }

    private func dispatchUpdate(_ message: BorrowedMessage) {
        if let correlationId = message.topic.level(5) {
            updateFamily.dispatch(byBytes: correlationId, message)
        }
    }

    private func dispatchResponse(_ eventType: WireEventType, _ message: BorrowedMessage) {
        guard let correlationId = message.topic.correlationIdLevel else { return }
        responseFamily.dispatch(
            matching: { $0.matches(eventType: eventType, correlationId: correlationId) },
            message
        )
    }

    private static let responseEventTypes: [WireEventType] = [
        .complete, .resolve, .retrieve, .returnEvent
    ]
}
