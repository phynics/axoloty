// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// Encodes the lifecycle payloads emitted by the host runtime.
enum RuntimeLifecyclePayload {
    static func advertise(_ identity: RuntimeIdentity) throws -> [UInt8] {
        let object: [String: Any] = [
            "objectId": uuidString(identity.id),
            "coreType": "Identity",
            "objectType": "coaty.Identity",
            "name": identity.name
        ]
        return try JSONSerialization.data(withJSONObject: ["object": object], options: [.sortedKeys]).map { $0 }
    }

    static func deadvertise(_ identity: RuntimeIdentity) -> [UInt8] {
        Array("{\"objectIds\":[\"\(uuidString(identity.id))\"]}".utf8)
    }

    private static func uuidString(_ value: UUID16) -> String {
        let bytes = value.bytes
        let raw: [UInt8] = [
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15
        ]
        let hex = raw.map { String(format: "%02x", $0) }
        return "\(hex[0...3].joined())-\(hex[4...5].joined())-\(hex[6...7].joined())-\(hex[8...9].joined())-\(hex[10...15].joined())"
    }
}
