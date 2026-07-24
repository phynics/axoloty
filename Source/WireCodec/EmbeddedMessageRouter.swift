// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Embedded-runtime adapter that dispatches `BorrowedMessage` through
/// `StaticDispatchTable` and `StaticFamilyTable` with zero heap allocation.
///
/// Each event type has its own dispatch table. Keyed families (Advertise by
/// filter, Channel by channel ID, IoState by source ID, Call/Update by
/// correlation ID, Response by correlation ID) use `StaticFamilyTable`
/// for selective dispatch.
///
/// Subscribers register via `subscribe(_:_)` / `subscribeFamily(key:_)` and
/// receive a token for later unsubscribe. The subscriber count per event
/// type is bounded by `WireBufferConfig.maxSubscribers`.
public final class EmbeddedMessageRouter: MessageRouter, @unchecked Sendable {
    private var tables: [WireEventType: StaticDispatchTable]
    private var rawTable: StaticDispatchTable
    private var ioValueTable: StaticDispatchTable

    // Keyed families mirroring CommunicationStreams
    private var ioStateFamily: StaticFamilyTable<String>
    private var advertiseFamily: StaticFamilyTable<String>
    private var channelFamily: StaticFamilyTable<String>
    private var callFamily: StaticFamilyTable<String>
    private var updateFamily: StaticFamilyTable<String>

    /// Creates a router with the given subscriber and family capacity limits.
    ///
    /// - Parameters:
    ///   - maxSubscribers: Maximum subscribers per flat event-type table.
    ///   - maxFamilyEntries: Maximum keyed entries per family table.
    ///   - maxFamilySubscribers: Maximum subscribers per family entry.
    public init(
        maxSubscribers: Int = WireBufferConfig.maxSubscribers,
        maxFamilyEntries: Int = WireBufferConfig.maxFamilyEntries,
        maxFamilySubscribers: Int = WireBufferConfig.maxFamilySubscribers
    ) {
        var tables: [WireEventType: StaticDispatchTable] = [:]
        let allTypes: [WireEventType] = [
            .advertise, .deadvertise, .channel, .associate,
            .discover, .resolve, .query, .retrieve,
            .update, .complete, .call, .returnEvent
        ]
        for type in allTypes {
            tables[type] = StaticDispatchTable(capacity: maxSubscribers)
        }
        self.tables = tables
        self.rawTable = StaticDispatchTable(capacity: maxSubscribers)
        self.ioValueTable = StaticDispatchTable(capacity: maxSubscribers)
        self.ioStateFamily = StaticFamilyTable<String>(
            maxEntries: maxFamilyEntries, maxSubscribersPerEntry: maxFamilySubscribers
        )
        self.advertiseFamily = StaticFamilyTable<String>(
            maxEntries: maxFamilyEntries, maxSubscribersPerEntry: maxFamilySubscribers
        )
        self.channelFamily = StaticFamilyTable<String>(
            maxEntries: maxFamilyEntries, maxSubscribersPerEntry: maxFamilySubscribers
        )
        self.callFamily = StaticFamilyTable<String>(
            maxEntries: maxFamilyEntries, maxSubscribersPerEntry: maxFamilySubscribers
        )
        self.updateFamily = StaticFamilyTable<String>(
            maxEntries: maxFamilyEntries, maxSubscribersPerEntry: maxFamilySubscribers
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
        guard var table = tables[eventType] else { return nil }
        let token = table.subscribe(handler)
        tables[eventType] = table
        return token
    }

    /// Removes the subscriber for the given event type identified by `token`.
    ///
    /// - Parameters:
    ///   - eventType: The event type the token was issued for.
    ///   - token: The token returned by ``subscribe(_:_:)``.
    public func unsubscribe(_ eventType: WireEventType, _ token: StaticDispatchTable.Token) {
        guard var table = tables[eventType] else { return }
        table.unsubscribe(token)
        tables[eventType] = table
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
    /// 8. Other event types → flat table by event type
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

        // Keyed dispatch for family events
        switch eventType {
        case .advertise:
            // Event-type filter is the part of topic level 3 after ':'.
            if let filter = message.topic.eventTypeFilter {
                advertiseFamily.dispatch(byBytes: filter, message)
            } else {
                advertiseFamily.dispatchAll(message)
            }

        case .deadvertise:
            // Deadvertise is delivered to all advertise subscribers
            advertiseFamily.dispatchAll(message)

        case .channel:
            // Channel ID is the event-type filter from topic level 3
            if let filter = message.topic.eventTypeFilter {
                channelFamily.dispatch(byBytes: filter, message)
            }

        case .call:
            // Correlation ID is topic level 5
            if let corrId = message.topic.level(5) {
                callFamily.dispatch(byBytes: corrId, message)
            }

        case .update:
            if let corrId = message.topic.level(5) {
                updateFamily.dispatch(byBytes: corrId, message)
            }

        default:
            // Flat dispatch for all other event types
            tables[eventType]?.dispatch(message)
        }
    }
}
