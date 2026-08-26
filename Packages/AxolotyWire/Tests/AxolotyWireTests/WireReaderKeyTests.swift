// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Regression tests for semantic JSON object-member name matching.
@Suite("WireReader key matching")
struct WireReaderKeyTests {
    @Test("ordinary keys remain readable")
    func ordinaryKeyMatches() {
        let bytes = Array(#"{"ordinary":7}"#.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(reader.readInt("ordinary") == 7)
        }
    }

    @Test("Unicode escapes match their decoded key")
    func unicodeEscapeMatches() {
        let bytes = Array(#"{"io\u0053ourceId":7}"#.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(reader.readInt("ioSourceId") == 7)
        }
    }

    @Test("escaped and unescaped semantic duplicates are rejected")
    func escapedDuplicateIsRejected() {
        let json = #"{"name":1,"na\u006De":2}"#
        let bytes = Array(json.utf8)
        let error = decodeError(bytes)

        guard let error else {
            Issue.record("Expected a duplicate-field error")
            return
        }
        guard case .duplicateField = error.reason else {
            Issue.record("Expected duplicateField, got \(error.reason)")
            return
        }
        // Duplicate offsets point to the first byte of key content, after its opening quote.
        #expect(error.byteOffset == Array(#"{"name":1,""#.utf8).count)
    }

    @Test("surrogate pairs match their raw Unicode scalar")
    func surrogatePairMatches() {
        let bytes = Array(#"{"\uD83D\uDE00":7}"#.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            #expect(reader.readInt("😀") == 7)
        }
    }

    @Test("surrogate-pair escapes duplicate an equivalent raw UTF-8 key")
    func surrogatePairDuplicateIsRejected() {
        let json = #"{"😀":1,"\uD83D\uDE00":2}"#
        let error = decodeError(Array(json.utf8))

        guard let error else {
            Issue.record("Expected a duplicate-field error")
            return
        }
        guard case .duplicateField = error.reason else {
            Issue.record("Expected duplicateField, got \(error.reason)")
            return
        }
        #expect(error.byteOffset == Array(#"{"😀":1,""#.utf8).count)
    }

    @Test("invalid surrogate keys retain invalid-escape errors", arguments: [
        #"{"\uD800":1}"#,
        #"{"\uDC00":1}"#,
        #"{"\uD800\u0041":1}"#,
    ])
    func invalidSurrogateKeyIsRejected(_ json: String) {
        let bytes = Array(json.utf8)
        guard let error = decodeError(bytes) else {
            Issue.record("Expected an invalid-escape error")
            return
        }
        guard case .invalidEscape = error.reason else {
            Issue.record("Expected invalidEscape, got \(error.reason)")
            return
        }
        #expect(error.byteOffset == 2)
    }
}

private func decodeError(_ bytes: [UInt8]) -> WireDecodeError? {
    bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return nil }
        let reader = WireReader(bytes: baseAddress, length: buffer.count)
        do {
            try reader.validate()
            return nil
        } catch {
            return error as? WireDecodeError
        }
    }
}
