// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The closed capability inventory of the Coaty Core Profile 3.
///
/// The raw values are stable profile ordinals, not wire event codes. Use
/// ``wireEventType`` when a binding needs the three-byte Coaty event code.
public enum ProtocolCapability: UInt8, Sendable, Equatable, Hashable {
    /// Advertise (`ADV`).
    case advertise = 0
    /// Deadvertise (`DAD`).
    case deadvertise
    /// Channel (`CHN`).
    case channel
    /// Associate (`ASC`).
    case associate
    /// IoValue (`IOV`).
    case ioValue
    /// Discover (`DSC`).
    case discover
    /// Resolve (`RSV`).
    case resolve
    /// Query (`QRY`).
    case query
    /// Retrieve (`RTV`).
    case retrieve
    /// Update (`UPD`).
    case update
    /// Complete (`CPL`).
    case complete
    /// Call (`CLL`).
    case call
    /// Return (`RTN`).
    case returnEvent

    /// The corresponding profile-neutral wire event.
    public var wireEventType: WireEventType {
        switch self {
        case .advertise: return .advertise
        case .deadvertise: return .deadvertise
        case .channel: return .channel
        case .associate: return .associate
        case .ioValue: return .ioValue
        case .discover: return .discover
        case .resolve: return .resolve
        case .query: return .query
        case .retrieve: return .retrieve
        case .update: return .update
        case .complete: return .complete
        case .call: return .call
        case .returnEvent: return .returnEvent
        }
    }

    /// Creates a capability from a recognized wire event.
    public init?(wireEventType: WireEventType) {
        switch wireEventType {
        case .advertise: self = .advertise
        case .deadvertise: self = .deadvertise
        case .channel: self = .channel
        case .associate: self = .associate
        case .ioValue: self = .ioValue
        case .discover: self = .discover
        case .resolve: self = .resolve
        case .query: self = .query
        case .retrieve: self = .retrieve
        case .update: self = .update
        case .complete: self = .complete
        case .call: self = .call
        case .returnEvent: self = .returnEvent
        }
    }

    /// Whether the event is fire-and-forget and therefore has no correlation
    /// level in a Coaty topic.
    public var isOneWay: Bool {
        wireEventType.isOneWay
    }
}

/// A fixed-width capability set suitable for both host and Embedded Swift.
///
/// The thirteen-bit profile inventory fits in a `UInt16`; no collection or
/// dynamic registry is required to answer membership queries.
public struct ProtocolCapabilities: Sendable, Equatable {
    private let bits: UInt16

    private init(uncheckedRawValue: UInt16) {
        self.bits = uncheckedRawValue
    }

    /// Creates a capability set from its encoded bitset.
    ///
    /// - Parameter rawValue: Only the low 13 bits are meaningful. Higher bits
    ///   are rejected so a future capability cannot silently enter Coaty/3.
    /// - Throws: ``ProtocolError`` when an unknown capability bit is set.
    public init(rawValue: UInt16) throws(ProtocolError) {
        guard rawValue & ~Self.knownMask == 0 else {
            throw ProtocolError(.unsupportedCapability, detail: rawValue)
        }
        self.bits = rawValue
    }

    /// Creates a capability set containing the supplied profile capabilities.
    public init(_ capabilities: ProtocolCapability...) {
        var bits: UInt16 = 0
        for capability in capabilities {
            bits |= Self.bit(for: capability)
        }
        self.bits = bits
    }

    /// The encoded capability bitset.
    public var rawValue: UInt16 { bits }

    /// Returns whether the set contains `capability`.
    public func contains(_ capability: ProtocolCapability) -> Bool {
        bits & Self.bit(for: capability) != 0
    }

    /// Returns whether all sealed Coaty Core Profile 3 capabilities are set.
    public var isCoatyCore3: Bool { bits == Self.knownMask }

    /// The complete, sealed Coaty Core Profile 3 capability set.
    public static let coatyCore3 = ProtocolCapabilities(uncheckedRawValue: Self.knownMask)

    /// Number of capabilities in the sealed profile.
    public static let coatyCore3Count = 13

    private static let knownMask: UInt16 = (1 << coatyCore3Count) - 1

    @inline(__always)
    private static func bit(for capability: ProtocolCapability) -> UInt16 {
        UInt16(1) << UInt16(capability.rawValue)
    }
}

/// The immutable identity of the Coaty Core Profile 3.
public enum CoatyCore3Profile {
    /// The Coaty protocol namespace.
    public static let namespace = "coaty"
    /// The sealed major profile version.
    public static let version: UInt8 = 3
    /// The canonical profile identifier used in diagnostics and manifests.
    public static let identifier = "coaty/3"
    /// The complete capability set.
    public static let capabilities = ProtocolCapabilities.coatyCore3
    /// The number of capabilities in the closed profile.
    public static let capabilityCount = ProtocolCapabilities.coatyCore3Count

}
