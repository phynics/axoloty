// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A structured, allocation-free decode error for the wire codec.
///
/// Designed for typed throws under Embedded Swift. Carries a machine-readable
/// reason, the byte offset where decoding failed, and an optional field name
/// (as a StaticString, so no allocation).
public struct WireDecodeError: Error, Sendable {
    public let reason: Reason
    public let byteOffset: Int
    public let field: StaticString?

    public enum Reason: Sendable {
        case unexpectedToken(expected: StaticString, actual: UInt8?)
        case missingField
        case typeMismatch(expected: StaticString)
        case invalidUTF8
        case unexpectedEndOfInput
        case malformedUUID
        case malformedTopic
        case integerOverflow
    }

    public init(_ reason: Reason, byteOffset: Int = 0, field: StaticString? = nil) {
        self.reason = reason
        self.byteOffset = byteOffset
        self.field = field
    }
}
