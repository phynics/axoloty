// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A structured, allocation-free decode error for the wire codec.
///
/// Designed for typed throws under Embedded Swift. Carries a machine-readable
/// reason, the byte offset where decoding failed, and an optional field name
/// (as a StaticString, so no allocation).
public struct WireDecodeError: Error, Sendable {
    /// The machine-readable failure reason.
    public let reason: Reason
    /// The byte offset in the input where decoding failed.
    public let byteOffset: Int
    /// The name of the field being decoded when the failure occurred, if any.
    public let field: StaticString?

    /// The categorized cause of a decode failure.
    public enum Reason: Sendable {
        /// An unexpected byte was encountered at the current position.
        case unexpectedToken(expected: StaticString, actual: UInt8?)
        /// A required field was absent from the JSON object.
        case missingField
        /// A field's value did not match the expected type.
        case typeMismatch(expected: StaticString)
        /// The input contained invalid UTF-8.
        case invalidUTF8
        /// The input ended before decoding completed.
        case unexpectedEndOfInput
        /// A UUID field did not parse as a valid 36-byte hyphenated string.
        case malformedUUID
        /// The topic did not parse as a valid Coaty topic.
        case malformedTopic
        /// An integer field's value overflowed the target `Int` width.
        case integerOverflow
    }

    /// Creates a decode error.
    ///
    /// - Parameters:
    ///   - reason: The categorized failure reason.
    ///   - byteOffset: The byte offset where decoding failed. Defaults to 0.
    ///   - field: The field name being decoded, if applicable.
    public init(_ reason: Reason, byteOffset: Int = 0, field: StaticString? = nil) {
        self.reason = reason
        self.byteOffset = byteOffset
        self.field = field
    }
}
