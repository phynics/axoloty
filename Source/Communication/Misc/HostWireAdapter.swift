// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import ErrorKit
import Foundation
import IkigaJSON

/// Host-only conversion between AxolotyWire's raw object fragments and the
/// registered Axoloty object model.
///
/// Runtime registration and class hydration deliberately live here rather
/// than in AxolotyWire. Unknown object types fall back to their declared core
/// class, whose `custom` dictionary retains fields outside the core schema.
enum HostWireAdapter {
    /// Hydrates a registered, core, or unknown Coaty object from owned JSON bytes.
    static func decodeObject(from bytes: [UInt8]) throws -> CoatyObject {
        do {
            let object = try JSONObject(data: Data(bytes))
            var settings = JSONDecoderSettings()
            settings.userInfo[CodingUserInfoKey(rawValue: "coreTypeKeys")!] = DecodingContextStack()
            settings.userInfo[CodingUserInfoKey(rawValue: "rawJSONObject")!] = RawJSONObjectContext(root: object)
            return try IkigaJSONDecoder(settings: settings)
                .decode(AnyCoatyObjectDecodable.self, from: object).object
        } catch {
            throw AxolotyError.decodingFailure(
                type: "CoatyObject",
                reason: ErrorKit.userFriendlyMessage(for: error),
                payload: String(bytes: bytes, encoding: .utf8)
            )
        }
    }

    /// Creates a value snapshot while retaining the exact custom-field payload.
    static func snapshot(from bytes: [UInt8]) throws -> CoatyObjectSnapshot {
        let object = try decodeObject(from: bytes)
        return CoatyObjectSnapshot(
            objectId: object.objectId.string,
            coreType: object.coreType,
            objectType: object.objectType,
            name: object.name,
            externalId: object.externalId,
            parentObjectId: object.parentObjectId?.string,
            locationId: object.locationId?.string,
            isDeactivated: object.isDeactivated,
            payload: String(bytes: bytes, encoding: .utf8)
        )
    }

    /// Creates snapshots for a raw JSON array of Coaty objects.
    static func snapshots(from bytes: [UInt8]) throws -> [CoatyObjectSnapshot] {
        try bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return [] }
            let slice = ByteSlice(bytes: base, length: buffer.count)
            guard let elements = WirePayloadExtractor.arrayElements(from: slice) else { return [] }
            return try elements.map { try snapshot(from: Array($0.utf8)) }
        }
    }
}
