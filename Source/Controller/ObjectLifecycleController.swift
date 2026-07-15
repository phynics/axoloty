//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  ObjectLifecycleController.swift
//  Axoloty
//

import Foundation

/// Keeps track of distributed objects through the async snapshot API provided
/// by ``ObjectLifecycleController+Async``.
open class ObjectLifecycleController: Controller {

    /// Advertises an object and makes it discoverable by its object type.
    ///
    /// Set `shouldSetParentObjectId` to attach the object to this container's
    /// identity before publishing it.
    public func advertiseDiscoverableObject(
        object: CoatyObject,
        shouldSetParentObjectId: Bool = true
    ) {
        if shouldSetParentObjectId {
            object.parentObjectId = container.identity?.objectId
        }
        guard let event = try? AdvertiseEvent.with(object: object) else { return }
        communicationManager.publishAdvertise(event)
    }

    /// Readvertises an object after one or more of its properties changed.
    public func readvertiseDiscoverableObject(object: CoatyObject) {
        guard let event = try? AdvertiseEvent.with(object: object) else { return }
        communicationManager.publishAdvertise(event)
    }

    /// Publishes a deadvertisement for an object.
    public func deadvertiseDiscoverableObject(object: CoatyObject) {
        communicationManager.publishDeadvertise(
            DeadvertiseEvent.with(objectIds: [object.objectId])
        )
    }
}
