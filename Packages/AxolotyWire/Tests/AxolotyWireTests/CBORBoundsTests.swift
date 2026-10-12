// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyWire
import Testing

/// Malformed-input, truncation, and nesting-bound tests for the deterministic
/// CBOR reader (`axoloty/1`, epic #977).
///
/// Each case asserts a structured ``WireDecodeError`` reason rather than a
/// trap or an out-of-bounds read.

// MARK: - Reason classification

private enum ReasonTag: Equatable {
    case unexpectedEndOfInput
    case cborIndefiniteLength
    case cborInvalidAdditionalInfo
    case cborNonMinimalInteger
    case cborUnexpectedMajorType
    case cborUnsupportedTag
    case cborDuplicateMapKey
    case cborNestingTooDeep
    case cborUnsupportedSimpleValue
    case invalidUTF8
    case integerOverflow
    case malformedUUID
    case other
}

private func tag(_ reason: WireDecodeError.Reason) -> ReasonTag {
    switch reason {
    case .unexpectedEndOfInput: return .unexpectedEndOfInput
    case .cborIndefiniteLength: return .cborIndefiniteLength
    case .cborInvalidAdditionalInfo: return .cborInvalidAdditionalInfo
    case .cborNonMinimalInteger: return .cborNonMinimalInteger
    case .cborUnexpectedMajorType: return .cborUnexpectedMajorType
    case .cborUnsupportedTag: return .cborUnsupportedTag
    case .cborDuplicateMapKey: return .cborDuplicateMapKey
    case .cborNestingTooDeep: return .cborNestingTooDeep
    case .cborUnsupportedSimpleValue: return .cborUnsupportedSimpleValue
    case .invalidUTF8: return .invalidUTF8
    case .integerOverflow: return .integerOverflow
    case .malformedUUID: return .malformedUUID
    default: return .other
    }
}

private func skipReason(_ bytes: [UInt8]) -> ReasonTag? {
    bytes.withUnsafeBufferPointer { buffer in
        var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
        do {
            try reader.skipItem()
            return nil
        } catch let error as WireDecodeError {
            return tag(error.reason)
        } catch {
            return .other
        }
    }
}

// MARK: - Bounds

@Suite
struct CBORBoundsTests {
    @Test
    func indefiniteLengthItemsAreRejected() {
        // Indefinite-length byte string, text string, array, map, and break.
        #expect(skipReason([0x5F, 0x41, 0x00, 0xFF]) == .cborIndefiniteLength)
        #expect(skipReason([0x7F, 0x61, 0x61, 0xFF]) == .cborIndefiniteLength)
        #expect(skipReason([0x9F, 0x00, 0xFF]) == .cborIndefiniteLength)
        #expect(skipReason([0xBF, 0x00, 0x00, 0xFF]) == .cborIndefiniteLength)
        #expect(skipReason([0xFF]) == .cborIndefiniteLength)
    }

