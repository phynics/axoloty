// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Testing

@Suite
struct AxolotyMCPDecodeTests {
    @Test("Decode tool renders hexadecimal CBOR as diagnostic notation")
    func decodeHexCBORAsDiagnostic() throws {
        let result = AxolotyMCPServer.handleDecodePayload(["payload": .string("a26161016162820203")])
        #expect(result.isError == false)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text == "{\"a\": 1, \"b\": [2, 3]}")
    }

    @Test("Decode tool renders base64 CBOR as sorted JSON")
    func decodeBase64CBORAsJSON() throws {
        let result = AxolotyMCPServer.handleDecodePayload([
            "payload": .string("oWFhAQ=="),
            "encoding": .string("base64"),
            "format": .string("json"),
        ])
        #expect(result.isError == false)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text == #"{"a":1}"#)
    }

    @Test("Decode tool requires a payload")
    func decodeRequiresPayload() throws {
        let result = AxolotyMCPServer.handleDecodePayload([:])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("payload"))
    }

    @Test("Decode tool rejects an unknown encoding")
    func decodeRejectsUnknownEncoding() throws {
        let result = AxolotyMCPServer.handleDecodePayload([
            "payload": .string("00"),
            "encoding": .string("octal"),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("Invalid encoding"))
    }

    @Test("Decode tool rejects an unknown format")
    func decodeRejectsUnknownFormat() throws {
        let result = AxolotyMCPServer.handleDecodePayload([
            "payload": .string("00"),
            "format": .string("xml"),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("Invalid format"))
    }

    @Test("Decode tool reports an undecodable payload without throwing")
    func decodeReportsUndecodablePayload() throws {
        let result = AxolotyMCPServer.handleDecodePayload(["payload": .string("ff")])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("neither JSON nor"))
    }
}
