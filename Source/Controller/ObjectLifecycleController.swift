//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  ObjectLifecycleController.swift
//  Axoloty
//

import ErrorKit
import Foundation
import Logging

/// Keeps track of distributed objects through the async snapshot API provided
/// by ``ObjectLifecycleController+Async``.
open class ObjectLifecycleController: Controller {

    private let log = LogManager.logger(.runtime)

    /// Advertises an object and makes it discoverable by its object type.
    ///
    /// Set `shouldSetParentObjectId` to attach the object to this container's
    /// identity before publishing it.
    ///
    /// This is a best-effort publication: an invalid object type or a transport
    /// failure prevents discovery, but the loss is surfaced as a structured
    /// log line (with ``AxolotyError``) instead of being silently swallowed.
    public func advertiseDiscoverableObject(
        object: CoatyObject,
        shouldSetParentObjectId: Bool = true
    ) {
        if shouldSetParentObjectId {
            object.parentObjectId = container.identity?.objectId
        }
        do {
            communicationManager.publishAdvertise(try AdvertiseEvent.with(object: object))
        } catch {
            log.error("Failed to advertise discoverable object", metadata: [
                "objectId": .string(object.objectId.string),
                "objectType": .string(object.objectType),
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
        }
    }

    /// Readvertises an object after one or more of its properties changed.
    ///
    /// This is a best-effort publication: an invalid object type or a transport
    /// failure prevents the readvertisement, but the loss is surfaced as a
    /// structured log line (with ``AxolotyError``) instead of being silently
    /// swallowed.
    public func readvertiseDiscoverableObject(object: CoatyObject) {
        do {
            communicationManager.publishAdvertise(try AdvertiseEvent.with(object: object))
        } catch {
            log.error("Failed to readvertise discoverable object", metadata: [
                "objectId": .string(object.objectId.string),
                "objectType": .string(object.objectType),
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
        }
    }

    /// Publishes a deadvertisement for an object.
    public func deadvertiseDiscoverableObject(object: CoatyObject) {
        communicationManager.publishDeadvertise(
            DeadvertiseEvent.with(objectIds: [object.objectId])
        )
    }
}
