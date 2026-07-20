// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Observes incoming Deadvertise snapshots.
    ///
    /// - Returns: An event-buffered `AsyncStream` of immutable Deadvertise snapshots.
    public func observeDeadvertiseStream() async -> AsyncStream<DeadvertiseEventSnapshot> {
        await streams.deadvertise.subscribe()
    }

    /// Observes incoming Discover snapshots.
    ///
    /// - Returns: An event-buffered `AsyncStream` of immutable Discover snapshots.
    public func observeDiscoverStream() async -> AsyncStream<DiscoverEventSnapshot> {
        await streams.discover.subscribe()
    }

    /// Observes incoming Query snapshots.
    ///
    /// Use the snapshot's ``QueryEventSnapshot/correlationId`` to publish a
    /// ``RetrieveEvent`` response via
    /// ``CommunicationManager/publishRetrieve(event:correlationId:)``.
    ///
    /// - Returns: An event-buffered `AsyncStream` of immutable Query snapshots.
    public func observeQueryStream() async -> AsyncStream<QueryEventSnapshot> {
        await streams.query.subscribe()
    }

    /// Observes incoming Call snapshots for a specific operation.
    ///
    /// Use the snapshot's ``CallEventSnapshot/correlationId`` to publish a
    /// ``ReturnEvent`` response via
    /// ``CommunicationManager/publishReturn(event:correlationId:)``.
    ///
    /// - Parameter operation: The remote operation name to observe.
    /// - Throws: ``AxolotyError.invalidArgument(argument:reason:)`` when
    ///   `operation` is not a valid event type filter.
    /// - Returns: An event-buffered `AsyncStream` of immutable Call snapshots.
    public func observeCallStream(operation: String) async throws -> AsyncStream<CallEventSnapshot> {
        guard CommunicationTopic.isValidEventTypeFilter(filter: operation) else {
            throw AxolotyError.invalidArgument(argument: "operation", reason: "\"\(operation)\" is not a valid call operation")
        }
        return await streams.callFamily.subscribe(for: operation)
    }
}