    @Test
    func nonMinimalIntegersAreRejected() {
        #expect(skipReason([0x18, 0x00]) == .cborNonMinimalInteger)
        #expect(skipReason([0x18, 0x17]) == .cborNonMinimalInteger)
        #expect(skipReason([0x19, 0x00, 0xFF]) == .cborNonMinimalInteger)
        #expect(skipReason([0x1A, 0x00, 0x00, 0xFF, 0xFF]) == .cborNonMinimalInteger)
        #expect(
            skipReason([0x1B, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
                == .cborNonMinimalInteger
        )
    }

    @Test
    func reservedAdditionalInfoIsRejected() {
        #expect(skipReason([0x1C]) == .cborInvalidAdditionalInfo)
        #expect(skipReason([0x1D]) == .cborInvalidAdditionalInfo)
        #expect(skipReason([0x1E]) == .cborInvalidAdditionalInfo)
    }

    @Test
    func truncatedItemsAreRejected() {
        #expect(skipReason([0x18]) == .unexpectedEndOfInput)
        #expect(skipReason([0x19, 0x03]) == .unexpectedEndOfInput)
        #expect(skipReason([0x5A, 0x00, 0x01, 0x00, 0x00]) == .unexpectedEndOfInput)
        #expect(skipReason([0x44, 0x01, 0x02]) == .unexpectedEndOfInput)
        #expect(skipReason([0x83, 0x01, 0x02]) == .unexpectedEndOfInput)
        #expect(skipReason([0x82, 0x61, 0x61]) == .unexpectedEndOfInput)
    }

    @Test
    func undefinedSimpleValueIsRejected() {
        #expect(skipReason([0xF7]) == .cborUnsupportedSimpleValue)
    }

    @Test
    func nonPreferredSimpleValueExtensionIsRejected() {
        // 0xF8 0x00 encodes simple value 0 in the extended form; the direct
        // form 0xE0 is required.
        #expect(skipReason([0xF8, 0x00]) == .cborNonMinimalInteger)
        // 0xF8 0x18 is simple value 24, which is a valid extended form.
        #expect(skipReason([0xF8, 0x18]) == nil)
    }

    @Test
    func nestingBeyondTheBoundIsRejected() {
        var bytes: [UInt8] = Array(repeating: 0x81, count: 40)
        bytes.append(0x00)
        #expect(skipReason(bytes) == .cborNestingTooDeep)

        // A shallow tree within the bound still skips cleanly.
        var shallow: [UInt8] = Array(repeating: 0x81, count: 8)
        shallow.append(0x00)
        #expect(skipReason(shallow) == nil)
    }

    @Test
    func unsupportedTagsAreRejected() {
        #expect(skipReason([0xC2, 0x42, 0x01, 0x00]) == .cborUnsupportedTag)
        #expect(skipReason([0xD8, 0x64, 0x00]) == .cborUnsupportedTag)
    }

    @Test
    func duplicateMapKeysAreRejected() {
        // { "a": 1, "a": 2 }
        #expect(skipReason([0xA2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02]) == .cborDuplicateMapKey)
        // { 1: "x", 1: "y" }
        #expect(skipReason([0xA2, 0x01, 0x61, 0x78, 0x01, 0x61, 0x79]) == .cborDuplicateMapKey)
        // { "a": 1, "b": 2 } is distinct and accepted.
        #expect(skipReason([0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02]) == nil)
    }

    @Test
    func invalidUTF8TextStringsAreRejected() {
        #expect(skipReason([0x61, 0xFF]) == .invalidUTF8)
        // An overlong two-byte encoding of NUL is invalid.
        #expect(skipReason([0x62, 0xC0, 0x80]) == .invalidUTF8)
        // A lone continuation byte is invalid.
        #expect(skipReason([0x61, 0x80]) == .invalidUTF8)
        // A valid two-byte sequence is accepted.
        #expect(skipReason([0x62, 0xC3, 0xBC]) == nil)
    }

    @Test
    func stringLengthLimitIsEnforced() throws {
        // 0x65 is a five-byte text string; the reader is limited to four.
        let content: [UInt8] = [0x65, 0x61, 0x61, 0x61, 0x61, 0x61]
        try content.withUnsafeBufferPointer { buffer in
            var reader = CBORReader(
                bytes: buffer.baseAddress!,
                length: buffer.count,
                maximumStringLength: 4
            )
            #expect(throws: WireDecodeError.self) {
                _ = try reader.readTextString()
            }
        }
    }

    @Test
    func readUUIDRejectsWrongTagAndLength() throws {
        // Tag 1 followed by a byte string is not a UUID.
        try [UInt8]([0xC1, 0x50]).withUnsafeBufferPointer { buffer in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(throws: WireDecodeError.self) {
                _ = try reader.readUUID()
            }
        }
        // Tag 37 followed by a non-16-byte string is not a UUID.
        try [UInt8]([0xD8, 0x25, 0x41, 0x00]).withUnsafeBufferPointer { buffer in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(throws: WireDecodeError.self) {
                _ = try reader.readUUID()
            }
        }
    }

    @Test
    func emptyInputIsRejected() {
        var dummy: UInt8 = 0
        withUnsafePointer(to: &dummy) { pointer in
            var reader = CBORReader(bytes: pointer, length: 0)
            #expect(throws: WireDecodeError.self) {
                try reader.skipItem()
            }
        }
    }
}
