// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

extension MQTTNIOClient {
    /// Routes a parsed MQTT message to the appropriate event streams.
    ///
    /// This is the single routing decision point for all non-IoValue, non-raw
    /// Coaty messages. The exhaustive switch ensures that adding a new event
    /// type produces a compiler error here.
    ///
    /// - Parameters:
    ///   - parsed: the parsed transport message.
    ///   - streams: the communication streams to dispatch into.
    internal static func routeParsedMessage(
        parsed: ParsedMQTTMessage,
        into streams: CommunicationStreams
    ) async {
        switch parsed.eventType {
        case .advertise:
            guard let snapshot = AdvertiseEventSnapshot(parsedMQTTMessage: parsed) else { return }
            let baseKey = AdvertiseKey(eventTypeFilter: parsed.eventTypeFilter ?? "")
            await streams.advertiseFamily.send(snapshot, for: baseKey)
            if let coreType = CoreType.getCoreType(forObjectType: snapshot.object.objectType),
               parsed.eventTypeFilter == coreType.rawValue {
                let objectKey = AdvertiseKey(
                    eventTypeFilter: coreType.rawValue,
                    objectTypeFilter: snapshot.object.objectType
                )
                await streams.advertiseFamily.send(snapshot, for: objectKey)
            }
            await streams.advertiseAll.send(snapshot)
        case .deadvertise:
            if let snapshot = DeadvertiseEventSnapshot(parsedMQTTMessage: parsed) {
                await streams.deadvertise.send(snapshot)
            }
        case .discover:
            if let snapshot = DiscoverEventSnapshot(parsedMQTTMessage: parsed) {
                await streams.discover.send(snapshot)
            }
        case .query:
            if let snapshot = QueryEventSnapshot(parsedMQTTMessage: parsed) {
                await streams.query.send(snapshot)
            }
        case .call:
            if let snapshot = CallEventSnapshot(parsedMQTTMessage: parsed),
               let operation = parsed.eventTypeFilter {
                await streams.callFamily.send(snapshot, for: operation)
            }
        case .complete, .resolve, .retrieve, .returnEvent:
            if let correlationId = parsed.correlationId {
                let object: CoatyObjectSnapshot?
                switch parsed.event {
                case .resolve(let wire): object = try? HostWireAdapter.snapshot(from: wire.object)
                case .complete(let wire): object = wire.object.flatMap { try? HostWireAdapter.snapshot(from: $0) }
                default: object = nil
                }
                let snapshot = ResponseEventSnapshot(
                    eventType: parsed.eventType.rawValue,
                    sourceId: parsed.sourceId,
                    correlationId: correlationId,
                    payload: parsed.payloadString ?? "",
                    object: object
                )
                await streams.responseFamily.send(
                    snapshot,
                    for: ResponseKey(eventType: parsed.eventType, correlationId: correlationId)
                )
            }
        case .update:
            guard let snapshot = UpdateEventSnapshot(parsedMQTTMessage: parsed),
                  let filter = parsed.eventTypeFilter else { return }
            await streams.updateFamily.send(snapshot, for: filter)
        case .channel:
            guard let snapshot = ChannelEventSnapshot(parsedMQTTMessage: parsed),
                  let channelId = parsed.eventTypeFilter else { return }
            await streams.channelFamily.send(snapshot, for: channelId)
        case .associate:
            guard let snapshot = AssociateEventSnapshot(parsedMQTTMessage: parsed),
                  let contextName = snapshot.ioContextName else { return }
            await streams.associateFamily.send(snapshot, for: contextName)
        case .ioValue:
            break
        }
    }
}
