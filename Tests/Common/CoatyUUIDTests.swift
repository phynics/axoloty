//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  CoatyUUIDTests.swift
//  Axoloty
//

import Axoloty
import Foundation
import Testing

/// Focused value-semantic and wire-round-trip tests for ``CoatyUUID``.
///
/// Locks in the immutable, ``Sendable`` value-type behavior: the lowercase
/// ``CoatyUUID/string`` is cached at construction time, equality and hashing
/// are driven by the underlying `UUID`, and the wire form remains a bare
/// lowercase UUID string for CoatyJS compatibility.
@Suite
struct CoatyUUIDTests {

    // MARK: - Lowercase string

    @Test
    func defaultInitProducesLowercaseString() {
        let uuid = CoatyUUID()
        #expect(uuid.string == uuid.string.lowercased())
    }

    @Test
    func lowercaseInputIsPreserved() throws {
        let uuid = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        #expect(uuid.string == "550e8400-e29b-41d4-a716-446655440000")
    }

    @Test
    func uppercaseInputIsLowercased() throws {
        let uuid = try #require(CoatyUUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        #expect(uuid.string == "550e8400-e29b-41d4-a716-446655440000")
    }

    // MARK: - Failable initializer

    @Test
    func invalidUUIDStringsProduceNil() {
        for invalid in ["", "not-a-uuid", "00000000-0000-0000-0000",
                        "00000000/0000/0000/0000/000000000000"] {
            #expect(CoatyUUID(uuidString: invalid) == nil, "expected nil for \(invalid)")
        }
    }

    // MARK: - Equality

    @Test
    func sameUnderlyingUUIDIsEqualRegardlessOfInputCase() throws {
        let a = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let b = try #require(CoatyUUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        #expect(a == b)
    }

    @Test
    func differentUUIDsAreUnequal() throws {
        let a = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let b = try #require(CoatyUUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        #expect(a != b)
    }

    // MARK: - Hashing

    @Test
    func equalUUIDsCollapseAsDictionaryKey() throws {
        let key = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let lookup = try #require(CoatyUUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        var dict: [CoatyUUID: String] = [key: "value"]
        #expect(dict[lookup] == "value")
        dict[lookup] = "updated"
        #expect(dict.count == 1)
        #expect(dict[key] == "updated")
    }

    @Test
    func equalUUIDsCollapseInSet() throws {
        let a = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let b = try #require(CoatyUUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        #expect(Set([a, b]).count == 1)
    }

    // MARK: - Codable round trip

    @Test
    func codableRoundTripPreservesValue() throws {
        let uuid = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let decoded = try JSONDecoder().decode(CoatyUUID.self, from: JSONEncoder().encode(uuid))
        #expect(decoded == uuid)
        #expect(decoded.string == uuid.string)
    }

    @Test
    func encodingProducesBareLowercaseString() throws {
        let uuid = try #require(CoatyUUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        let data = try JSONEncoder().encode(uuid)
        #expect(String(data: data, encoding: .utf8) == "\"550e8400-e29b-41d4-a716-446655440000\"")
    }

    @Test
    func decodingLowerAndUppercaseProduceEqualValues() throws {
        let lower = try JSONDecoder().decode(CoatyUUID.self,
                                             from: "\"550e8400-e29b-41d4-a716-446655440000\"".data(using: .utf8)!)
        let upper = try JSONDecoder().decode(CoatyUUID.self,
                                             from: "\"550E8400-E29B-41D4-A716-446655440000\"".data(using: .utf8)!)
        #expect(lower == upper)
        #expect(lower.string == "550e8400-e29b-41d4-a716-446655440000")
    }

    // MARK: - Value semantics

    @Test
    func copyIsIndependentEqualValue() {
        let original = CoatyUUID()
        let copy = original
        #expect(original == copy)
        #expect(original.string == copy.string)
    }

    // MARK: - CustomStringConvertible

    @Test
    func descriptionMatchesString() throws {
        let uuid = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        #expect(uuid.description == uuid.string)
        #expect("\(uuid)" == "550e8400-e29b-41d4-a716-446655440000")
    }

    // MARK: - Sendable

    @Test
    func sendableValueCrossesActorBoundary() async throws {
        let uuid = try #require(CoatyUUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let echoed = await Self.echo(uuid)
        #expect(echoed == uuid)
    }

    /// Crossing into a nonisolated async function requires a ``Sendable``
    /// value under strict concurrency; this compiles only because
    /// ``CoatyUUID`` is `Sendable`.
    private static func echo(_ uuid: CoatyUUID) async -> CoatyUUID {
        uuid
    }
}
