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
        let coordinator = subscriptionCoordinator!
        return await eventHub.registerStream(
            key: CommunicationEventHubKeys.response(eventType: eventType, correlationId: correlationId),
            buffering: .event,
            onFirst: {},
            onLast: { _Concurrency.Task { await coordinator.release(topic: topic) } }
        )
    }

    public func publishUpdate(_ event: UpdateEvent) async -> EventStream<ResponseEventSnapshot> {
        event.sourceId = identity.objectId
        let correlationId = CoatyUUID().string
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Update, eventTypeFilter: event.data.object.coreType.rawValue, correlationId: correlationId)
        let responseTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(eventType: .Complete, namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace, correlationId: correlationId)
        let stream = await responseStream(.Complete, correlationId: correlationId, topic: responseTopic)
        publish(topic: topic, message: event.json)
        return stream
    }

    public func publishDiscover(_ event: DiscoverEvent) async -> EventStream<ResponseEventSnapshot> {
        event.sourceId = identity.objectId
        let correlationId = CoatyUUID().string
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Discover, correlationId: correlationId)
        let responseTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(eventType: .Resolve, namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace, correlationId: correlationId)
        let stream = await responseStream(.Resolve, correlationId: correlationId, topic: responseTopic)
        publish(topic: topic, message: event.json)
        return stream
    }

    public func publishQuery(_ event: QueryEvent) async -> EventStream<ResponseEventSnapshot> {
        event.sourceId = identity.objectId
        let correlationId = CoatyUUID().string
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Query, correlationId: correlationId)
        let responseTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(eventType: .Retrieve, namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace, correlationId: correlationId)
        let stream = await responseStream(.Retrieve, correlationId: correlationId, topic: responseTopic)
        publish(topic: topic, message: event.json)
        return stream
    }

    public func publishCall(_ event: CallEvent) async -> EventStream<ResponseEventSnapshot> {
        event.sourceId = identity.objectId
        let correlationId = CoatyUUID().string
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Call, eventTypeFilter: event.operation, correlationId: correlationId)
        let responseTopic = CommunicationTopic.createTopicStringByLevelsForSubscribe(eventType: .Return, namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace, correlationId: correlationId)
        let stream = await responseStream(.Return, correlationId: correlationId, topic: responseTopic)
        publish(topic: topic, message: event.json)
        return stream
    }

    internal func publishComplete(event: CompleteEvent, correlationId: String) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Complete, correlationId: correlationId)
        publish(topic: topic, message: event.json)
    }

    internal func publishResolve(event: ResolveEvent, correlationId: String) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Resolve, correlationId: correlationId)
        publish(topic: topic, message: event.json)
    }

    internal func publishRetrieve(event: RetrieveEvent, correlationId: String) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Retrieve, correlationId: correlationId)
        publish(topic: topic, message: event.json)
    }

    internal func publishReturn(event: ReturnEvent, correlationId: String) {
        event.sourceId = identity.objectId
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Return, correlationId: correlationId)
        publish(topic: topic, message: event.json)
    }

    public func publishIoValue(event: IoValueEvent) {
        guard let source = event.ioSource, let item = ioSourceItems[source.objectId.string] else { return }
        event.topic = item.associatingRoute
        event.sourceId = identity.objectId
        publish(topic: item.associatingRoute, message: event.json)
    }

    internal func publishAssociate(event: AssociateEvent) throws {
        guard let name = event.ioContextName, CommunicationTopic.isValidEventTypeFilter(filter: name) else { throw AxolotyError.InvalidArgument("Associate: Invalid eventTypeFilter") }
        let topic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: namespace, sourceId: identity.objectId, eventType: .Associate, eventTypeFilter: name)
        publish(topic: topic, message: event.json)
    }
}
