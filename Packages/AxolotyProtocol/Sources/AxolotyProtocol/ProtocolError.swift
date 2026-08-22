// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Structured, Foundation-free failures at the portable protocol boundary.
public struct ProtocolError: Error, Sendable, Equatable {
    /// Stable machine-readable protocol failure categories.
    public enum Code: UInt8, Sendable, Equatable {
        /// The frame or routing key is malformed.
        case malformedFrame = 1
        /// A frame names a capability outside the sealed profile.
        case unsupportedCapability = 2
        /// A one-way event carried a correlation key or vice versa.
        case invalidCorrelation = 3
        /// The caller attempted to cross the borrowed-value lifetime boundary.
        case borrowedValueEscaped = 4
        /// An action or frame exceeds a bounded portable capacity.
        case capacityExceeded = 5
        /// The operation repeats an already-consumed correlation or association.
        case duplicate = 6
        /// The caller supplied a time after the protocol deadline.
        case deadlineExpired = 7
        /// A response correlation does not match the pending request.
        case correlationMismatch = 8
        /// An external-route flag disagrees with binding classification.
        case externalRouteMismatch = 9
        /// The payload is syntactically valid JSON but not valid for its family.
        case malformedPayload = 10
    }

    /// The stable failure category.
    public let code: Code
    /// A compact numeric context owned by the caller (length, bitset, or
    /// capacity). It is deliberately not a formatted string.
    public let detail: UInt16

    /// Creates a structured protocol error.
    public init(_ code: Code, detail: UInt16 = 0) {
        self.code = code
        self.detail = detail
    }
}
