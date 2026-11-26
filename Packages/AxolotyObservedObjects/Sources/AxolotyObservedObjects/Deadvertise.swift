// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// Visits UUIDs in a Deadvertise payload and leaves opaque identifiers alone.
func visitDeadvertisedIDs(
    in payload: [UInt8],
    profile: WireProfile,
    _ visit: (UUID16) -> Void
) throws(WireDecodeError) {
    guard payload.count <= WireBufferConfig.maxPayloadSize else {
        throw WireDecodeError(.payloadExceedsLimit)
    }
    try payload.withUnsafeBufferPointer { buffer throws(WireDecodeError) in
        guard let base = buffer.baseAddress else { throw WireDecodeError(.missingField, field: "objectIds") }
        let reader = WireCodec(profile: profile).reader(bytes: base, length: buffer.count)
        try reader.validate()
        guard let ids = reader.readField("objectIds") else {
            throw WireDecodeError(.missingField, field: "objectIds")
        }
        switch profile {
        case .coaty3JSON:
            var invalidElement = false
            try ids.withArrayElements { element in
                guard element.wireValueKind == .string, element.length > 2 else {
                    invalidElement = true
                    return
                }
                let text = element.subSlice(from: 1, length: element.length - 2)
                if let id = UUID16(parsing: text) { visit(id) }
            }
            guard !invalidElement else {
                throw WireDecodeError(.typeMismatch(expected: "non-empty string"), field: "objectIds")
            }
        case .axoloty1CBOR:
            let outcome = ids.withBytes { pointer, count -> Result<Void, WireDecodeError> in
                var cursor = CBORReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
                do throws(WireDecodeError) {
                    let elementCount = try cursor.readArrayHeader()
                    for _ in 0..<elementCount {
                        if let first = ids.byte(at: cursor.offset), first >> 5 == 3 {
                            let text = try cursor.readTextString()
                            guard text.length > 0 else {
                                throw WireDecodeError(.typeMismatch(expected: "non-empty string"), field: "objectIds")
                            }
                            if let id = UUID16(parsing: text) { visit(id) }
                        } else {
                            visit(try cursor.readUUID())
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            try outcome.get()
        }
    }
}
