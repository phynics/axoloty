// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {
    public func publishRaw(topic: String, withString value: String) throws {
        guard CommunicationTopic.isValidPublicationTopic(topic) else { throw AxolotyError.InvalidArgument("Could not publish raw: invalid topic name.") }
        publish(topic: topic, message: value)
    }

    public func publishRaw(topic: String, withBinary value: [UInt8]) throws {
        guard CommunicationTopic.isValidPublicationTopic(topic) else { throw AxolotyError.InvalidArgument("Could not publish raw: invalid topic name.") }
        publish(topic: topic, message: value)
    }

    public func publishAdvertise(_ event: AdvertiseEvent) {
        event.sourceId = identity.objectId
        let core = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Advertise, eventTypeFilter: event.data.object.coreType.rawValue)
        publish(topic: core, message: event.json)
        if event.data.object.coreType.objectType != event.data.object.objectType {
            let object = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Advertise, eventTypeFilter: EVENT_TYPE_FILTER_SEPARATOR + event.data.object.objectType)
            publish(topic: object, message: event.json)
        }
        if [.Identity, .IoNode].contains(event.data.object.coreType), !deadvertiseIds.contains(event.data.object.objectId) {
            deadvertiseIds.append(event.data.object.objectId)
        }
    }

    public func publishDeadvertise(_ event: DeadvertiseEvent) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Deadvertise)
        publish(topic: topic, message: event.json)
    }

    public func publishChannel(_ event: ChannelEvent) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Channel, eventTypeFilter: event.channelId)
        publish(topic: topic, message: event.json)
    }

    private func responseStream(_ eventType: CommunicationEventType, correlationId: String, topic: String) async -> EventStream<ResponseEventSnapshot> {
        await acquireSubscription(topic: topic)
        let key = CommunicationEventHubKeys.response(eventType: eventType, correlationId: correlationId)

        guard let coordinator = subscriptionCoordinator else {
            // The manager has no coordinator (e.g. this call raced teardown).
            // Fail gracefully with an already-finished stream instead of crashing.
            let stream: EventStream<ResponseEventSnapshot> = await eventHub.registerStream(
                key: key,
                buffering: .event,
                onLast: {}
            )
            await eventHub.finish(key: key)
            return stream
        }

        return await eventHub.registerStream(
            key: key,
            buffering: .event,
            onLast: { _Concurrency.Task { await coordinator.release(topic: topic) } }
        )
    }

    private func publishWithResponse<D: CommunicationEventData>(
        _ event: CommunicationEvent<D>,
        request eventType: CommunicationEventType,
        response responseType: CommunicationEventType,
        eventTypeFilter: String? = nil
    ) async -> EventStream<ResponseEventSnapshot> {
        event.sourceId = identity.objectId
        let correlationId = CoatyUUID().string
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(
            namespace: namespace,
            sourceId: identity.objectId,
            eventType: eventType,
            eventTypeFilter: eventTypeFilter,
            correlationId: correlationId)
        let responseTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
            eventType: responseType,
            namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace,
            correlationId: correlationId)
        let stream = await responseStream(responseType, correlationId: correlationId, topic: responseTopic)
        publish(topic: topic, message: event.json)
        return stream
    }

    private func publishResponseless<D: CommunicationEventData>(
        _ event: CommunicationEvent<D>,
        eventType: CommunicationEventType,
        correlationId: String
    ) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(
            namespace: namespace,
            sourceId: identity.objectId,
            eventType: eventType,
            correlationId: correlationId)
        publish(topic: topic, message: event.json)
    }

    public func publishUpdate(_ event: UpdateEvent) async -> EventStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .Update, response: .Complete, eventTypeFilter: event.data.object.coreType.rawValue)
    }

    public func publishDiscover(_ event: DiscoverEvent) async -> EventStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .Discover, response: .Resolve)
    }

    public func publishQuery(_ event: QueryEvent) async -> EventStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .Query, response: .Retrieve)
    }

    public func publishCall(_ event: CallEvent) async -> EventStream<ResponseEventSnapshot> {
        await publishWithResponse(event, request: .Call, response: .Return, eventTypeFilter: event.operation)
    }

    internal func publishComplete(event: CompleteEvent, correlationId: String) {
        publishResponseless(event, eventType: .Complete, correlationId: correlationId)
    }

    internal func publishResolve(event: ResolveEvent, correlationId: String) {
        publishResponseless(event, eventType: .Resolve, correlationId: correlationId)
    }

    internal func publishRetrieve(event: RetrieveEvent, correlationId: String) {
        publishResponseless(event, eventType: .Retrieve, correlationId: correlationId)
    }

    internal func publishReturn(event: ReturnEvent, correlationId: String) {
        publishResponseless(event, eventType: .Return, correlationId: correlationId)
    }

    public func publishIoValue(event: IoValueEvent) {
        guard let source = event.ioSource, let item = ioSourceItems[source.objectId.string] else { return }
        event.topic = item.associatingRoute
        event.sourceId = identity.objectId
        let route = item.associatingRoute
        // Publish the bare payload, matching CoatyJS 2.4.0: its
        // `IoValueEventData.toJsonObject` returns the payload directly (the
        // scalar `42`, not `{"payload":42}`), and raw values are sent as bytes.
        // Sending `event.json` here previously wrapped JSON values under a
        // `payload` key and routed raw bytes through the String overload; both
        // diverged from the reference. See AGENTS.md "Wire compatibility".
        if let raw = event.data.rawPayload {
            publish(topic: route, message: raw)
        } else if let json = event.data.jsonPayload {
            publish(topic: route, message: PayloadCoder.encode(json))
        }
    }

    internal func publishAssociate(event: AssociateEvent) throws {
        guard let name = event.ioContextName, CommunicationTopic.isValidEventTypeFilter(filter: name) else { throw AxolotyError.InvalidArgument("Associate: Invalid eventTypeFilter") }
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Associate, eventTypeFilter: name)
        publish(topic: topic, message: event.json)
    }
}
