// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire

/// Encodes the lifecycle payloads emitted by the host runtime.
///
/// The `coaty/3` builders keep their exact JSON bytes. When the transport is
/// bound to `axoloty/1`, ``RuntimeWirePayload`` re-encodes the same value as
/// CBOR.
enum RuntimeLifecyclePayload {
    /// Encodes an advertise payload for `profile`.
    ///
    /// - Parameters:
    ///   - identity: The runtime identity to advertise.
    ///   - profile: The bound transport profile.
    /// - Returns: The advertise payload bytes.
    /// - Throws: ``ProtocolError`` when the payload cannot be built.
    static func advertise(
        _ identity: RuntimeIdentity,
        profile: WireProfile = .coaty3JSON
    ) throws(ProtocolError) -> [UInt8] {
        let object: [String: Any] = [
            "objectId": CoatyRoute.uuidString(identity.id),
            "coreType": "Identity",
            "objectType": "coaty.Identity",
            "name": identity.name
        ]
        guard let json = try? JSONSerialization.data(
            withJSONObject: ["object": object],
            options: [.sortedKeys]
        ) else {
            throw ProtocolError(.malformedPayload)
        }
        return try RuntimeWirePayload.encode(json: Array(json), profile: profile)
    }

    /// Encodes a deadvertise payload for one identity.
    ///
    /// - Parameters:
    ///   - identity: The identity to deadvertise.
    ///   - profile: The bound transport profile.
    /// - Returns: The deadvertise payload bytes.
    /// - Throws: ``ProtocolError`` when the CBOR form does not fit.
    static func deadvertise(
        _ identity: RuntimeIdentity,
        profile: WireProfile = .coaty3JSON
    ) throws(ProtocolError) -> [UInt8] {
        try deadvertise(uuid: CoatyRoute.uuidString(identity.id), profile: profile)
    }

    /// Encodes a deadvertise payload for one object identifier.
    ///
    /// - Parameters:
    ///   - objectID: The object identifier to deadvertise.
    ///   - profile: The bound transport profile.
    /// - Returns: The deadvertise payload bytes.
    /// - Throws: ``ProtocolError`` when the CBOR form does not fit.
    static func deadvertise(
        objectID: ObjectID,
        profile: WireProfile = .coaty3JSON
    ) throws(ProtocolError) -> [UInt8] {
        try deadvertise(uuid: CoatyRoute.uuidString(objectID.uuid), profile: profile)
    }

    private static func deadvertise(uuid: String, profile: WireProfile) throws(ProtocolError) -> [UInt8] {
        let json = Array("{\"objectIds\":[\"\(uuid)\"]}".utf8)
        return try RuntimeWirePayload.encode(json: json, profile: profile)
    }
}
