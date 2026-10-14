// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct InspectorCBORCodecTests {

    private let codec = InspectorCBORCodec()

    private static func bytes(_ hex: String) -> [UInt8] {
        var output: [UInt8] = []
        var high: UInt8?
        for character in hex {
            guard let nibble = character.hexDigitValue else { continue }
            if let pending = high {
                output.append((pending << 4) | UInt8(nibble))
                high = nil
            } else {
                high = UInt8(nibble)
            }
        }
        return output
    }

    @Test
    func detectsJSONPayload() {
        #expect(codec.format(of: Array(#"{"name":"agent"}"#.utf8)) == .json)
        #expect(codec.format(of: Array("[1, 2, 3]".utf8)) == .json)
        #expect(codec.format(of: Array("  null".utf8)) == .json)
        #expect(codec.format(of: Array("true".utf8)) == .json)
    }

    @Test
    func detectsCBORPayload() {
        #expect(codec.format(of: Self.bytes("a1616101")) == .cbor)
        #expect(codec.format(of: Self.bytes("83010203")) == .cbor)
        #expect(codec.format(of: Self.bytes("4401020304")) == .cbor)
    }

    @Test
    func reportsUnknownPayload() {
        #expect(codec.format(of: []) == .unknown)
        #expect(codec.format(of: Self.bytes("ff")) == .unknown)
        #expect(codec.format(of: Self.bytes("18")) == .unknown)
    }

    @Test
    func autoDetectionResolvesAmbiguousBytesToJSON() {
        // `0x30` is the JSON number `0` and the CBOR negative integer `-17`.
        #expect(codec.format(of: Self.bytes("30")) == .json)
        #expect(codec.format(of: Self.bytes("30"), encoding: .auto) == .json)
    }

    @Test
    func explicitEncodingOverridesAmbiguousBytes() {
        #expect(codec.format(of: Self.bytes("30"), encoding: .json) == .json)
        #expect(codec.format(of: Self.bytes("30"), encoding: .cbor) == .cbor)
    }

    @Test
    func explicitEncodingRejectsAMismatch() {
        // A CBOR map is not valid JSON, and a JSON object is not a complete CBOR item.
        #expect(codec.format(of: Self.bytes("a1616101"), encoding: .json) == .unknown)
        #expect(codec.format(of: Array(#"{"a":1}"#.utf8), encoding: .cbor) == .unknown)
    }

    @Test
    func decodesAndRendersDiagnosticNotation() throws {
        let notation = try codec.diagnosticNotation(of: Self.bytes("a26161016162820203"))
        #expect(notation == "{\"a\": 1, \"b\": [2, 3]}")
    }

    @Test
    func projectsMapToJSONObject() throws {
        let object = try #require(codec.jsonObject(of: Self.bytes("a26161016162820203")))
        #expect(object["a"] as? Int == 1)
        #expect((object["b"] as? [Any])?.count == 2)
    }

    @Test
    func projectsUUIDTagToText() throws {
        // 37(h'00112233445566778899aabbccddeeff')
        let object = try #require(codec.jsonObject(of: Self.bytes("a1686f626a6563744964d8255000112233445566778899aabbccddeeff")))
        #expect(object["objectId"] as? String == "00112233-4455-6677-8899-AABBCCDDEEFF")
    }

    @Test
    func projectsByteStringToBase64() throws {
        let object = try #require(codec.jsonObject(of: Self.bytes("a1616243010203")))
        #expect(object["b"] as? String == "AQID")
    }

    @Test
    func projectsNestedValues() throws {
        let object = try #require(codec.jsonObject(of: Self.bytes("a56161016162f56163f66164f76165f0")))
        #expect(object["a"] as? Int == 1)
        #expect(object["b"] as? Bool == true)
        #expect(object["c"] is NSNull)
        #expect(object["d"] is NSNull)
        #expect(object["e"] as? Int == 16)
    }

    @Test
    func emitsSortedJSONText() throws {
        let text = try #require(codec.jsonText(of: Self.bytes("a2616201616102")))
        #expect(text == #"{"a":2,"b":1}"#)
    }

    @Test
    func jsonTextIsNilForNonMapPayload() {
        #expect(codec.jsonText(of: Self.bytes("83010203")) == nil)
        #expect(codec.jsonObject(of: Self.bytes("83010203")) == nil)
    }

    @Test
    func rejectsTruncatedPayload() {
        #expect(throws: CBORDecodingError.self) {
            try codec.decodedValue(of: Self.bytes("18"))
        }
    }

    @Test
    func rejectsTrailingBytes() {
        #expect(throws: CBORDecodingError.self) {
            try codec.decodedValue(of: Self.bytes("0000"))
        }
    }

    @Test
    func enforcesDepthLimit() {
        // 33 nested one-element arrays exceeds the profile depth of 32.
        var bytes: [UInt8] = Array(repeating: 0x81, count: 33)
        bytes.append(0x00)
        #expect(throws: CBORDecodingError.self) {
            try codec.decodedValue(of: bytes)
        }
    }

    @Test
    func decodesHalfPrecision() throws {
        var decoder = CBORDecoder(Self.bytes("f93e00"))
        #expect(try decoder.decode() == .float(1.5))
    }
}
