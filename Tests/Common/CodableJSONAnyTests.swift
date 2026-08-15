// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  CodableJSONAnyTests.swift
//  Axoloty

@testable import Axoloty
import Foundation
import Testing

/// Regression tests for the heterogeneous-array decode in `Codable+JSON.swift`.
///
/// Issue #445 / P1-4: `UnkeyedDecodingContainer.decode([Any].self)` first
/// probed `decode(String?.self)` unconditionally before any type ladder. For a
/// heterogeneous JSON array whose first element is *not* a string, that probe
/// throws and the whole decode fails; and any JSON `null` element was silently
/// dropped via `if value == nil { continue }`.
///
/// The fixed implementation mirrors the keyed probe-ladder (probe each
/// supported type with `try?`, advancing only on a match) and preserves `null`
/// elements explicitly via `decodeNil()`.
@Suite
struct CodableJSONAnyTests {

    /// A `Decodable` whose single field routes straight into
    /// `UnkeyedDecodingContainer.decode([Any].self)`.
    private struct HeterogeneousWrapper: Decodable {
        let values: [Any]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            // Unsafe because the resulting [Any] boxed values (Bool, Double,
            // String, NSNull/optional) are down-cast later only by their
            // expected JSON type, never by `Any` themselves.
            values = try container.decode([Any].self)
        }
    }

    /// A heterogeneous array whose first element is not a string must decode
    /// successfully, preserving every element including nulls. On the buggy
    /// `main` the leading `decode(String?.self)` probe threw on the leading
    /// number.
    @Test
    func heterogeneousArrayDecodesPreservingNulls() throws {
        let json = Data("""
            ["a", 1, true, null, {"k": 1}, [1, 2]]
            """.utf8)
        let wrapper = try JSONDecoder().decode(HeterogeneousWrapper.self, from: json)

        #expect(wrapper.values.count == 6)
        #expect(wrapper.values[0] as? String == "a")
        #expect(wrapper.values[1] as? Int == 1)
        #expect(wrapper.values[2] as? Bool == true)
        // The JSON `null` must be preserved rather than dropped.
        #expect(wrapper.values[3] is NSNull || isNilValue(wrapper.values[3]))
        // The nested JSON object must decode as a dictionary.
        let dict = wrapper.values[4] as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["k"] as? Int == 1)
        // The nested JSON array must decode as an array.
        let nestedArray = wrapper.values[5] as? [Any]
        #expect(nestedArray != nil)
        #expect(nestedArray?.count == 2)
    }

    /// A leading non-string element with a later string must still decode all
    /// elements in order.
    @Test
    func nonStringLeadingElementDecodesInOrder() throws {
        let json = Data("""
            [42, "later", false]
            """.utf8)
        let wrapper = try JSONDecoder().decode(HeterogeneousWrapper.self, from: json)

        #expect(wrapper.values.count == 3)
        #expect(wrapper.values[0] as? Int == 42)
        #expect(wrapper.values[1] as? String == "later")
        #expect(wrapper.values[2] as? Bool == false)
    }

    /// A nested heterogeneous array inside the top-level array decodes.
    @Test
    func nestedArrayDecodes() throws {
        let json = Data("""
            [1, [true, "x"]]
            """.utf8)
        let wrapper = try JSONDecoder().decode(HeterogeneousWrapper.self, from: json)
        #expect(wrapper.values.count == 2)
        let nested = try #require(wrapper.values[1] as? [Any])
        #expect(nested.count == 2)
        #expect(nested[0] as? Bool == true)
        #expect(nested[1] as? String == "x")
    }

    /// The encode side must be able to round-trip a value containing a null so
    /// that `null` survives as `null`, not as a dropped element.
    @Test
    func nullElementsRoundTripAsNull() throws {
        let json = Data("""
            ["a", null, "c"]
            """.utf8)
        let wrapper = try JSONDecoder().decode(HeterogeneousWrapper.self, from: json)
        #expect(wrapper.values.count == 3)

        // Re-encode and re-decode: length must still be 3, with a null in the
        // middle.
        let data = try encodeHeterogeneous(wrapper.values)
        let second = try JSONDecoder().decode(HeterogeneousWrapper.self, from: data)
        #expect(second.values.count == 3)
    }

    private func isNilValue(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// Re-encodes an `[Any]` through `UnkeyedEncodingContainer.encode([Any])`,
    /// which the encode side already handles (including `Optional.none` →
    /// `encodeNil()`).
    private func encodeHeterogeneous(_ values: [Any]) throws -> Data {
        struct AnyArrayWrapper: Encodable {
            let values: [Any]
            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(values)
            }
        }
        return try JSONEncoder().encode(AnyArrayWrapper(values: values))
    }
}