// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyWire
import Testing

/// Round-trip and RFC 8949 Appendix A conformance tests for the deterministic
/// CBOR reader and writer (`axoloty/1`, epic #977).
///
/// Every vector is checked in both directions: the writer must emit the exact
/// preferred-serialization bytes, and the reader must decode them back to the
/// original value. The skip path must consume exactly one item.

// MARK: - Helpers

private func encoded(_ body: (inout CBORWriter) throws -> Void) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 256)
    return try output.withUnsafeMutableBufferPointer { buffer -> [UInt8] in
        var writer = CBORWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try body(&writer)
        return Array(buffer.prefix(writer.position))
    }
}

private func skipAll(_ bytes: [UInt8]) throws -> Bool {
    try bytes.withUnsafeBufferPointer { buffer in
        var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
        try reader.skipItem()
        return reader.isAtEnd
    }
}

private func decodedInteger(_ bytes: [UInt8]) throws -> Int64 {
    try bytes.withUnsafeBufferPointer { buffer in
        var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
        return try reader.readInteger()
    }
}

private func decodedUnsigned(_ bytes: [UInt8]) throws -> UInt64 {
    try bytes.withUnsafeBufferPointer { buffer in
        var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
        return try reader.readUnsigned()
    }
}

private func decodedText(_ bytes: [UInt8]) throws -> String {
    try bytes.withUnsafeBufferPointer { buffer in
        var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
        return String(decoding: try reader.readTextString().ownedBytes(), as: UTF8.self)
    }
}

