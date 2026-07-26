// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {
    public func publishRaw(topic: String, withString value: String) throws {
        guard TopicBuilder.isValidPublicationTopic(topic) else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "\"\(topic)\" is not a valid publication topic name")
        }
        publish(topic: topic, message: value)
    }

    public func publishRaw(topic: String, withBinary value: [UInt8]) throws {
        guard TopicBuilder.isValidPublicationTopic(topic) else {
            throw AxolotyError.invalidArgument(argument: "topic", reason: "\"\(topic)\" is not a valid publication topic name")
        }
        publish(topic: topic, message: value)
    }

    public func publishAdvertise(_ event: AdvertiseEvent) {
        event.sourceId = identity.objectId
        let components = TopicStringComponents(
            namespace: namespace, eventType: .advertise,
            eventTypeFilter: event.data.object.coreType.rawValue
        )
        publish(topic: TopicBuilder.publishTopic(components: components, sourceId: identity.objectId),
                message: event.json)
        if event.data.object.coreType.objectType != event.data.object.objectType {
            let object = TopicBuilder.publishTopic(
                components: .init(
                    namespace: namespace, eventType: .advertise,
                    eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + event.data.object.objectType
                ),
                sourceId: identity.objectId
            )
            publish(topic: object, message: event.json)
        }
        if [.Identity, .IoNode].contains(event.data.object.coreType), !deadvertiseIds.contains(event.data.object.objectId) {
            deadvertiseIds.append(event.data.object.objectId)
        }
    }

    public func publishDeadvertise(_ event: DeadvertiseEvent) {
        event.sourceId = identity.objectId
        let topic = TopicBuilder.publishTopic(
            components: .init(namespace: namespace, eventType: .deadvertise),
            sourceId: identity.objectId
        )
        publish(topic: topic, message: event.json)
    }

    public func publishChannel(_ event: ChannelEvent) {
        event.sourceId = identity.objectId
        let topic = TopicBuilder.publishTopic(
            components: .init(namespace: namespace, eventType: .channel, eventTypeFilter: event.channelId),
            sourceId: identity.objectId
        )
        publish(topic: topic, message: event.json)
    }

    private func responseStream(_ eventType: WireEventType, correlationId: String, topic: String) async -> AsyncStream<ResponseEventSnapshot> {
        guard subscriptionCoordinator != nil else {
            return AsyncStream { $0.finish() }
        }
        return await streams.responseFamily.subscribe(
            for: ResponseKey(eventType: eventType, correlationId: correlationId)
        )
    }

    /// Publishes a request event and returns the response stream.
    ///
    /// The returned `AsyncStream`'s continuation is registered eagerly
    /// inside ``Broadcast/subscribe()`` before this method returns, so a
    /// fast broker response is buffered and delivered to the first
    /// iterator — no registration race.
    private func publishWithResponse<D: CommunicationEventData>(
        _ event: CommunicationEvent<D>,
        request eventType: WireEventType,
        response responseType: WireEventType,
        eventTypeFilter: String? = nil
    ) async -> AsyncStream<ResponseEventSnapshot> {
        event.sourceId = identity.objectId
        let correlationId = CoatyUUID().string
        log.debug("Minted request/response correlation id", metadata: [
            "correlationId": .string(correlationId),
            "eventType": .string(eventType.rawValue),
        ])
        let components = TopicStringComponents(
            namespace: namespace,
            eventType: eventType,
            eventTypeFilter: eventTypeFilter,
            correlationId: correlationId
        )
        let topic = TopicBuilder.publishTopic(components: components, sourceId: identity.objectId)
        let responseTopic = TopicBuilder.subscribeTopic(
            eventType: responseType,
            namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace,
            correlationId: correlationId
        )
        let stream = await responseStream(responseType, correlationId: correlationId, topic: responseTopic)
        publish(topic: topic, message: event.json)
        return stream
    }

    private func publishResponseless<D: CommunicationEventData>(
        _ event: CommunicationEvent<D>,
        eventType: WireEventType,
        correlationId: String
    ) {
        event.sourceId = identity.objectId
        log.debug("Publishing response for correlation id", metadata: [
            "correlationId": .string(correlationId),
            "eventType": .string(eventType.rawValue),
        ])
        let topic = TopicBuilder.publishTopic(
            components: .init(namespace: namespace, eventType: eventType, correlationId: correlationId),
            sourceId: identity.objectId
        )
        publish(topic: topic, message: event.json)
    }

    public func publishUpdate(_ event: UpdateEvent) async -> AsyncStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .update, response: .complete, eventTypeFilter: event.data.object.coreType.rawValue)
    }

    public func publishDiscover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .discover, response: .resolve)
    }

    public func publishQuery(_ event: QueryEvent) async -> AsyncStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .query, response: .retrieve)
    }

    public func publishCall(_ event: CallEvent) async -> AsyncStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .call, response: .returnEvent, eventTypeFilter: event.operation)
    }

    internal func publishComplete(event: CompleteEvent, correlationId: String) {
        publishResponseless(event, eventType: .complete, correlationId: correlationId)
    }

    internal func publishResolve(event: ResolveEvent, correlationId: String) {
        publishResponseless(event, eventType: .resolve, correlationId: correlationId)
    }

    internal func publishRetrieve(event: RetrieveEvent, correlationId: String) {
        publishResponseless(event, eventType: .retrieve, correlationId: correlationId)
    }

    internal func publishReturn(event: ReturnEvent, correlationId: String) {
        publishResponseless(event, eventType: .returnEvent, correlationId: correlationId)
    }

    public func publishIoValue(event: IoValueEvent) {
        guard let source = event.ioSource, let route = ioRegistry.associatingRoute(for: source.objectId) else { return }
        event.topic = route
        event.sourceId = identity.objectId
        log.trace("Publishing IoValue", metadata: [
            "ioSourceId": .string(source.objectId.string),
            "ioRoute": .string(route),
        ])
        // Publish the bare payload, matching CoatyJS 2.4.0: its
        // `IoValueEventData.toJsonObject` returns the payload directly (the
        // scalar `42`, not `{"payload":42}`), and raw values are sent as bytes.
        // Sending `event.json` here previously wrapped JSON values under a
        // `payload` key and routed raw bytes through the String overload; both
        // diverged from the reference. See AGENTS.md "Wire compatibility".
        if let raw = event.data.rawPayload {
            publish(topic: route, message: raw)
        } else if let json = event.data.jsonPayload {
            // `jsonPayload` is already raw JSON text; publish it directly,
            // matching CoatyJS 2.4.0's bare-value wire shape.
            publish(topic: route, message: json)
        }
    }

    internal func publishAssociate(event: AssociateEvent) throws {
        guard let name = event.ioContextName, TopicBuilder.isValidEventTypeFilter(filter: name) else {
            throw AxolotyError.invalidArgument(argument: "ioContextName", reason: "Associate: not a valid eventTypeFilter")
        }
        let topic = TopicBuilder.publishTopic(
            components: .init(namespace: namespace, eventType: .associate, eventTypeFilter: name),
            sourceId: identity.objectId
        )
        publish(topic: topic, message: event.json)
    }
}
