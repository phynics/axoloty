// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Testing

@Suite
struct CBORDiagnosticNotationTests {

    private func decode(_ hex: String) throws -> CBORValue {
        var decoder = CBORDecoder(Self.bytes(hex))
        return try decoder.decode()
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex)
        var output: [UInt8] = []
        var high: UInt8?
        for character in digits {
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
    func rendersIntegers() throws {
        #expect(CBORDiagnosticNotation.render(try decode("00")) == "0")
        #expect(CBORDiagnosticNotation.render(try decode("17")) == "23")
        #expect(CBORDiagnosticNotation.render(try decode("1818")) == "24")
        #expect(CBORDiagnosticNotation.render(try decode("1b000000e8d4a51000")) == "1000000000000")
        #expect(CBORDiagnosticNotation.render(try decode("20")) == "-1")
        #expect(CBORDiagnosticNotation.render(try decode("29")) == "-10")
        #expect(CBORDiagnosticNotation.render(try decode("3863")) == "-100")
        #expect(CBORDiagnosticNotation.render(try decode("3903e7")) == "-1000")
        #expect(CBORDiagnosticNotation.render(try decode("3bffffffffffffffff")) == "-18446744073709551616")
    }

    @Test
    func rendersStrings() throws {
        #expect(CBORDiagnosticNotation.render(try decode("40")) == "h''")
        #expect(CBORDiagnosticNotation.render(try decode("4401020304")) == "h'01020304'")
        #expect(CBORDiagnosticNotation.render(try decode("60")) == "\"\"")
        #expect(CBORDiagnosticNotation.render(try decode("6449455446")) == "\"IETF\"")
        #expect(CBORDiagnosticNotation.render(try decode("62c3bc")) == "\"\u{00fc}\"")
        #expect(CBORDiagnosticNotation.render(try decode("63e6b0b4")) == "\"\u{6c34}\"")
    }

    @Test
    func rendersIndefiniteStrings() throws {
        #expect(CBORDiagnosticNotation.render(try decode("5f42010243030405ff")) == "(_ h'0102', h'030405')")
        #expect(CBORDiagnosticNotation.render(try decode("7f657374726561646d696e67ff")) == "(_ \"strea\", \"ming\")")
    }

    @Test
    func rendersContainers() throws {
        #expect(CBORDiagnosticNotation.render(try decode("80")) == "[]")
        #expect(CBORDiagnosticNotation.render(try decode("83010203")) == "[1, 2, 3]")
        #expect(CBORDiagnosticNotation.render(try decode("9f010203ff")) == "[_ 1, 2, 3]")
        #expect(CBORDiagnosticNotation.render(try decode("a0")) == "{}")
        #expect(CBORDiagnosticNotation.render(try decode("a201020304")) == "{1: 2, 3: 4}")
        #expect(CBORDiagnosticNotation.render(try decode("bf616101ff")) == "{_ \"a\": 1}")
    }

    @Test
    func rendersTags() throws {
        #expect(CBORDiagnosticNotation.render(try decode("c11a514b67b0")) == "1(1363896240)")
        #expect(CBORDiagnosticNotation.render(try decode("c1fb41d452d9ec200000")) == "1(1363896240.5)")
        #expect(CBORDiagnosticNotation.render(try decode("c074323031332d30332d32315432303a30343a30305a")) == "0(\"2013-03-21T20:04:00Z\")")
    }

    @Test
    func rendersSimpleAndBooleans() throws {
        #expect(CBORDiagnosticNotation.render(try decode("f0")) == "simple(16)")
        #expect(CBORDiagnosticNotation.render(try decode("f8ff")) == "simple(255)")
        #expect(CBORDiagnosticNotation.render(try decode("f4")) == "false")
        #expect(CBORDiagnosticNotation.render(try decode("f5")) == "true")
        #expect(CBORDiagnosticNotation.render(try decode("f6")) == "null")
        #expect(CBORDiagnosticNotation.render(try decode("f7")) == "undefined")
    }

    @Test
    func rendersFloats() throws {
        #expect(CBORDiagnosticNotation.render(try decode("f93e00")) == "1.5")
        #expect(CBORDiagnosticNotation.render(try decode("f97bff")) == "65504.0")
        #expect(CBORDiagnosticNotation.render(try decode("fa47c35000")) == "100000.0")
        #expect(CBORDiagnosticNotation.render(try decode("fb3ff199999999999a")) == "1.1")
        #expect(CBORDiagnosticNotation.render(try decode("f90000")) == "0.0")
        #expect(CBORDiagnosticNotation.render(try decode("f98000")) == "-0.0")
        #expect(CBORDiagnosticNotation.render(try decode("f97c00")) == "Infinity")
        #expect(CBORDiagnosticNotation.render(try decode("f9fc00")) == "-Infinity")
        #expect(CBORDiagnosticNotation.render(try decode("f97e00")) == "NaN")
    }

    @Test
    func parseAcceptsDefiniteAndIndefiniteForms() throws {
        #expect(try CBORDiagnosticNotation.parse("[1, 2, 3]") == .array([.unsigned(1), .unsigned(2), .unsigned(3)], indefinite: false))
        #expect(try CBORDiagnosticNotation.parse("[_ 1, 2, 3]") == .array([.unsigned(1), .unsigned(2), .unsigned(3)], indefinite: true))
        #expect(try CBORDiagnosticNotation.parse("{_ \"a\": 1}") == .map([CBORMapEntry(key: .textString("a"), value: .unsigned(1))], indefinite: true))
        #expect(try CBORDiagnosticNotation.parse("(_ h'0102', h'03')") == .chunkedByteString([[1, 2], [3]]))
        #expect(try CBORDiagnosticNotation.parse("(_ \"strea\", \"ming\")") == .chunkedTextString(["strea", "ming"]))
    }

    @Test
    func parseHandlesTagsAndScalars() throws {
        #expect(try CBORDiagnosticNotation.parse("1(1363896240)") == .tag(1, .unsigned(1_363_896_240)))
        #expect(try CBORDiagnosticNotation.parse("simple(255)") == .simple(255))
        #expect(try CBORDiagnosticNotation.parse("true") == .boolean(true))
        #expect(try CBORDiagnosticNotation.parse("false") == .boolean(false))
        #expect(try CBORDiagnosticNotation.parse("null") == .null)
        #expect(try CBORDiagnosticNotation.parse("undefined") == .undefined)
        #expect(try CBORDiagnosticNotation.parse("-1") == .negative(0))
        #expect(try CBORDiagnosticNotation.parse("-18446744073709551616") == .negative(.max))
    }

    @Test
    func parseRejectsMalformedInput() {
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("[1, 2") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("1 2") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("h'abc'") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("(_ h'01', \"a\")") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("wat") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("1.") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("1e") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("1e+") }
        #expect(throws: CBORParseError.self) { try CBORDiagnosticNotation.parse("1 (2)") }
    }

