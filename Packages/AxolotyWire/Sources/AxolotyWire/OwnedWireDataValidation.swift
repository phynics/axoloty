// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The shared bound for one owned raw field, in bytes.
///
/// An owned raw field is one complete encoded object, array, or value. The
/// wire payload that carries it is bounded by
/// ``WireBufferConfig/maxPayloadSize``, so a raw field larger than that can
/// never fit a wire frame and validation rejects it up front. Validation is
/// necessary but not sufficient for encodability: the enclosing event adds
/// its own keys and structure, and only the encoder knows whether the complete
/// event fits. ``WireEncodeError/bufferOverflow`` remains the authoritative
/// rejection when an accepted field does not fit its writer.
private let maxOwnedRawValueSize = WireBufferConfig.maxPayloadSize

/// The semantic shape an owned raw field must have in its profile encoding.
enum OwnedValueShape {
    /// Any single value accepted by the profile.
    case any
    /// A map or object.
    case object
    /// An array.
    case array
    /// A map/object or an array.
    case objectOrArray
    /// Plain string content without the enclosing quotes or a CBOR text-string
    /// head. JSON content carries escapes; CBOR content is raw UTF-8.
    case textContent
}

#if canImport(_JSONCore)
private func invalidOwnedJSON(field: StaticString) -> WireDecodeError {
    WireDecodeError(.unexpectedToken(expected: "valid JSON value", actual: nil), field: field)
}

private func validateOwnedJSONSyntax(
    _ bytes: [UInt8],
    field: StaticString
) throws(WireDecodeError) {
    guard !bytes.isEmpty else {
        throw WireDecodeError(.unexpectedEndOfInput, field: field)
    }

    guard bytes.count <= maxOwnedRawValueSize else {
        throw WireDecodeError(.payloadExceedsLimit, byteOffset: bytes.count, field: field)
    }

    let isValid = bytes.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        return WireReader.isValidJSONValue(ByteSlice(bytes: base, length: buffer.count))
    }
    guard !isValid else { return }

    let validationFailure = bytes.withUnsafeBufferPointer { buffer -> WireDecodeError? in
        guard let base = buffer.baseAddress else { return WireDecodeError(.unexpectedEndOfInput, field: field) }
        let reader = WireReader(bytes: base, length: buffer.count)
        if let failure = reader.index.failure {
            return WireDecodeError(failure.reason, byteOffset: failure.byteOffset, field: field)
        }
        guard reader.index.rootObject else { return WireDecodeError(.typeMismatch(expected: "object"), field: field) }
        return nil
    }
    if let validationFailure { throw validationFailure }
    throw invalidOwnedJSON(field: field)
}

/// Validates one owned raw field encoded as `coaty/3` JSON.
///
/// - Parameters:
///   - bytes: The complete JSON value, or JSON string content for
///     ``OwnedValueShape/textContent``.
///   - field: The field name reported in a thrown error.
///   - shape: The required top-level shape.
/// - Throws: ``WireDecodeError`` when `bytes` is malformed or has the wrong
///   shape.
func validateOwnedJSON(
    _ bytes: [UInt8],
    field: StaticString,
    shape: OwnedValueShape = .any
) throws(WireDecodeError) {
    if case .textContent = shape {
        guard bytes.count <= maxOwnedRawValueSize - 2 else {
            throw WireDecodeError(.payloadExceedsLimit, byteOffset: bytes.count + 2, field: field)
        }
        var quoted = [UInt8]()
        quoted.reserveCapacity(bytes.count + 2)
        quoted.append(0x22)
        quoted.append(contentsOf: bytes)
        quoted.append(0x22)
        try validateOwnedJSON(quoted, field: field)
        return
    }

    try validateOwnedJSONSyntax(bytes, field: field)
    guard let first = bytes.first(where: { !isJSONWhitespace($0) }) else {
        throw WireDecodeError(.unexpectedEndOfInput, field: field)
    }
    switch shape {
    case .any, .textContent:
        return
    case .object:
        guard first == 0x7B else {
            throw WireDecodeError(.typeMismatch(expected: "object"), field: field)
        }
    case .array:
        guard first == 0x5B else {
            throw WireDecodeError(.typeMismatch(expected: "array"), field: field)
        }
    case .objectOrArray:
        guard first == 0x7B || first == 0x5B else {
            throw WireDecodeError(.typeMismatch(expected: "object or array"), field: field)
        }
    }
}

private func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}
#else
@inline(__always)
private func ownedValidationUnavailable(field: StaticString) -> WireDecodeError {
    WireDecodeError(.invalidValue, field: field)
}

