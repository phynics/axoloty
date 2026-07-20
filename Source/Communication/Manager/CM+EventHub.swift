// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Returns an async stream that replays the current operating lifecycle
    /// state and emits future start/stop transitions.
    public func observeOperatingStateStream() async -> AsyncStream<OperatingState> {
        await streams.operatingState.subscribe()
    }

    /// Returns an async stream that replays the current ``CommunicationState``
    /// and emits future state changes.
    ///
    /// The returned stream uses state buffering, so the most recently emitted
    /// state is replayed to new subscribers before any future changes.
    ///
    /// - Returns: an `AsyncStream` of ``CommunicationState`` values.
    public func observeCommunicationStateStream() async -> AsyncStream<CommunicationState> {
        await streams.communicationState.subscribe()
    }

    /// Returns an async stream of raw incoming MQTT transport messages.
    ///
    /// The returned stream uses event buffering and emits one ``RawMQTTMessage``
    /// for each incoming MQTT `PUBLISH` packet. It does not replay historical
    /// messages.
    ///
    /// - Returns: an `AsyncStream` of ``RawMQTTMessage`` values.
    public func observeRawMQTTMessageStream() async -> AsyncStream<RawMQTTMessage> {
        await streams.rawMQTTMessages.subscribe()
    }
}
