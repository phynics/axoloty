// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Provides async convenience methods for observing IO actor values and associations.
open class IoActorController: Controller {
    /// Observes raw IO value snapshots routed to an actor.
    public func observeIoValue(actor: IoActor) async -> AsyncStream<IoValueEventSnapshot> {
        await communicationManager.observeIoValueStream()
    }

    /// Returns the latest decoded value received for an actor, as raw JSON text.
    ///
    /// The authoritative IO value state is maintained by the communication
    /// manager. There is no public synchronous query exposing it, so this is a
    /// streams-only stub; use ``observeIoValue(actor:)`` to receive values.
    public func getIoValue(actor: IoActor) -> String? {
        nil
    }

    /// Observes association state snapshots for an actor.
    public func observeAssociation(actor: IoActor) async -> AsyncStream<IoStateEventSnapshot> {
        await communicationManager.observeIoStateStream(ioPoint: actor)
    }

    /// Determines whether an actor is currently associated.
    ///
    /// The authoritative association state is maintained by the communication
    /// manager's IO registry. There is no public synchronous query exposing it,
    /// so this returns `false`; prefer ``observeAssociation(actor:)`` for
    /// association-aware value handling.
    public func isAssociated(actor: IoActor) -> Bool {
        false
    }
}
