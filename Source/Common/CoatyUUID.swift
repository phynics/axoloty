//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CoatyUUID.swift
//  Axoloty
//
//

import Foundation

/// Custom implementation of a UUID that actually is compatible with the RFC
/// 4122 V4 specification of defining UUIDs (lowercase in contrast to
/// Apple's uppercase implementation).
///
/// `CoatyUUID` is an immutable, `Sendable` value type. The lowercase string
/// representation is computed once at construction time and cached, so
/// repeated ``string`` reads allocate nothing.
public struct CoatyUUID: Codable, CustomStringConvertible, Hashable, Sendable {

    private let uuid: UUID

    /// The UUID as a lowercased string.
    ///
    /// Computed once per instance at construction time and cached, so repeated
    /// reads allocate nothing.
    public let string: String

    /// Creates a `CoatyUUID` assigned a new random UUID.
    public init() {
        let uuid = UUID()
        self.uuid = uuid
        self.string = uuid.uuidString.lowercased()
    }

    /// Creates a `CoatyUUID` from the given UUID string.
    ///
    /// Returns `nil` if `uuidString` is not a valid RFC 4122 UUID.
    ///
    /// - Parameter uuidString: A UUID string, upper- or lowercase.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else {
            return nil
        }
        self.uuid = uuid
        self.string = uuid.uuidString.lowercased()
    }

    // MARK: - Codable methods.

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.uuid = try container.decode(UUID.self)
        self.string = uuid.uuidString.lowercased()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.string)
    }

    // MARK: - Hashable / Equatable methods.

    public static func == (lhs: CoatyUUID, rhs: CoatyUUID) -> Bool {
        return lhs.uuid == rhs.uuid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.uuid)
    }

    // MARK: - Custom String Convertible.

    public var description: String {
        return self.string
    }
}
