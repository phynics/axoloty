// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyObjectModel
import AxolotyWire

/// Encodes the lifecycle payloads emitted by the host runtime.
enum RuntimeLifecyclePayload {
    static func advertise(_ identity: RuntimeIdentity) throws -> [UInt8] {
        let object: [String: Any] = [
            "objectId": CoatyRoute.uuidString(identity.id),
            "coreType": "Identity",
            "objectType": "coaty.Identity",
            "name": identity.name
        ]
        return try JSONSerialization.data(withJSONObject: ["object": object], options: [.sortedKeys]).map { $0 }
    }

    static func deadvertise(_ identity: RuntimeIdentity) -> [UInt8] {
        Array("{\"objectIds\":[\"\(CoatyRoute.uuidString(identity.id))\"]}".utf8)
    }

    static func deadvertise(objectID: ObjectID) -> [UInt8] {
        Array("{\"objectIds\":[\"\(CoatyRoute.uuidString(objectID.uuid))\"]}".utf8)
    }
}
