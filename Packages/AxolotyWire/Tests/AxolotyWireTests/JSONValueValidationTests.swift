// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if canImport(_JSONCore)
import Testing
@testable import AxolotyWire

@Suite("JSON value validation")
struct JSONValueValidationTests {
    @Test("an unaligned JSON value above the former stack copy validates")
    func unalignedLargeValueIsValid() {
        expectUnalignedValidation(for: jsonValue(padding: 600), expected: true)
    }

    @Test("an unaligned invalid JSON value above the former stack copy is rejected")
    func unalignedLargeValueIsInvalid() {
        var bytes = jsonValue(padding: 600)
        bytes.removeLast()
        expectUnalignedValidation(for: bytes, expected: false)
    }

    @Test("an unaligned value at the payload bound validates and one byte over is rejected")
    func unalignedBoundary() {
        expectUnalignedValidation(for: jsonValue(padding: 2_036), expected: true)
        expectUnalignedValidation(for: jsonValue(padding: 2_037), expected: false)
    }

    private func expectUnalignedValidation(for json: [UInt8], expected: Bool) {
        var storage = [UInt8](repeating: 0xAA, count: json.count + 1)
        storage.withUnsafeMutableBufferPointer { buffer in
            for (offset, byte) in json.enumerated() {
                buffer[offset + 1] = byte
            }
            let slice = ByteSlice(
                bytes: UnsafePointer(buffer.baseAddress! + 1),
                length: json.count
            )
            #expect(WireReader.isValidJSONValue(slice) == expected)
        }
    }

    /// Builds a complete JSON object whose only value is a long ASCII string.
    private func jsonValue(padding: Int) -> [UInt8] {
        var bytes = Array(#"{"value":""#.utf8)
        bytes.append(contentsOf: Array(repeating: 0x61, count: padding))
        bytes.append(contentsOf: Array(#""}"#.utf8))
        return bytes
    }
}
#endif
