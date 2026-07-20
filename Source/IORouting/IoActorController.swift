// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Provides async convenience methods for observing IO actor values and associations.
open class IoActorController: Controller {
    private var actorValues: [String: AnyCodable?] = [:]
    private var actorAssociations: [String: Bool] = [:]

    override open func onInit() {
        super.onInit()
        actorValues.removeAll()
        actorAssociations.removeAll()
    }

    /// Observes raw IO value snapshots routed to an actor.
    public func observeIoValue(actor: IoActor) async -> AsyncStream<IoValueEventSnapshot> {
        await communicationManager.observeIoValueStream()
    }

    /// Returns the latest decoded value received for an actor.
    public func getIoValue(actor: IoActor) -> AnyCodable? {
        actorValues[actor.objectId.string] ?? nil
    }

    /// Observes association state snapshots for an actor.
    public func observeAssociation(actor: IoActor) async -> AsyncStream<IoStateEventSnapshot> {
        await communicationManager.observeIoStateStream(ioPoint: actor)
    }

    /// Determines whether an actor is currently associated.
    public func isAssociated(actor: IoActor) -> Bool {
        actorAssociations[actor.objectId.string] ?? false
    }
}
