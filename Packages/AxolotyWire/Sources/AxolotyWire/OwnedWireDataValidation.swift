// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

private let maxOwnedJSONSize = 16 * 1_024 * 1_024

private struct JSONValidationDestination: JSONTokenizerDestination {
    typealias ArrayStartContext = UInt8
    typealias ObjectStartContext = UInt8

    mutating func arrayStartFound(_ start: JSONToken.ArrayStart) -> UInt8 { 0 }
    mutating func arrayEndFound(_ end: JSONToken.ArrayEnd, context: consuming UInt8) {}
    mutating func objectStartFound(_ start: JSONToken.ObjectStart) -> UInt8 { 0 }
    mutating func objectEndFound(_ end: JSONToken.ObjectEnd, context: consuming UInt8) {}
    mutating func booleanTrueFound(_ boolean: JSONToken.BooleanTrue) {}
    mutating func booleanFalseFound(_ boolean: JSONToken.BooleanFalse) {}
    mutating func nullFound(_ null: JSONToken.Null) {}
    mutating func stringFound(_ string: JSONToken.String) {}
    mutating func numberFound(_ number: JSONToken.Number) {}
}

enum OwnedJSONShape {
    case any
    case object
    case array
    case objectOrArray
    case encodedString
}

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

    guard bytes.count <= maxOwnedJSONSize else {
        throw WireDecodeError(.payloadExceedsLimit, byteOffset: bytes.count, field: field)
    }

    if bytes.count > WireBufferConfig.maxPayloadSize {
        try validateLargeOwnedJSONSyntax(bytes, field: field)
        return
    }

    let isValid = bytes.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        return WireReader.isValidJSONValue(ByteSlice(bytes: base, length: buffer.count))
    }
    guard !isValid else { return }

    try bytes.withUnsafeBufferPointer { buffer throws(WireDecodeError) in
        guard let base = buffer.baseAddress else {
            throw WireDecodeError(.unexpectedEndOfInput, field: field)
        }
        let reader = WireReader(bytes: base, length: buffer.count)
        do {
            try reader.validate()
        } catch {
            guard let failure = error as? WireDecodeError else {
                throw invalidOwnedJSON(field: field)
            }
            throw WireDecodeError(failure.reason, byteOffset: failure.byteOffset, field: field)
        }
        throw invalidOwnedJSON(field: field)
    }
}

private func validateLargeOwnedJSONSyntax(
    _ bytes: [UInt8],
    field: StaticString
) throws(WireDecodeError) {
    var padded = bytes
    padded.append(contentsOf: repeatElement(0x7D, count: 8))
    let result = padded.withUnsafeBufferPointer { buffer -> (valid: Bool, offset: Int) in
        var tokenizer = JSONTokenizer(
            bytes: buffer,
            destination: JSONValidationDestination()
        )
        do {
            try tokenizer.scanValue()
        } catch {
            return (false, tokenizer.currentOffset)
        }

        var offset = tokenizer.currentOffset
        while offset < bytes.count && isJSONWhitespace(bytes[offset]) {
            offset += 1
        }
        return (offset == bytes.count, offset)
    }
    guard result.valid else {
        if result.offset >= bytes.count {
            throw WireDecodeError(.unexpectedEndOfInput, byteOffset: bytes.count, field: field)
        }
        throw WireDecodeError(
            .unexpectedToken(expected: "valid JSON value", actual: bytes[result.offset]),
            byteOffset: result.offset,
            field: field
        )
    }
}

func validateOwnedJSON(
    _ bytes: [UInt8],
    field: StaticString,
    shape: OwnedJSONShape = .any
) throws(WireDecodeError) {
    if case .encodedString = shape {
        guard bytes.count <= maxOwnedJSONSize - 2 else {
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
    case .any, .encodedString:
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

func validateOptionalOwnedJSON(
    _ bytes: [UInt8]?,
    field: StaticString,
    shape: OwnedJSONShape
) throws(WireDecodeError) {
    if let bytes {
        try validateOwnedJSON(bytes, field: field, shape: shape)
    }
}

func validateOptionalEncodedString(
    _ bytes: [UInt8]?,
    field: StaticString
) throws(WireDecodeError) {
    if let bytes {
        try validateOwnedJSON(bytes, field: field, shape: .encodedString)
    }
}

private func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}
