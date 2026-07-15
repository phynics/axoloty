// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Returns an async stream that replays the current operating lifecycle
    /// state and emits future start/stop transitions.
    public func observeOperatingStateStream() async -> EventStream<OperatingState> {
        await client.eventHub.registerStream(
            key: CommunicationEventHubKeys.operatingState,
            buffering: .state,
            onFirst: {},
            onLast: {}
        )
    }

    /// Returns an async stream that replays the current ``CommunicationState``
    /// and emits future state changes.
    ///
    /// The returned stream uses state buffering, so the most recently emitted
    /// state is replayed to new subscribers before any future changes.
    ///
    /// - Returns: an ``EventStream`` of ``CommunicationState`` values.
    public func observeCommunicationStateStream() async -> EventStream<CommunicationState> {
        return await client.eventHub.registerStream(
            key: CommunicationEventHubKeys.communicationState,
            buffering: .state,
            onFirst: {},
            onLast: {}
        )
    }

    /// Returns an async stream of raw incoming MQTT transport messages.
    ///
    /// The returned stream uses event buffering and emits one ``RawMQTTMessage``
    /// for each incoming MQTT `PUBLISH` packet. It does not replay historical
    /// messages.
    ///
    /// - Returns: an ``EventStream`` of ``RawMQTTMessage`` values.
    public func observeRawMQTTMessageStream() async -> EventStream<RawMQTTMessage> {
        return await client.eventHub.registerStream(
            key: CommunicationEventHubKeys.rawMQTTMessage,
            buffering: .event,
            onFirst: {},
            onLast: {}
        )
    }
}