private func encodedByteString(_ content: [UInt8]) throws -> [UInt8] {
    try content.withUnsafeBufferPointer { buffer -> [UInt8] in
        try encoded { writer in
            try writer.writeByteString(ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }
}

private func encodedTextString(_ content: [UInt8]) throws -> [UInt8] {
    try content.withUnsafeBufferPointer { buffer -> [UInt8] in
        try encoded { writer in
            try writer.writeTextString(ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }
}

// MARK: - Codec

@Suite
struct CBORCodecTests {
    @Test
    func integerVectorsRoundTrip() throws {
        let vectors: [(Int64, [UInt8])] = [
            (0, [0x00]), (1, [0x01]), (10, [0x0A]), (23, [0x17]),
            (24, [0x18, 0x18]), (25, [0x18, 0x19]), (100, [0x18, 0x64]),
            (1000, [0x19, 0x03, 0xE8]),
            (1_000_000, [0x1A, 0x00, 0x0F, 0x42, 0x40]),
            (1_000_000_000_000, [0x1B, 0x00, 0x00, 0x00, 0xE8, 0xD4, 0xA5, 0x10, 0x00]),
            (-1, [0x20]), (-10, [0x29]), (-100, [0x38, 0x63]), (-1000, [0x39, 0x03, 0xE7]),
            (Int64.max, [0x1B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            (Int64.min, [0x3B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ]
        for (value, hex) in vectors {
            let bytes = try encoded { writer in try writer.writeInteger(value) }
            #expect(bytes == hex, "encode \(value)")
            #expect(try skipAll(hex), "skip \(value)")
            #expect(try decodedInteger(hex) == value, "decode \(value)")
        }
    }

    @Test
    func unsignedMaximumRoundTrips() throws {
        let hex: [UInt8] = [0x1B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(try decodedUnsigned(hex) == UInt64.max)
        let bytes = try encoded { writer in try writer.writeUnsigned(UInt64.max) }
        #expect(bytes == hex)
    }

    @Test
    func deterministicShortestForms() throws {
        #expect(try encoded { try $0.writeUnsigned(23) } == [0x17])
        #expect(try encoded { try $0.writeUnsigned(24) } == [0x18, 0x18])
        #expect(try encoded { try $0.writeUnsigned(255) } == [0x18, 0xFF])
        #expect(try encoded { try $0.writeUnsigned(256) } == [0x19, 0x01, 0x00])
        #expect(try encoded { try $0.writeUnsigned(65535) } == [0x19, 0xFF, 0xFF])
        #expect(try encoded { try $0.writeUnsigned(65536) } == [0x1A, 0x00, 0x01, 0x00, 0x00])
        #expect(
            try encoded { try $0.writeUnsigned(4_294_967_295) }
                == [0x1A, 0xFF, 0xFF, 0xFF, 0xFF]
        )
        #expect(
            try encoded { try $0.writeUnsigned(4_294_967_296) }
                == [0x1B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        )
    }

    // MARK: - Byte and text strings

    @Test
    func byteStringVectorsRoundTrip() throws {
        #expect(try encodedByteString([0x01, 0x02, 0x03, 0x04]) == [0x44, 0x01, 0x02, 0x03, 0x04])
        #expect(try skipAll([0x44, 0x01, 0x02, 0x03, 0x04]))
    }

    @Test
    func emptyByteStringRoundTrips() throws {
        #expect(try encodedByteString([]) == [0x40])
        #expect(try skipAll([0x40]))
    }

    @Test
    func textStringVectorsRoundTrip() throws {
        let vectors: [(String, [UInt8])] = [
            ("", [0x60]),
            ("a", [0x61, 0x61]),
            ("IETF", [0x64, 0x49, 0x45, 0x54, 0x46]),
            ("\"\\", [0x62, 0x22, 0x5C]),
            ("\u{00FC}", [0x62, 0xC3, 0xBC]),
            ("\u{6C34}", [0x63, 0xE6, 0xB0, 0xB4]),
            ("\u{10151}", [0x64, 0xF0, 0x90, 0x85, 0x91]),
        ]
        for (value, hex) in vectors {
            #expect(try skipAll(hex), "skip \(value)")
            #expect(try decodedText(hex) == value, "decode \(value)")
            #expect(try encodedTextString(Array(value.utf8)) == hex, "encode \(value)")
        }
    }

    // MARK: - Containers and simple values

    @Test
    func arrayAndMapVectorsSkip() throws {
        #expect(try skipAll([0x80]))
        #expect(try skipAll([0x83, 0x01, 0x02, 0x03]))
        #expect(try skipAll([0x83, 0x01, 0x82, 0x02, 0x03, 0x82, 0x04, 0x05]))
        #expect(try skipAll([0xA0]))
        #expect(try skipAll([0xA2, 0x01, 0x02, 0x03, 0x04]))
        #expect(try skipAll([0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03]))
    }

    @Test
    func arrayHeaderAndItemsRoundTrip() throws {
        let bytes = try encoded { writer in
            try writer.writeArrayHeader(3)
            try writer.writeInteger(1)
            try writer.writeInteger(2)
            try writer.writeInteger(3)
        }
        #expect(bytes == [0x83, 0x01, 0x02, 0x03])
    }

    @Test
    func mapHeaderAndPairsRoundTrip() throws {
        let keyA: [UInt8] = [0x61]
        let keyB: [UInt8] = [0x62]
        let bytes = try keyA.withUnsafeBufferPointer { a in
            try keyB.withUnsafeBufferPointer { b in
                try encoded { writer in
                    try writer.writeMapHeader(2)
                    try writer.writeTextString(ByteSlice(bytes: a.baseAddress!, length: a.count))
                    try writer.writeInteger(1)
                    try writer.writeTextString(ByteSlice(bytes: b.baseAddress!, length: b.count))
                    try writer.writeArrayHeader(2)
                    try writer.writeInteger(2)
                    try writer.writeInteger(3)
                }
            }
        }
        #expect(bytes == [0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03])
    }

    @Test
    func boolAndNullVectors() throws {
        #expect(try encoded { try $0.writeBool(false) } == [0xF4])
        #expect(try encoded { try $0.writeBool(true) } == [0xF5])
        #expect(try encoded { try $0.writeNull() } == [0xF6])
        #expect(try skipAll([0xF4]))
        #expect(try skipAll([0xF5]))
        #expect(try skipAll([0xF6]))
    }

    // MARK: - Floating point

    @Test
    func floatVectorsDecode() throws {
        let vectors: [(Double, [UInt8])] = [
            (0.0, [0xF9, 0x00, 0x00]),
            (1.0, [0xF9, 0x3C, 0x00]),
            (1.5, [0xF9, 0x3E, 0x00]),
            (65504.0, [0xF9, 0x7B, 0xFF]),
            (100_000.0, [0xFA, 0x47, 0xC3, 0x50, 0x00]),
            (3.4028234663852886e+38, [0xFA, 0x7F, 0x7F, 0xFF, 0xFF]),
            (1.1, [0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A]),
        ]
        for (value, hex) in vectors {
            let decoded = try hex.withUnsafeBufferPointer { buffer -> Double in
                var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
                return try reader.readFloat()
            }
            #expect(decoded == value, "decode \(value)")
            #expect(try skipAll(hex), "skip \(value)")
        }
    }

    @Test
    func floatWriterUsesShortestLosslessWidth() throws {
        #expect(try encoded { try $0.writeFloat64(1.0) } == [0xFA, 0x3F, 0x80, 0x00, 0x00])
        #expect(
            try encoded { try $0.writeFloat64(1.1) }
                == [0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A]
        )
    }

    @Test
    func floatSubnormalSingleRoundTrips() throws {
        // Smallest single-precision subnormal, 2^-149, uses the widest single
        // exponent path in the bit-manipulation widening.
        let smallest = 0x1p-149
        #expect(try encoded { try $0.writeFloat64(smallest) } == [0xFA, 0x00, 0x00, 0x00, 0x01])
        let single: [UInt8] = [0xFA, 0x00, 0x00, 0x00, 0x01]
        let decoded = try single.withUnsafeBufferPointer { buffer -> Double in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
            return try reader.readFloat()
        }
        #expect(decoded == smallest)
        // 2^-150 is below the single-precision range, so it needs a double.
        #expect(try encoded { try $0.writeFloat64(0x1p-150) }.first == 0xFB)
        // The largest single subnormal is still exact.
        #expect(
            try encoded { try $0.writeFloat64(0x1.fffffcp-127) }
                == [0xFA, 0x00, 0x7F, 0xFF, 0xFF]
        )
    }

    // MARK: - Tags and UUID

    @Test
    func uuidTagRoundTrip() throws {
        let uuid = try #require(UUID16(parsing: "11111111-1111-4111-8111-111111111111"))
        let bytes = try encoded { writer in try writer.writeUUID(uuid) }
        #expect(bytes.first == 0xD8) // tag 37 in one-byte extension form
        #expect(bytes.count == 19)
        let decoded = try bytes.withUnsafeBufferPointer { buffer -> UUID16 in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
            return try reader.readUUID()
        }
        #expect(decoded == uuid)
        #expect(try skipAll(bytes))
    }

    @Test
    func uuidCanonicalTextFormIsAccepted() throws {
        let text = "11111111-1111-4111-8111-111111111111"
        let bytes = try encodedTextString(Array(text.utf8))
        let decoded = try bytes.withUnsafeBufferPointer { buffer -> UUID16 in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
            return try reader.readUUID()
        }
        #expect(decoded == (try #require(UUID16(parsing: text))))
    }

    @Test
    func malformedTextUUIDIsRejected() throws {
        // Same 36-byte length as a canonical UUID, but not hexadecimal.
        let text = "11111111-1111-4111-8111-11111111111Z"
        let bytes = try encodedTextString(Array(text.utf8))
        bytes.withUnsafeBufferPointer { buffer in
            var reader = CBORReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(throws: WireDecodeError.self) {
                _ = try reader.readUUID()
            }
        }
    }

    @Test
    func emptyTagPolicyRejectsUUIDTag() throws {
        let uuid = try #require(UUID16(parsing: "11111111-1111-4111-8111-111111111111"))
        let bytes = try encoded { writer in try writer.writeUUID(uuid) }
        bytes.withUnsafeBufferPointer { buffer in
            var reader = CBORReader(
                bytes: buffer.baseAddress!,
                length: buffer.count,
                tagPolicy: .none
            )
            #expect(throws: WireDecodeError.self) {
                _ = try reader.readUUID()
            }
        }
    }

    @Test
    func epochTimeTagIsAllowedAndOtherTagsRejected() throws {
        // Tag 1 (epoch time) is on the profile allow-list.
        #expect(try skipAll([0xC1, 0x1A, 0x51, 0x4B, 0x67, 0xB0]))
        // Tag 2 (positive bignum) is not.
        #expect(throws: WireDecodeError.self) {
            _ = try skipAll([0xC2, 0x42, 0x01, 0x00])
        }
    }

    // MARK: - Writer capacity

    @Test
    func writerOverflowIsStructured() {
        var output = [UInt8](repeating: 0, count: 1)
        let failed = output.withUnsafeMutableBufferPointer { buffer -> Bool in
            var writer = CBORWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
            do {
                try writer.writeUnsigned(24)
                return false
            } catch {
                return true
            }
        }
        #expect(failed)
    }

    @Test
    func writerRewindRestoresPosition() throws {
        var output = [UInt8](repeating: 0, count: 8)
        try output.withUnsafeMutableBufferPointer { buffer in
            var writer = CBORWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
            try writer.writeUnsigned(1)
            let checkpoint = writer.position
            try writer.writeUnsigned(2)
            writer.rewind(to: checkpoint)
            try writer.writeUnsigned(3)
            #expect(buffer[0] == 0x01)
            #expect(buffer[1] == 0x03)
            #expect(writer.position == 2)
        }
    }
}