    @Test
    func parsePreservesNegativeFloatSigns() throws {
        #expect(try CBORDiagnosticNotation.parse("-1.5") == .float(-1.5))
        #expect(CBORDiagnosticNotation.render(try CBORDiagnosticNotation.parse("-0.0")) == "-0.0")
        #expect(try CBORDiagnosticNotation.parse("-0") == .unsigned(0))
    }

    @Test
    func parseCanonicalizesEmptyChunkedStringToText() throws {
        #expect(try CBORDiagnosticNotation.parse("(_)") == .chunkedTextString([]))
    }

    @Test
    func decoderRejectsMismatchedIndefiniteChunks() {
        // Indefinite byte string containing a definite text chunk.
        #expect(throws: CBORDecodingError.self) { try decode("5f6161ff") }
        // Indefinite text string containing a definite byte chunk.
        #expect(throws: CBORDecodingError.self) { try decode("7f4161ff") }
    }

    @Test
    func parseRoundTripsThroughDeterministicEncoder() throws {
        let samples = [
            "0",
            "-1",
            "18446744073709551615",
            "-18446744073709551616",
            "1.5",
            "100000.0",
            "\"IETF\"",
            "h'01020304'",
            "[1, 2, 3]",
            "{1: 2, 3: 4}",
            "37(h'00112233445566778899aabbccddeeff')",
            "simple(16)",
            "NaN",
            "Infinity",
            "-Infinity",
        ]
        for sample in samples {
            let parsed = try CBORDiagnosticNotation.parse(sample)
            let encoded = CBOREncoder.encode(parsed)
            let rendered = try CBORDiagnosticNotation.render(bytes: encoded)
            let reparsed = try CBORDiagnosticNotation.parse(rendered)
            #expect(CBOREncoder.encode(reparsed) == encoded, "round trip failed for \(sample)")
        }
    }

    @Test
    func deterministicEncoderSortsMapKeys() {
        let value = CBORValue.map([
            CBORMapEntry(key: .unsigned(2), value: .unsigned(0)),
            CBORMapEntry(key: .unsigned(1), value: .unsigned(0)),
        ], indefinite: false)
        #expect(CBOREncoder.encode(value) == [0xA2, 0x01, 0x00, 0x02, 0x00])
    }

    @Test
    func deterministicEncoderUsesShortestFloatWidth() {
        #expect(CBOREncoder.encode(.float(1.5)) == [0xFA, 0x3F, 0xC0, 0x00, 0x00])
        #expect(CBOREncoder.encode(.float(100_000.0)) == [0xFA, 0x47, 0xC3, 0x50, 0x00])
        #expect(CBOREncoder.encode(.float(1.1)) == [0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A])
        #expect(CBOREncoder.encode(.float(.nan)) == [0xF9, 0x7E, 0x00])
        #expect(CBOREncoder.encode(.float(.infinity)) == [0xFA, 0x7F, 0x80, 0x00, 0x00])
        #expect(CBOREncoder.encode(.float(-.infinity)) == [0xFA, 0xFF, 0x80, 0x00, 0x00])
    }
}