/// Rejects owned JSON validation because the JSON engine is not linked.
private func validateOwnedJSON(
    _ bytes: [UInt8],
    field: StaticString,
    shape: OwnedValueShape = .any
) throws(WireDecodeError) {
    _ = bytes
    _ = shape
    throw ownedValidationUnavailable(field: field)
}
#endif

/// Validates one owned raw field encoded as `axoloty/1` CBOR.
///
/// A `textContent` field carries plain UTF-8 string content; every other shape
/// carries exactly one complete CBOR item accepted by the `axoloty/1` reader.
/// Ascending map-key order is a writer rule, not a reader rule, so a retained
/// raw field keeps a peer's key order unchanged.
private func validateOwnedCBOR(
    _ bytes: [UInt8],
    field: StaticString,
    shape: OwnedValueShape
) throws(WireDecodeError) {
    guard bytes.count <= maxOwnedRawValueSize else {
        throw WireDecodeError(.payloadExceedsLimit, byteOffset: bytes.count, field: field)
    }

    // String content is not a complete item and may be empty. The profile's
    // string head is regenerated on encode.
    if case .textContent = shape {
        let isValidUTF8 = bytes.withUnsafeBufferPointer { buffer -> Bool in
            guard buffer.count > 0 else { return true }
            guard let base = buffer.baseAddress else { return false }
            return ByteSlice(bytes: base, length: buffer.count).isValidUTF8()
        }
        guard isValidUTF8 else {
            throw WireDecodeError(.invalidUTF8, field: field)
        }
        return
    }

    guard !bytes.isEmpty else {
        throw WireDecodeError(.unexpectedEndOfInput, field: field)
    }

    // A CBOR item starts with its initial byte; no leading whitespace exists.
    let majorType = bytes[0] >> 5
    switch shape {
    case .object where majorType != 5:
        throw WireDecodeError(.typeMismatch(expected: "object"), field: field)
    case .array where majorType != 4:
        throw WireDecodeError(.typeMismatch(expected: "array"), field: field)
    case .objectOrArray where majorType != 4 && majorType != 5:
        throw WireDecodeError(.typeMismatch(expected: "object or array"), field: field)
    default:
        break
    }

    let failure = bytes.withUnsafeBufferPointer { buffer -> WireDecodeError? in
        guard let base = buffer.baseAddress else {
            return WireDecodeError(.unexpectedEndOfInput, field: field)
        }
        var reader = CBORReader(
            bytes: base,
            length: buffer.count,
            maximumStringLength: maxOwnedRawValueSize
        )
        do throws(WireDecodeError) {
            try reader.skipItem()
        } catch {
            return error
        }
        guard reader.isAtEnd else {
            return WireDecodeError(
                .unexpectedToken(expected: "one complete CBOR item", actual: base[reader.offset]),
                byteOffset: reader.offset,
                field: field
            )
        }
        return nil
    }
    if let failure { throw failure }
}

/// Validates one owned raw field against the profile that produced it.
///
/// The CBOR path is always available because it does not need the JSON engine.
/// Without `_JSONCore`, a `coaty/3` field cannot be validated and is rejected.
///
/// - Parameters:
///   - bytes: The owned raw bytes.
///   - profile: The profile whose encoding `bytes` must carry.
///   - field: The field name reported in a thrown error.
///   - shape: The required top-level shape.
/// - Throws: ``WireDecodeError`` when `bytes` is malformed, has the wrong
///   shape, or is not a legal value of `profile`.
func validateOwnedValue(
    _ bytes: [UInt8],
    profile: WireProfile,
    field: StaticString,
    shape: OwnedValueShape = .any
) throws(WireDecodeError) {
    switch profile {
    case .coaty3JSON:
        try validateOwnedJSON(bytes, field: field, shape: shape)
    case .axoloty1CBOR:
        try validateOwnedCBOR(bytes, field: field, shape: shape)
    }
}

/// Validates an optional owned raw field against `profile` when present.
///
/// - Parameters:
///   - bytes: The optional owned raw bytes.
///   - profile: The profile whose encoding `bytes` must carry.
///   - field: The field name reported in a thrown error.
///   - shape: The required top-level shape.
/// - Throws: ``WireDecodeError`` when a present value is malformed, has the
///   wrong shape, or is not a legal value of `profile`.
func validateOptionalOwnedValue(
    _ bytes: [UInt8]?,
    profile: WireProfile,
    field: StaticString,
    shape: OwnedValueShape = .any
) throws(WireDecodeError) {
    if let bytes {
        try validateOwnedValue(bytes, profile: profile, field: field, shape: shape)
    }
}
